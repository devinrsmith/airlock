# shellcheck shell=bash
# `airlock path` — where a workspace keeps something.
#
# Its whole reason to exist is being used inside a command substitution, so the
# assertions here care as much about the shape of the output as the value.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
export AIRLOCK_CONFIG="$TMP/airlock-config"
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

git init --quiet -b main "$TMP/src"
( cd "$TMP/src" || exit 1
  echo one > file.txt && git add file.txt && git commit --quiet -m "initial" ) >/dev/null 2>&1
"$AIRLOCK" init demo --from-local "$TMP/src" --project widget >/dev/null 2>&1
WS="$AIRLOCK_DATA_HOME/demo"

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

# --- the use case it exists for -------------------------------------------

case_begin "the hub path can be used to add a remote, without knowing the layout"
git init --quiet -b main "$TMP/mine"
( cd "$TMP/mine" || exit 1
  echo x > x && git add x && git commit --quiet -m "mine" ) >/dev/null 2>&1
assert_ok "remote add from a substitution" \
  git -C "$TMP/mine" remote add hub "$("$AIRLOCK" path demo)"
assert_ok "and it fetches" git -C "$TMP/mine" fetch --quiet hub
assert_ok "the hub's branch arrived" git -C "$TMP/mine" rev-parse --verify refs/remotes/hub/main

case_begin "the output is one bare line, usable unquoted in a substitution"
assert_eq "1" "$("$AIRLOCK" path demo | wc -l)" "exactly one line"
assert_eq "$WS/work_dir/widget.git" "$("$AIRLOCK" path demo)" "and nothing but the path"

# --- selectors --------------------------------------------------------------

case_begin "each selector names a different part of the workspace"
assert_eq "$WS/work_dir/widget.git" "$("$AIRLOCK" path demo --hub)" "hub"
assert_eq "$WS/work_dir/widget" "$("$AIRLOCK" path demo --clone)" "clone"
assert_eq "$WS" "$("$AIRLOCK" path demo --root)" "root"
assert_eq "$WS/agent_home" "$("$AIRLOCK" path demo --agent-home)" "agent home"
assert_eq "$WS/config" "$("$AIRLOCK" path demo --config)" "config"

case_begin "the default is the hub, because that is what it is for"
assert_eq "$("$AIRLOCK" path demo --hub)" "$("$AIRLOCK" path demo)" "same as --hub"

# --- refusals ---------------------------------------------------------------

case_begin "a path to something missing is refused, not printed"
# Printing it would hand a broken path to whatever consumed the substitution,
# and the failure would surface further from the cause.
rm -rf "$WS/work_dir/widget"
assert_fails "refused" run path demo --clone
assert_contains "$OUT" "airlock doctor demo" "points at doctor"
assert_eq "" "$(run path demo --clone 2>/dev/null; true)" "and prints no path"

case_begin "an unknown workspace is refused"
assert_fails "refused" run path nosuchworkspace

case_begin "an unknown selector is refused"
assert_fails "refused" run path demo --sideways

# --- discoverability --------------------------------------------------------

case_begin "status shows the command, so the layout need not be learned"
assert_ok "status succeeds" run status demo
# shellcheck disable=SC2016  # matching the literal text status prints
assert_contains "$OUT" 'git remote add hub "$(airlock path demo)"' "the exact command"
