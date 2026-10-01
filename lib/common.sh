# shellcheck shell=bash
# Shared helpers. Sourced by bin/airlock; never executed directly.

airlock_prog="${airlock_prog:-airlock}"

die()  { printf '%s: error: %s\n' "$airlock_prog" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$airlock_prog" "$*" >&2; }
info() { printf '%s\n' "$*"; }

# --- paths ---------------------------------------------------------------

# Workspaces are tool-owned (D4). AIRLOCK_DATA_HOME exists for tests and for
# users who want them somewhere disposable.
data_home() {
  if [ -n "${AIRLOCK_DATA_HOME:-}" ]; then
    printf '%s\n' "$AIRLOCK_DATA_HOME"
  else
    printf '%s/airlock\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
  fi
}

workspace_root() { printf '%s/%s\n' "$(data_home)" "$1"; }

# A workspace name becomes a directory name, so keep it boring. Rejecting `.`
# and `..` outright is cheaper than reasoning about what they would resolve to.
validate_workspace_name() {
  local name="$1"
  [ -n "$name" ] || die "workspace name must not be empty"
  case "$name" in
    .|..)      die "invalid workspace name: $name" ;;
    -*)        die "workspace name must not start with '-': $name" ;;
    */*)       die "workspace name must not contain '/': $name" ;;
  esac
  case "$name" in
    *[!A-Za-z0-9._-]*) die "workspace name may only contain letters, digits, '.', '_' and '-': $name" ;;
  esac
}

# --- agent flavors (D11) -------------------------------------------------
#
# A flavor differs in exactly three facts. Keep them in one place so adding a
# fifth agent is a row, not a search.
#
#   flavor | flake attr | settings path in agent_home | context filename
flavor_row() {
  case "$1" in
    claude) printf 'claude\t.claude/settings.json\tCLAUDE.md\n' ;;
    gemini) printf 'gemini\t.gemini/settings.json\tGEMINI.md\n' ;;
    codex)  printf 'codex\t.codex/config.toml\tAGENTS.md\n' ;;
    pi)     printf 'pi\t\tAGENTS.md\n' ;;
    *)      return 1 ;;
  esac
}

flavor_attr()         { flavor_row "$1" | cut -f1; }
flavor_settings_path() { flavor_row "$1" | cut -f2; }
flavor_context_file() { flavor_row "$1" | cut -f3; }

validate_flavor() {
  flavor_row "$1" >/dev/null 2>&1 || die "unknown agent flavor: $1 (known: claude, gemini, codex, pi)"
}

# --- workspace config ----------------------------------------------------
#
# `key = value`, one per line, `#` comments. Parsed rather than sourced: the
# file is meant to be read by a reviewer (D9), not to be shell.

config_get() {
  local file="$1" key="$2" default="${3-}" value
  value="$(awk -F= -v k="$key" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      name = $1
      sub(/^[[:space:]]+/, "", name); sub(/[[:space:]]+$/, "", name)
      if (name != k) next
      sub(/^[^=]*=/, "")
      sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")
      print
    }' "$file" 2>/dev/null | tail -1)"
  if [ -n "$value" ]; then printf '%s\n' "$value"; else printf '%s\n' "$default"; fi
}

# --- git helpers ---------------------------------------------------------

is_git_repo() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

# The default branch of a remote, via the symref HEAD advertises. Empty when
# the remote does not advertise one (an empty repository, typically).
remote_default_branch() {
  git ls-remote --symref "$1" HEAD 2>/dev/null \
    | awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2; exit }'
}
