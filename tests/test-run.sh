# shellcheck shell=bash
# Behaviour of `airlock run` (D12, D13, D18, §4).
#
# No VM is launched. Everything up to the launch is ordinary shell, so it is
# covered two ways: --dry-run prints the environment the substrate would be
# handed, and AIRLOCK_LAUNCHER points the launch at a stub that records what it
# received. Booting a real guest stays a manual smoke test (§8).

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
export ANTHROPIC_API_KEY=test-key-not-real

setup() { # name [flavor] -> echoes the workspace root
  local name="$1"
  local flavor="${2:-claude}"
  local src="$TMP/src-$name"
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

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

set_config() { # workspace key value
  local ws="$1" key="$2" value="$3"
  sed -i "s|^${key}  *=.*|${key} = ${value}|" "$ws/config"
}

# A stub standing in for the microVM launcher: records the environment it was
# handed and whether the lock was held while it ran.
make_stub() { # path [exit_code]
  # The bash that is running, not `/usr/bin/env bash`: this file is written at
  # test time, so patchShebangs cannot reach it, and the Nix build sandbox has
  # no /usr/bin/env.
  cat > "$1" <<EOF
#!$BASH
env | grep -E '^(WORK_DIR|AGENT_HOME|VM_|AGENTS_ARGS|ENABLE_CRI|EXTRA_ENV)=' | sort > "$TMP/stub.env"
cat "\$AIRLOCK_TEST_WS/lock" > "$TMP/stub.lock" 2>/dev/null || echo "NO LOCK" > "$TMP/stub.lock"
exit ${2:-0}
EOF
  chmod +x "$1"
}

# --- the environment the substrate is handed ------------------------------

case_begin "dry run reports the mapping from workspace to substrate"
WS="$(setup mapping)"
assert_ok "dry run succeeds" run run mapping --dry-run
assert_contains "$OUT" "WORK_DIR=$WS/work_dir" "shares work_dir, not the workspace root"
assert_contains "$OUT" "AGENT_HOME=$WS/agent_home" "and agent_home separately"
if grep -qE "^(WORK_DIR|AGENT_HOME)=$WS\$" "$OUT"; then
  _fail "the unmounted workspace root was handed to the substrate"
else
  _pass
fi
assert_contains "$OUT" "VM_VCPU=4" "default cpus"
assert_contains "$OUT" "VM_MEM=8192" "default memory"
assert_contains "$OUT" "claude-microvm#claude" "launches the configured flavor"

case_begin "resource caps come from the workspace config"
set_config "$WS" cpus 2
set_config "$WS" memory_mb 2048
assert_ok "dry run succeeds" run run mapping --dry-run
assert_contains "$OUT" "VM_VCPU=2" "cpus honoured"
assert_contains "$OUT" "VM_MEM=2048" "memory honoured"

case_begin "optional knobs are only passed when set"
assert_ok "dry run succeeds" run run mapping --dry-run
if grep -qE '^(ENABLE_CRI|EXTRA_ENV|VM_STORE_SIZE)=' "$OUT"; then
  _fail "sent a knob the workspace never asked for"
else
  _pass
fi
printf 'cri = docker\nstore_size_mb = 4096\n' >> "$WS/config"
set_config "$WS" env_forward "FOO,BAR=baz"
assert_ok "dry run succeeds" run run mapping --dry-run
assert_contains "$OUT" "ENABLE_CRI=docker" "cri forwarded"
assert_contains "$OUT" "VM_STORE_SIZE=4096" "store size forwarded"
assert_contains "$OUT" "EXTRA_ENV=FOO,BAR=baz" "env_forward forwarded"

case_begin "the substrate reference is configurable and pinnable"
set_config "$WS" substrate "github:systemstart/claude-microvm/abc123"
assert_ok "dry run succeeds" run run mapping --dry-run
assert_contains "$OUT" "claude-microvm/abc123#claude" "honours the pin"

# --- permission posture (D12) ---------------------------------------------

case_begin "prompts = bypass passes the agent's bypass flag"
WS="$(setup bypass)"
assert_ok "dry run succeeds" run run bypass --dry-run
assert_contains "$OUT" "AGENTS_ARGS=--dangerously-skip-permissions" "bypass flag passed"

case_begin "prompts = prompt passes nothing"
set_config "$WS" prompts prompt
assert_ok "dry run succeeds" run run bypass --dry-run
if grep -q 'AGENTS_ARGS' "$OUT"; then _fail "passed agent args anyway"; else _pass; fi

case_begin "a flavor with no verified bypass flag says so instead of guessing"
WS="$(setup nobypass codex)"
assert_ok "dry run succeeds" run run nobypass --dry-run
assert_contains "$OUT" "no bypass flag is known for codex" "warns"
if grep -q 'AGENTS_ARGS' "$OUT"; then _fail "guessed a flag"; else _pass; fi

case_begin "agent_args and trailing arguments are appended"
WS="$(setup args)"
set_config "$WS" agent_args "--verbose"
assert_ok "dry run succeeds" run run args --dry-run -- -p "summarize this repo"
assert_contains "$OUT" "--dangerously-skip-permissions --verbose -p summarize this repo" "all three, in order"

# --- the launch itself, against a stub ------------------------------------

case_begin "the launcher receives the environment and the lock is held while it runs"
WS="$(setup launching)"
export AIRLOCK_TEST_WS="$WS"
make_stub "$TMP/stub"
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run launching
assert_contains "$TMP/stub.env" "WORK_DIR=$WS/work_dir" "stub saw WORK_DIR"
assert_contains "$TMP/stub.env" "AGENTS_ARGS=--dangerously-skip-permissions" "stub saw the agent args"
if grep -qx '[0-9][0-9]*' "$TMP/stub.lock"; then
  _pass
else
  _fail "the lock was not held while the launcher ran"
fi

case_begin "the lock is released when the run ends"
assert_absent "$WS/lock"

case_begin "the launcher's exit status is the command's exit status"
make_stub "$TMP/stub" 3
AIRLOCK_LAUNCHER="$TMP/stub" run run launching
assert_eq "3" "$?" "exit status propagated"
assert_absent "$WS/lock"

# --- one VM per workspace (D13) -------------------------------------------

case_begin "a second run is refused while one holds the lock"
echo $$ > "$WS/lock"
make_stub "$TMP/stub"
AIRLOCK_LAUNCHER="$TMP/stub" assert_fails "refused" run run launching
assert_contains "$OUT" "already in progress" "explains why"
assert_eq "$$" "$(cat "$WS/lock")" "the live lock is left alone"
rm -f "$WS/lock"

case_begin "a stale lock is cleared with a warning"
echo 999999 > "$WS/lock"
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run proceeds" run run launching
assert_contains "$OUT" "stale lock" "says what it did"
assert_absent "$WS/lock"

# --- preflight ------------------------------------------------------------

case_begin "a symlinked agent_home is refused, not launched"
WS="$(setup symlinked)"
rmdir "$WS/agent_home"
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$WS/agent_home"
AIRLOCK_LAUNCHER="$TMP/stub" assert_fails "refused" run run symlinked
assert_contains "$OUT" "symlink" "names the problem"
assert_contains "$OUT" "outside the workspace" "explains the consequence"

case_begin "a missing clone is refused"
WS="$(setup noclone)"
rm -rf "$WS/work_dir/widget"
AIRLOCK_LAUNCHER="$TMP/stub" assert_fails "refused" run run noclone
assert_contains "$OUT" "clone is missing" "names the problem"

case_begin "an unknown workspace is refused"
assert_fails "unknown name" run run nosuchworkspace

# --- dev shells (D18) ------------------------------------------------------

case_begin "devshell = host-eval with nothing to evaluate warns rather than failing"
WS="$(setup noflake)"
set_config "$WS" devshell host-eval
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run proceeds" run run noflake
assert_contains "$OUT" "no flake.nix" "says there was nothing to evaluate"

case_begin "devshell = off evaluates nothing on the host"
WS="$(setup offbydefault)"
echo '{ outputs = _: { }; }' > "$WS/work_dir/widget/flake.nix"
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run offbydefault
assert_absent "$WS/agent_home/.microvm-devshell"
if grep -qi 'evaluating the dev shell' "$OUT"; then
  _fail "evaluated guest-writable Nix code on the host without being asked"
else
  _pass
fi

case_begin "a dry run does not demand a host that can launch"
# A dry run prints a mapping. Requiring nix and /dev/kvm for that makes the
# command unusable anywhere a VM cannot run — CI included. Proven with a PATH
# that has what airlock needs and no nix at all.
WS="$(setup nohost)"
mkdir -p "$TMP/nixless"
# This list is also a statement of what airlock shells out to: add a new
# dependency and this case fails until it is listed.
for t in bash git awk cut head tail cat cp mv rm ln mkdir sed grep find wc sort tr basename dirname mktemp env ls seq; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$TMP/nixless/$t"
done
if [ -x "$TMP/nixless/git" ] && ! PATH="$TMP/nixless" command -v nix >/dev/null 2>&1; then
  assert_ok "dry run with no nix on PATH" \
    env -u AIRLOCK_LAUNCHER "PATH=$TMP/nixless" "$AIRLOCK" run nohost --dry-run
else
  skip "could not build a nix-free PATH"
fi

# --- where the hypervisor's control socket lands ---------------------------
#
# microvm.nix defaults `microvm.socket` to "<hostName>.sock" and QEMU opens it
# relative to its working directory, so it followed whatever directory airlock
# was invoked from. The launcher now runs from the workspace root.

case_begin "the launcher runs from the workspace root"
WS="$(setup cwd)"
assert_ok "dry run succeeds" run run cwd --dry-run
assert_contains "$OUT" "cwd: $WS" "dry run says where it will run"

cat > "$TMP/pwdstub" <<EOF
#!$BASH
echo "PWD=\$PWD" > "$TMP/stub.pwd"
EOF
chmod +x "$TMP/pwdstub"
( cd "$TMP" || exit 1
  AIRLOCK_LAUNCHER="$TMP/pwdstub" "$AIRLOCK" run cwd ) > "$OUT" 2>&1
assert_contains "$TMP/stub.pwd" "PWD=$WS" "and really runs there, not in the caller's cwd"

case_begin "a launcher given as a relative path still resolves after the move"
( cd "$TMP" || exit 1
  AIRLOCK_LAUNCHER="./pwdstub" "$AIRLOCK" run cwd ) > "$OUT" 2>&1
assert_contains "$TMP/stub.pwd" "PWD=$WS" "relative launcher was resolved first"

case_begin "a local substrate flake ref is made absolute, a remote one is left alone"
WS="$(setup subref)"
set_config "$WS" substrate "./local-substrate"
( cd "$TMP" || exit 1
  "$AIRLOCK" run subref --dry-run ) > "$OUT" 2>&1
assert_contains "$OUT" "launcher: nix run $TMP/local-substrate#claude" "relative ref resolved"
set_config "$WS" substrate "github:systemstart/claude-microvm"
assert_ok "dry run succeeds" run run subref --dry-run
assert_contains "$OUT" "launcher: nix run github:systemstart/claude-microvm#claude" "remote ref untouched"

if command -v socat >/dev/null 2>&1; then
  case_begin "a control socket left by a dead run is cleared, and only sockets are"
  WS="$(setup stalesock)"
  socat UNIX-LISTEN:"$WS/claude-vm.sock",fork /dev/null &
  SOCAT_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$WS/claude-vm.sock" ] && break; sleep 0.1; done
  kill -9 "$SOCAT_PID" 2>/dev/null
  wait "$SOCAT_PID" 2>/dev/null
  assert_ok "the socket file survived its process" test -S "$WS/claude-vm.sock"
  # A regular file with the same suffix must not be swept up: the cleanup is
  # deliberately narrow.
  echo "not a socket" > "$WS/decoy.sock"
  make_stub "$TMP/stub"
  export AIRLOCK_TEST_WS="$WS"
  AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run stalesock
  assert_absent "$WS/claude-vm.sock"
  assert_file "$WS/decoy.sock"
  assert_contains "$OUT" "left by an earlier run" "says what it cleared"
else
  case_begin "stale control socket"
  skip "needs socat"
fi
