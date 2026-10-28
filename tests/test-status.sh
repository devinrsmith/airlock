# shellcheck shell=bash
# Behaviour of `airlock status` (§5, §7).
#
# status is read-only and offline. The assertions below pin that as much as
# they pin the output: it must never fetch, repair, or write anything.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
# A stand-in for the baked-in substrate, so the "default" status compares
# against is fixed rather than whatever this checkout is locked to.
export AIRLOCK_SUBSTRATE="github:systemstart/claude-microvm/0000000"
export AIRLOCK_NIXPKGS="github:NixOS/nixpkgs/0000000"
export AIRLOCK_CONFIG="$TMP/no-user-config"
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

case_begin "a fresh workspace has nothing ahead of its default branch"
WS="$(setup quiet)"
assert_ok "status succeeds" run status
assert_contains "$OUT" "quiet" "lists the workspace"
assert_contains "$OUT" "nothing ahead of main" "and says it is quiet"
assert_contains "$OUT" "stopped" "reports the VM as stopped"

case_begin "pushed work is counted in the list"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/one "first" a.txt
agent_push "$WS/work_dir/widget" "$HUB" agent/one "second" b.txt
assert_ok "status succeeds" run status
assert_contains "$OUT" "1 branch, 2 commit(s)" "counts branches and commits"

case_begin "a stacked branch counts shared commits once"
# agent/two is cut from agent/one, so it carries first and second as well.
agent_push "$WS/work_dir/widget" "$HUB" agent/two "third" c.txt
assert_ok "status succeeds" run status
assert_contains "$OUT" "2 branches, 3 commit(s)" "counts both, distinct commits"

case_begin "work that reaches the default branch drops out"
git -C "$HUB" update-ref refs/heads/main "$(git -C "$HUB" rev-parse refs/heads/agent/one)"
assert_ok "status succeeds" run status
assert_contains "$OUT" "1 branch, 1 commit(s)" "only what main still lacks"
git -C "$HUB" update-ref refs/heads/main "$(git -C "$HUB" rev-parse refs/heads/agent/two)"
assert_ok "status succeeds" run status
assert_contains "$OUT" "nothing ahead of main" "quiet again"

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
assert_contains "$OUT" "not pushed to the hub" "and is clear it has not arrived"
assert_contains "$OUT" "nothing ahead of main" "uncommitted work is not pushed work"

case_begin "detail lists branches ahead of the default with their counts"
agent_push "$WS/work_dir/widget" "$HUB" agent/topic "the work" t.txt
assert_ok "status succeeds" run status detail
assert_contains "$OUT" "ahead of main" "explains the baseline"
assert_contains "$OUT" "agent/topic" "names the branch"
assert_contains "$OUT" "1 commit(s)" "counts it"
# shellcheck disable=SC2016  # the substitution is literal text status prints
assert_contains "$OUT" 'git remote add hub "$(airlock path detail)"' "says how to fetch it"

# --- a running VM ---------------------------------------------------------

case_begin "a live lock is reported as a running VM"
WS="$(setup livevm)"   # not named "running": the assertions below look for that word
hold_lock "$WS/lock"
assert_ok "status succeeds" run status livevm
assert_contains "$OUT" "running (pid $$)" "detail names the pid"
assert_ok "list succeeds" run status
assert_contains "$OUT" "running" "list says running"
drop_lock "$WS/lock"
assert_ok "status succeeds" run status livevm
assert_contains "$OUT" "stopped" "stopped once the lock is gone"

case_begin "a stale lock is not a running VM"
echo 999999 > "$WS/lock"
assert_ok "status succeeds" run status livevm
assert_contains "$OUT" "stopped" "a dead pid is not running"
# The pid is for people to read: a live process that does not hold the lock —
# a pid reused after a crash or a reboot — is not a running VM.
echo $$ > "$WS/lock"
assert_ok "status succeeds" run status livevm
assert_contains "$OUT" "stopped" "a live pid without the lock is not running"
rm -f "$WS/lock"

# --- which substrate a workspace runs on -----------------------------------

set_config() { # workspace key value
  sed -i "s|^$2  *=.*|$2 = $3|" "$1/config"
}

case_begin "a workspace on the default substrate is not marked"
WS="$(setup plainsub)"
assert_ok "status succeeds" run status
if grep -q 'plainsub .*\*' "$OUT" || grep -q 'substrate other than the default' "$OUT"; then
  _fail "marked a workspace that runs the default substrate"
else
  _pass
fi
assert_ok "detail succeeds" run status plainsub
assert_contains "$OUT" "substrate    $AIRLOCK_SUBSTRATE (default)" "detail names the default"
assert_contains "$OUT" "nixpkgs      $AIRLOCK_NIXPKGS (airlock's, overriding the substrate's own)" \
  "and the nixpkgs it runs on"

case_begin "a key that restates the default is not an override"
set_config "$WS" substrate "$AIRLOCK_SUBSTRATE"
assert_ok "status succeeds" run status
if grep -q 'substrate other than the default' "$OUT"; then
  _fail "marked a workspace pinned to the default itself"
else
  _pass
fi

case_begin "a workspace pinned elsewhere is marked in the list and named in detail"
set_config "$WS" substrate "github:systemstart/claude-microvm/deadbeef"
assert_ok "status succeeds" run status
if grep -Eq '^plainsub +widget +claude +stopped\* ' "$OUT"; then _pass; else _fail "no marker on the workspace's row"; fi
if grep -Eq '^(quiet|detail) .*\*' "$OUT"; then _fail "marked a workspace that was not pinned"; else _pass; fi
assert_contains "$OUT" "* on a substrate other than the default" "explains the marker"
assert_ok "detail succeeds" run status plainsub
assert_contains "$OUT" \
  "substrate    github:systemstart/claude-microvm/deadbeef (overrides default $AIRLOCK_SUBSTRATE)" \
  "detail names the ref it will launch, and the default"
assert_contains "$OUT" "nixpkgs      the substrate's own lock" "a pinned substrate keeps its nixpkgs"

case_begin "a relative ref is resolved the way run resolves it"
set_config "$WS" substrate "./local-substrate"
assert_ok "detail succeeds" run status plainsub
assert_contains "$OUT" "substrate    $TMP/local-substrate (overrides" "absolute, against the caller's cwd"
rm -rf "$WS"

# --- what a running VM was launched with ------------------------------------
#
# The stub launcher runs status itself, while `run` holds the lock, so these
# read the launch record `run` really writes rather than one written by hand.
# STUB_BEFORE is evaluated first: it is how a case changes the config under a
# running VM.

cat > "$TMP/statusstub" <<STUB
#!$BASH
[ -z "\${STUB_BEFORE:-}" ] || eval "\$STUB_BEFORE"
"$AIRLOCK" status > "$TMP/during.list" 2>&1
"$AIRLOCK" status "\$STUB_WS" > "$TMP/during.detail" 2>&1
STUB
chmod +x "$TMP/statusstub"

launch() { # name [args after --...] — runs status from inside the launch
  local name="$1"; shift
  rm -f "$TMP/during.list" "$TMP/during.detail"
  STUB_WS="$name" AIRLOCK_LAUNCHER="$TMP/statusstub" ANTHROPIC_API_KEY=not-real \
    "$AIRLOCK" run "$name" ${1+--} "$@" > "$OUT" 2>&1
}

case_begin "a VM running on the default substrate is reported as launched"
WS="$(setup launched)"
launch launched
assert_contains "$TMP/during.detail" "substrate    $AIRLOCK_SUBSTRATE (running; default)" "names what it runs on"
assert_contains "$TMP/during.detail" "nixpkgs      $AIRLOCK_NIXPKGS (airlock's" "and the nixpkgs it was launched on"
assert_contains "$TMP/during.detail" "config       as launched" "and that nothing has changed"
if grep -Eq '^launched .*running[*!]' "$TMP/during.list"; then _fail "marked a VM running as configured"; else _pass; fi

case_begin "a VM running on a pinned substrate is marked"
set_config "$WS" substrate "github:systemstart/claude-microvm/deadbeef"
launch launched
if grep -Eq '^launched +widget +claude +running\* ' "$TMP/during.list"; then _pass; else _fail "no * on the running row"; fi
assert_contains "$TMP/during.detail" \
  "substrate    github:systemstart/claude-microvm/deadbeef (running; overrides default $AIRLOCK_SUBSTRATE)" \
  "detail names the running ref"

case_begin "unpinning under a running VM reports what runs, not what is configured"
STUB_BEFORE="sed -i 's|^substrate  *=.*|substrate =|' '$WS/config'" launch launched
assert_contains "$TMP/during.detail" "substrate    github:systemstart/claude-microvm/deadbeef (running;" \
  "the running VM is still on the pinned ref"
assert_contains "$TMP/during.detail" "config       changed since launch: substrate, nixpkgs —" \
  "and the change is named, with the override the default would bring"
if grep -Eq '^launched +widget +claude +running\*! ' "$TMP/during.list"; then _pass; else _fail "list lacks *!"; fi
assert_contains "$TMP/during.list" "! config changed since this VM launched" "explains the marker"

case_begin "a changed setting is named by its config key"
STUB_BEFORE="sed -i 's|^memory_mb  *=.*|memory_mb = 1024|' '$WS/config'" launch launched
assert_contains "$WS/config" "memory_mb = 1024" "fixture: the edit applied"
assert_contains "$TMP/during.detail" "changed since launch: memory_mb —" "memory_mb, not VM_MEM"
if grep -Eq '^launched +widget +claude +running! ' "$TMP/during.list"; then _pass; else _fail "list lacks !"; fi

case_begin "turning registry on under a running VM is named as registry"
set_config "$WS" memory_mb 8192
set_config "$WS" cri docker
STUB_BEFORE="sed -i 's|^registry  *=.*|registry = on|' '$WS/config'" launch launched
assert_contains "$WS/config" "registry = on" "fixture: the edit applied"
assert_contains "$TMP/during.detail" "changed since launch: registry —" "registry, not REGISTRY_MIRRORS"
set_config "$WS" registry off
set_config "$WS" cri ""

case_begin "arguments after -- belong to the run, not the config"
set_config "$WS" memory_mb 8192
launch launched -p "say hello"
assert_contains "$TMP/during.detail" "run args     -p say hello" "shown"
assert_contains "$TMP/during.detail" "config       as launched" "and not mistaken for a change"

case_begin "a config that no longer launches is said so, not fatal"
STUB_BEFORE="sed -i 's|^settings  *=.*|settings = $TMP/no-such-settings.json|' '$WS/config'" launch launched
assert_contains "$TMP/during.detail" "would not launch now — airlock run launched --dry-run says why" "says so"
if grep -Eq '^launched .*running! ' "$TMP/during.list"; then _pass; else _fail "list lacks !"; fi
set_config "$WS" settings ""

case_begin "relative paths are compared from where the run started"
set_config "$WS" substrate "./local-substrate"
# Launched from $TMP; the stub runs status from the workspace root.
launch launched
assert_contains "$TMP/during.detail" "substrate    $TMP/local-substrate (running;" "recorded resolved"
assert_contains "$TMP/during.detail" "config       as launched" "not a change just because status ran elsewhere"

case_begin "a stale lock's record is not a running VM's"
set_config "$WS" substrate "github:systemstart/claude-microvm/deadbeef"
printf '999999\nsubstrate github:elsewhere/x\n' > "$WS/lock"
assert_ok "detail succeeds" run status launched
assert_contains "$OUT" "substrate    github:systemstart/claude-microvm/deadbeef (overrides" "the config, not the dead record"
rm -f "$WS/lock"
rm -rf "$WS"

# --- status changes nothing ----------------------------------------------

case_begin "status never writes to the hub or the workspace"
WS="$(setup readonly)"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/topic "work" w.txt
BEFORE_REFS="$(git -C "$HUB" for-each-ref --format='%(refname) %(objectname)')"
BEFORE_ROOT="$(ls -A "$WS")"
run status readonly
run status
assert_eq "$BEFORE_REFS" "$(git -C "$HUB" for-each-ref --format='%(refname) %(objectname)')" "hub refs untouched"
assert_eq "$BEFORE_ROOT" "$(ls -A "$WS")" "nothing new in the workspace root"

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
