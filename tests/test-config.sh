# shellcheck shell=bash
# `airlock config` — reading and editing the two config files.
#
# Modelled on `git config`, minus its one central idea: git resolves a key
# through a hierarchy of scopes, and airlock's two scopes are not a hierarchy
# (D19). There is no merged view here, and the tests below pin that.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
export AIRLOCK_CONFIG="$TMP/airlock-config"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Git Identity
	email = git@example.invalid
[init]
	defaultBranch = main
EOF

AIRLOCK="$REPO_ROOT/bin/airlock"
OUT="$TMP/out"

git init --quiet -b main "$TMP/src"
( cd "$TMP/src" || exit 1
  echo one > file.txt && git add file.txt && git commit --quiet -m "initial" ) >/dev/null 2>&1

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

# --- the global scope ------------------------------------------------------

case_begin "the first set writes a documented template"
rm -f "$AIRLOCK_CONFIG"
assert_ok "set succeeds" run config user_name "A Person"
assert_file "$AIRLOCK_CONFIG"
assert_contains "$AIRLOCK_CONFIG" "never an existing one" "the template explains what the file is for"
assert_contains "$AIRLOCK_CONFIG" "memory_mb" "and lists the keys that can be set"

case_begin "a value round-trips"
assert_ok "get succeeds" run config user_name
assert_contains "$OUT" "A Person" "reads back"

case_begin "setting a value leaves every comment in place"
BEFORE_COMMENTS="$(grep -c '^#' "$AIRLOCK_CONFIG")"
assert_ok "set succeeds" run config cpus 8
assert_eq "$BEFORE_COMMENTS" "$(grep -c '^#' "$AIRLOCK_CONFIG")" "comment count unchanged"
assert_ok "get succeeds" run config cpus
assert_contains "$OUT" "8" "and the value took"

case_begin "an unset key reads as nothing, non-zero"
assert_fails "exits non-zero" run config agent_args
assert_eq "" "$(cat "$OUT")" "and prints nothing"

case_begin "--list names the file and says what the scope means"
assert_ok "list succeeds" run config --list
assert_contains "$OUT" "$AIRLOCK_CONFIG" "names the file"
assert_contains "$OUT" "workspaces created from now on" "says what it is for"
assert_contains "$OUT" "cpus=8" "lists what is set"

case_begin "--unset removes the line from the global file"
assert_ok "unset succeeds" run config --unset cpus
assert_fails "now unset" run config cpus
if grep -qE '^cpus[[:space:]]*=[[:space:]]*[0-9]' "$AIRLOCK_CONFIG"; then
  _fail "the value is still there"
else
  _pass
fi

# --- validation ------------------------------------------------------------

case_begin "an unknown key is refused"
assert_fails "refused" run config nonsense 1
assert_contains "$OUT" "not a key airlock reads" "explains"

case_begin "enum values are checked"
assert_fails "bad prompts" run config prompts maybe
assert_contains "$OUT" "must be 'bypass' or 'prompt'" "names the options"
assert_fails "bad devshell" run config devshell sometimes
assert_fails "bad flavor" run config flavor emacs
assert_ok "a good one is accepted" run config prompts prompt

case_begin "numbers are checked"
assert_fails "not a number" run config cpus lots
assert_contains "$OUT" "whole number" "explains"
assert_fails "zero" run config memory_mb 0
assert_ok "a real number is accepted" run config memory_mb 2048

case_begin "list-shaped values are checked"
assert_fails "bad runtime" run config cri dockerr
assert_ok "good runtimes" run config cri docker,podman
assert_fails "bad env name" run config env_forward "9FOO"
assert_ok "good env forwards" run config env_forward "FOO,BAR=baz"

case_begin "a settings file that is not there yet warns but is accepted"
assert_ok "accepted" run config settings "$TMP/not-yet.json"
assert_contains "$OUT" "no file at" "warns"

# --- the workspace scope ---------------------------------------------------

case_begin "a workspace's own config is a separate scope"
rm -f "$AIRLOCK_CONFIG"
"$AIRLOCK" init demo --from-local "$TMP/src" --project widget >/dev/null 2>&1
assert_ok "get succeeds" run config --workspace demo cpus
assert_contains "$OUT" "4" "the built-in default it was created with"
assert_ok "set succeeds" run config --workspace demo cpus 2
assert_ok "get succeeds" run config --workspace demo cpus
assert_contains "$OUT" "2" "changed"

case_begin "the global scope is untouched by a workspace set"
assert_fails "still unset globally" run config cpus

case_begin "--unset blanks a workspace key but keeps the line"
# A workspace config stays the complete statement of what that workspace does
# (D9), so a key never disappears from it.
assert_ok "unset succeeds" run config --workspace demo cpus
assert_ok "unset succeeds" run config --workspace demo --unset cpus
assert_ok "the line is still there" \
  grep -qE '^cpus[[:space:]]*=' "$AIRLOCK_DATA_HOME/demo/config"
assert_fails "but reads as unset" run config --workspace demo cpus

case_begin "project cannot be changed after init"
assert_fails "refused" run config --workspace demo project something-else
assert_contains "$OUT" "cannot be changed after init" "explains why"

case_begin "a key belongs to the scope that has it"
assert_fails "project is not a global key" run config project widget
assert_ok "but is a workspace key" run config --workspace demo project

case_begin "an unknown workspace is refused"
assert_fails "refused" run config --workspace nosuch cpus

# --- the drift that `config` deliberately does not fix ---------------------

case_begin "changing the identity says the clone is now out of step"
assert_ok "set succeeds" run config --workspace demo user_email "new@example.invalid"
assert_contains "$OUT" "airlock doctor" "points at doctor"

case_begin "doctor detects the identity drift and --fix reconciles it"
assert_fails "doctor reports it" run doctor demo
assert_contains "$OUT" "config says" "shows both sides"
assert_ok "--fix reconciles" run doctor demo --fix
assert_eq "new@example.invalid" \
  "$(git -C "$AIRLOCK_DATA_HOME/demo/work_dir/widget" config --get user.email)" "clone updated"
assert_ok "clean afterwards" run doctor demo

case_begin "changing the flavor leaves a stale context file, and doctor says so"
assert_ok "set succeeds" run config --workspace demo flavor codex
assert_fails "doctor reports it" run doctor demo
assert_contains "$OUT" "AGENTS.md is missing" "the new flavor's file is absent"
assert_contains "$OUT" "CLAUDE.md is left over" "the old flavor's file is still in the share"
assert_ok "--fix reconciles" run doctor demo --fix
assert_file "$AIRLOCK_DATA_HOME/demo/work_dir/AGENTS.md"
assert_absent "$AIRLOCK_DATA_HOME/demo/work_dir/CLAUDE.md"

# --- the editor ------------------------------------------------------------

case_begin "--edit opens the file in \$EDITOR"
cat > "$TMP/fake-editor" <<EOF
#!$BASH
printf 'agent_args = --from-the-editor\n' >> "\$1"
EOF
chmod +x "$TMP/fake-editor"
EDITOR="$TMP/fake-editor" assert_ok "edit succeeds" run config --workspace demo --edit
assert_ok "the edit took" run config --workspace demo agent_args
assert_contains "$OUT" "--from-the-editor" "read back"

case_begin "no editor set is an error, not a guess"
assert_fails "refused" env -u VISUAL -u EDITOR "$AIRLOCK" config --edit

case_begin "setting a key twice leaves one line, not two"
# Appending instead of replacing reads back correctly — config_get takes the
# last match — but the file is meant to be read by a person, and a file with
# two cpus lines is not a statement of anything.
assert_ok "set once" run config cpus 8
assert_ok "set again" run config cpus 6
assert_eq "1" "$(grep -cE '^cpus[[:space:]]*=' "$AIRLOCK_CONFIG")" "one line in the global file"
assert_ok "get succeeds" run config cpus
assert_contains "$OUT" "6" "and it is the new value"
assert_ok "set in a workspace" run config --workspace demo memory_mb 4096
assert_ok "set again" run config --workspace demo memory_mb 2048
assert_eq "1" "$(grep -cE '^memory_mb[[:space:]]*=' "$AIRLOCK_DATA_HOME/demo/config")" \
  "one line in the workspace file"

case_begin "cri_storage_mb accepts zero; the other caps do not"
assert_ok "zero container disk" run config cri_storage_mb 0
assert_fails "zero cpus" run config cpus 0
assert_fails "zero memory" run config memory_mb 0
assert_fails "not a number" run config cri_storage_mb lots
