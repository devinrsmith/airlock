# shellcheck shell=bash
# The web UI (D36): `status --json`, which is all it knows of a workspace, and
# `airlock ui`'s server — its token, its Host check, and the commands it runs.
#
# The server cases need python3 and curl, and skip without them; the flake
# check has both.

TMP="$(mktemp -d)"
HOLDERS=()
UI_PID=""
trap 'kill "${HOLDERS[@]}" $UI_PID 2>/dev/null; rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
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
export ANTHROPIC_API_KEY=test-key-not-real
mkdir -p "$TMP/substrate"
echo "{ outputs = _: { }; }" > "$TMP/substrate/flake.nix"
export AIRLOCK_SUBSTRATE="$TMP/substrate"
export AIRLOCK_NIXPKGS="github:NixOS/nixpkgs/0000000000000000000000000000000000000000"

# systemd, as far as status asks it: every unit inactive but the hub. A test
# PATH without it is the "cannot ask" case.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/systemctl" <<EOF
#!$BASH
case "\$*" in
  "--user show-environment") exit 0 ;;
  "--user is-active airlock-hub") echo active ;;
  *) echo inactive; exit 3 ;;
esac
EOF
chmod +x "$TMP/stub/systemctl"
STUB_PATH="$TMP/stub:$PATH"

run() { local rc=0; PATH="$STUB_PATH" "$AIRLOCK" "$@" > "$OUT" 2>"$TMP/err" || rc=$?; return $rc; }
jqo() { jq -r "$1" "$OUT"; }  # filter -> value from the last command's output

hold() { hold_lock "$@"; HOLDERS+=("$HELD_LOCK_PID"); }

if ! command -v jq >/dev/null 2>&1; then
  case_begin "ui"
  skip "no jq to read the JSON with"
  return 0   # sourced by run-tests.sh
fi

GIT_VERSION="$(git --version | awk '{print $3}')"
if [ "$(printf '%s\n' 2.48 "$GIT_VERSION" | sort -V | head -1)" != "2.48" ]; then
  case_begin "ui"
  skip "git $GIT_VERSION has no worktree --relative-paths (2.48+)"
  return 0
fi

# --- json_str ------------------------------------------------------------

case_begin "json_str escapes every control character"
weird=$'quote" back\\ tab\t nl\n cr\r bell\a esc\e del\x7f é'
got="$(bash -c '. "$1/lib/common.sh"; json_str "$2"' _ "$REPO_ROOT" "$weird" | jq -j .)"
assert_eq "$weird" "$got" "round trip through jq"

# --- status --json -------------------------------------------------------

case_begin "status --json with no workspaces"
assert_ok "exits zero" run status --json
assert_eq "0" "$(jqo '.workspaces | length')" "no workspaces"
assert_eq "$AIRLOCK_DATA_HOME" "$(jqo .data_home)" "data_home"

git init --quiet -b main "$TMP/src"
( cd "$TMP/src" && echo one > file.txt && git add file.txt && git commit --quiet -m one )
"$AIRLOCK" init demo --from-local "$TMP/src" --project widget >/dev/null 2>&1
"$AIRLOCK" task new demo fix-parser --prompt "fix it" >/dev/null 2>&1
"$AIRLOCK" task new demo idle >/dev/null 2>&1
WS="$AIRLOCK_DATA_HOME/ws/demo"
WT="$WS/work_dir/tasks/fix-parser"

case_begin "status --json lists the workspace, its tasks and the services"
assert_ok "exits zero" run status --json
assert_eq "demo" "$(jqo '.workspaces[0].name')" "name"
assert_eq "true" "$(jqo '.workspaces[0].ok')" "ok"
assert_eq "widget" "$(jqo '.workspaces[0].project')" "project"
assert_eq "claude" "$(jqo '.workspaces[0].flavor')" "flavor"
assert_eq "main" "$(jqo '.workspaces[0].default_branch')" "default branch"
assert_eq "fix-parser idle" "$(jqo '[.workspaces[0].tasks[].name] | join(" ")')" "tasks"
assert_eq "false" "$(jqo '.workspaces[0].tasks[0].running')" "stopped"
assert_eq "null" "$(jqo '.workspaces[0].tasks[0].changes')" "the list runs no git in worktrees"
assert_eq "0" "$(jqo '.workspaces[0].ahead | length')" "nothing ahead"
assert_eq "active" "$(jqo .services.hub.state)" "hub state from systemd"
assert_eq "5100" "$(jqo .services.hub.port)" "hub port"
assert_eq "docker.io inactive" "$(jqo '.services.registry[0] | "\(.upstream) \(.state)"')" "a registry cache"

case_begin "status --json says null, not stopped, when systemd cannot be asked"
mkdir -p "$TMP/nosystemd"
printf '#!%s\nexit 1\n' "$BASH" > "$TMP/nosystemd/systemctl"
chmod +x "$TMP/nosystemd/systemctl"
PATH="$TMP/nosystemd:$PATH" "$AIRLOCK" status --json > "$OUT" 2>/dev/null
assert_eq "null" "$(jqo .services.hub.state)" "hub"
assert_eq "null" "$(jqo '.services.registry[0].state')" "registry"

case_begin "status <name> --json gives each task's worktree and what it has not pushed"
( cd "$WT" && echo two >> file.txt && git commit --quiet -am two && git push --quiet origin agent/fix-parser 2>/dev/null )
( cd "$WT" && echo three >> file.txt && git commit --quiet -am three && echo dirty > new.txt )
assert_ok "exits zero" run status demo --json
assert_eq "$(realpath "$WS")" "$(realpath "$(jqo .root)")" "root"
assert_eq "true" "$(jqo .repository)" "repository"
assert_eq "agent/fix-parser" "$(jqo '.tasks[0].on')" "on its branch"
assert_eq "1" "$(jqo '.tasks[0].changes')" "one uncommitted change"
assert_eq "1" "$(jqo '.tasks[0].unpushed')" "one unpushed commit"
assert_eq "0" "$(jqo '.tasks[1].changes')" "the idle task is clean"
assert_eq "0" "$(jqo '.tasks[1].unpushed')" "and has pushed nothing it lacks"
assert_eq "agent/fix-parser 1" "$(jqo '.ahead[] | "\(.branch) \(.commits)"')" "the hub's branch ahead of main"
assert_eq "1" "$(jqo .commits)" "distinct commits"

case_begin "status --json reports a running task, its pid, and drift"
hold "$WS/tasks/idle/lock" "4242"
assert_ok "detail exits zero" run status demo --json
assert_eq "true" "$(jqo '.tasks[1].running')" "running"
assert_eq "4242" "$(jqo '.tasks[1].pid')" "the pid from the lock"
assert_eq "true" "$(jqo '.tasks[0].running | not')" "the other is not"
assert_ok "list exits zero" run status --json
assert_eq "true" "$(jqo '.workspaces[0].tasks[1].running')" "running in the list too"
# A launch record whose plan the config no longer gives.
printf '4242\nflavor claude\nsubstrate %s\nenv VM_VCPU=99\n' "$AIRLOCK_SUBSTRATE" > "$TMP/record"
kill "${HOLDERS[@]}" 2>/dev/null; wait "${HOLDERS[@]}" 2>/dev/null; HOLDERS=()
hold "$WS/tasks/idle/lock" "$(cat "$TMP/record")"
run status demo --json
assert_eq "true" "$(jqo '.tasks[1].drift | index("cpus") != null')" "cpus drifted: $(jqo '.tasks[1].drift')"
kill "${HOLDERS[@]}" 2>/dev/null; wait "${HOLDERS[@]}" 2>/dev/null; HOLDERS=()

case_begin "status --json reports a broken workspace and exits non-zero"
mkdir -p "$AIRLOCK_DATA_HOME/ws/wreck"
assert_fails "exits non-zero" run status --json
assert_eq "false" "$(jqo '.workspaces[] | select(.name == "wreck") | .ok')" "wreck is not ok"
assert_eq "true" "$(jqo '.workspaces[] | select(.name == "demo") | .ok')" "demo still is"
rmdir "$AIRLOCK_DATA_HOME/ws/wreck"

# --- the server ----------------------------------------------------------

if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  case_begin "ui server"
  skip "needs python3 and curl"
  return 0
fi

case_begin "airlock ui prints a URL with a token, and serves the page without one"
unset AIRLOCK_UI_ADDR   # the default address is what is under test
PATH="$STUB_PATH" "$AIRLOCK" ui --port 0 > "$TMP/ui.out" 2> "$TMP/ui.err" &
UI_PID=$!
URL=""
for _ in $(seq 1 100); do
  URL="$(grep -o 'http://127\.0\.0\.2:[0-9]*/#token=[A-Za-z0-9_-]*' "$TMP/ui.out" 2>/dev/null || true)"
  [ -z "$URL" ] || break
  sleep 0.1
done
if [ -z "$URL" ]; then
  _fail "no URL printed: $(cat "$TMP/ui.out" "$TMP/ui.err")"
  return 0
fi
_pass
BASE="${URL%%/#*}"
TOKEN="${URL##*token=}"
PORT="${BASE##*:}"
code() { curl -s -o "$OUT" -D "$TMP/headers" -w '%{http_code}' "$@"; }
auth=(-H "Authorization: Bearer $TOKEN")
json=(-H "Content-Type: application/json")

assert_eq "200" "$(code "$BASE/")" "the page"
assert_contains "$OUT" "/app.js" "is the UI"
assert_contains "$TMP/headers" "Content-Security-Policy: default-src 'self'" "with a CSP"
assert_eq "200" "$(code "$BASE/app.js")" "its script"
assert_eq "404" "$(code --path-as-is "$BASE/../server.py")" "nothing else from the filesystem"
assert_eq "404" "$(code "$BASE/static/app.js")" "not even beside it"

case_begin "the API refuses a request without the token"
assert_eq "401" "$(code "$BASE/api/status")" "no token"
assert_eq "401" "$(code -H "Authorization: Bearer wrong" "$BASE/api/status")" "wrong token"
assert_eq "401" "$(code -H "Authorization: Bearer ${TOKEN}x" "$BASE/api/status")" "token plus a character"
assert_eq "401" "$(code "${json[@]}" -d '{"task":"sneaky"}' "$BASE/api/workspaces/demo/tasks")" "no token, POST"
assert_absent "$WS/tasks/sneaky"

case_begin "the server refuses any Host but its own"
assert_eq "403" "$(code "${auth[@]}" -H "Host: attacker.example:$PORT" "$BASE/api/status")" "a rebound name"
assert_eq "403" "$(code -H "Host: attacker.example" "$BASE/")" "the page too"
assert_eq "403" "$(code "${auth[@]}" -H "Host: localhost:$PORT" "$BASE/api/status")" "localhost, which is 127.0.0.1"
assert_eq "403" "$(code "${auth[@]}" -H "Host: 127.0.0.1:$PORT" "$BASE/api/status")" "127.0.0.1"

case_begin "the server is not on 127.0.0.1, where a guest reaches (D35)"
assert_eq "000" "$(code --max-time 5 "${auth[@]}" "http://127.0.0.1:$PORT/api/status")" "nothing answers there"

case_begin "GET /api/status is airlock status --json"
assert_eq "200" "$(code "${auth[@]}" "$BASE/api/status")" "status"
assert_eq "fix-parser idle" "$(jqo '[.workspaces[0].tasks[].name] | join(" ")')" "the tasks"
assert_eq "active" "$(jqo .services.hub.state)" "run with the server's environment"
assert_eq "200" "$(code "${auth[@]}" "$BASE/api/workspaces/demo")" "detail"
assert_eq "1" "$(jqo '.tasks[0].changes')" "with the worktree's state"
assert_eq "502" "$(code "${auth[@]}" "$BASE/api/workspaces/nope")" "a workspace that is not there"
assert_contains "$OUT" "no such workspace" "says why, in airlock's words"
assert_eq "400" "$(code "${auth[@]}" "$BASE/api/workspaces/-x")" "a name that would be an option"

# Polls a job to its end; leaves its last view in $OUT.
wait_job() { # id
  local _
  for _ in $(seq 1 300); do
    curl -s "${auth[@]}" "$BASE/api/jobs/$1" > "$OUT"
    [ "$(jqo .state)" = "running" ] || return 0
    sleep 0.1
  done
}

case_begin "POST a task: airlock task new, as a job"
assert_eq "202" "$(code "${auth[@]}" "${json[@]}" -d '{"task":"from-ui","prompt":"--yes\nmultiline","base":"main"}' "$BASE/api/workspaces/demo/tasks")" "accepted"
job="$(jqo .id)"
assert_eq '["airlock","task","new","demo","from-ui","--prompt","--yes\nmultiline","--base","main"]' "$(jq -c .argv "$OUT")" "argv"
wait_job "$job"
assert_eq "ok" "$(jqo .state)" "finished: $(jqo .output)"
assert_eq "0" "$(jqo .code)" "exit status"
assert_contains "$OUT" "created task 'from-ui'" "its output"
assert_dir "$WS/tasks/from-ui"
assert_eq "$(printf -- '--yes\nmultiline')" "$(cat "$WS/tasks/from-ui/context/prompt.md")" "the prompt, verbatim"

case_begin "a job's output can be read from an offset"
curl -s "${auth[@]}" "$BASE/api/jobs/$job?since=9" > "$OUT"
assert_eq "true" "$(jqo '.output | startswith("out origin/main into")')" "from the 10th character: $(jqo .output)"

case_begin "a failing command is a failed job, with airlock's message"
code "${auth[@]}" "${json[@]}" -d '{"task":"from-ui"}' "$BASE/api/workspaces/demo/tasks" >/dev/null
wait_job "$(jqo .id)"
assert_eq "failed" "$(jqo .state)" "failed"
assert_eq "1" "$(jqo .code)" "exit status"
assert_contains "$OUT" "already has a task from-ui" "why"

case_begin "the server refuses names that are not names, before running anything"
before="$(curl -s "${auth[@]}" "$BASE/api/jobs" | jq '.jobs | length')"
assert_eq "400" "$(code "${auth[@]}" "${json[@]}" -d '{"task":"--yes"}' "$BASE/api/workspaces/demo/tasks")" "an option as a task"
assert_eq "400" "$(code "${auth[@]}" "${json[@]}" -d '{"task":"../x"}' "$BASE/api/workspaces/demo/tasks")" "a path as a task"
assert_eq "400" "$(code "${auth[@]}" "${json[@]}" -d '{"name":"..","source":"local","location":"/x"}' "$BASE/api/workspaces")" "a path as a workspace"
assert_eq "400" "$(code "${auth[@]}" "${json[@]}" -d '{"name":"w","source":"local","location":"rel/path"}' "$BASE/api/workspaces")" "a relative checkout"
assert_eq "400" "$(code "${auth[@]}" -d 'task=x' "$BASE/api/workspaces/demo/tasks")" "a form post"
assert_eq "404" "$(code "${auth[@]}" "${json[@]}" -d '{}' "$BASE/api/workspaces/demo/tasks/idle/run")" "an action there is none of"
assert_eq "$before" "$(curl -s "${auth[@]}" "$BASE/api/jobs" | jq '.jobs | length')" "no job started"

case_begin "POST a workspace: airlock init"
git init --quiet -b trunk "$TMP/src2"
( cd "$TMP/src2" && echo x > x && git add x && git commit --quiet -m x )
code "${auth[@]}" "${json[@]}" -d "{\"name\":\"second\",\"source\":\"local\",\"location\":\"$TMP/src2\",\"project\":\"gadget\"}" "$BASE/api/workspaces" >/dev/null
wait_job "$(jqo .id)"
assert_eq "ok" "$(jqo .state)" "created: $(jqo .output)"
assert_dir "$AIRLOCK_DATA_HOME/ws/second/gadget.git"

case_begin "removing a task: airlock task rm --yes"
code "${auth[@]}" "${json[@]}" -d '{}' "$BASE/api/workspaces/demo/tasks/from-ui/rm" >/dev/null
wait_job "$(jqo .id)"
assert_eq "ok" "$(jqo .state)" "removed: $(jqo .output)"
assert_absent "$WS/tasks/from-ui"

kill "$UI_PID" 2>/dev/null; wait "$UI_PID" 2>/dev/null; UI_PID=""

case_begin "airlock ui checks its port"
assert_fails "not a number" "$AIRLOCK" ui --port eighty
assert_fails "too large" "$AIRLOCK" ui --port 70000
