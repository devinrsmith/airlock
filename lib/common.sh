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

# --- workspace layout helpers -------------------------------------------

# The emitted workspace pointer (D14, middle layer). airlock owns this file
# completely and regenerates it; it lives at the root of the share, outside the
# repository, so it never collides with the project's own committed context.
write_context_file() {
  local dest="$1" project="$2"
  cat > "$dest" <<EOF
# This workspace

You are running in an airlock workspace: an isolated microVM whose only channel
to the outside is a bare git repository. Nothing here is your developer's
working tree, and nothing you do reaches them until it is a commit in the hub.

## Where to work

- \`/work/$project\` — your clone. Do all work here.
- \`/work/$project.git\` — the **hub**. Push to it; never edit inside it, and
  never run commands that rewrite its refs directly. It is the record your
  developer reads.

Do not create or modify anything else under \`/work\`.

## Branches

Name your branches \`agent/<topic>\` — for example \`agent/fix-parser\`. Ordinary
git works normally:

\`\`\`sh
git checkout -b agent/<topic>
git push -u origin HEAD
\`\`\`

The hub refuses force-pushes and branch deletions. If you need to correct a
commit you already pushed, add a new commit — do not amend and force.

## Getting work out

Your developer reviews what arrives in the hub and publishes it themselves from
their own machine. There are no forge credentials in this VM and pushing to
GitHub or any other forge will not work — pushing to \`origin\` is the whole job.

## Upstream code

Branches from configured upstream remotes appear as read-only remote-tracking
refs under \`upstreams/<remote>/<branch>\`. Fetch \`origin\` to refresh them. You
cannot push to an upstream, and private upstreams are only visible if your
developer has fetched them into the hub.
EOF
}

# Watermark storage (D16). One file per ref, mirroring the ref path, so branch
# names containing '/' need no escaping. The whole tree lives in the unmounted
# workspace root, which is what keeps the guest from forging it.
watermark_file() { printf '%s/watermarks/%s\n' "$1" "$2"; }

# One VM per workspace (D13). The lock holds the pid of the `airlock run` that
# took it, so a lock left by a crashed run is distinguishable from a live one.
lock_file() { printf '%s/lock\n' "$1"; }

lock_is_live() {
  local file="$1" pid
  [ -f "$file" ] || return 1
  pid="$(head -1 "$file" 2>/dev/null || true)"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;   # unparseable: not a live run
  esac
  kill -0 "$pid" 2>/dev/null
}
