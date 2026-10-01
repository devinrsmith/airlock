# shellcheck shell=bash
# User-level defaults: settings a person wants on every workspace they create.
#
# They are baked into the workspace config at init, not layered underneath it at
# every read — a workspace's config is meant to be the whole statement of what
# that workspace does (D9). The last case here is what pins that.

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

init_ws() { # name [extra args...]
  local name="$1"; shift
  local rc=0
  "$AIRLOCK" init "$name" --from-local "$TMP/src" --project widget "$@" > "$OUT" 2>&1 || rc=$?
  return $rc
}
cfg() { grep -E "^$2 " "$AIRLOCK_DATA_HOME/$1/config" | sed 's/.*= *//'; }

# --- without a defaults file ----------------------------------------------

case_begin "no defaults file leaves the built-ins in place"
rm -f "$AIRLOCK_CONFIG"
assert_ok "init succeeds" init_ws plain
assert_eq "claude" "$(cfg plain flavor)" "flavor"
assert_eq "4" "$(cfg plain cpus)" "cpus"
assert_eq "bypass" "$(cfg plain prompts)" "prompts"
assert_eq "Git Identity" "$(cfg plain user_name)" "identity falls back to git's"

# --- with one ---------------------------------------------------------------

case_begin "defaults are baked into a new workspace"
cat > "$AIRLOCK_CONFIG" <<'EOF'
flavor     = codex
user_name  = A Person
user_email = person@example.invalid
cpus       = 8
memory_mb  = 16384
prompts    = prompt
devshell   = host-eval
settings   = /etc/airlock/settings.json
agent_args = --verbose
EOF
assert_ok "init succeeds" init_ws mine
assert_eq "codex" "$(cfg mine flavor)" "flavor"
assert_eq "A Person" "$(cfg mine user_name)" "committer name"
assert_eq "person@example.invalid" "$(cfg mine user_email)" "committer email"
assert_eq "8" "$(cfg mine cpus)" "cpus"
assert_eq "16384" "$(cfg mine memory_mb)" "memory"
assert_eq "prompt" "$(cfg mine prompts)" "prompts"
assert_eq "host-eval" "$(cfg mine devshell)" "devshell"
assert_eq "/etc/airlock/settings.json" "$(cfg mine settings)" "settings"
assert_eq "--verbose" "$(cfg mine agent_args)" "agent args"

case_begin "an airlock identity default beats git's"
assert_eq "A Person" "$(cfg mine user_name)" "not Git Identity"

case_begin "a command-line flag beats the default"
assert_ok "init succeeds" init_ws override --flavor claude
assert_eq "claude" "$(cfg override flavor)" "--flavor won"

case_begin "the agent's clone commits under the configured identity"
assert_eq "A Person" \
  "$(git -C "$AIRLOCK_DATA_HOME/mine/work_dir/widget" config --get user.name)" "clone identity"

# --- typos ------------------------------------------------------------------

case_begin "a key airlock does not read is reported"
printf 'cpu = 4\nmemory = 2048\n' >> "$AIRLOCK_CONFIG"
assert_ok "init still succeeds" init_ws typo
assert_contains "$OUT" "'cpu' is not a key airlock reads" "names the typo"
assert_contains "$OUT" "'memory' is not a key airlock reads" "and the other one"
assert_contains "$OUT" "no effect" "says what it means"

# --- the property that makes baking the right choice ------------------------

case_begin "changing the defaults never changes an existing workspace"
BEFORE="$(cat "$AIRLOCK_DATA_HOME/mine/config")"
cat > "$AIRLOCK_CONFIG" <<'EOF'
flavor    = gemini
cpus      = 1
user_name = Someone Else
EOF
assert_ok "a later init picks up the new defaults" init_ws later
assert_eq "gemini" "$(cfg later flavor)" "the new workspace has them"
assert_eq "$BEFORE" "$(cat "$AIRLOCK_DATA_HOME/mine/config")" \
  "the existing workspace is byte-identical"

case_begin "a workspace config stays the whole statement of what it does"
# Nothing airlock reads at launch may come from the user file: a reviewer has
# to be able to read the workspace config alone and know what will happen.
rm -f "$AIRLOCK_CONFIG"
assert_eq "codex" "$(cfg mine flavor)" "still codex with no defaults file at all"
assert_eq "8" "$(cfg mine cpus)" "still 8"
