# shellcheck shell=bash
# Behaviour of `airlock rm`.
#
# The hub is the only copy of anything the agent pushed and you have not
# published, so most of this is about what rm refuses to do.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Test Developer
	email = dev@example.invalid
[init]
	defaultBranch = main
EOF

AIRLOCK="$REPO_ROOT/bin/airlock"
OUT="$TMP/out"

setup() { # name -> echoes the workspace root
  local name="$1"
  local src="$TMP/src-$name"
  {
    git init --quiet -b main "$src"
    ( cd "$src" || exit 1
      echo one > file.txt
      git add file.txt
      git commit --quiet -m "initial commit" )
    "$AIRLOCK" init "$name" --from-local "$src" --project widget
  } >/dev/null 2>&1
  printf '%s/%s\n' "$AIRLOCK_DATA_HOME" "$name"
}

agent_push() { # workspace branch message file
  local ws="$1"
  ( cd "$ws/work_dir/widget" || exit 1
    git checkout --quiet -b "$2" 2>/dev/null || git checkout --quiet "$2"
    echo "$4" > "$4"
    git add "$4"
    git commit --quiet -m "$3"
    git push --quiet "$ws/work_dir/widget.git" "HEAD:refs/heads/$2" ) >/dev/null 2>&1
}

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

# --- the happy path -------------------------------------------------------

case_begin "removing a quiet workspace takes everything it owns"
WS="$(setup quiet)"
# The substrate's disks are siblings of agent_home inside the root, so one
# removal has to take them too (§4).
mkdir -p "$WS/agent_home-cri" "$WS/agent_home-store"
assert_ok "rm succeeds" run rm quiet --yes
assert_absent "$WS"
assert_contains "$OUT" "remote remove hub" "says what to do about a dangling remote"

case_begin "other workspaces are untouched"
WS="$(setup keeper)"
OTHER="$(setup goner)"
assert_ok "rm succeeds" run rm goner --yes
assert_absent "$OTHER"
assert_dir "$WS"

# --- refusals -------------------------------------------------------------

case_begin "a run in progress is refused"
WS="$(setup running)"
echo $$ > "$WS/lock"
assert_fails "refused" run rm running --yes
assert_contains "$OUT" "a run is in progress" "explains why"
assert_dir "$WS" "nothing removed"
rm -f "$WS/lock"

case_begin "a stale lock does not block removal"
echo 999999 > "$WS/lock"
assert_ok "rm succeeds" run rm running --yes
assert_absent "$WS"

case_begin "no confirmation and no terminal is a refusal"
WS="$(setup unconfirmed)"
assert_fails "refused" run rm unconfirmed
assert_contains "$OUT" "pass --yes if you mean it" "says how to proceed"
assert_dir "$WS" "nothing removed"

case_begin "an unknown workspace is refused"
assert_fails "unknown name" run rm nosuchworkspace

case_begin "a directory that is not a workspace is refused"
mkdir -p "$AIRLOCK_DATA_HOME/notours/something"
assert_fails "refused" run rm notours --yes
assert_contains "$OUT" "does not look like an airlock workspace" "explains"
assert_dir "$AIRLOCK_DATA_HOME/notours"

# --- what would be lost ---------------------------------------------------

case_begin "branches ahead of the default are spelled out before removal"
WS="$(setup pending)"
agent_push "$WS" agent/work "work you have not read" w.txt
run rm pending   # refused for want of confirmation, but it reports first
assert_contains "$OUT" "commits main does not have" "warns"
assert_contains "$OUT" "agent/work" "names the branch"
assert_contains "$OUT" "only copy" "explains the stakes"

case_begin "--rescue-into saves the hub before removing"
RESCUE="$TMP/rescue-repo"
git init --quiet -b main "$RESCUE"
( cd "$RESCUE" || exit 1
  echo seed > seed.txt && git add seed.txt && git commit --quiet -m seed ) >/dev/null 2>&1
SHA="$(git -C "$WS/work_dir/widget.git" rev-parse refs/heads/agent/work)"
assert_ok "rm with rescue succeeds" run rm pending --yes --rescue-into "$RESCUE"
assert_absent "$WS"
assert_eq "$SHA" "$(git -C "$RESCUE" rev-parse refs/remotes/pending/agent/work)" "the work survived"

case_begin "a bad rescue target aborts before anything is removed"
WS="$(setup badrescue)"
agent_push "$WS" agent/work "work" w.txt
assert_fails "refused" run rm badrescue --yes --rescue-into "$TMP/not-a-repo"
assert_contains "$OUT" "needs a git repository" "explains"
assert_dir "$WS" "nothing removed"

# --- interactive confirmation ---------------------------------------------

if command -v script >/dev/null 2>&1; then

  rm_tty() { # workspace answer
    printf '%s\n' "$2" | script -qec "$AIRLOCK rm $1" /dev/null > "$OUT" 2>&1
  }

  case_begin "a quiet workspace takes a plain yes"
  WS="$(setup iquiet)"
  rm_tty iquiet n
  assert_dir "$WS" "n leaves it alone"
  rm_tty iquiet y
  assert_absent "$WS"

  case_begin "a workspace holding unmerged work makes you type its name"
  WS="$(setup ipending)"
  agent_push "$WS" agent/work "unread" w.txt
  rm_tty ipending y
  assert_contains "$OUT" "Type the workspace name" "asks for the name, not y/N"
  assert_dir "$WS" "a bare yes is not enough"
  rm_tty ipending wrongname
  assert_dir "$WS" "the wrong name is not enough"
  rm_tty ipending ipending
  assert_absent "$WS"

else
  case_begin "interactive rm"
  skip "needs script(1)"
fi
