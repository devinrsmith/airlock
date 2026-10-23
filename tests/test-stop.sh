# shellcheck shell=bash
# Behaviour of `airlock stop`.
#
# The stopping is the substrate's microvm-stop, so what is under test is
# airlock's side: which launch it picks out of the substrate's runtime
# directory, and what it asks the substrate to do. A launch here is an
# instance dir with an instance.json and a lock held by a background process,
# as the substrate's launcher and QEMU hold theirs. AIRLOCK_STOPPER stands in
# for microvm-stop; a fake nix checks the real command line.
#
# These need jq, and skip without it rather than build it.

TMP="$(mktemp -d)"
HOLDERS=()
trap 'kill "${HOLDERS[@]}" 2>/dev/null; rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

# Workspaces are reached through a symlink: the substrate writes the realpath
# of its work dir into instance.json, so airlock has to compare against that.
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
VMS="$XDG_RUNTIME_DIR/claude-microvm/vms"
REAL_DATA="$(realpath "$TMP/data")"

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

if ! command -v jq >/dev/null 2>&1; then
  case_begin "stop"
  skip "needs jq"
  return 0   # sourced by run-tests.sh
fi

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

# hold <file> [content] — hold_lock, keeping every holder to kill later.
hold() { hold_lock "$@"; HOLDERS+=("$HELD_LOCK_PID"); }
release_all() {
  [ "${#HOLDERS[@]}" -eq 0 ] || { kill "${HOLDERS[@]}" 2>/dev/null; wait "${HOLDERS[@]}" 2>/dev/null; }
  HOLDERS=()
}

# launch <id> <work> [running] [json id] — an instance dir as the substrate
# leaves it. Running means its lock is held; json id is what its
# instance.json claims, which is the dir's name unless a test says otherwise.
launch() {
  mkdir -p "$VMS/$1"
  jq -n --arg id "${4:-$1}" --arg work "$2" '{version: 1, id: $id, work: $work}' > "$VMS/$1/instance.json"
  if [ "${3-}" = "running" ]; then hold "$VMS/$1/lock"; else : > "$VMS/$1/lock"; fi
}

cat > "$TMP/stopper" <<EOF
#!$BASH
printf '%s\n' "\$*" > "$TMP/stopper.args"
exit \${STUB_RC:-0}
EOF
chmod +x "$TMP/stopper"
export AIRLOCK_STOPPER="$TMP/stopper"

WS="$(setup alpha)"
setup beta >/dev/null
WORK="$REAL_DATA/alpha/work_dir"

# --- nothing to stop -----------------------------------------------------

case_begin "a workspace with no run is left alone"
assert_ok "succeeds" run stop alpha
assert_contains "$OUT" "alpha is not running" "says so"
assert_absent "$TMP/stopper.args"

case_begin "a stale lock is not a run"
printf '999999\nsubstrate github:o/r/abc\n' > "$WS/lock"
assert_ok "succeeds" run stop alpha
assert_contains "$OUT" "alpha is not running" "says so"
assert_absent "$TMP/stopper.args"
rm -f "$WS/lock"

# --- which launch is this workspace's ------------------------------------

case_begin "the running launch for this workspace's work dir is the one stopped"
hold "$WS/lock"
launch aaaaaaaaaaaa "$WORK" running
launch bbbbbbbbbbbb "$REAL_DATA/beta/work_dir" running   # another workspace's
launch cccccccccccc "$WORK"                              # left over by a killed launcher
launch dddddddddddd "$WORK" running eeeeeeeeeeee         # instance.json is not its own
assert_ok "succeeds" run stop alpha
assert_eq "aaaaaaaaaaaa" "$(cat "$TMP/stopper.args")" "asks for that launch alone, by ID"

case_begin "--force and --timeout are handed on"
assert_ok "succeeds" run stop alpha --force --timeout 5
assert_eq "--force --timeout 5 aaaaaaaaaaaa" "$(cat "$TMP/stopper.args")" "both, before the ID"
assert_ok "succeeds" run stop alpha --timeout=0
assert_eq "--timeout 0 aaaaaaaaaaaa" "$(cat "$TMP/stopper.args")" "the = form too"

case_begin "the stopper's exit status is the command's"
STUB_RC=3 run stop alpha
assert_eq "3" "$?" "still running after the timeout is reported as such"

case_begin "two running launches for one workspace are not guessed between"
hold "$VMS/cccccccccccc/lock"
assert_fails "refused" run stop alpha
assert_contains "$OUT" "aaaaaaaaaaaa, cccccccccccc" "names both"
assert_contains "$OUT" "microvm-stop <id>" "says how to stop one"

case_begin "a run with no launch to find says what to do instead"
release_all
rm -rf "$VMS"
hold "$WS/lock"
rm -f "$TMP/stopper.args"
assert_fails "refused" run stop alpha
assert_contains "$OUT" "no launch under $VMS is for $WORK" "says what it looked for"
assert_contains "$OUT" "exit the agent instead" "and what to do"
assert_absent "$TMP/stopper.args"
release_all

# --- the substrate's microvm-stop ----------------------------------------

mkdir -p "$TMP/fakenix"
cat > "$TMP/fakenix/nix" <<EOF
#!$BASH
printf '%s\n' "\$*" > "$TMP/nix.args"
EOF
chmod +x "$TMP/fakenix/nix"
stop_real() { # args... — with the fake nix and no stopper override
  local rc=0
  env -u AIRLOCK_STOPPER PATH="$TMP/fakenix:$PATH" "$AIRLOCK" stop "$@" > "$OUT" 2>&1 || rc=$?
  return $rc
}

case_begin "a real stop runs the substrate and nixpkgs the VM was launched with"
hold "$WS/lock" "$(printf '%s\n%s\n%s\n%s' "$$" "cwd $TMP" "substrate github:o/r/abc" "nixpkgs github:NixOS/nixpkgs/def")"
launch aaaaaaaaaaaa "$WORK" running
set_config() { sed -i "s|^$2  *=.*|$2 = $3|" "$1/config"; }
set_config "$WS" substrate "github:elsewhere/now"   # the config moving on does not matter
assert_ok "succeeds" stop_real alpha --force
assert_eq "run --override-input nixpkgs github:NixOS/nixpkgs/def github:o/r/abc#microvm-stop -- --force aaaaaaaaaaaa" \
  "$(cat "$TMP/nix.args")" "from the launch record, not the config"
release_all

case_begin "a launch with no nixpkgs override gets none"
hold "$WS/lock" "$(printf '%s\n%s' "$$" "substrate github:o/r/abc")"
launch aaaaaaaaaaaa "$WORK" running
assert_ok "succeeds" stop_real alpha
assert_eq "run github:o/r/abc#microvm-stop -- aaaaaaaaaaaa" "$(cat "$TMP/nix.args")" "the substrate as recorded"
release_all

case_begin "a run that recorded no launch is not guessed at"
rm -f "$TMP/nix.args"
hold "$WS/lock" "$$"
launch aaaaaaaaaaaa "$WORK" running
assert_fails "refused" stop_real alpha
assert_contains "$OUT" "launch was not recorded" "says why"
assert_absent "$TMP/nix.args"
release_all

# --- usage ---------------------------------------------------------------

case_begin "bad arguments are refused"
assert_fails "no name" run stop
assert_fails "unknown workspace" run stop nosuchworkspace
assert_fails "unknown option" run stop alpha --now
assert_fails "--timeout with no value" run stop alpha --timeout
assert_fails "--timeout that is not whole seconds" run stop alpha --timeout 1.5
assert_contains "$OUT" "whole seconds" "says what it wants"
assert_fails "--timeout that is empty" run stop alpha --timeout=
