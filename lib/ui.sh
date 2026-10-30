# shellcheck shell=bash
# airlock ui — a local web UI over this CLI (D36).
#
# The server (lib/ui/server.py) is an adapter: what it shows comes from `airlock
# status --json` and what it changes is an airlock command, so this file only
# finds a Python and starts it. It runs in the foreground, like `run`: Ctrl-C
# ends it, and any command it started with it.
#
# It listens on 127.0.0.2, not 127.0.0.1, as `airlock web` does (D35): slirp
# maps a guest's 10.0.2.2 to 127.0.0.1 alone, so no guest can reach it. The
# token stays: every local user, and any web page the browser loads, can still
# reach 127.0.0.2.

ui_usage() {
  cat <<'EOF'
usage: airlock ui [--port <port>]

  Serve the web UI on 127.0.0.2 until interrupted, and print the URL to open.
  Guests cannot reach 127.0.0.2, but every user of this host can, so the URL
  carries a token, new each time, that every request must present. Treat the
  URL as you would a password. From another machine, keep the address:
  ssh -L 127.0.0.2:<port>:127.0.0.2:<port>.

  --port <port>   listen here (default 5180, or AIRLOCK_UI_PORT; 0 picks one)
EOF
}

# Not 127.0.0.1: see the top of this file.
ui_addr() { printf '%s\n' "${AIRLOCK_UI_ADDR:-127.0.0.2}"; }
ui_port() { printf '%s\n' "${AIRLOCK_UI_PORT:-5180}"; }

# Python, for the server: AIRLOCK_PYTHON (an installed build bakes one in),
# else the one on PATH, else built from airlock's nixpkgs, as jq_bin does.
ui_python() {
  local nixpkgs out
  if [ -n "${AIRLOCK_PYTHON:-}" ]; then printf '%s\n' "$AIRLOCK_PYTHON"; return 0; fi
  if command -v python3 >/dev/null 2>&1; then command -v python3; return 0; fi
  nixpkgs="$(nixpkgs_ref)" || die "python3 is not on PATH, and there is no nixpkgs to build it from"
  command -v nix >/dev/null 2>&1 || die "python3 is not on PATH, and neither is nix to build it with"
  out="$(nix build --no-link --print-out-paths "$nixpkgs#python3" | head -1)" \
    || die "could not build $nixpkgs#python3"
  printf '%s\n' "$out/bin/python3"
}

cmd_ui() {
  local port python
  port="$(ui_port)"
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) ui_usage; return 0 ;;
      --port)    [ $# -ge 2 ] || die "--port needs a number"; port="$2"; shift 2 ;;
      --port=*)  port="${1#--port=}"; shift ;;
      *)         die "unexpected argument: $1" ;;
    esac
  done
  case "$port" in ''|*[!0-9]*) die "--port is a number: $port" ;; esac
  [ "$port" -le 65535 ] || die "--port is at most 65535: $port"
  python="$(ui_python)" || exit 1

  # What the server runs for every command: this very airlock, with the
  # environment it was given, so a source checkout drives itself and an
  # installed build its own wrapper's settings.
  AIRLOCK_UI_CLI="$(realpath "$AIRLOCK_LIB/../bin/airlock")" || die "cannot find bin/airlock beside $AIRLOCK_LIB"
  export AIRLOCK_UI_CLI
  info "airlock ui: serving workspaces under $(workspaces_home); Ctrl-C stops it"
  exec "$python" -I -B "$AIRLOCK_LIB/ui/server.py" "$(ui_addr)" "$port"
}
