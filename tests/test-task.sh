# shellcheck shell=bash
# Behaviour of tasks (D26-D31): `airlock task`, and what a task changes about
# run, stop, status, rm, doctor and path.
#
# No VM is launched: run is checked with --dry-run and with AIRLOCK_LAUNCHER
# pointed at a stub, and stop with a launch directory faked the way the
# substrate leaves one, as test-run.sh and test-stop.sh do.

TMP="$(mktemp -d)"
HOLDERS=()
trap 'kill "${HOLDERS[@]}" 2>/dev/null; rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

# Reached through a symlink, as in test-stop.sh: the substrate records
# realpaths in instance.json, so airlock has to compare against those.
mkdir -p "$TMP/data"
ln -s "$TMP/data" "$TMP/data-link"
export AIRLOCK_DATA_HOME="$TMP/data-link"
export XDG_RUNTIME_DIR="$TMP/run"
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
REAL_DATA="$(realpath "$TMP/data")"
VMS="$XDG_RUNTIME_DIR/airlock-vm/vms"
export ANTHROPIC_API_KEY=test-key-not-real

mkdir -p "$TMP/substrate"
echo "{ outputs = _: { }; }" > "$TMP/substrate/flake.nix"
export AIRLOCK_SUBSTRATE="$TMP/substrate"
export AIRLOCK_NIXPKGS="github:NixOS/nixpkgs/0000000000000000000000000000000000000000"

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

hold() { hold_lock "$@"; HOLDERS+=("$HELD_LOCK_PID"); }
release_all() {
  [ "${#HOLDERS[@]}" -eq 0 ] || { kill "${HOLDERS[@]}" 2>/dev/null; wait "${HOLDERS[@]}" 2>/dev/null; }
  HOLDERS=()
}

setup() { # name [flavor] -> echoes the workspace root
  local name="$1" flavor="${2:-claude}" src="$TMP/src-$1"
  {
    git init --quiet -b main "$src"
    ( cd "$src" || exit 1
      echo one > file.txt
      git add file.txt
      git commit --quiet -m "initial commit" )
    "$AIRLOCK" init "$name" --from-local "$src" --project widget --flavor "$flavor"
  } >/dev/null 2>&1
  printf '%s/%s\n' "$AIRLOCK_DATA_HOME" "$name"
}

GIT_VERSION="$(git --version | awk '{print $3}')"
if [ "$(printf '%s\n' 2.48 "$GIT_VERSION" | sort -V | head -1)" != "2.48" ]; then
  case_begin "tasks"
  skip "git $(git --version | awk '{print $3}') has no worktree --relative-paths (2.48+)"
  return 0   # sourced by run-tests.sh
fi

WS="$(setup demo)"
REPO="$WS/work_dir/.repo"
HUB="$WS/widget.git"

# --- task new ------------------------------------------------------------

case_begin "task new makes a worktree on agent/<task>, with a context and a home"
mkdir -p "$TMP/ctx/sub"
echo notes > "$TMP/ctx/notes.txt"
echo deep > "$TMP/ctx/sub/deep.txt"
ln -s "$TMP/ctx/notes.txt" "$TMP/ctx/linked.txt"
assert_ok "succeeds" run task new demo fix-parser --prompt "Fix the parser." --context "$TMP/ctx"
T="$WS/tasks/fix-parser"
WT="$WS/work_dir/tasks/fix-parser"
assert_eq "agent/fix-parser" "$(git -C "$WT" symbolic-ref --short HEAD)" "on its own branch"
assert_eq "$(git -C "$REPO" rev-parse origin/main)" "$(git -C "$WT" rev-parse HEAD)" "from the hub's default branch"
assert_eq "gitdir: ../../.repo/worktrees/fix-parser" "$(cat "$WT/.git")" \
  "linked by a relative path, which resolves in the guest too"
assert_eq "origin" "$(git -C "$REPO" config branch.agent/fix-parser.remote)" "tracks the hub"
assert_dir "$T/agent_home"
assert_eq "" "$(ls -A "$T/agent_home")" "an empty home (D28)"
assert_eq "Fix the parser." "$(cat "$T/context/prompt.md")" "the prompt"
assert_eq "notes" "$(cat "$T/context/notes.txt")" "--context files"
assert_eq "deep" "$(cat "$T/context/sub/deep.txt")" "and subdirectories"
if [ -f "$T/context/linked.txt" ] && [ ! -L "$T/context/linked.txt" ]; then _pass; else
  _fail "a symlink in --context was not copied as the file it points at"; fi
assert_contains "$T/context/task.json" '"branch": "agent/fix-parser"' "task.json names the branch"
assert_contains "$T/context/task.json" '"worktree": "/work/tasks/fix-parser"' "and the worktree, as the guest sees it"
assert_contains "$T/context/task.json" '"base": "origin/main"' "and where it started"

case_begin "task names are held to what a branch, a directory and a VM name all take"
for bad in -x .x _x 'a b' 'a/b' 'a..b' 'x.lock' ''; do
  assert_fails "refuses '$bad'" run task new demo "$bad"
done
assert_absent "$WS/tasks/a..b"

case_begin "a task that exists is not made again"
assert_fails "refused" run task new demo fix-parser
assert_contains "$OUT" "already has a task fix-parser" "says why"

case_begin "a bad prompt or context leaves nothing behind"
assert_fails "two prompts" run task new demo two --prompt a --prompt-file "$TMP/ctx/notes.txt"
assert_fails "a missing prompt file" run task new demo nofile --prompt-file "$TMP/nope"
mkfifo "$TMP/ctx-fifo-dir" 2>/dev/null; mkdir -p "$TMP/ctxbad"; mkfifo "$TMP/ctxbad/pipe"
assert_fails "a FIFO in --context" run task new demo fifo --context "$TMP/ctxbad"
assert_contains "$OUT" "other than files and directories" "says why"
for t in two nofile fifo; do
  assert_absent "$WS/tasks/$t"
  assert_absent "$WS/work_dir/tasks/$t"
done
if git -C "$REPO" show-ref --quiet refs/heads/agent/fifo; then _fail "made a branch anyway"; else _pass; fi

case_begin "--base starts the branch elsewhere; the hub's own agent/<task> is picked up"
git -C "$HUB" branch side main >/dev/null
( cd "$TMP/src-demo" && echo two > file.txt && git commit --quiet -am two )
git -C "$HUB" fetch --quiet "$TMP/src-demo" main:refs/heads/agent/resume
assert_ok "--base" run task new demo based --base side
assert_contains "$WS/tasks/based/context/task.json" '"base": "origin/side"' "from the hub's side"
assert_ok "an existing hub branch" run task new demo resume
assert_eq "$(git -C "$HUB" rev-parse agent/resume)" "$(git -C "$WS/work_dir/tasks/resume" rev-parse HEAD)" \
  "continues the hub's agent/resume"
assert_fails "a --base that names nothing" run task new demo nowhere --base no-such-ref
assert_absent "$WS/tasks/nowhere"

case_begin "task ls lists each task, its branch and whether it runs"
echo change >> "$WT/file.txt"
assert_ok "succeeds" run task ls demo
assert_contains "$OUT" "fix-parser" "lists the task"
if grep -Eq '^fix-parser +agent/fix-parser +stopped +1 uncommitted' "$OUT"; then _pass; else
  _fail "row is not branch, stopped, 1 uncommitted change: $(grep fix-parser "$OUT")"; fi
hold "$T/lock"
run task ls demo
if grep -Eq '^fix-parser +agent/fix-parser +running ' "$OUT"; then _pass; else _fail "not shown running"; fi
release_all
git -C "$WT" checkout --quiet -- file.txt

case_begin "path --task names a task's places"
assert_ok "context by default" run path demo --task fix-parser
assert_eq "$T/context" "$(cat "$OUT")" "context"
run path demo --task fix-parser --worktree
assert_eq "$WT" "$(cat "$OUT")" "worktree"
run path demo --task fix-parser --agent-home
assert_eq "$T/agent_home" "$(cat "$OUT")" "agent home"
assert_fails "--hub is not a task's" run path demo --task fix-parser --hub
assert_fails "--worktree needs a task" run path demo --worktree
assert_fails "an unknown task" run path demo --task nope
assert_fails "--agent-home needs a task" run path demo --agent-home

# --- run -----------------------------------------------------------------

case_begin "a task's run is handed its home, context, start directory and name"
assert_ok "dry run" run run demo fix-parser --dry-run
assert_contains "$OUT" "AGENT_HOME=$T/agent_home" "the task's home, not the workspace's"
assert_contains "$OUT" "MICROVM_CONTEXT=$T/context" "its context"
assert_contains "$OUT" "MICROVM_START_DIR=/work/tasks/fix-parser" "starts in its worktree"
assert_contains "$OUT" "MICROVM_NAME=demo.fix-parser" "named <workspace>.<task>"
assert_contains "$OUT" "WORK_CACHE=never" "/work uncached (D27)"
assert_contains "$OUT" "WORK_DIR=$WS/work_dir" "the same work_dir as every task"

case_begin "the first run points the agent at its context; later runs continue"
assert_contains "$OUT" "AGENTS_ARGS=--dangerously-skip-permissions 'Your task is described in /run/microvm/context/" \
  "a fixed pointer, quoted for the guest's eval"
if grep -q 'Fix the parser' "$OUT"; then _fail "the developer's own text reached the command line"; else _pass; fi
# A conversation from another directory, as a home from before tasks holds
# (its agent started in /work): claude --continue would find nothing and exit.
mkdir -p "$T/agent_home/.claude/projects/-work"
: > "$T/agent_home/.claude/projects/-work/old.jsonl"
run run demo fix-parser --dry-run
if grep -q -- '--continue' "$OUT"; then _fail "continued a conversation from another directory"; else _pass; fi
assert_contains "$OUT" "'Your task is described in" "a first prompt instead"
mkdir -p "$T/agent_home/.claude/projects/-work-tasks-fix-parser"
: > "$T/agent_home/.claude/projects/-work-tasks-fix-parser/session.jsonl"
run run demo fix-parser --dry-run
assert_contains "$OUT" "AGENTS_ARGS=--dangerously-skip-permissions --continue" "continues"
if grep -q 'Your task is described' "$OUT"; then _fail "prompted again"; else _pass; fi
run run demo fix-parser --fresh --dry-run
assert_contains "$OUT" "'Your task is described in" "--fresh asks again"
if grep -q -- '--continue' "$OUT"; then _fail "--fresh continued anyway"; else _pass; fi
assert_fails "--fresh needs a task" run run demo --fresh --dry-run

case_begin "a flavor with no verified continue or prompt says so"
setup other codex >/dev/null
run task new other t1
assert_ok "dry run" run run other t1 --dry-run
assert_contains "$OUT" "no verified way to give codex a first prompt" "warns"
if grep -q 'AGENTS_ARGS' "$OUT"; then _fail "guessed at codex's arguments"; else _pass; fi

case_begin "every run is a task's"
assert_fails "no task" run run demo --dry-run
assert_contains "$OUT" "name the task to run" "says so"
assert_fails "an unknown task" run run demo nope --dry-run
assert_absent "$WS/agent_home"

cat > "$TMP/stub" <<EOF
#!$BASH
env | grep -E '^(AGENT_HOME|AGENTS_ARGS|WORK_CACHE|MICROVM_CONTEXT|MICROVM_START_DIR|MICROVM_NAME)=' | sort > "$TMP/stub.env"
if flock -n "$T/lock" true 2>/dev/null; then echo free; else echo held; fi > "$TMP/stub.task-lock"
if flock -n "$WS/lock" true 2>/dev/null; then echo free; else echo held; fi > "$TMP/stub.ws-lock"
exit 0
EOF
chmod +x "$TMP/stub"

case_begin "a task's launch holds the task's lock, seeds its trust and the pointer"
rm -rf "$T/agent_home/.claude" "$WS/work_dir/CLAUDE.md"
AIRLOCK_LAUNCHER="$TMP/stub" run run demo fix-parser
assert_eq "held" "$(cat "$TMP/stub.task-lock")" "the task's lock is held"
assert_eq "free" "$(cat "$TMP/stub.ws-lock")" "the workspace's is not"
assert_absent "$T/lock"
assert_contains "$T/agent_home/.claude.json" '"/work/tasks/fix-parser": { "hasTrustDialogAccepted": true }' \
  "trusts where the task starts"
assert_contains "$WS/work_dir/CLAUDE.md" "/work/tasks/<task>" "the workspace pointer is rewritten, with tasks in it"

case_begin "a task can run beside other tasks, but not twice"
hold "$WS/tasks/based/lock" "$$"
assert_ok "beside them" env AIRLOCK_LAUNCHER="$TMP/stub" "$AIRLOCK" run demo fix-parser
hold "$T/lock" "$$"
assert_fails "not twice" env AIRLOCK_LAUNCHER="$TMP/stub" "$AIRLOCK" run demo fix-parser
release_all
rm -f "$WS/tasks/based/lock" "$T/lock"

case_begin "a task setting exported by the caller never replaces airlock's"
MICROVM_CONTEXT=/elsewhere MICROVM_START_DIR=/elsewhere MICROVM_NAME=elsewhere AIRLOCK_LAUNCHER="$TMP/stub" run run demo based
if grep -q 'elsewhere' "$TMP/stub.env"; then _fail "passed on: $(cat "$TMP/stub.env")"; else _pass; fi
assert_contains "$TMP/stub.env" "MICROVM_START_DIR=/work/tasks/based" "airlock's own"

case_begin "a task whose home is a symlink, or whose worktree is gone, is refused"
mv "$T/agent_home" "$T/home-real"; ln -s "$T/home-real" "$T/agent_home"
assert_fails "symlinked home" run run demo fix-parser --dry-run
rm "$T/agent_home"; mv "$T/home-real" "$T/agent_home"
mv "$WS/work_dir/tasks/based" "$TMP/based-moved"
assert_fails "missing worktree" run run demo based --dry-run
assert_contains "$OUT" "worktree is missing" "says why"
mv "$TMP/based-moved" "$WS/work_dir/tasks/based"

# --- status, doctor ----------------------------------------------------

case_begin "status shows a workspace's tasks"
hold "$T/lock" "$$"
run status
if grep -Eq '^demo +widget +claude +3, 1 running ' "$OUT"; then _pass; else
  _fail "list row lacks the task count: $(grep '^demo ' "$OUT")"; fi
run status demo
assert_contains "$OUT" "task         fix-parser: running (pid $$)" "detail names the running task"
assert_contains "$OUT" "task         based: stopped; on agent/based, clean" "and the others"
release_all
rm -f "$T/lock"

case_begin "a task launched as configured is not reported as drift"
# A real run, against a launcher that stays up until killed: its launch record
# is what status compares the task's plan with.
# The launcher says when it has started, which is after run took the lock;
# probing the lock itself could take it at the moment run tries to.
printf '#!%s\ntouch %q\nexec sleep 60\n' "$BASH" "$TMP/sleeper.started" > "$TMP/sleeper"
chmod +x "$TMP/sleeper"
rm -f "$TMP/sleeper.started"
AIRLOCK_LAUNCHER="$TMP/sleeper" "$AIRLOCK" run demo fix-parser > /dev/null 2>&1 &
RUN_PID=$!
for _ in $(seq 1 600); do [ -e "$TMP/sleeper.started" ] && break; sleep 0.05; done
assert_file "$TMP/sleeper.started"
run status demo
assert_contains "$OUT" "task         fix-parser: running (pid $RUN_PID); on" "no drift on a task launched as configured"
if grep -q 'fix-parser: running.*config changed' "$OUT"; then _fail "its own home or context read as drift"; else _pass; fi
set_cpus() { sed -i "s|^cpus *=.*|cpus = $1|" "$WS/config"; grep -q '^cpus' "$WS/config" || printf 'cpus = %s\n' "$1" >> "$WS/config"; }
set_cpus 2
run status demo
assert_contains "$OUT" "fix-parser: running (pid $RUN_PID), config changed since launch: cpus" "a real change is"
run status
if grep -Eq '^demo .* 3, 1 running! ' "$OUT"; then _pass; else _fail "list lacks the task's !: $(grep '^demo ' "$OUT")"; fi
set_cpus 4
pkill -P "$RUN_PID" 2>/dev/null; kill "$RUN_PID" 2>/dev/null; wait "$RUN_PID" 2>/dev/null
for _ in $(seq 1 100); do [ -e "$T/lock" ] || break; sleep 0.05; done
rm -f "$T/lock"

case_begin "doctor checks each task"
assert_ok "a sound workspace" run doctor demo
assert_contains "$OUT" "task fix-parser: worktree of the repository" "checks the worktree"
printf 'x\n' > "$T/lock"
run doctor demo
assert_contains "$OUT" "task fix-parser: stale lock" "finds a stale task lock"
run doctor demo --fix
assert_absent "$T/lock"
mv "$WS/work_dir/tasks/based" "$TMP/based-moved"
assert_fails "a missing worktree fails" run doctor demo
assert_contains "$OUT" "task based: worktree" "names it"
mv "$TMP/based-moved" "$WS/work_dir/tasks/based"

# --- stop ----------------------------------------------------------------

if command -v jq >/dev/null 2>&1; then
  cat > "$TMP/stopper" <<EOF
#!$BASH
printf '%s\n' "\$*" > "$TMP/stopper.args"
EOF
  chmod +x "$TMP/stopper"
  export AIRLOCK_STOPPER="$TMP/stopper"
  launch() { # id context|"" [running]
    mkdir -p "$VMS/$1"
    if [ -n "$2" ]; then
      jq -n --arg id "$1" --arg work "$REAL_DATA/demo/work_dir" --arg c "$2" \
        '{version: 1, id: $id, work: $work, context: $c}' > "$VMS/$1/instance.json"
    else
      jq -n --arg id "$1" --arg work "$REAL_DATA/demo/work_dir" \
        '{version: 1, id: $id, work: $work, context: null}' > "$VMS/$1/instance.json"
    fi
    hold "$VMS/$1/lock"
  }
  REC="$(printf '%s\n%s' "$$" "namespace airlock-vm")"

  case_begin "stop <ws> <task> stops that task's launch, by its context"
  hold "$T/lock" "$REC"
  hold "$WS/tasks/based/lock" "$REC"
  launch aaaaaaaaaaaa ""
  launch bbbbbbbbbbbb "$REAL_DATA/demo/tasks/fix-parser/context"
  launch cccccccccccc "$REAL_DATA/demo/tasks/based/context"
  assert_ok "succeeds" run stop demo fix-parser
  assert_eq "bbbbbbbbbbbb" "$(cat "$TMP/stopper.args")" "the task's launch, not its neighbours'"
  assert_ok "succeeds" run stop demo based
  assert_eq "cccccccccccc" "$(cat "$TMP/stopper.args")" "and the other's"

  case_begin "stop <ws> without a task names the running ones"
  rm -f "$TMP/stopper.args"
  assert_fails "refused" run stop demo
  assert_contains "$OUT" "name the task to stop (running: based, fix-parser)" "lists them"
  assert_absent "$TMP/stopper.args"
  release_all
  rm -f "$T/lock" "$WS/tasks/based/lock"
  rm -rf "$VMS"
else
  case_begin "stop for tasks"
  skip "needs jq"
fi

# --- task rm, rm ---------------------------------------------------------

case_begin "task rm refuses a running task, and asks when there is no terminal"
hold "$T/lock" "$$"
assert_fails "running" run task rm demo fix-parser --yes
assert_contains "$OUT" "is running" "says why"
release_all
rm -f "$T/lock"
assert_fails "no terminal, no --yes" run task rm demo fix-parser < /dev/null
assert_dir "$T"

case_begin "task rm reports unpushed work, and keeps the hub's branch"
( cd "$WT" && echo more >> file.txt && git commit --quiet -am more )
git -C "$REPO" push --quiet "$HUB" agent/fix-parser 2>/dev/null
( cd "$WT" && echo again >> file.txt && git commit --quiet -am again && echo dirty > new.txt )
run task rm demo fix-parser < /dev/null
assert_contains "$OUT" "1 uncommitted change(s) in its worktree" "the uncommitted change"
assert_contains "$OUT" "1 commit(s) on agent/fix-parser not pushed to the hub" "and the unpushed commit"
assert_ok "--yes removes it" run task rm demo fix-parser --yes
assert_absent "$T"
assert_absent "$WT"
if git -C "$REPO" show-ref --quiet refs/heads/agent/fix-parser; then _fail "the repository kept the branch"; else _pass; fi
if git -C "$REPO" worktree list | grep -q fix-parser; then _fail "the repository still lists the worktree"; else _pass; fi
assert_ok "the hub keeps agent/fix-parser" git -C "$HUB" rev-parse --verify --quiet refs/heads/agent/fix-parser

case_begin "rm refuses while a task runs, and counts tasks' work as lost"
hold "$WS/tasks/based/lock" "$$"
assert_fails "refused" run rm demo --yes
assert_contains "$OUT" "task based is running" "names the task"
release_all
rm -f "$WS/tasks/based/lock"
echo dirty >> "$WS/work_dir/tasks/based/file.txt"
# shellcheck disable=SC2217  # stdin is airlock rm's, for its confirmation
run rm demo < /dev/null
assert_contains "$OUT" "These tasks hold work the hub does not have" "warns"
assert_contains "$OUT" "based" "names the task"
assert_ok "--yes removes everything" run rm demo --yes
assert_absent "$WS"
