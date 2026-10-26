# shellcheck shell=bash
# Git LFS through the hub (D25): init and fetch carry LFS objects into it, the
# agent's clone checks them out and can push new ones back.
#
# All local: the "forge" is a bare repository, which git-lfs serves over its
# standalone file transfer exactly as it does the hub.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
# The filter section is what `git lfs install` writes, and what the developer
# who hit this had globally: the clone's checkout smudged through it and found
# no objects in the hub.
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Test Developer
	email = dev@example.invalid
[init]
	defaultBranch = main
[filter "lfs"]
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process
	required = true
EOF

AIRLOCK="$REPO_ROOT/bin/airlock"

if ! git lfs version >/dev/null 2>&1; then
  case_begin "lfs"
  skip "git-lfs is not on PATH"
  return 0
fi

# A forge holding one LFS file on `trunk`, and a working copy of it that is the
# developer's checkout. Pushes go through a named remote: git-lfs refuses a
# bare path given as an argument.
git init --quiet --bare -b trunk "$TMP/forge.git"
git init --quiet -b trunk "$TMP/dev"
( cd "$TMP/dev" || exit 1
  git lfs install --local >/dev/null
  git lfs track '*.bin' >/dev/null
  head -c 2048 /dev/urandom > big.bin
  echo text > file.txt
  git add .gitattributes big.bin file.txt
  git commit --quiet -m "with an lfs file"
  git remote add origin "$TMP/forge.git"
  git push --quiet origin trunk ) >/dev/null 2>&1
OID="$(git -C "$TMP/dev" lfs ls-files --long | awk '{ print $1 }')"
lfs_object() { printf '%s/lfs/objects/%s/%s/%s' "$1" "${OID:0:2}" "${OID:2:2}" "$OID"; }

# --- seeding from a remote -----------------------------------------------

case_begin "init --from-remote carries LFS objects into the hub"
assert_ok "init succeeds" "$AIRLOCK" init remote --from-remote "$TMP/forge.git"
HUB="$AIRLOCK_DATA_HOME/remote/work_dir/forge.git"
CLONE="$AIRLOCK_DATA_HOME/remote/work_dir/forge"
assert_file "$(lfs_object "$HUB")"
assert_ok "the clone has the content, not a pointer" cmp "$CLONE/big.bin" "$TMP/dev/big.bin"
assert_eq "" "$(git -C "$CLONE" status --porcelain)" "and a clean tree"

case_begin "the clone carries its own LFS filter and hooks"
# The guest has no global LFS config: what it gets is what is in the clone.
assert_eq "git-lfs filter-process" "$(git -C "$CLONE" config --local filter.lfs.process)" "filter is local"
assert_eq "true" "$(git -C "$CLONE" config --local filter.lfs.required)" "and required"
assert_file "$CLONE/.git/hooks/pre-push"

case_begin "the agent's new LFS objects reach the hub"
# Origin is a guest path; point a copy at the hub as the guest would see it.
cp -a "$CLONE" "$TMP/agent"
git -C "$TMP/agent" remote set-url origin "$HUB"
( cd "$TMP/agent" || exit 1
  git checkout --quiet -b agent/more
  head -c 1024 /dev/urandom > new.bin
  git add new.bin
  git commit --quiet -m "another lfs file" ) >/dev/null 2>&1
assert_ok "push succeeds" git -C "$TMP/agent" push --quiet origin agent/more
NEW_OID="$(git -C "$TMP/agent" lfs ls-files --long | awk '$3 == "new.bin" { print $1 }')"
assert_file "$HUB/lfs/objects/${NEW_OID:0:2}/${NEW_OID:2:2}/$NEW_OID"

# --- seeding from a local checkout ---------------------------------------

case_begin "init --from-local carries the checkout's own LFS objects"
assert_ok "init succeeds" "$AIRLOCK" init local --from-local "$TMP/dev" --project widget
assert_file "$(lfs_object "$AIRLOCK_DATA_HOME/local/work_dir/widget.git")"
assert_ok "clone has the content" cmp "$AIRLOCK_DATA_HOME/local/work_dir/widget/big.bin" "$TMP/dev/big.bin"

case_begin "objects a local checkout lacks come from its origin"
GIT_LFS_SKIP_SMUDGE=1 git clone --quiet "$TMP/forge.git" "$TMP/sparse" >/dev/null 2>&1
rm -rf "$TMP/sparse/.git/lfs/objects"
assert_ok "init succeeds" "$AIRLOCK" init sparse --from-local "$TMP/sparse" --project widget
assert_file "$(lfs_object "$AIRLOCK_DATA_HOME/sparse/work_dir/widget.git")"
assert_ok "clone has the content" cmp "$AIRLOCK_DATA_HOME/sparse/work_dir/widget/big.bin" "$TMP/dev/big.bin"

case_begin "objects nowhere to be found fail init, and leave nothing"
git -C "$TMP/sparse" remote remove origin
OUT="$TMP/orphan-err"
if "$AIRLOCK" init orphan --from-local "$TMP/sparse" --project widget > "$OUT" 2>&1; then
  _fail "init succeeded without the LFS objects"
else
  _pass
fi
assert_contains "$OUT" "lacks Git LFS objects" "says why"
assert_absent "$AIRLOCK_DATA_HOME/orphan"

case_begin "an LFS repository without git-lfs is refused by name"
NOLFS_PATH=""
IFS=: read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  [ -x "$d/git-lfs" ] || NOLFS_PATH="${NOLFS_PATH:+$NOLFS_PATH:}$d"
done
OUT="$TMP/nolfs-err"
if PATH="$NOLFS_PATH" "$AIRLOCK" init nolfs --from-remote "$TMP/forge.git" > "$OUT" 2>&1; then
  _fail "init succeeded without git-lfs"
else
  _pass
fi
assert_contains "$OUT" "git-lfs is not on PATH" "names what is missing"
assert_absent "$AIRLOCK_DATA_HOME/nolfs"

# --- refreshing from upstream ----------------------------------------------

case_begin "airlock fetch carries the LFS objects of upstream branches"
( cd "$TMP/dev" || exit 1
  git checkout --quiet -b feature
  head -c 4096 /dev/urandom > later.bin
  git add later.bin
  git commit --quiet -m "a later lfs file"
  git push --quiet origin feature ) >/dev/null 2>&1
LATER_OID="$(git -C "$TMP/dev" lfs ls-files --long | awk '$3 == "later.bin" { print $1 }')"
assert_ok "fetch succeeds" "$AIRLOCK" fetch remote
assert_file "$HUB/lfs/objects/${LATER_OID:0:2}/${LATER_OID:2:2}/$LATER_OID"

# --- repositories without LFS are untouched -------------------------------

case_begin "a repository without LFS gets no LFS setup"
git init --quiet -b trunk "$TMP/plain"
( cd "$TMP/plain" || exit 1
  echo one > file.txt
  git add file.txt
  git commit --quiet -m plain ) >/dev/null 2>&1
assert_ok "init succeeds" "$AIRLOCK" init plain --from-local "$TMP/plain"
assert_absent "$AIRLOCK_DATA_HOME/plain/work_dir/plain.git/lfs"
assert_absent "$AIRLOCK_DATA_HOME/plain/work_dir/plain/.git/hooks/pre-push"
