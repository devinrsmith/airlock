# shellcheck shell=bash
# Behaviour of `airlock status` (§5, §7).
#
# status is read-only and offline. The assertions below pin that as much as
# they pin the output: it must never fetch, repair, or advance a watermark.

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
  local up="$TMP/up-$name"
  local src="$TMP/src-$name"
  {
    git init --quiet -b main "$up"
    ( cd "$up" || exit 1
      echo one > file.txt
      git add file.txt
      git commit --quiet -m "upstream one" )
    git clone --quiet "$up" "$src"
    "$AIRLOCK" init "$name" --from-local "$src" --project widget
  } >/dev/null 2>&1
  printf '%s/%s\n' "$AIRLOCK_DATA_HOME" "$name"
}

agent_push() { # clone hub branch message file
  ( cd "$1" || exit 1
    if git rev-parse --verify --quiet "$3" >/dev/null 2>&1; then
      git checkout --quiet "$3"
    else
      git checkout --quiet -b "$3"
    fi
    echo "$5" > "$5"
    git add "$5"
    git commit --quiet -m "$4"
    git push --quiet "$2" "HEAD:refs/heads/$3" ) >/dev/null 2>&1
}

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

# --- the list view --------------------------------------------------------

case_begin "a fresh workspace has nothing to review"
WS="$(setup quiet)"
assert_ok "status succeeds" run status
assert_contains "$OUT" "quiet" "lists the workspace"
assert_contains "$OUT" "nothing to review" "and says it is quiet"
assert_contains "$OUT" "stopped" "reports the VM as stopped"

case_begin "pushed work is counted in the list"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/one "first" a.txt
agent_push "$WS/work_dir/widget" "$HUB" agent/one "second" b.txt
assert_ok "status succeeds" run status
assert_contains "$OUT" "1 branch, 2 commit(s)" "counts branches and commits"

case_begin "a second branch is counted too"
agent_push "$WS/work_dir/widget" "$HUB" agent/two "third" c.txt
assert_ok "status succeeds" run status
assert_contains "$OUT" "2 branches, 3 commit(s)" "counts both"

case_begin "accepting clears the count"
run review quiet --accept >/dev/null 2>&1
assert_ok "status succeeds" run status
assert_contains "$OUT" "nothing to review" "quiet again"

# --- status agrees with review -------------------------------------------

case_begin "status and review never disagree about what is pending"
WS="$(setup agree)"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/x "work" x.txt
run status agree
STATUS_SAYS="$(grep -c 'new branch' "$OUT" || true)"
run review agree
REVIEW_SAYS="$(grep -c 'new branch' "$OUT" || true)"
assert_eq "$STATUS_SAYS" "$REVIEW_SAYS" "same branches reported"

# --- the detail view ------------------------------------------------------

case_begin "detail shows the workspace's shape"
WS="$(setup detail)"
HUB="$WS/work_dir/widget.git"
assert_ok "status <name> succeeds" run status detail
assert_contains "$OUT" "workspace detail" "names the workspace"
assert_contains "$OUT" "default branch main" "reports the default branch"
assert_contains "$OUT" "claude" "reports the agent flavor"
assert_contains "$OUT" "upstream" "reports the upstream remote"
assert_contains "$OUT" "0 ref(s) fetched" "upstream is unfetched until you fetch"

case_begin "detail distinguishes the agent's uncommitted work from pushed work"
echo scratch > "$WS/work_dir/widget/untracked.txt"
assert_ok "status succeeds" run status detail
assert_contains "$OUT" "uncommitted change(s)" "sees the dirty clone"
assert_contains "$OUT" "not pushed, not reviewable" "and is clear it is not reviewable"
assert_contains "$OUT" "nothing to review" "uncommitted work is not unreviewed work"

case_begin "detail lists unreviewed branches with their counts"
agent_push "$WS/work_dir/widget" "$HUB" agent/topic "the work" t.txt
assert_ok "status succeeds" run status detail
assert_contains "$OUT" "agent/topic" "names the branch"
assert_contains "$OUT" "new branch since main" "explains the baseline"
assert_contains "$OUT" "airlock review detail" "points at review"

# --- a running VM ---------------------------------------------------------

case_begin "a live lock is reported as a running VM"
WS="$(setup livevm)"   # not named "running": the assertions below look for that word
echo $$ > "$WS/lock"
assert_ok "status succeeds" run status livevm
assert_contains "$OUT" "running (pid $$)" "detail names the pid"
assert_ok "list succeeds" run status
assert_contains "$OUT" "running" "list says running"
rm -f "$WS/lock"
assert_ok "status succeeds" run status livevm
assert_contains "$OUT" "stopped" "stopped once the lock is gone"

case_begin "a stale lock is not a running VM"
echo 999999 > "$WS/lock"
assert_ok "status succeeds" run status livevm
assert_contains "$OUT" "stopped" "a dead pid is not running"
rm -f "$WS/lock"

# --- tampering ------------------------------------------------------------

case_begin "tampering is surfaced and exits non-zero"
WS="$(setup tampered)"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/topic "real work" r.txt
run review tampered --accept >/dev/null 2>&1
git -C "$HUB" update-ref refs/heads/agent/topic "$(git -C "$HUB" rev-parse refs/heads/main)"
assert_fails "detail exits non-zero" run status tampered
assert_contains "$OUT" "TAMPER" "says tamper"
assert_contains "$OUT" "airlock doctor tampered" "points at doctor"
assert_fails "the list exits non-zero too" run status
assert_contains "$OUT" "TAMPER" "and shows it in the list"

# --- status changes nothing ----------------------------------------------

case_begin "status never advances a watermark or touches the hub"
WS="$(setup readonly)"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/topic "work" w.txt
BEFORE_WM="$(cat "$WS/watermarks/refs/heads/main")"
BEFORE_REFS="$(git -C "$HUB" for-each-ref --format='%(refname) %(objectname)')"
run status readonly
run status
assert_eq "$BEFORE_WM" "$(cat "$WS/watermarks/refs/heads/main")" "watermark untouched"
assert_eq "$BEFORE_REFS" "$(git -C "$HUB" for-each-ref --format='%(refname) %(objectname)')" "hub refs untouched"
assert_absent "$WS/watermarks/refs/heads/agent/topic"

case_begin "status never fetches"
# Point the upstream somewhere unreachable: an offline command cannot notice.
git -C "$HUB" remote set-url upstream "https://127.0.0.1:1/nope.git"
assert_ok "status still succeeds" run status readonly
assert_contains "$OUT" "0 ref(s) fetched" "reports what is there, fetches nothing"

# --- broken workspaces and bad arguments ----------------------------------

case_begin "a broken workspace is reported, not fatal"
WS="$(setup broken)"
rm "$WS/config"
assert_fails "list exits non-zero" run status
assert_contains "$OUT" "broken — run airlock doctor broken" "explains what to do"
assert_contains "$OUT" "readonly" "other workspaces still listed"

case_begin "an unknown workspace is refused"
assert_fails "unknown name" run status nosuchworkspace

case_begin "no workspaces at all is not an error"
export AIRLOCK_DATA_HOME="$TMP/empty-data"
assert_ok "status succeeds" run status
assert_contains "$OUT" "no workspaces yet" "says so"
export AIRLOCK_DATA_HOME="$TMP/data"
