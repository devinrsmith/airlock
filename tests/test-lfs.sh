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
REPO="$AIRLOCK_DATA_HOME/remote/work_dir/.repo"
assert_file "$(lfs_object "$HUB")"
assert_ok "a task" "$AIRLOCK" task new remote t1
WT="$AIRLOCK_DATA_HOME/remote/work_dir/tasks/t1"
assert_ok "its worktree has the content, not a pointer" cmp "$WT/big.bin" "$TMP/dev/big.bin"
assert_eq "" "$(git -C "$WT" status --porcelain)" "and a clean tree"

case_begin "the repository carries its own LFS filter and hooks, for every worktree"
# The guest has no global LFS config: what it gets is what is in the repository.
assert_eq "git-lfs filter-process" "$(git -C "$REPO" config --local filter.lfs.process)" "filter is local"
assert_eq "true" "$(git -C "$REPO" config --local filter.lfs.required)" "and required"
assert_file "$REPO/hooks/pre-push"

case_begin "the agent's new LFS objects reach the hub"
# Origin is a guest path; point it at the hub as the guest would see it, for
# this push only, through the repository the worktree shares and its hooks.
git -C "$REPO" remote set-url origin "$HUB"
( cd "$WT" || exit 1
  head -c 1024 /dev/urandom > new.bin
  git add new.bin
  git commit --quiet -m "another lfs file" ) >/dev/null 2>&1
assert_ok "push succeeds" git -C "$WT" push --quiet origin agent/t1
NEW_OID="$(git -C "$WT" lfs ls-files --long | awk '$3 == "new.bin" { print $1 }')"
assert_file "$HUB/lfs/objects/${NEW_OID:0:2}/${NEW_OID:2:2}/$NEW_OID"
git -C "$REPO" remote set-url origin /work/forge.git

# --- seeding from a local checkout ---------------------------------------

case_begin "init --from-local carries the checkout's own LFS objects"
assert_ok "init succeeds" "$AIRLOCK" init local --from-local "$TMP/dev" --project widget
assert_file "$(lfs_object "$AIRLOCK_DATA_HOME/local/work_dir/widget.git")"
assert_ok "a task" "$AIRLOCK" task new local t
assert_ok "its worktree has the content" cmp "$AIRLOCK_DATA_HOME/local/work_dir/tasks/t/big.bin" "$TMP/dev/big.bin"

case_begin "objects a local checkout lacks come from its origin"
GIT_LFS_SKIP_SMUDGE=1 git clone --quiet "$TMP/forge.git" "$TMP/sparse" >/dev/null 2>&1
rm -rf "$TMP/sparse/.git/lfs/objects"
assert_ok "init succeeds" "$AIRLOCK" init sparse --from-local "$TMP/sparse" --project widget
assert_file "$(lfs_object "$AIRLOCK_DATA_HOME/sparse/work_dir/widget.git")"
assert_ok "a task" "$AIRLOCK" task new sparse t
assert_ok "its worktree has the content" cmp "$AIRLOCK_DATA_HOME/sparse/work_dir/tasks/t/big.bin" "$TMP/dev/big.bin"

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

case_begin "airlock fetch carries the LFS objects of the default branch only"
obj() { printf '%s/lfs/objects/%s/%s/%s' "$HUB" "${1:0:2}" "${1:2:2}" "$1"; }
( cd "$TMP/dev" || exit 1
  head -c 3072 /dev/urandom > trunk-later.bin
  git add trunk-later.bin
  git commit --quiet -m "a later lfs file on trunk"
  git push --quiet origin trunk
  git checkout --quiet -b feature
  head -c 4096 /dev/urandom > later.bin
  git add later.bin
  git commit --quiet -m "a later lfs file on a branch"
  git push --quiet origin feature
  git checkout --quiet trunk ) >/dev/null 2>&1
TRUNK_OID="$(git -C "$TMP/dev" lfs ls-files --long | awk '$3 == "trunk-later.bin" { print $1 }')"
LATER_OID="$(git -C "$TMP/dev" lfs ls-files --long feature | awk '$3 == "later.bin" { print $1 }')"
assert_ok "fetch succeeds" "$AIRLOCK" fetch remote
assert_file "$(obj "$TRUNK_OID")"
assert_absent "$(obj "$LATER_OID")"

case_begin "task new fetches the LFS objects of where it starts, and checks them out"
assert_ok "task new from the upstream branch" "$AIRLOCK" task new remote feat --base upstream/feature
assert_file "$(obj "$LATER_OID")"
WT="$AIRLOCK_DATA_HOME/remote/work_dir/tasks/feat"
assert_eq "$LATER_OID" "$(sha256sum < "$WT/later.bin" | cut -d" " -f1)" "the worktree has the content, not a pointer"
assert_eq "" "$(git -C "$WT" status --porcelain)" "and a clean tree"

case_begin "the LFS step says what it does, and git-lfs prints nothing of its own"
OUT="$TMP/init-out"
"$AIRLOCK" init quiet --from-remote "$TMP/forge.git" > "$OUT" 2>&1
assert_contains "$OUT" "fetching the Git LFS objects of trunk from upstream" "names the step"
QHUB="$AIRLOCK_DATA_HOME/quiet/work_dir/forge.git"
assert_file "$QHUB/lfs/objects/${TRUNK_OID:0:2}/${TRUNK_OID:2:2}/$TRUNK_OID"
assert_absent "$QHUB/lfs/objects/${LATER_OID:0:2}/${LATER_OID:2:2}/$LATER_OID"
if grep -q "Fetching reference\|Downloading LFS" "$OUT"; then _fail "git-lfs output leaked: $(grep -m1 "Fetching reference\|Downloading LFS" "$OUT")"; else _pass; fi

# --- repositories without LFS are untouched -------------------------------

case_begin "a repository without LFS gets no LFS setup"
git init --quiet -b trunk "$TMP/plain"
( cd "$TMP/plain" || exit 1
  echo one > file.txt
  git add file.txt
  git commit --quiet -m plain ) >/dev/null 2>&1
assert_ok "init succeeds" "$AIRLOCK" init plain --from-local "$TMP/plain"
assert_absent "$AIRLOCK_DATA_HOME/plain/work_dir/plain.git/lfs"
assert_absent "$AIRLOCK_DATA_HOME/plain/work_dir/.repo/hooks/pre-push"
