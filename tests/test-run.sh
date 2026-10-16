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

# A stand-in for the vendored substrate, so these tests do not depend on
# whether the submodule is checked out — it is not, inside a Nix build.
mkdir -p "$TMP/substrate"
echo "{ outputs = _: { }; }" > "$TMP/substrate/flake.nix"
export AIRLOCK_SUBSTRATE="$TMP/substrate"
# And for the baked-in nixpkgs, so the override is fixed rather than whatever
# this checkout is locked to.
export AIRLOCK_NIXPKGS="github:NixOS/nixpkgs/0000000000000000000000000000000000000000"

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
env | grep -E '^(WORK_DIR|AGENT_HOME|VM_|AGENTS_ARGS|ENABLE_CRI|EXTRA_ENV|REGISTRY_MIRRORS)=' | sort > "$TMP/stub.env"
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
assert_contains "$OUT" "launcher: nix run --override-input nixpkgs $AIRLOCK_NIXPKGS $TMP/substrate#claude" \
  "launches the vendored substrate on airlock's nixpkgs, with the configured flavor"

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

case_begin "the lock records what the VM was launched with"
# status reads this back: it is the only record of a running VM's launch.
assert_contains "$TMP/stub.lock" "substrate $AIRLOCK_SUBSTRATE" "the resolved substrate"
assert_contains "$TMP/stub.lock" "nixpkgs $AIRLOCK_NIXPKGS" "the nixpkgs it was overridden to"
assert_contains "$TMP/stub.lock" "flavor claude" "the flavor"
assert_contains "$TMP/stub.lock" "env VM_VCPU=4" "the environment handed over"
assert_contains "$TMP/stub.lock" "cwd $TMP" "where relative paths were resolved from"
if grep -q '^substrate\.' "$TMP/stub.lock"; then
  _fail "asked nix to resolve the substrate for a stub launch"
else
  _pass
fi
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run launching -- -p hi
assert_contains "$TMP/stub.lock" "args -p hi" "arguments after -- kept apart"
if grep -q '^env AGENTS_ARGS=.*-p hi' "$TMP/stub.lock"; then
  _fail "per-run arguments recorded as if the config asked for them"
else
  _pass
fi

case_begin "a real launch records exactly which substrate it resolved to"
# A fake nix answers `flake metadata` and stands in for `nix run`. Its locks
# carry a second, nested "locked" object: only the top-level one is the
# substrate's own.
mkdir -p "$TMP/fakenix"
cat > "$TMP/fakenix/nix" <<STUB
#!$BASH
case "\$1 \$2" in
  "flake metadata")
    printf '%s\n' '{"description":"x","locked":{"lastModified":1,"narHash":"sha256-top=","owner":"o","repo":"r","rev":"0123abcd","type":"github"},"locks":{"nodes":{"n":{"locked":{"narHash":"sha256-nested=","rev":"ffff0000"}}}}}' ;;
  run*) cat "\$AIRLOCK_TEST_WS/lock" > "$TMP/fakenix.lock"; printf '%s\n' "\$*" > "$TMP/fakenix.args" ;;
esac
STUB
chmod +x "$TMP/fakenix/nix"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  env -u AIRLOCK_LAUNCHER PATH="$TMP/fakenix:$PATH" "$AIRLOCK" run launching > "$OUT" 2>&1
  assert_contains "$TMP/fakenix.lock" "substrate.rev 0123abcd" "the revision"
  assert_contains "$TMP/fakenix.lock" "substrate.narHash sha256-top=" "and the content hash"
  assert_contains "$TMP/fakenix.args" "run --override-input nixpkgs $AIRLOCK_NIXPKGS $AIRLOCK_SUBSTRATE#claude" \
    "nix run is handed the override"
  if grep -q 'ffff0000\|sha256-nested=' "$TMP/fakenix.lock"; then _fail "read a nested lock node"; else _pass; fi
else
  skip "needs /dev/kvm to get past the launch preflight"
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

# --- which substrate gets launched ----------------------------------------

case_begin "an unset substrate uses what the build was locked against"
WS="$(setup vendored)"
assert_ok "dry run succeeds" run run vendored --dry-run
assert_contains "$OUT" "launcher: nix run --override-input nixpkgs $AIRLOCK_NIXPKGS $AIRLOCK_SUBSTRATE#claude" \
  "the baked-in reference, on the baked-in nixpkgs"

case_begin "a workspace can pin itself to a different substrate"
set_config "$WS" substrate "github:systemstart/claude-microvm/deadbeef"
assert_ok "dry run succeeds" run run vendored --dry-run
assert_contains "$OUT" "launcher: nix run github:systemstart/claude-microvm/deadbeef#claude" \
  "explicit wins, and keeps its own nixpkgs"
set_config "$WS" substrate ""

case_begin "a pin that restates the default still runs on airlock's nixpkgs"
set_config "$WS" substrate "$AIRLOCK_SUBSTRATE"
assert_ok "dry run succeeds" run run vendored --dry-run
assert_contains "$OUT" "launcher: nix run --override-input nixpkgs $AIRLOCK_NIXPKGS $AIRLOCK_SUBSTRATE#claude" \
  "not an override, so treated as the default"
set_config "$WS" substrate ""

case_begin "a source checkout reads the revision out of flake.lock"
# An install has the reference baked into its wrapper. A checkout has not, and
# must land on the same microVM rather than drifting to whatever github serves.
cat > "$TMP/fake.lock" <<'EOF'
{
  "nodes": {
    "nixpkgs": {
      "locked": { "rev": "1111111111111111111111111111111111111111", "type": "github", "owner": "NixOS", "repo": "nixpkgs" }
    },
    "claude-microvm": {
      "flake": false,
      "locked": { "rev": "abc1230000000000000000000000000000000def", "type": "github", "owner": "systemstart", "repo": "claude-microvm" }
    }
  }
}
EOF
env -u AIRLOCK_SUBSTRATE -u AIRLOCK_NIXPKGS AIRLOCK_FLAKE_LOCK="$TMP/fake.lock" \
  "$AIRLOCK" run vendored --dry-run > "$OUT" 2>&1
# Each revision in its own place: neither node is mistaken for the other.
assert_contains "$OUT" \
  "launcher: nix run --override-input nixpkgs github:NixOS/nixpkgs/1111111111111111111111111111111111111111 github:systemstart/claude-microvm/abc1230000000000000000000000000000000def#claude" \
  "the locked substrate, on the locked nixpkgs"

case_begin "a lock with no nixpkgs launches the substrate on its own"
cat > "$TMP/no-nixpkgs.lock" <<'EOF'
{
  "nodes": {
    "claude-microvm": {
      "flake": false,
      "locked": { "rev": "abc1230000000000000000000000000000000def", "type": "github", "owner": "systemstart", "repo": "claude-microvm" }
    }
  }
}
EOF
env -u AIRLOCK_SUBSTRATE -u AIRLOCK_NIXPKGS AIRLOCK_FLAKE_LOCK="$TMP/no-nixpkgs.lock" \
  "$AIRLOCK" run vendored --dry-run > "$OUT" 2>&1
assert_contains "$OUT" \
  "launcher: nix run github:systemstart/claude-microvm/abc1230000000000000000000000000000000def#claude" \
  "no override"

case_begin "nothing pinning the substrate at all fails loudly"
assert_fails "refused" \
  env -u AIRLOCK_SUBSTRATE AIRLOCK_FLAKE_LOCK="$TMP/no-such.lock" \
    "$AIRLOCK" run vendored --dry-run
env -u AIRLOCK_SUBSTRATE AIRLOCK_FLAKE_LOCK="$TMP/no-such.lock" \
  "$AIRLOCK" run vendored --dry-run > "$OUT" 2>&1 || true
assert_contains "$OUT" "no substrate" "says what is wrong"
assert_contains "$OUT" "flake.lock" "says where the revision should come from"
# The message has to come from die, not from bash echoing a mangled command.
if grep -q 'command not found' "$OUT"; then _fail "the refusal was a shell error"; else _pass; fi

case_begin "a lock with no claude-microvm node is not silently accepted"
printf '{ "nodes": { "nixpkgs": { "locked": { "rev": "2222222222222222222222222222222222222222" } } } }\n' \
  > "$TMP/wrong.lock"
assert_fails "refused" \
  env -u AIRLOCK_SUBSTRATE AIRLOCK_FLAKE_LOCK="$TMP/wrong.lock" \
    "$AIRLOCK" run vendored --dry-run

case_begin "a fork in flake.nix stays a fork: the reference is rebuilt from the whole locked entry"
# Shaped the way `nix flake lock` writes it, one key per line, with `original`
# placed first on purpose: only `locked` may answer, never `original` and never
# another node.
cat > "$TMP/fork.lock" <<'EOF'
{
  "nodes": {
    "claude-microvm": {
      "flake": false,
      "original": {
        "owner": "systemstart",
        "repo": "claude-microvm",
        "type": "github"
      },
      "locked": {
        "lastModified": 1792021524,
        "narHash": "sha256-GoEXXmwRchZE63FSuOZZ4cbY6dH2IBgqE+UtDLp3XBw=",
        "owner": "devinrsmith",
        "repo": "claude-microvm",
        "rev": "e2ac8c9a6efb87dfc90666e11ea2f10d58983ced",
        "type": "github"
      }
    },
    "nixpkgs": {
      "locked": {
        "owner": "someone",
        "repo": "nixpkgs-fork",
        "rev": "4444444444444444444444444444444444444444",
        "type": "github"
      },
      "original": {
        "owner": "NixOS",
        "ref": "nixos-unstable",
        "repo": "nixpkgs",
        "type": "github"
      }
    },
    "root": {
      "inputs": {
        "claude-microvm": "claude-microvm",
        "nixpkgs": "nixpkgs"
      }
    }
  },
  "root": "root",
  "version": 7
}
EOF
env -u AIRLOCK_SUBSTRATE -u AIRLOCK_NIXPKGS AIRLOCK_FLAKE_LOCK="$TMP/fork.lock" \
  "$AIRLOCK" run vendored --dry-run > "$OUT" 2>&1
assert_contains "$OUT" \
  "launcher: nix run --override-input nixpkgs github:someone/nixpkgs-fork/4444444444444444444444444444444444444444 github:devinrsmith/claude-microvm/e2ac8c9a6efb87dfc90666e11ea2f10d58983ced#claude" \
  "both forks, at their own revisions"

case_begin "a nixpkgs fork is what the registry builds from, too"
# shellcheck disable=SC2016  # $1 is the inner shell's, passed as an argument
env -u AIRLOCK_NIXPKGS AIRLOCK_FLAKE_LOCK="$TMP/fork.lock" \
  bash -c '. "$1/lib/common.sh"; nixpkgs_ref' _ "$REPO_ROOT" > "$OUT" 2>&1
assert_eq "github:someone/nixpkgs-fork/4444444444444444444444444444444444444444" "$(cat "$OUT")" "nixpkgs_ref"

case_begin "a git input becomes a git+ reference at its revision"
printf '%s\n' '{ "nodes": { "claude-microvm": { "locked": { "rev": "5555555555555555555555555555555555555555", "type": "git", "url": "https://example.org/microvm.git" } } } }' \
  > "$TMP/git.lock"
env -u AIRLOCK_SUBSTRATE -u AIRLOCK_NIXPKGS AIRLOCK_FLAKE_LOCK="$TMP/git.lock" \
  "$AIRLOCK" run vendored --dry-run > "$OUT" 2>&1
assert_contains "$OUT" "launcher: nix run git+https://example.org/microvm.git?rev=5555555555555555555555555555555555555555#claude" \
  "url and rev"

case_begin "an input type with no reference form is refused, not guessed"
printf '%s\n' '{ "nodes": { "claude-microvm": { "locked": { "rev": "6666666666666666666666666666666666666666", "type": "tarball", "url": "https://example.org/x.tar.gz" } } } }' \
  > "$TMP/tarball.lock"
assert_fails "refused" \
  env -u AIRLOCK_SUBSTRATE -u AIRLOCK_NIXPKGS AIRLOCK_FLAKE_LOCK="$TMP/tarball.lock" \
    "$AIRLOCK" run vendored --dry-run
env -u AIRLOCK_SUBSTRATE -u AIRLOCK_NIXPKGS AIRLOCK_FLAKE_LOCK="$TMP/tarball.lock" \
  "$AIRLOCK" run vendored --dry-run > "$OUT" 2>&1 || true
assert_contains "$OUT" "locked as a 'tarball' input" "names the type"
if grep -q 'github:systemstart' "$OUT"; then _fail "fell back to a guessed reference"; else _pass; fi

# --- the trust dialog ------------------------------------------------------
#
# Claude Code asks whether you trust the directory it starts in and records the
# answer in ~/.claude.json under projects.<dir>. The guest starts it in /work.

case_begin "a first launch seeds the trust record"
WS="$(setup trust)"
export AIRLOCK_TEST_WS="$WS"
make_stub "$TMP/stub"
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run trust
TRUSTFILE="$WS/agent_home/.claude.json"
assert_file "$TRUSTFILE"
assert_contains "$TRUSTFILE" '"/work": { "hasTrustDialogAccepted": true }' "the directory the agent starts in"
assert_contains "$TRUSTFILE" '"/work/widget": { "hasTrustDialogAccepted": true }' "and the clone"

case_begin "the agent's own state file is never rewritten"
# It is the agent's, it is guest-writable, and it holds history. Rewriting it to
# answer a question it has already answered would throw that away.
printf '{"projects":{"/work":{"hasTrustDialogAccepted":true,"irreplaceable":"state"}}}' > "$TRUSTFILE"
BEFORE="$(cat "$TRUSTFILE")"
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run trust
assert_eq "$BEFORE" "$(cat "$TRUSTFILE")" "byte-identical"

case_begin "an existing file with no trust record is reported, not edited"
printf '{"projects":{}}' > "$TRUSTFILE"
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run trust
assert_contains "$OUT" "records no trust decision" "warns"
assert_eq '{"projects":{}}' "$(cat "$TRUSTFILE")" "left alone"

case_begin "only claude gets a claude state file"
WS="$(setup trustcodex codex)"
export AIRLOCK_TEST_WS="$WS"
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run trustcodex
assert_absent "$WS/agent_home/.claude.json"

case_begin "a dry run writes nothing into agent_home"
WS="$(setup trustdry)"
assert_ok "dry run succeeds" run run trustdry --dry-run
assert_absent "$WS/agent_home/.claude.json"

# --- seeding the agent's own settings --------------------------------------
#
# The substrate copies a host file into the agent home at the flavor's config
# path. This is the one knob of its own that airlock had never exposed.

case_begin "a settings file is passed through to the substrate"
WS="$(setup settings)"
printf '{"model":"opus"}' > "$TMP/my-settings.json"
set_config "$WS" settings "$TMP/my-settings.json"
assert_ok "dry run succeeds" run run settings --dry-run
assert_contains "$OUT" "AGENT_SETTINGS=$TMP/my-settings.json" "absolute path forwarded"

case_begin "a path relative to the caller is resolved before the launcher moves"
( cd "$TMP" || exit 1
  "$AIRLOCK" run settings --dry-run ) > "$OUT" 2>&1
set_config "$WS" settings "./my-settings.json"
( cd "$TMP" || exit 1
  "$AIRLOCK" run settings --dry-run ) > "$OUT" 2>&1
assert_contains "$OUT" "AGENT_SETTINGS=$TMP/my-settings.json" "resolved against the caller's cwd"

case_begin "a leading ~ is expanded"
# The config is parsed, not sourced, so nothing expands it for us — and this is
# how someone will write a path to their dotfiles.
mkdir -p "$TMP/fakehome"
printf '{"model":"opus"}' > "$TMP/fakehome/settings.json"
# shellcheck disable=SC2088  # the literal tilde is the point: it is written
# into the config file for airlock to expand, not for the shell to.
set_config "$WS" settings "~/settings.json"
HOME="$TMP/fakehome" "$AIRLOCK" run settings --dry-run > "$OUT" 2>&1
assert_contains "$OUT" "AGENT_SETTINGS=$TMP/fakehome/settings.json" "~ expanded"

case_begin "a settings file that is not there fails before the guest is built"
set_config "$WS" settings "$TMP/no-such-settings.json"
assert_fails "refused" run run settings --dry-run
assert_contains "$OUT" "settings file not found" "says which"

case_begin "a flavor with no settings path says so rather than passing it"
WS="$(setup settingspi pi)"
printf '{}' > "$TMP/pi-settings.json"
set_config "$WS" settings "$TMP/pi-settings.json"
assert_ok "dry run succeeds" run run settingspi --dry-run
assert_contains "$OUT" "has no settings path" "warns"
if grep -q 'AGENT_SETTINGS' "$OUT"; then _fail "passed settings to a flavor that has none"; else _pass; fi

case_begin "the dev-shell opt-in passes DIRENV_ALLOW, not just the cache file"
# The guest gates sourcing ~/.microvm-devshell on DIRENV_ALLOW (base.nix), so
# writing the cache without the variable leaves it written and ignored.
WS="$(setup direnv)"
assert_ok "dry run succeeds" run run direnv --dry-run
if grep -q 'DIRENV_ALLOW' "$OUT"; then
  _fail "sent DIRENV_ALLOW for a workspace with devshell = off"
else
  _pass
fi
set_config "$WS" devshell host-eval
assert_ok "dry run succeeds" run run direnv --dry-run
assert_contains "$OUT" "DIRENV_ALLOW=1" "the guest will read the cache"

# --- which kind of dev shell a project has --------------------------------
#
# Mirrors the substrate's own detection. The combination that matters most is
# flake.nix *and* devenv.nix, which needs --impure: getting that wrong fails at
# evaluation rather than visibly.

case_begin "dev-shell detection matches the substrate's"
mkdir -p "$TMP/d-flake" "$TMP/d-both" "$TMP/d-devenv" "$TMP/d-legacy" "$TMP/d-none"
: > "$TMP/d-flake/flake.nix"
: > "$TMP/d-both/flake.nix"; : > "$TMP/d-both/devenv.nix"
: > "$TMP/d-devenv/devenv.nix"
: > "$TMP/d-legacy/.devenv.flake.nix"
kind() { ( . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/run.sh"; devshell_kind "$1" ); }
assert_eq "flake"        "$(kind "$TMP/d-flake")"  "flake.nix alone"
assert_eq "flake-impure" "$(kind "$TMP/d-both")"   "flake.nix with devenv.nix needs --impure"
assert_eq "devenv"       "$(kind "$TMP/d-devenv")" "devenv.nix alone"
assert_eq "devenv"       "$(kind "$TMP/d-legacy")" ".devenv.flake.nix, the older marker"
assert_eq ""             "$(kind "$TMP/d-none")"   "nothing to evaluate"

case_begin "a devenv project without devenv on PATH says so rather than failing"
WS="$(setup devenvless)"
set_config "$WS" devshell host-eval
: > "$WS/work_dir/widget/devenv.nix"
make_stub "$TMP/stub"
export AIRLOCK_TEST_WS="$WS"
# A PATH with the tools airlock needs and no devenv.
mkdir -p "$TMP/nodevenv"
for t in bash git awk cut head tail cat cp mv rm ln mkdir sed grep find wc sort tr basename dirname mktemp env ls seq nix; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$TMP/nodevenv/$t"
done
if PATH="$TMP/nodevenv" command -v devenv >/dev/null 2>&1; then
  skip "devenv is present even on the trimmed PATH"
else
  AIRLOCK_LAUNCHER="$TMP/stub" PATH="$TMP/nodevenv" "$AIRLOCK" run devenvless > "$OUT" 2>&1
  assert_contains "$OUT" "devenv is not on PATH" "names the missing tool"
  assert_absent "$WS/agent_home/.microvm-devshell"
fi

case_begin "container runtimes and their storage cap reach the substrate"
WS="$(setup cri)"
set_config "$WS" cri podman
set_config "$WS" cri_storage_mb 20480
assert_ok "dry run succeeds" run run cri --dry-run
assert_contains "$OUT" "ENABLE_CRI=podman" "the runtime"
assert_contains "$OUT" "CRI_STORAGE_SIZE=20480" "and the cap on its disk"

case_begin "zero means no container disk, and only there"
# CRI_STORAGE_SIZE=0 runs the runtime with storage in RAM. Zero cpus or zero
# memory is a typo, so those stay refused.
set_config "$WS" cri_storage_mb 0
assert_ok "dry run succeeds" run run cri --dry-run
assert_contains "$OUT" "CRI_STORAGE_SIZE=0" "passed through"

# --- registry mirrors (D21) -------------------------------------------------

case_begin "registry is off unless asked, and on means nothing without runtimes"
WS="$(setup mirrors)"
assert_contains "$WS/config" "registry       = off" "a new workspace says off"
set_config "$WS" cri docker,podman
assert_ok "dry run succeeds" run run mirrors --dry-run
if grep -q '^REGISTRY_MIRRORS=' "$OUT"; then _fail "mirrors handed over with registry = off"; else _pass; fi
set_config "$WS" registry on
set_config "$WS" cri ""
assert_ok "dry run succeeds" run run mirrors --dry-run
if grep -q '^REGISTRY_MIRRORS=' "$OUT"; then _fail "mirrors handed over with no runtime to use them"; else _pass; fi

case_begin "registry = on hands the guest every cache, at the address it can reach"
set_config "$WS" cri docker,podman
assert_ok "dry run succeeds" run run mirrors --dry-run
assert_contains "$OUT" "REGISTRY_MIRRORS=docker.io=http://10.0.2.2:5101,ghcr.io=http://10.0.2.2:5102,quay.io=http://10.0.2.2:5103,registry.k8s.io=http://10.0.2.2:5104" "the whole table, guest-side"

# systemctl stands in for the user manager, as in test-registry.sh: a unit is
# running while a file of its name exists.
mkdir -p "$TMP/sysbin" "$TMP/units"
cat > "$TMP/sysbin/systemctl" <<STUB
#!$BASH
[ "\$1" = "--user" ] || exit 1
case "\$2" in
  show-environment) exit 0 ;;
  is-active) if [ -e "$TMP/units/\$3" ]; then echo active; else echo inactive; exit 3; fi ;;
esac
exit 1
STUB
chmod +x "$TMP/sysbin/systemctl"
export AIRLOCK_TEST_WS="$WS"
make_stub "$TMP/stub"

case_begin "the launch carries the mirrors, and warns when no cache is up to serve them"
PATH="$TMP/sysbin:$PATH" AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run mirrors
assert_contains "$TMP/stub.env" "REGISTRY_MIRRORS=docker.io=http://10.0.2.2:5101" "the substrate got them"
assert_contains "$OUT" "no cache is running" "says so"
assert_contains "$OUT" "airlock registry start" "and how to fix it"
assert_contains "$TMP/stub.lock" "env REGISTRY_MIRRORS=docker.io=" "the launch record has them, for status"

case_begin "with a cache running there is nothing to warn about"
touch "$TMP/units/airlock-registry-ghcr.io"
PATH="$TMP/sysbin:$PATH" AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run mirrors
if grep -q "no cache is running" "$OUT"; then _fail "warned with a cache running"; else _pass; fi

case_begin "when systemd cannot be asked, it does not claim no cache is running"
printf '#!%s\nexit 1\n' "$BASH" > "$TMP/sysbin/systemctl"
PATH="$TMP/sysbin:$PATH" AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run mirrors
if grep -q "no cache is running" "$OUT"; then _fail "warned without being able to tell"; else _pass; fi

case_begin "with no systemctl at all, it does not claim no cache is running either"
# The trimmed PATH from the devenv case: the tools airlock needs, and no
# systemctl.
if PATH="$TMP/nodevenv" command -v systemctl >/dev/null 2>&1; then
  skip "systemctl is present even on the trimmed PATH"
else
  AIRLOCK_LAUNCHER="$TMP/stub" PATH="$TMP/nodevenv" "$AIRLOCK" run mirrors > "$OUT" 2>&1
  assert_contains "$TMP/stub.env" "REGISTRY_MIRRORS=" "still launched with the mirrors"
  if grep -q "no cache is running" "$OUT"; then _fail "warned without being able to tell"; else _pass; fi
fi

case_begin "registry off launches without mirrors and without the warning"
set_config "$WS" registry off
PATH="$TMP/sysbin:$PATH" AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run mirrors
if grep -q '^REGISTRY_MIRRORS=' "$TMP/stub.env"; then _fail "the substrate got mirrors"; else _pass; fi
if grep -q "no cache is running" "$OUT"; then _fail "warned about caches it was not using"; else _pass; fi

case_begin "a REGISTRY_MIRRORS in the caller's environment does not override the config"
# The launcher inherits airlock's environment. Off means off, whatever the
# developer has exported from trying the substrate by hand.
REGISTRY_MIRRORS="docker.io=http://elsewhere.example" AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run mirrors
if grep -q '^REGISTRY_MIRRORS=' "$TMP/stub.env"; then _fail "the caller's REGISTRY_MIRRORS leaked through"; else _pass; fi
set_config "$WS" registry on
REGISTRY_MIRRORS="docker.io=http://elsewhere.example" AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run succeeds" run run mirrors
assert_contains "$TMP/stub.env" "REGISTRY_MIRRORS=docker.io=http://10.0.2.2:5101" "on means the caches, not the caller's value"
set_config "$WS" registry off
