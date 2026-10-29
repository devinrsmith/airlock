# shellcheck shell=bash
# Behaviour of the hub service (D33): the hub in the unmounted root, each
# workspace's key forced to its own hub, the guest's way in written into the
# task's context, and a real sshd that serves fetch and push and nothing else.
#
# The service is started by `airlock hub start` as it would be, with stub
# systemd-run and systemctl that run sshd as an ordinary background process on
# a port of the test's own. A "guest" is played by ssh with a workspace's key.

TMP="$(mktemp -d)"
trap '[ -f "$TMP/stub/pid" ] && kill "$(cat "$TMP/stub/pid")" 2>/dev/null; rm -rf -- "$TMP"' EXIT
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
# A port of the test's own, not the real service's.
export AIRLOCK_HUB_PORT=$(( 20000 + RANDOM % 20000 ))
AIRLOCK="$REPO_ROOT/bin/airlock"
OUT="$TMP/out"
run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

if [ -z "${AIRLOCK_OPENSSH:-}" ] || [ ! -x "$AIRLOCK_OPENSSH/bin/sshd" ]; then
  case_begin "hub"
  skip "no OpenSSH (AIRLOCK_OPENSSH)"
  return 0   # sourced by run-tests.sh
fi
SSH="$AIRLOCK_OPENSSH/bin/ssh"

setup() { # name -> echoes the workspace root
  local src="$TMP/src-$1"
  {
    git init --quiet -b main "$src"
    ( cd "$src" || exit 1; echo one > file.txt; git add file.txt; git commit --quiet -m one )
    "$AIRLOCK" init "$1" --from-local "$src" --project widget
    "$AIRLOCK" task new "$1" t
  } >/dev/null 2>&1
  printf '%s/%s\n' "$AIRLOCK_DATA_HOME" "$1"
}

# --- the layout ------------------------------------------------------------

case_begin "the hub is in the root, out of every guest's reach"
A="$(setup alpha)"
B="$(setup beta)"
assert_ok "the hub is in the root" git -C "$A/widget.git" rev-parse --git-dir
assert_absent "$A/work_dir/widget.git"
assert_eq "true" "$(git -C "$A/widget.git" config receive.denyNonFastForwards)" "guardrails set"

case_begin "each workspace has a key, forced to its own hub"
assert_file "$A/hub_key"
assert_file "$A/hub_key.pub"
KEYS="$AIRLOCK_HUB_HOME/authorized_keys"
assert_file "$KEYS"
assert_contains "$KEYS" "restrict,command=\"$AIRLOCK_HUB_HOME/shell $A/widget.git\" $(cat "$A/hub_key.pub")" "alpha's line"
assert_contains "$KEYS" "restrict,command=\"$AIRLOCK_HUB_HOME/shell $B/widget.git\" $(cat "$B/hub_key.pub")" "beta's line"
assert_file "$AIRLOCK_HUB_HOME/host_key"

case_begin "the repository reaches the hub by its host path, and over SSH only in a guest"
assert_eq "../../../widget.git" "$(git -C "$A/work_dir/.repo" remote get-url origin)" "relative origin"
assert_eq "/run/microvm/context/.airlock/gitconfig" \
  "$(git -C "$A/work_dir/.repo" config --get includeIf.gitdir:/work/.path)" "guest-only include"
assert_ok "the host fetches through it, as the agent would" git -C "$A/work_dir/tasks/t" fetch --quiet origin

# --- what a launch hands the guest ----------------------------------------

case_begin "a launch writes the guest's way to its hub into the task's context"
printf '#!%s\nexit 0\n' "$BASH" > "$TMP/launcher"; chmod +x "$TMP/launcher"
export ANTHROPIC_API_KEY=not-real
AIRLOCK_LAUNCHER="$TMP/launcher" AIRLOCK_SUBSTRATE="$TMP" AIRLOCK_NIXPKGS="github:x/y/0" run run alpha t
CTX="$A/tasks/t/context/.airlock"
assert_ok "the key, the workspace's" cmp "$CTX/hub_key" "$A/hub_key"
assert_eq "400" "$(stat -c %a "$CTX/hub_key")" "read-only"
assert_contains "$CTX/known_hosts" "[10.0.2.2]:$AIRLOCK_HUB_PORT $(cut -d' ' -f1,2 "$AIRLOCK_HUB_HOME/host_key.pub")" "the service's host key"
assert_contains "$CTX/ssh_config" "Port $AIRLOCK_HUB_PORT" "the port"
assert_contains "$CTX/ssh_config" "User $(id -un)" "the host's user"
assert_contains "$CTX/ssh_config" "StrictHostKeyChecking yes" "checked"
assert_contains "$CTX/gitconfig" "sshCommand = ssh -F /run/microvm/context/.airlock/ssh_config" "ssh through it"
assert_contains "$CTX/gitconfig" "insteadOf = ../../../widget.git" "the host path rewritten"
assert_contains "$OUT" "the hub is not running" "a launch without the service says so"

# --- the service -------------------------------------------------------------

mkdir -p "$TMP/stub"
cat > "$TMP/stub/systemd-run" <<EOF
#!$BASH
printf '%s\n' "\$@" > "$TMP/stub/run-args"
while [ \$# -gt 0 ] && [ "\$1" != "--" ]; do shift; done
shift
"\$@" > "$TMP/stub/sshd.log" 2>&1 &
echo \$! > "$TMP/stub/pid"
EOF
cat > "$TMP/stub/systemctl" <<EOF
#!$BASH
case "\$*" in
  "--user show-environment") exit 0 ;;
  "--user is-active airlock-hub")
    if [ -f "$TMP/stub/pid" ] && kill -0 "\$(cat "$TMP/stub/pid")" 2>/dev/null; then echo active; else echo inactive; exit 3; fi ;;
  "--user stop airlock-hub") kill "\$(cat "$TMP/stub/pid")"; rm -f "$TMP/stub/pid" ;;
esac
EOF
chmod +x "$TMP/stub/systemd-run" "$TMP/stub/systemctl"
hubctl() { PATH="$TMP/stub:$PATH" AIRLOCK_HUB_SETTLE=1 "$AIRLOCK" hub "$@"; }

case_begin "hub start runs sshd sandboxed, on loopback only"
assert_ok "starts" hubctl start
assert_contains "$TMP/stub/run-args" "ProtectHome=tmpfs" "home hidden"
assert_contains "$TMP/stub/run-args" "ProtectSystem=strict" "system read-only"
assert_contains "$TMP/stub/run-args" "BindPaths=$AIRLOCK_DATA_HOME" "workspaces bound back"
assert_contains "$AIRLOCK_HUB_HOME/sshd_config" "ListenAddress 127.0.0.1:$AIRLOCK_HUB_PORT" "loopback"
assert_contains "$AIRLOCK_HUB_HOME/sshd_config" "DisableForwarding yes" "no forwarding"
hubctl status > "$OUT" 2>&1
assert_contains "$OUT" "hub: active" "status says so"

# A guest, played by ssh with a workspace's key against the service. sshd runs
# the forced command through the user's login shell, which a build sandbox may
# not have (nixbld's is /noshell); the cases that need a session skip there.
LOGIN_SHELL="$(awk -F: -v u="$(id -un)" '$1 == u { print $7 }' /etc/passwd 2>/dev/null)"
if [ -z "$LOGIN_SHELL" ] || [ ! -x "$LOGIN_SHELL" ]; then
  case_begin "hub sessions"
  skip "$(id -un) has no usable login shell (${LOGIN_SHELL:-none}), which sshd runs the forced command through"
  hubctl stop >/dev/null 2>&1
  return 0   # sourced by run-tests.sh
fi
"$AIRLOCK_OPENSSH/bin/ssh-keyscan" -p "$AIRLOCK_HUB_PORT" 127.0.0.1 2>/dev/null | grep -v '^#' \
  | sed "s/^127.0.0.1/[127.0.0.1]:$AIRLOCK_HUB_PORT/" > "$TMP/known_hosts"
as() { # workspace-root -> GIT_SSH_COMMAND for that workspace's key
  printf '%s -i %s -o IdentitiesOnly=yes -o UserKnownHostsFile=%s -o StrictHostKeyChecking=yes -o BatchMode=yes' \
    "$SSH" "$1/hub_key" "$TMP/known_hosts"
}
URL="ssh://$(id -un)@127.0.0.1:$AIRLOCK_HUB_PORT/whatever.git"
git init --quiet -b main "$TMP/guest"
( cd "$TMP/guest" && git pull --quiet "$A/widget.git" main && echo two >> file.txt && git commit --quiet -am two ) >/dev/null 2>&1

case_begin "a push over SSH lands in the key's own hub, whatever the URL names"
assert_ok "push" env GIT_SSH_COMMAND="$(as "$A")" git -C "$TMP/guest" push --quiet "$URL" main:agent/over-ssh
assert_ok "in alpha's hub" git -C "$A/widget.git" rev-parse --verify --quiet refs/heads/agent/over-ssh
if git -C "$B/widget.git" rev-parse --verify --quiet refs/heads/agent/over-ssh >/dev/null; then
  _fail "landed in beta's hub"; else _pass; fi
assert_ok "fetch" env GIT_SSH_COMMAND="$(as "$A")" git -C "$TMP/guest" fetch --quiet "$URL" agent/over-ssh

case_begin "the guardrails hold, since the hub's config is the host's (D17)"
( cd "$TMP/guest" && git commit --quiet --amend -m rewritten ) >/dev/null 2>&1
assert_fails "force push refused" env GIT_SSH_COMMAND="$(as "$A")" git -C "$TMP/guest" push --force "$URL" main:agent/over-ssh
assert_fails "deletion refused" env GIT_SSH_COMMAND="$(as "$A")" git -C "$TMP/guest" push "$URL" :agent/over-ssh

case_begin "nothing but fetch and push is served"
$(as "$A") -p "$AIRLOCK_HUB_PORT" "$(id -un)@127.0.0.1" "touch $TMP/pwned" > "$OUT" 2>&1 < /dev/null
assert_contains "$OUT" "only git fetch and push are served here" "a command is refused"
assert_absent "$TMP/pwned"
$(as "$A") -p "$AIRLOCK_HUB_PORT" "$(id -un)@127.0.0.1" "git-lfs-transfer x upload" > "$OUT" 2>&1 < /dev/null
assert_contains "$OUT" "Git LFS is not served" "LFS is refused by name"

case_begin "a removed workspace's key stops working at once"
mkdir -p "$TMP/beta-key" && cp "$B/hub_key" "$TMP/beta-key/hub_key"
assert_ok "beta's key works before" env GIT_SSH_COMMAND="$(as "$TMP/beta-key")" \
  git -C "$TMP/guest" fetch --quiet "$URL" main
assert_ok "rm" run rm beta --yes
if grep -qF "$B/widget.git" "$KEYS"; then _fail "beta is still authorised"; else _pass; fi
assert_fails "beta's key is refused" env GIT_SSH_COMMAND="$(as "$TMP/beta-key")" \
  git -C "$TMP/guest" fetch --quiet "$URL" main

case_begin "hub stop stops it"
assert_ok "stops" hubctl stop
hubctl status > "$OUT" 2>&1
assert_contains "$OUT" "hub: inactive" "status says so"
