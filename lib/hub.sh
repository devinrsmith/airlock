# shellcheck shell=bash
# airlock hub — the hubs, served to guests over SSH (D33).
#
# A workspace's hub lives in its root, which no VM mounts (D3), so nothing in a
# guest can write it, or its config, directly. The only way in is this: one
# unprivileged sshd, run as a systemd --user unit like the registry caches
# (D21), on host loopback, which a guest reaches at 10.0.2.2:<port>. Each
# workspace has a key, and the key's line in authorized_keys forces airlock's
# own command, which runs git-upload-pack or git-receive-pack on that
# workspace's hub and nothing else — whatever the client asked for. So a push
# is receive-pack against a hub whose config only the host writes, and its
# guardrails (receive.denyNonFastForwards, receive.denyDeletes) hold (D17).
#
# Git LFS is not served: a guest cannot push new LFS objects. The objects of
# what a task starts from reach the hub on the host (D25).

hub_usage() {
  cat <<'EOF'
usage: airlock hub [start | stop | restart | status]

  start     start the SSH service through which guests fetch and push
  stop      stop it
  restart   stop it, then start it
  status    whether it runs, and where (the default)

Guests reach it at 10.0.2.2:<port>; it listens on this host's loopback only.
Each workspace's key reaches its own hub and nothing else.
EOF
}

# The port a guest dials, at 10.0.2.2. Beside the registry caches' (D21).
hub_port() { printf '%s\n' "${AIRLOCK_HUB_PORT:-5100}"; }
HUB_GUEST_HOST="10.0.2.2"
HUB_UNIT="airlock-hub"

# The service's own state: its host key, sshd_config, the forced command and
# authorized_keys. State rather than cache: the host key is what guests check
# the service against.
hub_home() {
  if [ -n "${AIRLOCK_HUB_HOME:-}" ]; then
    printf '%s\n' "$AIRLOCK_HUB_HOME"
  else
    printf '%s/airlock/hub\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
  fi
}

# An OpenSSH program: from AIRLOCK_OPENSSH (a package root, for tests), else
# built from airlock's nixpkgs like the registry, so sshd is one known build.
hub_openssh() { # program
  local root nixpkgs
  if [ -n "${AIRLOCK_OPENSSH:-}" ]; then
    root="$AIRLOCK_OPENSSH"
  elif [ "$1" = "ssh-keygen" ] && command -v ssh-keygen >/dev/null 2>&1; then
    # Any ssh-keygen makes an ed25519 key the same way; only sshd is pinned.
    command -v ssh-keygen
    return 0
  else
    nixpkgs="$(nixpkgs_ref)" || die "cannot tell which OpenSSH to run: no nixpkgs in ${AIRLOCK_FLAKE_LOCK:-$AIRLOCK_LIB/../flake.lock}"
    command -v nix >/dev/null 2>&1 || die "nix is not on PATH; it is what provides OpenSSH for the hub"
    root="$(nix build --no-link --print-out-paths "$nixpkgs#openssh" | grep -v -- '-man$' | head -1)" \
      || die "could not build $nixpkgs#openssh"
  fi
  [ -x "$root/bin/$1" ] || die "no $1 in $root/bin"
  printf '%s\n' "$root/bin/$1"
}

# A path written into authorized_keys or sshd_config, which have quoting rules
# of their own; refusing the characters that would need them is simpler than
# getting those rules right.
hub_plain_path() { # path
  case "$1" in
    *[[:space:]\'\"\\]*) die "airlock hub cannot serve a path with spaces, quotes or backslashes in it: $1" ;;
  esac
}

# The service's directory, made the first time: its host key, kept across
# restarts, and the command every key is forced to run.
hub_ensure_home() {
  local home keygen
  home="$(hub_home)"
  hub_plain_path "$home"
  mkdir -p "$home"
  chmod 700 "$home"
  if [ ! -f "$home/host_key" ]; then
    keygen="$(hub_openssh ssh-keygen)" || exit 1
    "$keygen" -q -t ed25519 -N '' -C "airlock hub" -f "$home/host_key" \
      || die "could not make the hub's host key"
  fi
  hub_write_shell "$home"
}

# The forced command. It is given the hub to serve by its authorized_keys line
# and serves only that, so the path the client named, and anything else it
# sent, is ignored. Absolute paths throughout: sshd starts it with a minimal
# PATH, through the user's login shell.
hub_write_shell() { # home
  local git bash
  git="$(command -v git)" || die "git is not on PATH"
  bash="${BASH:-$(command -v bash)}"
  cat > "$1/shell.new" <<EOF
#!$bash
# Written by airlock hub; the command every workspace's key is forced to run.
# \$1 is that workspace's hub. Only fetch and push are served, and only there.
set -eu
case "\${SSH_ORIGINAL_COMMAND:-}" in
  "git-upload-pack "*|"git upload-pack "*)   exec $git upload-pack "\$1" ;;
  "git-receive-pack "*|"git receive-pack "*) exec $git receive-pack "\$1" ;;
  git-lfs-*) echo "airlock hub: Git LFS is not served; LFS objects reach the hub from the host" >&2; exit 1 ;;
  *)         echo "airlock hub: only git fetch and push are served here" >&2; exit 1 ;;
esac
EOF
  chmod 700 "$1/shell.new"
  mv "$1/shell.new" "$1/shell"
}

# One line per workspace that has a key: the key, with every SSH feature but
# the command turned off (restrict), forced to the shell on its own hub.
# Rewritten whole whenever workspaces come and go, and at each launch; sshd
# reads it at every connection, so a running service needs no restart.
hub_sync_keys() {
  local home dh ws name project hub tmp
  home="$(hub_home)"
  [ -d "$home" ] || return 0
  dh="$(data_home)"
  tmp="$home/authorized_keys.new"
  : > "$tmp"
  chmod 600 "$tmp"
  for ws in "$dh"/*/; do
    [ -d "$ws" ] || continue
    ws="${ws%/}"
    name="$(basename "$ws")"
    [ -f "$ws/hub_key.pub" ] || continue
    project="$(config_get "$ws/config" project)"
    [ -n "$project" ] || continue
    hub="$ws/$project.git"
    ( hub_plain_path "$hub" ) || { warn "workspace $name: its hub's path cannot be served"; continue; }
    printf 'restrict,command="%s %s" %s\n' "$home/shell" "$hub" "$(cat "$ws/hub_key.pub")" >> "$tmp"
  done
  mv "$tmp" "$home/authorized_keys"
}

# A workspace's key, made once. In the root, which no VM mounts; each launch
# hands the guest a read-only copy (hub_write_context).
hub_ensure_key() { # root name
  local keygen
  [ -f "$1/hub_key" ] && return 0
  keygen="$(hub_openssh ssh-keygen)" || exit 1
  "$keygen" -q -t ed25519 -N '' -C "airlock workspace $2" -f "$1/hub_key" \
    || die "could not make workspace $2's hub key"
}

hub_write_config() { # home
  local home="$1"
  cat > "$home/sshd_config" <<EOF
# Written by airlock hub start; regenerated at every start.
ListenAddress 127.0.0.1:$(hub_port)
HostKey $home/host_key
AuthorizedKeysFile $home/authorized_keys
AuthenticationMethods publickey
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PidFile none
AllowUsers $(id -un)
DisableForwarding yes
PermitTTY no
PermitUserRC no
PermitUserEnvironment no
PrintMotd no
# The service's view of home is an empty tmpfs (see hub_start), so the
# permission checks on it would refuse every login.
StrictModes no
LogLevel VERBOSE
EOF
}

hub_state() {
  systemctl --user is-active "$HUB_UNIT" 2>/dev/null || true
}

hub_running() { [ "$(hub_state)" = "active" ]; }

hub_preflight() {
  local tool
  for tool in systemctl systemd-run; do
    command -v "$tool" >/dev/null 2>&1 \
      || die "airlock hub runs as a systemd user unit, and $tool is not on PATH"
  done
  systemctl --user show-environment >/dev/null 2>&1 \
    || die "no systemd user manager is reachable (systemctl --user failed)"
}

hub_start() {
  hub_preflight
  if hub_running; then
    info "hub: already running — 127.0.0.1:$(hub_port) on this host, $HUB_GUEST_HOST:$(hub_port) from a guest"
    return 0
  fi
  local home sshd dh
  hub_ensure_home
  home="$(hub_home)"
  hub_write_config "$home"
  hub_sync_keys
  sshd="$(hub_openssh sshd)" || exit 1
  "$sshd" -t -f "$home/sshd_config" || die "sshd refused its config ($home/sshd_config)"
  dh="$(data_home)"
  hub_plain_path "$dh"
  mkdir -p "$dh"

  # It runs git on hubs for guests, so it sees as little of the host as it can
  # still work with, as the registry does (D21): the filesystem read-only, home
  # an empty tmpfs, and only its own directory and the workspaces bound back in
  # — the workspaces writable, since a push writes a hub.
  systemd-run --user --quiet --collect --unit="$HUB_UNIT" --slice=airlock-hub \
    --description="airlock hub: git over SSH for guests (127.0.0.1:$(hub_port), $HUB_GUEST_HOST:$(hub_port) from a guest)" \
    -p Documentation=https://github.com/devinrsmith/airlock#the-hub \
    -p SyslogIdentifier="$HUB_UNIT" \
    -p NoNewPrivileges=yes -p UMask=0077 \
    -p ProtectSystem=strict -p ProtectHome=tmpfs -p PrivateTmp=yes \
    -p BindPaths="$home" -p BindPaths="$dh" \
    -- "$sshd" -D -e -f "$home/sshd_config" >/dev/null \
    || die "systemd-run failed to start the hub"

  # A port in use, or a config the sandbox breaks, makes sshd exit at once.
  sleep "${AIRLOCK_HUB_SETTLE:-1}"
  hub_running || die "the hub did not stay up ($(hub_state)); see: journalctl --user -u $HUB_UNIT"
  info "hub: started — 127.0.0.1:$(hub_port) on this host, $HUB_GUEST_HOST:$(hub_port) from a guest"
}

hub_stop() {
  hub_preflight
  if ! hub_running; then
    info "hub: not running"
    return 0
  fi
  systemctl --user stop "$HUB_UNIT" || die "could not stop $HUB_UNIT"
  info "hub: stopped"
}

hub_status() {
  local state
  state="$(hub_state)"
  printf 'hub: %s' "${state:-unknown}"
  [ "$state" != "active" ] || printf ' — 127.0.0.1:%s on this host, %s:%s from a guest' "$(hub_port)" "$HUB_GUEST_HOST" "$(hub_port)"
  printf '\n  state  %s\n' "$(hub_home)"
  if [ -f "$(hub_home)/authorized_keys" ]; then
    printf '  keys   %s workspace(s)\n' "$(grep -c '' "$(hub_home)/authorized_keys")"
  fi
}

# What a task's guest needs to reach its hub, in the task's context under
# .airlock/, which airlock owns and rewrites at every launch (D29, D33):
#   hub_key      the workspace's key, read-only
#   known_hosts  the service's host key, as the guest addresses it
#   ssh_config   Host airlock-hub: where, as whom, with which key
#   gitconfig    included by the repository only inside a guest (init sets
#                includeIf "gitdir:/work/"): ssh through ssh_config, and the
#                hub's host-relative URL rewritten to airlock-hub, so the same
#                origin is the hub's path on the host and the service in a guest
hub_write_context() { # context root project
  local ctx="$1/.airlock" root="$2" project="$3" home g="/run/microvm/context/.airlock"
  home="$(hub_home)"
  [ -f "$home/host_key.pub" ] || die "the hub has no host key yet (airlock hub start)"
  rm -rf "$ctx"
  mkdir -p "$ctx"
  install -m 0400 "$root/hub_key" "$ctx/hub_key"
  printf '[%s]:%s %s\n' "$HUB_GUEST_HOST" "$(hub_port)" "$(cut -d' ' -f1,2 "$home/host_key.pub")" > "$ctx/known_hosts"
  cat > "$ctx/ssh_config" <<EOF
# Written by airlock run; how this guest reaches its workspace's hub (D33).
Host airlock-hub
  HostName $HUB_GUEST_HOST
  Port $(hub_port)
  User $(id -un)
  IdentityFile $g/hub_key
  IdentitiesOnly yes
  UserKnownHostsFile $g/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
EOF
  cat > "$ctx/gitconfig" <<EOF
# Written by airlock run; included by the worktrees' repository in a guest only.
[core]
	sshCommand = ssh -F $g/ssh_config
[url "airlock-hub:$project.git"]
	insteadOf = ../../../$project.git
EOF
}

cmd_hub() {
  local sub="${1:-status}"
  [ $# -eq 0 ] || shift
  [ $# -eq 0 ] || die "unexpected argument: $1"
  case "$sub" in
    -h|--help|help) hub_usage ;;
    start)   hub_start ;;
    stop)    hub_stop ;;
    restart) hub_stop; hub_start ;;
    status)  hub_status ;;
    *)       hub_usage >&2; die "unknown hub command: $sub" ;;
  esac
}
