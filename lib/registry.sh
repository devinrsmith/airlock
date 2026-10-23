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
       airlock registry restart [<upstream>...]
       airlock registry import [--write]

  status   which caches are running, where, what each pulls from, and how
           much each holds
  start    start caches (all of them unless named)
  stop     stop caches (all of them unless named); the cached data is kept
  restart  stop, then start: how a change to the remotes file takes effect
  import   propose remotes from this host's registries.conf, as Podman reads
           it; --write writes them into the remotes file

Upstreams:
  docker.io  ghcr.io  quay.io  registry.k8s.io

Caches listen on 127.0.0.1 only; a guest reaches one at 10.0.2.2:<port>. They
are pull-only. They run as systemd user units, so they stop when your user
manager does — at logout, unless lingering is enabled for you.

Each cache pulls from its upstream's public endpoint unless the remotes file
names another, such as a mirror on your LAN — one line per upstream:

  docker.io = http://mirror.lan:5000

The file is $XDG_CONFIG_HOME/airlock/registry; `status` shows which it is.
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

registry_default_remote() { registry_row "$1" | cut -f2; }
registry_port()           { registry_row "$1" | cut -f3; }
registry_unit()   { printf 'airlock-registry-%s\n' "$1"; }

validate_upstream() {
  registry_row "$1" >/dev/null 2>&1 \
    || die "unknown upstream: $1 (known: ${REGISTRY_UPSTREAMS// /, })"
}

# --- where each cache pulls from -------------------------------------------
#
# The table's remotes are the public endpoints. The remotes file overrides
# them per upstream — a pull-through mirror on the LAN, say — so that the
# caches chain: guest -> this host's cache -> the mirror -> the registry. The
# guest's side is unchanged by it, and so is every workspace's plan: which
# remote a cache uses is the cache's business, not the workspace's.
#
# Its own file rather than a key in the defaults file, because that one is a
# template read only at init (D19), and this is read at every start.
registry_config_path() {
  if [ -n "${AIRLOCK_REGISTRY_CONFIG:-}" ]; then
    printf '%s\n' "$AIRLOCK_REGISTRY_CONFIG"
  else
    printf '%s/airlock/registry\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
  fi
}

# A scheme and a host, optionally a port: nothing else. `distribution` takes the
# remote as a base URL and asks it for /v2/..., so a path would not be the
# prefix it looks like (a Harbor proxy project, say, cannot be reached this
# way). Credentials in the URL are refused rather than written into a config
# file under the cache directory. The narrow character set is also what keeps
# the value safe to write into YAML unquoted.
REGISTRY_REMOTE_RE='^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?$'

# Dies on anything in the remotes file that would otherwise be ignored quietly
# or written into a cache's config: a name not in the table, a malformed URL.
# An empty value is allowed and means the table's own remote.
registry_check_config() {
  local file key eq value
  file="$(registry_config_path)"
  [ -f "$file" ] || return 0
  while IFS=$'\t' read -r key eq value; do
    [ "$eq" = "=" ] || die "$file: '$key' is not a line of the form <upstream> = <url>"
    registry_row "$key" >/dev/null 2>&1 \
      || die "$file: '$key' is not an upstream (known: ${REGISTRY_UPSTREAMS// /, })"
    [ -z "$value" ] || [[ "$value" =~ $REGISTRY_REMOTE_RE ]] \
      || die "$file: $key: '$value' is not a registry URL: expected http(s)://host[:port], with no path or credentials"
  done < <(awk '/^[[:space:]]*#/ { next } /^[[:space:]]*$/ { next } {
             name = $0; eq = "-"; value = ""
             if (index($0, "=") > 0) { sub(/=.*/, "", name); eq = "="; value = $0; sub(/^[^=]*=/, "", value) }
             sub(/^[[:space:]]+/, "", name); sub(/[[:space:]]+$/, "", name)
             sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
             print name "\t" eq "\t" value
           }' "$file")
}

# What a cache started now would pull from. Assumes registry_check_config.
registry_remote() { # upstream
  local file value=""
  file="$(registry_config_path)"
  [ ! -f "$file" ] || value="$(config_get "$file" "$1")"
  value="${value%/}"
  if [ -n "$value" ]; then printf '%s\n' "$value"; else registry_default_remote "$1"; fi
}

# What a running cache is pulling from: the config it was started with, which
# is rewritten only at start. Empty when there is none to read.
registry_running_remote() { # upstream
  local conf
  conf="$(registry_home)/$1/config.yml"
  [ -f "$conf" ] || return 0
  awk '/^[[:space:]]*remoteurl:/ { print $2; exit }' "$conf"
}

# A cache started before the remotes file last changed keeps pulling from the
# old remote until it is restarted, so say so wherever it is looked at.
registry_note_stale() { # upstream
  local running want
  running="$(registry_running_remote "$1")"
  want="$(registry_remote "$1")"
  [ -z "$running" ] || [ "$running" = "$want" ] \
    || warn "$1: running against $running, but the remotes file now says $want; airlock registry restart $1"
}

# --- importing the host's registries.conf ---------------------------------
#
# Podman, Buildah, Skopeo and CRI-O read their mirrors from registries.conf
# through one library, go.podman.io/image/v5 pkg/sysregistriesv2. `import` asks
# that library too, through registries-conf
# (github.com/devinrsmith/registries-conf), a small CLI around it: which files,
# their order, merging, validation and prefix matching are all its answer, not
# a restatement of it. What stays here is airlock's own question — which of the
# mirrors it reports can a cache pull from — and the writing of a remotes file
# you can read. Import is explicit, rather than the caches reading
# registries.conf themselves, so that file is a record of what was chosen.

# The registries-conf executable: AIRLOCK_REGISTRIES_CONF if set (an installed
# build bakes it in; tests set it), else the revision in flake.lock, built on
# first use against airlock's own nixpkgs, as the registry is.
registry_rc_bin() {
  local lock ref nixpkgs out
  if [ -n "${AIRLOCK_REGISTRIES_CONF:-}" ]; then
    [ -x "$AIRLOCK_REGISTRIES_CONF" ] \
      || die "AIRLOCK_REGISTRIES_CONF names $AIRLOCK_REGISTRIES_CONF, which is not an executable"
    printf '%s\n' "$AIRLOCK_REGISTRIES_CONF"
    return 0
  fi
  lock="${AIRLOCK_FLAKE_LOCK:-$AIRLOCK_LIB/../flake.lock}"
  ref="$(flake_lock_ref "$lock" registries-conf)" \
    || die "cannot tell which registries-conf to run: no AIRLOCK_REGISTRIES_CONF and no registries-conf in $lock"
  nixpkgs="$(nixpkgs_ref)" || die "no nixpkgs in $lock to build registries-conf against"
  command -v nix >/dev/null 2>&1 || die "nix is not on PATH; it is what provides registries-conf"
  out="$(nix build --no-link --print-out-paths --override-input nixpkgs "$nixpkgs" "$ref" | head -1)" \
    || die "could not build $ref"
  [ -x "$out/bin/registries-conf" ] || die "$ref has no bin/registries-conf (in $out)"
  printf '%s\n' "$out/bin/registries-conf"
}

# registries-conf's JSON for one command, from the executable in $1.
# AIRLOCK_CONTAINERS_ROOT is its --root, which prefixes /etc and /usr/share;
# tests use it. On failure, prints the library's own error instead — which names
# the file at fault — and returns 1.
registry_rc_try() { # bin command [image...]
  local bin="$1" cmd="$2" err out rc=0
  shift 2
  err="$(mktemp)"
  out="$("$bin" "$cmd" --format json ${AIRLOCK_CONTAINERS_ROOT:+--root "$AIRLOCK_CONTAINERS_ROOT"} "$@" 2>"$err")" || rc=$?
  [ "$rc" -eq 0 ] || out="$(sed 's/^registries-conf: //' "$err" | tr '\n' ' ' | sed 's/ $//')"
  rm -f "$err"
  printf '%s\n' "$out"
  return "$rc"
}

# What the library says about each upstream, given its merged config: one
# tab-separated record per line, empty fields as "-" (consecutive tabs would
# collapse in a shell read):
#   entry   <upstream> <prefix> <blocked 0|1> <digest-only 0|1>
#   cand    <upstream> <location> <insecure 0|1> <pull-from-mirror> <namespace-proxy> <mirror|location>
#   narrow  <upstream> <prefix>
#   error   <upstream> <the library's error>
# Which entry applies is asked by resolving an image under the upstream, so
# longest-prefix and wildcard matching are the library's; that entry's mirrors
# then come from the merged config, in the order the tools try them. Resolving
# fails when the tools themselves could not pull from that entry — a mirror
# location no image reference can be built on — which is that upstream's
# problem, not the others', so it is one upstream at a time.
registry_rc_records() { # bin jq config-json
  local bin="$1" jq="$2" cfg="$3" res u
  for u in $REGISTRY_UPSTREAMS; do
    if ! res="$(registry_rc_try "$bin" resolve "$u/airlock-import/probe:latest")"; then
      printf 'error\t%s\t%s\n' "$u" "${res:--}"
      continue
    fi
    # shellcheck disable=SC2016 # jq's variables, not the shell's
    "$jq" -nr --argjson cfg "$cfg" --argjson res "$res" --arg u "$u" '
      def b: if . == true then "1" else "0" end;
      ($res[0].candidates[0].registryPrefix // "") as $p
      | ( if $p == "" then empty else
            ($cfg.registries[] | select(.prefix == $p)) as $r
            | ["entry", $u, $r.prefix, ($r.blocked | b), ($r.mirrorByDigestOnly | b)],
              ($r.mirrors[] | ["cand", $u, .location, (.insecure | b),
                               (.pullFromMirror // ""), (.namespaceProxy // ""), "mirror"]),
              (if $r.location != "" and $r.location != $u
               then ["cand", $u, $r.location, ($r.insecure | b), "", "", "location"]
               else empty end)
          end ),
        # Entries for part of the upstream take those images somewhere other
        # than the cache would.
        ($cfg.registries[] | select(.prefix | startswith($u + "/")) | ["narrow", $u, .prefix])
      | map(if . == "" then "-" else . end) | @tsv' || return 1
  done
}

# Whether a location is one of airlock's own caches: a host that is this host
# (or a guest's way to it) on a port from the table. Importing one would make a
# cache its own remote.
registry_is_own_cache() { # location
  local host="${1%%:*}" port="" u
  case "$1" in *:*) port="${1##*:}" ;; esac
  case "$host" in
    localhost|127.*|"$REGISTRY_GUEST_HOST") ;;
    *) return 1 ;;
  esac
  for u in $REGISTRY_UPSTREAMS; do
    [ "$port" != "$(registry_port "$u")" ] || return 0
  done
  return 1
}

registry_import() {
  local write=0 present=0 bin jq cfg sources records conf u kind rest
  local f1 f2 f3 f4 f5 f6 loc url why chosen current
  local -a lines=() picks=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --write) write=1; shift ;;
      *)       die "registry import takes only --write (got: $1)" ;;
    esac
  done
  # It edits the remotes file, so that file has to be one it can read.
  registry_check_config
  conf="$(registry_config_path)"

  bin="$(registry_rc_bin)" || exit 1
  jq="$(jq_bin)" || exit 1
  # Loading the config is what validates every file, so a refusal here is the
  # one the tools would make.
  cfg="$(registry_rc_try "$bin" config)" || die "registries.conf: $cfg"
  # The library lists every path it searches, highest priority first: the
  # main-file candidates, of which it reads the first that exists, then the
  # drop-in directories. Shown is what exists of that.
  sources="$("$jq" -r '.sources[]' <<<"$cfg")"
  info "configuration from:"
  while IFS= read -r f1; do
    if [ -d "$f1" ]; then
      info "  $f1/*.conf"
    elif [ "$present" = "0" ] && [ -e "$f1" ]; then
      info "  $f1"
    else
      continue
    fi
    present=1
  done <<<"$sources"
  [ -z "${CONTAINERS_REGISTRIES_CONF_OVERRIDE:-}" ] \
    || { info "  $CONTAINERS_REGISTRIES_CONF_OVERRIDE (CONTAINERS_REGISTRIES_CONF_OVERRIDE)"; present=1; }
  if [ "$present" = "0" ]; then
    info "  nothing: no registries.conf and no drop-in directory exists"
    return 0
  fi
  records="$(registry_rc_records "$bin" "$jq" "$cfg")" || exit 1

  for u in $REGISTRY_UPSTREAMS; do
    lines=()
    chosen=""
    local blocked=0 found=0 unused=0 digest_only=0 failed=""
    while IFS=$'\t' read -r kind rest; do
      [ -n "$kind" ] || continue
      IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 <<<"$rest"
      [ "$f1" = "$u" ] || continue
      case "$kind" in
        entry)
          found=1
          [ "$f3" = "0" ] || blocked=1
          [ "$f2" = "$u" ] || lines+=("matched by prefix $f2")
          # mirror-by-digest-only on the registry restricts every mirror.
          [ "$f4" = "0" ] || lines+=("mirror-by-digest-only: its mirrors serve digests only, and a cache would serve tags too")
          digest_only="$f4"
          ;;
        cand)
          [ "$blocked" = "0" ] || continue
          loc="$f2"
          why=""
          if [ -n "$chosen" ]; then
            unused=$((unused + 1)); continue
          fi
          if [ "${digest_only:-0}" = "1" ] && [ "$f6" = "mirror" ]; then
            why="digest-only"
          elif [ "$f4" = "digest-only" ]; then
            why="pull-from-mirror = digest-only: it serves digests only, and a cache would serve tags too"
          elif [ "$f5" != "-" ]; then
            why="namespace-proxy: it needs an ns parameter on every request, which a cache cannot send"
          elif [[ "$loc" == */* ]]; then
            why="has a path; a cache can only pull from a registry's root"
          elif registry_is_own_cache "$loc"; then
            why="that is airlock's own cache"
          else
            if [ "$f3" = "1" ]; then url="http://$loc"; else url="https://$loc"; fi
            if ! [[ "$url" =~ $REGISTRY_REMOTE_RE ]]; then
              why="not a host[:port] the remotes file can name"
            elif [ "$url" = "$(registry_default_remote "$u")" ]; then
              why="that is $u's own endpoint"
            fi
          fi
          if [ -n "$why" ]; then
            [ "$why" = "digest-only" ] || lines+=("skipped $loc: $why")
            continue
          fi
          chosen="$url"
          lines=("from its $f6" "${lines[@]}")
          [ "$f3" = "0" ] || lines+=("insecure = true, read as plain http; change it to https if $loc serves TLS")
          ;;
        narrow)
          lines+=("$f2 sends those images elsewhere; the cache serves them from $u")
          ;;
        error)
          failed="$f2"
          ;;
      esac
    done <<<"$records"

    if [ -n "$failed" ]; then
      printf '%-16s %s\n' "$u" "not importable: the tools themselves fail on its entry"
      lines+=("$failed")
    elif [ "$found" = "0" ]; then
      printf '%-16s %s\n' "$u" "no entry"
    elif [ "$blocked" = "1" ]; then
      printf '%-16s %s\n' "$u" "blocked: nothing to import"
    elif [ -z "$chosen" ]; then
      printf '%-16s %s\n' "$u" "no usable mirror"
    else
      printf '%-16s %s\n' "$u" "$chosen"
      [ "$unused" -eq 0 ] || lines+=("$unused more after it not used: a cache takes one remote, so there is no failover between them")
      picks+=("$u=$chosen")
    fi
    for f1 in "${lines[@]}"; do printf '%-16s   %s\n' "" "$f1"; done
  done

  printf '\n'
  if [ ${#picks[@]} -eq 0 ]; then
    info "nothing to import; $conf is unchanged"
    return 0
  fi
  info "remotes file $conf:"
  for f1 in "${picks[@]}"; do
    u="${f1%%=*}" url="${f1#*=}"
    current=""
    [ ! -f "$conf" ] || current="$(registry_remote "$u")"
    [ -n "$current" ] || current="$(registry_default_remote "$u")"
    if [ "$current" = "$url" ]; then
      printf '  %-16s = %s  (unchanged)\n' "$u" "$url"
    else
      printf '  %-16s = %s  (was %s)\n' "$u" "$url" "$current"
    fi
  done
  if [ "$write" = "0" ]; then
    info "nothing written; airlock registry import --write applies it"
    return 0
  fi
  mkdir -p "$(dirname "$conf")"
  [ -f "$conf" ] || printf '# Where each airlock registry cache pulls from; see: airlock registry --help\n' > "$conf"
  for f1 in "${picks[@]}"; do
    config_set_in_file "$conf" "${f1%%=*}" "${f1#*=}"
  done
  registry_check_config
  info "wrote $conf; running caches pick it up at: airlock registry restart"
}

# --- what a guest is handed (registry = on) -------------------------------
#
# A guest reaches host loopback through its user-mode network's gateway.
REGISTRY_GUEST_HOST="10.0.2.2"

# The substrate's REGISTRY_MIRRORS: every upstream in the table, running or
# not. The guest's runtimes fall back to the registry itself when a cache is
# down, so a cache started later is picked up on the next pull, and one never
# started costs nothing — and the value depends on the table alone, which is
# what lets it sit in run_plan().
registry_mirrors_value() {
  local u out=""
  for u in $REGISTRY_UPSTREAMS; do
    out="${out:+$out,}$u=http://$REGISTRY_GUEST_HOST:$(registry_port "$u")"
  done
  printf '%s\n' "$out"
}

# How many caches are running: a number, or nothing when systemd cannot be
# asked, which is not the same as none.
registry_running_count() {
  local u n=0
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl --user show-environment >/dev/null 2>&1 || return 0
  for u in $REGISTRY_UPSTREAMS; do
    [ "$(registry_state "$u")" != "active" ] || n=$((n + 1))
  done
  printf '%s\n' "$n"
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
# locked against (nixpkgs_ref) — the same arrangement as the substrate (D10): an
# installed build has it baked in, a source checkout reads the revision out of
# flake.lock, so both run the same build and `nix flake update` is how it moves.
# AIRLOCK_REGISTRY_PKG names the package outright, which is what tests use.
registry_pkg_ref() {
  local nixpkgs
  if [ -n "${AIRLOCK_REGISTRY_PKG:-}" ]; then
    printf '%s\n' "$AIRLOCK_REGISTRY_PKG"
    return 0
  fi
  nixpkgs="$(nixpkgs_ref)" \
    || die "cannot tell which registry to run: no AIRLOCK_NIXPKGS and no nixpkgs in ${AIRLOCK_FLAKE_LOCK:-$AIRLOCK_LIB/../flake.lock}"
  printf '%s#distribution\n' "$nixpkgs"
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
  # distribution 3 exports OpenTelemetry traces by default, to an OTLP collector
  # on localhost that nobody runs, and logs the refused connection every five
  # seconds; OTEL_TRACES_EXPORTER=none turns the exporter off.
  systemd-run --user --quiet --collect --unit="$unit" --slice=airlock \
    --description="airlock registry: $upstream (pull-through cache of $(registry_remote "$upstream"))" \
    -p Documentation=https://github.com/devinrsmith/airlock#registry-caches \
    -p SyslogIdentifier="$unit" \
    -p Environment=OTEL_TRACES_EXPORTER=none \
    -p NoNewPrivileges=yes -p UMask=0077 \
    -p ProtectSystem=strict -p ProtectHome=tmpfs -p PrivateTmp=yes \
    -p BindPaths="$dir" \
    -- "$bin" serve "$dir/config.yml" >/dev/null \
    || { warn "$upstream: systemd-run failed"; return 1; }

  # A bad port or config makes the registry exit at once, and systemd-run has
  # already returned by then — so look again before calling it started. So does
  # a remote it cannot reach: proxy mode asks the remote for /v2/ at startup and
  # panics without an answer (verified 2026-10-16), which is the likely cause
  # when the remote is a LAN mirror, and so is named in the warning. The
  # sandbox needs unprivileged user namespaces in a user unit; a host without
  # them lands here too, and the journal says which it was.
  sleep "${AIRLOCK_REGISTRY_SETTLE:-1}"
  state="$(registry_state "$upstream")"
  if [ "$state" != "active" ]; then
    warn "$upstream: did not stay up (${state:-gone}); it must reach $(registry_remote "$upstream") to start; see: journalctl --user -u $unit"
    return 1
  fi
  info "$upstream: started — 127.0.0.1:$(registry_port "$upstream") on this host, 10.0.2.2:$(registry_port "$upstream") from a guest"
  [ "$(registry_remote "$upstream")" = "$(registry_default_remote "$upstream")" ] \
    || info "$upstream: pulling from $(registry_remote "$upstream")"
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
  registry_check_config
  registry_preflight
  for u in $targets; do
    if [ "$(registry_state "$u")" = "active" ]; then
      info "$u: already running — 10.0.2.2:$(registry_port "$u") from a guest"
      registry_note_stale "$u"
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

registry_restart() {
  registry_targets "$@" >/dev/null || exit 1
  # Unknown names and the remotes file are checked before anything stops: a
  # typo in either should not take down caches that were working.
  registry_check_config
  # The names as given, not the expanded list: with none, both act on every
  # upstream, and stop stays quiet about the ones that were not running.
  registry_stop "$@"
  registry_start "$@"
}

# REMOTE is what a running cache is actually pulling from, and what a stopped
# one would; a running one the remotes file has moved on from is named after
# the table.
registry_status() {
  local u state size dir home remote file
  registry_check_config
  registry_preflight
  home="$(registry_home)"
  printf '%-16s %-6s %-10s %-7s %s\n' UPSTREAM PORT STATE CACHED REMOTE
  for u in $REGISTRY_UPSTREAMS; do
    state="$(registry_state "$u")"
    dir="$home/$u/data"
    size="-"
    [ -d "$dir" ] && size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
    remote=""
    [ "$state" != "active" ] || remote="$(registry_running_remote "$u")"
    [ -n "$remote" ] || remote="$(registry_remote "$u")"
    printf '%-16s %-6s %-10s %-7s %s\n' "$u" "$(registry_port "$u")" "${state:-unknown}" "$size" "$remote"
  done
  file="$(registry_config_path)"
  printf '\ncache data: %s\n' "$home"
  if [ -f "$file" ]; then
    printf 'remotes:    %s\n' "$file"
  else
    printf 'remotes:    %s (absent; every cache pulls from its upstream)\n' "$file"
  fi
  printf 'from a guest, a running cache is http://10.0.2.2:<port> (pull-only)\n'
  for u in $REGISTRY_UPSTREAMS; do
    [ "$(registry_state "$u")" != "active" ] || registry_note_stale "$u"
  done
}

cmd_registry() {
  local sub="${1:-status}"
  [ $# -eq 0 ] || shift
  case "$sub" in
    -h|--help|help) registry_usage ;;
    start)  registry_start "$@" ;;
    stop)   registry_stop "$@" ;;
    restart) registry_restart "$@" ;;
    import)  registry_import "$@" ;;
    status) [ $# -eq 0 ] || die "registry status takes no arguments"; registry_status ;;
    *)      registry_usage >&2; die "unknown registry command: $sub" ;;
  esac
}
