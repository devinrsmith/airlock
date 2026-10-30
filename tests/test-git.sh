# shellcheck shell=bash
# airlock git: the developer's git in a task's worktree, confined as airlock's
# own is (D34). What it is for works — status, log, commit, fetch from the hub
# — and what the sandbox exists to stop does not: the repository's traps, and
# writing the hub.

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
run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

if [ -z "${AIRLOCK_BWRAP:-}" ] \
   || ! "$AIRLOCK_BWRAP" --unshare-all --ro-bind / / -- true >/dev/null 2>&1; then
  case_begin "git"
  skip "no bubblewrap that can make namespaces here (AIRLOCK_BWRAP)"
  return 0   # sourced by run-tests.sh
fi

git init --quiet -b main "$TMP/src"
( cd "$TMP/src" && echo one > file.txt && git add file.txt && git commit --quiet -m one )
"$AIRLOCK" init demo --from-local "$TMP/src" --project widget >/dev/null 2>&1
"$AIRLOCK" task new demo t >/dev/null 2>&1
W="$AIRLOCK_DATA_HOME/ws/demo"; WD="$W/work_dir"; R="$WD/.repo"; T="$WD/tasks/t"; HUB="$W/widget.git"

case_begin "git runs in the task's worktree"
echo changed >> "$T/file.txt"
assert_ok "status" run git demo t status --porcelain
assert_contains "$OUT" " M file.txt" "sees the worktree's change"
assert_ok "log" run git demo t log -1 --format=%s
assert_eq "one" "$(cat "$OUT")" "its history"
assert_ok "-- before git's arguments" run git demo t -- rev-parse --abbrev-ref HEAD
assert_eq "agent/t" "$(cat "$OUT")" "on the task's branch"
assert_ok "paths are the worktree's" run git demo t add file.txt
assert_ok "commit, with -m" run git demo t commit --quiet -m two
assert_eq "two" "$(git --git-dir="$R" log -1 --format=%s agent/t)" "committed on agent/t"
assert_eq "dev@example.invalid" "$(git --git-dir="$R" log -1 --format=%ae agent/t)" "as the repository's identity"

case_begin "git's exit status is airlock's"
rc=0; "$AIRLOCK" git demo t rev-parse --verify --quiet no-such-ref >/dev/null 2>&1 || rc=$?
assert_eq "1" "$rc" "rev-parse's 1, not airlock's own failure"
rc=0; "$AIRLOCK" git demo t no-such-command >/dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then _pass; else _fail "an unknown git command succeeded"; fi

case_begin "the hub can be fetched from, not written"
git clone --quiet "$HUB" "$TMP/elsewhere"
( cd "$TMP/elsewhere" && git checkout --quiet -b agent/other && echo x > x.txt && git add x.txt \
  && git commit --quiet -m other && git push --quiet origin agent/other ) >/dev/null 2>&1
assert_ok "fetch origin" run git demo t fetch --quiet origin
assert_ok "the hub's branch arrived" git --git-dir="$R" rev-parse --verify --quiet refs/remotes/origin/agent/other
assert_fails "push refused" run git demo t push origin HEAD:refs/heads/agent/from-host
if git -C "$HUB" rev-parse --verify --quiet refs/heads/agent/from-host >/dev/null; then
  _fail "a push from the sandbox reached the hub"; else _pass; fi

case_begin "what the repository names does not run"
cat > "$WD/trap" <<EOF
#!$BASH
echo ran >> "$WD/.ran"
EOF
chmod +x "$WD/trap"
git --git-dir="$R" config core.fsmonitor "$WD/trap"
cp "$WD/trap" "$R/hooks/post-commit"
echo again >> "$T/file.txt"
assert_ok "status" run git demo t status --porcelain
assert_ok "commit" run git demo t commit --quiet -am three
assert_absent "$WD/.ran"
# And armed: plain git runs both.
echo once-more >> "$T/file.txt"
git -C "$T" commit --quiet -am four >/dev/null 2>&1
assert_file "$WD/.ran"
git --git-dir="$R" config --unset core.fsmonitor; rm -f "$R/hooks/post-commit" "$WD/.ran"

case_begin "usage and mistakes"
assert_ok "--help" run git --help
assert_contains "$OUT" "usage: airlock git <name> <task>" "says how"
rc=0; "$AIRLOCK" git demo > "$OUT" 2>&1 || rc=$?
assert_eq "2" "$rc" "a task is required"
assert_fails "an unknown task" run git demo nope status
assert_contains "$OUT" "has no task nope" "says which"

case_begin "a bubblewrap that cannot start is a refusal"
printf '#!%s\nexit 1\n' "$BASH" > "$TMP/badbwrap"; chmod +x "$TMP/badbwrap"
if AIRLOCK_BWRAP="$TMP/badbwrap" "$AIRLOCK" git demo t status > "$OUT" 2>&1; then
  _fail "ran without a sandbox"; else _pass; fi
assert_contains "$OUT" "cannot make a sandbox here" "says why"
