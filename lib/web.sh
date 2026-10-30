# shellcheck shell=bash
# airlock web — every workspace's hub, read-only, in a browser (D35).
#
# cgit behind lighttpd, run as a systemd --user unit like the hub service (D33)
# and the registry caches (D21). A viewer and nothing more: it keeps no review
# state (D16), serves no git transport, and shows the hubs only — never .repo
# or a worktree, which are the agent's to write (D34).
#
# It listens on 127.0.0.2, not 127.0.0.1. A guest reaches host loopback through
# slirp, but slirp maps the guest's 10.0.2.2 to 127.0.0.1 alone, so a service
# listing every workspace's hub stays out of every guest's reach, where the hub
# service gives each guest its own hub and nothing else.
#
# What it renders was written by agents: commit messages, paths, file contents.
# So no cgit filter runs (no highlighting, no README rendering), every response
# forbids scripts, and the unit sees each hub read-only and nothing else of the
# workspaces.

web_usage() {
  cat <<'EOF'
usage: airlock web [start | stop | restart | status]

  start     start the read-only web view of every workspace's hub
  stop      stop it
  restart   stop it, then start it
  status    whether it runs, and where (the default)

It listens on 127.0.0.2, which guests cannot reach, and shows each workspace
at http://127.0.0.2:<port>/<workspace>/ (airlock path <name> --web). From
another machine, keep the address: ssh -L 127.0.0.2:<port>:127.0.0.2:<port>.
EOF
}

# Not 127.0.0.1: see the top of this file.
web_addr() { printf '%s\n' "${AIRLOCK_WEB_ADDR:-127.0.0.2}"; }
web_port() { printf '%s\n' "${AIRLOCK_WEB_PORT:-5110}"; }
# With a workspace, its page; given "", the index.
web_url()  { printf 'http://%s:%s/%s\n' "$(web_addr)" "$(web_port)" "${1:+$1/}"; }
WEB_UNIT="airlock-web"

# The service's own files: lighttpd.conf, cgitrc, and which workspaces
# directory it serves. All rewritten at every start, so state, not data.
web_home() {
  if [ -n "${AIRLOCK_WEB_HOME:-}" ]; then
    printf '%s\n' "$AIRLOCK_WEB_HOME"
  else
    printf '%s/airlock/web\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
  fi
}

# A package root: from its variable (tests), else built from airlock's nixpkgs
# like the hub's sshd. Not baked into an installed build: the service is
# optional, and cgit's closure is most of 300 MiB.
web_pkg() { # attribute variable
  local root="${!2:-}" nixpkgs
  if [ -z "$root" ]; then
    nixpkgs="$(nixpkgs_ref)" || die "cannot tell which $1 to run: no nixpkgs in ${AIRLOCK_FLAKE_LOCK:-$AIRLOCK_LIB/../flake.lock}"
    command -v nix >/dev/null 2>&1 || die "nix is not on PATH; it is what provides $1 for airlock web"
    root="$(nix build --no-link --print-out-paths "$nixpkgs#$1" | head -1)" \
      || die "could not build $nixpkgs#$1"
  fi
  printf '%s\n' "$root"
}

# Paths go into lighttpd.conf and cgitrc, and into systemd properties, where a
# colon separates a bind's source from its destination.
web_plain_path() { # path
  hub_plain_path "$1"
  case "$1" in
    *:*) die "airlock web cannot serve a path with a colon in it: $1" ;;
  esac
}

# Every workspace with a hub to show: its name, then its hub.
web_hubs() {
  local dh ws name project
  dh="$(workspaces_home)"
  for ws in "$dh"/*/; do
    [ -d "$ws" ] || continue
    ws="${ws%/}"
    name="$(basename "$ws")"
    [ -f "$ws/config" ] || continue
    project="$(config_get "$ws/config" project)"
    [ -n "$project" ] && [ -d "$ws/$project.git" ] || continue
    ( web_plain_path "$ws/$project.git" ) 2>/dev/null \
      || { warn "workspace $name: its hub's path cannot be served"; continue; }
    printf '%s\t%s\n' "$name" "$ws/$project.git"
  done
}

# No filter is configured: cgit's about- and source-filters run more parsers
# over agent content, and the about-filter emits HTML the agent wrote. No
# snapshots, no git over HTTP, no cache, so the unit writes nothing.
web_write_cgitrc() { # home hubs
  local name hub project
  {
    cat <<'EOF'
# Written by airlock web start; regenerated at every start.
root-title=airlock
root-desc=Workspace hubs, read-only
virtual-root=/
css=/cgit.css
logo=/cgit.png
favicon=/favicon.ico
js=
robots=noindex, nofollow
cache-size=0
enable-http-clone=0
snapshots=
enable-git-config=0
enable-index-owner=0
enable-commit-graph=1
enable-log-filecount=1
enable-log-linecount=1
branch-sort=age
EOF
    while IFS=$'\t' read -r name hub; do
      [ -n "$name" ] || continue
      project="$(basename "$hub" .git)"
      printf '\nrepo.url=%s\nrepo.path=%s\nrepo.desc=%s\n' "$name" "$hub" "$project"
    done <<< "$2"
  } > "$1/cgitrc.new"
  mv "$1/cgitrc.new" "$1/cgitrc"
}

# Everything that is not a static file is cgit. The Host check refuses any name
# that is not loopback, so a web page that rebinds its own name to 127.0.0.2
# gets nothing (an ssh -L tunnel on another port still works). The CSP stops
# scripts outright; inline styles are allowed because cgit draws its diffstat
# bars with them, and with default-src 'none' CSS has nowhere to send anything.
web_write_lighttpd() { # home cgit
  local home="$1" cgit="$2/cgit" f
  {
    cat <<EOF
# Written by airlock web start; regenerated at every start.
server.modules = ( "mod_access", "mod_alias", "mod_setenv", "mod_cgi" )
server.bind = "$(web_addr)"
server.port = $(web_port)
server.document-root = "$cgit"
server.tag = "airlock"
mimetype.assign = ( ".css" => "text/css", ".png" => "image/png", ".ico" => "image/x-icon", ".txt" => "text/plain" )
setenv.set-environment = ( "CGIT_CONFIG" => "$home/cgitrc" )
setenv.set-response-header = (
  "Content-Security-Policy" => "default-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
  "X-Content-Type-Options" => "nosniff",
  "Referrer-Policy" => "no-referrer"
)
\$HTTP["host"] !~ "^(localhost|127\\.[0-9.]+|\\[::1\\])(:[0-9]+)?\$" {
  url.access-deny = ( "" )
}
cgi.assign = ( "cgit.cgi" => "" )
EOF
    printf 'alias.url = ('
    for f in cgit.css cgit.png favicon.ico robots.txt; do
      printf ' "/%s" => "%s/%s",' "$f" "$cgit" "$f"
    done
    printf ' "" => "%s/cgit.cgi" )\n' "$cgit"
  } > "$home/lighttpd.conf.new"
  mv "$home/lighttpd.conf.new" "$home/lighttpd.conf"
}

web_state() {
  systemctl --user is-active "$WEB_UNIT" 2>/dev/null || true
}

web_running() { [ "$(web_state)" = "active" ]; }

# Running, and serving this data directory's workspaces: what a URL printed for
# one of them, or a restart on its behalf, needs. Each start records which.
web_serving() {
  web_running || return 1
  [ "$(cat "$(web_home)/workspaces" 2>/dev/null)" = "$(workspaces_home)" ]
}

web_preflight() {
  local tool
  for tool in systemctl systemd-run; do
    command -v "$tool" >/dev/null 2>&1 \
      || die "airlock web runs as a systemd user unit, and $tool is not on PATH"
  done
  systemctl --user show-environment >/dev/null 2>&1 \
    || die "no systemd user manager is reachable (systemctl --user failed)"
}

web_start() {
  web_preflight
  if web_running; then
    info "web: already running — $(web_url "")"
    return 0
  fi
  local home dh cgit lighttpd hubs name hub n=0
  local -a binds=()
  home="$(web_home)"
  dh="$(workspaces_home)"
  web_plain_path "$home"
  web_plain_path "$dh"
  cgit="$(web_pkg cgit AIRLOCK_CGIT)" || exit 1
  lighttpd="$(web_pkg lighttpd AIRLOCK_LIGHTTPD)" || exit 1
  [ -x "$cgit/cgit/cgit.cgi" ] || die "no cgit/cgit.cgi in $cgit"
  [ -x "$lighttpd/bin/lighttpd" ] || die "no bin/lighttpd in $lighttpd"
  mkdir -p "$home" "$dh"
  chmod 700 "$home"

  hubs="$(web_hubs)"
  web_write_cgitrc "$home" "$hubs"
  web_write_lighttpd "$home" "$cgit"
  printf '%s\n' "$dh" > "$home/workspaces"
  "$lighttpd/bin/lighttpd" -tt -f "$home/lighttpd.conf" >/dev/null \
    || die "lighttpd refused its config ($home/lighttpd.conf)"

  # Each hub is bound back read-only over an empty workspaces directory: a
  # workspace root also holds its hub key and config, and work_dir/, none of
  # which cgit has any business reading. So the hubs it can see are fixed
  # here, and init and rm restart a running service (web_sync).
  while IFS=$'\t' read -r name hub; do
    [ -n "$name" ] || continue
    binds+=(-p "BindReadOnlyPaths=$hub")
    n=$((n + 1))
  done <<< "$hubs"

  systemd-run --user --quiet --collect --unit="$WEB_UNIT" --slice=airlock-web \
    --description="airlock web: the hubs, read-only ($(web_url ""))" \
    -p Documentation=https://github.com/devinrsmith/airlock#browsing-the-hubs \
    -p SyslogIdentifier="$WEB_UNIT" \
    -p NoNewPrivileges=yes -p UMask=0077 \
    -p ProtectSystem=strict -p ProtectHome=tmpfs -p PrivateTmp=yes \
    -p RestrictAddressFamilies="AF_INET AF_INET6 AF_UNIX" \
    -p TemporaryFileSystem="$dh:ro" \
    -p BindReadOnlyPaths="$home" \
    "${binds[@]}" \
    -- "$lighttpd/bin/lighttpd" -D -f "$home/lighttpd.conf" >/dev/null \
    || die "systemd-run failed to start airlock web"

  # A port in use, or an address that is not there, makes lighttpd exit at once.
  sleep "${AIRLOCK_WEB_SETTLE:-1}"
  web_running || die "airlock web did not stay up ($(web_state)); see: journalctl --user -u $WEB_UNIT"
  info "web: started — $(web_url "") ($n workspace(s))"
}

web_stop() {
  web_preflight
  if ! web_running; then
    info "web: not running"
    return 0
  fi
  systemctl --user stop "$WEB_UNIT" || die "could not stop $WEB_UNIT"
  info "web: stopped"
}

web_status() {
  local state
  state="$(web_state)"
  printf 'web: %s' "${state:-unknown}"
  [ "$state" != "active" ] || printf ' — %s' "$(web_url "")"
  printf '\n  state  %s\n' "$(web_home)"
  if [ -f "$(web_home)/cgitrc" ]; then
    printf '  hubs   %s workspace(s) at its last start\n' "$(grep -c '^repo\.url=' "$(web_home)/cgitrc")"
  fi
}

# After a workspace comes or goes: a running service sees only the hubs it was
# started with, so restart it. A failure here is a warning; the workspace
# change it follows has already happened.
web_sync() {
  web_serving || return 0
  ( web_stop >/dev/null && web_start >/dev/null ) \
    || warn "airlock web did not restart; the workspaces it shows are out of date (airlock web restart)"
}

cmd_web() {
  local sub="${1:-status}"
  [ $# -eq 0 ] || shift
  [ $# -eq 0 ] || die "unexpected argument: $1"
  case "$sub" in
    -h|--help|help) web_usage ;;
    start)   web_start ;;
    stop)    web_stop ;;
    restart) web_stop; web_start ;;
    status)  web_status ;;
    *)       web_usage >&2; die "unknown web command: $sub" ;;
  esac
}
