# shellcheck shell=bash
# airlock registry — pull-through caches of container registries, for guests.
#
# Each upstream gets its own instance of the Docker registry (`distribution`) in
# proxy mode, run as a transient `systemd --user` unit — the same way the
# substrate runs virtiofsd, so it needs no root (D1) and nothing to install.
# Proxy mode refuses pushes, so a cache is pull-only by construction and the hub
# stays the only channel from guest to host (D2). See D21.
#
# Instances listen on host loopback only. A guest reaches host loopback through
# its user-mode network's gateway, so `127.0.0.1:<port>` here is
# `10.0.2.2:<port>` there. Nothing about a guest is configured from here.
#
# The cached blobs are disposable — anything evicted is fetched again — so they
# live under the XDG cache directory, not beside workspaces in data_home, where
# `status` and `doctor` would take a stray directory for a broken workspace.

registry_usage() {
  cat <<'EOF'
usage: airlock registry [status]
       airlock registry start [<upstream>...]
       airlock registry stop [<upstream>...]

  status   which caches are running, where, and how much each holds
  start    start caches (all of them unless named)
  stop     stop caches (all of them unless named); the cached data is kept

Upstreams:
  docker.io  ghcr.io  quay.io  registry.k8s.io

Caches listen on 127.0.0.1 only; a guest reaches one at 10.0.2.2:<port>. They
are pull-only. They run as systemd user units, so they stop when your user
manager does — at logout, unless lingering is enabled for you.
EOF
}

# --- the upstream table --------------------------------------------------
#
# One row per upstream, like the flavor table: adding a registry is a row.
#
#   name | remote URL | host port
registry_row() {
  case "$1" in
    docker.io)       printf 'docker.io\thttps://registry-1.docker.io\t5101\n' ;;
    ghcr.io)         printf 'ghcr.io\thttps://ghcr.io\t5102\n' ;;
    quay.io)         printf 'quay.io\thttps://quay.io\t5103\n' ;;
    registry.k8s.io) printf 'registry.k8s.io\thttps://registry.k8s.io\t5104\n' ;;
    *)               return 1 ;;
  esac
}

REGISTRY_UPSTREAMS="docker.io ghcr.io quay.io registry.k8s.io"

registry_remote() { registry_row "$1" | cut -f2; }
registry_port()   { registry_row "$1" | cut -f3; }
registry_unit()   { printf 'airlock-registry-%s\n' "$1"; }

validate_upstream() {
  registry_row "$1" >/dev/null 2>&1 \
    || die "unknown upstream: $1 (known: ${REGISTRY_UPSTREAMS// /, })"
}

registry_home() {
  if [ -n "${AIRLOCK_REGISTRY_HOME:-}" ]; then
    printf '%s\n' "$AIRLOCK_REGISTRY_HOME"
  else
    printf '%s/airlock/registry\n' "${XDG_CACHE_HOME:-$HOME/.cache}"
  fi
}

# --- the registry package ------------------------------------------------
#
# Which `distribution` to run, as a flake reference into the nixpkgs airlock is
# locked against — the same arrangement as the substrate (D10): an installed
# build has it baked in, a source checkout reads the revision out of flake.lock,
# so both run the same build and `nix flake update` is how it moves.
registry_pkg_ref() {
  local lock rev
  if [ -n "${AIRLOCK_REGISTRY_PKG:-}" ]; then
    printf '%s\n' "$AIRLOCK_REGISTRY_PKG"
    return 0
  fi
  lock="${AIRLOCK_FLAKE_LOCK:-$AIRLOCK_LIB/../flake.lock}"
  rev="$(flake_lock_rev "$lock" nixpkgs)" \
    || die "cannot tell which registry to run: no AIRLOCK_REGISTRY_PKG and no nixpkgs in $lock"
  printf 'github:NixOS/nixpkgs/%s#distribution\n' "$rev"
}

# The registry executable, built (or fetched) on first use and a store lookup
# after that.
registry_bin() {
  local ref out
  ref="$(registry_pkg_ref)" || exit 1
  command -v nix >/dev/null 2>&1 || die "nix is not on PATH; it is what provides the registry"
  out="$(nix build --no-link --print-out-paths "$ref" | head -1)" \
    || die "could not build $ref"
  [ -x "$out/bin/registry" ] || die "$ref has no bin/registry (in $out)"
  printf '%s\n' "$out/bin/registry"
}

registry_preflight() {
  local tool
  for tool in systemctl systemd-run; do
    command -v "$tool" >/dev/null 2>&1 \
      || die "registry runs its caches as systemd user units, and $tool is not on PATH"
  done
  systemctl --user show-environment >/dev/null 2>&1 \
    || die "no systemd user manager is reachable (systemctl --user failed)"
}

# active, inactive, failed, activating, ... — whatever systemd says, verbatim.
registry_state() { # upstream
  systemctl --user is-active "$(registry_unit "$1")" 2>/dev/null || true
}

# The instance's config, regenerated at every start: airlock owns it, and a
# stale one should not outlive a change to the table.
registry_write_config() { # upstream dir
  local upstream="$1" dir="$2"
  local data="$dir/data"
  # YAML single quotes: the only escape is a doubled quote.
  local q="'${data//\'/\'\'}'"
  mkdir -p "$data"
  cat > "$dir/config.yml" <<EOF
# Written by airlock registry start; regenerated at every start.
version: 0.1
storage:
  filesystem:
    rootdirectory: $q
http:
  addr: 127.0.0.1:$(registry_port "$upstream")
proxy:
  remoteurl: $(registry_remote "$upstream")
log:
  level: warn
EOF
}

registry_start_one() { # upstream bin
  local upstream="$1" bin="$2" unit dir state
  unit="$(registry_unit "$upstream")"
  dir="$(registry_home)/$upstream"
  registry_write_config "$upstream" "$dir"

  # The registry parses requests guests control, outside any VM (D21), so it
  # sees as little of this host as it can still work with: the whole
  # filesystem read-only (ProtectSystem=strict), home replaced by an empty
  # tmpfs so nothing in it can be read either (ProtectHome=tmpfs — read-only
  # would still expose keys and tokens to a process that can talk to the
  # network), and only its own directory bound back in, writable. strict alone
  # leaves home writable in a user unit; it takes both. Verified 2026-10-15.
  # Metadata for whoever meets the unit in `systemctl --user status` or the
  # journal: what it is, where it is documented, a journal tag that tells the
  # four apart (the binary alone would tag them all "registry"), and one slice
  # for the lot, so `systemctl --user status airlock.slice` shows every cache.
  systemd-run --user --quiet --collect --unit="$unit" --slice=airlock \
    --description="airlock registry: $upstream (pull-through cache of $(registry_remote "$upstream"))" \
    -p Documentation=https://github.com/devinrsmith/airlock#registry-caches \
    -p SyslogIdentifier="$unit" \
    -p NoNewPrivileges=yes -p UMask=0077 \
    -p ProtectSystem=strict -p ProtectHome=tmpfs -p PrivateTmp=yes \
    -p BindPaths="$dir" \
    -- "$bin" serve "$dir/config.yml" >/dev/null \
    || { warn "$upstream: systemd-run failed"; return 1; }

  # A bad port or config makes the registry exit at once, and systemd-run has
  # already returned by then — so look again before calling it started. The
  # sandbox needs unprivileged user namespaces in a user unit; a host without
  # them lands here too, and the journal says which it was.
  sleep "${AIRLOCK_REGISTRY_SETTLE:-1}"
  state="$(registry_state "$upstream")"
  if [ "$state" != "active" ]; then
    warn "$upstream: did not stay up (${state:-gone}); see: journalctl --user -u $unit"
    return 1
  fi
  info "$upstream: started — 127.0.0.1:$(registry_port "$upstream") on this host, 10.0.2.2:$(registry_port "$upstream") from a guest"
}

registry_targets() { # upstream...
  local u
  if [ $# -eq 0 ]; then
    # shellcheck disable=SC2086  # a list of words, split on purpose
    printf '%s\n' $REGISTRY_UPSTREAMS
    return
  fi
  for u in "$@"; do
    validate_upstream "$u"
    printf '%s\n' "$u"
  done
}

registry_start() {
  local targets u bin="" failed=0
  targets="$(registry_targets "$@")" || exit 1
  registry_preflight
  for u in $targets; do
    if [ "$(registry_state "$u")" = "active" ]; then
      info "$u: already running — 10.0.2.2:$(registry_port "$u") from a guest"
      continue
    fi
    # Resolved only once something needs starting: a no-op start should not
    # wait on nix. Command substitutions do not inherit errexit, so a die in
    # one ends only the subshell: every one of them is checked explicitly.
    [ -n "$bin" ] || bin="$(registry_bin)" || exit 1
    registry_start_one "$u" "$bin" || failed=1
  done
  [ "$failed" -eq 0 ]
}

registry_stop() {
  local targets u
  targets="$(registry_targets "$@")" || exit 1
  registry_preflight
  for u in $targets; do
    if [ "$(registry_state "$u")" != "active" ]; then
      [ $# -eq 0 ] || info "$u: not running"
      continue
    fi
    systemctl --user stop "$(registry_unit "$u")" || die "$u: could not stop $(registry_unit "$u")"
    info "$u: stopped"
  done
}

registry_status() {
  local u state size dir home
  registry_preflight
  home="$(registry_home)"
  printf '%-16s %-6s %-10s %s\n' UPSTREAM PORT STATE CACHED
  for u in $REGISTRY_UPSTREAMS; do
    state="$(registry_state "$u")"
    dir="$home/$u/data"
    size="-"
    [ -d "$dir" ] && size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
    printf '%-16s %-6s %-10s %s\n' "$u" "$(registry_port "$u")" "${state:-unknown}" "$size"
  done
  printf '\ncache data: %s\n' "$home"
  printf 'from a guest, a running cache is http://10.0.2.2:<port> (pull-only)\n'
}

cmd_registry() {
  local sub="${1:-status}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    -h|--help|help) registry_usage ;;
    start)  registry_start "$@" ;;
    stop)   registry_stop "$@" ;;
    status) [ $# -eq 0 ] || die "registry status takes no arguments"; registry_status ;;
    *)      registry_usage >&2; die "unknown registry command: $sub" ;;
  esac
}
