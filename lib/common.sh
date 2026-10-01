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
#   flavor | flake attr | settings path | context file | api key var | bypass args
flavor_row() {
  case "$1" in
    claude) printf 'claude\t.claude/settings.json\tCLAUDE.md\tANTHROPIC_API_KEY\t--dangerously-skip-permissions\n' ;;
    gemini) printf 'gemini\t.gemini/settings.json\tGEMINI.md\tGEMINI_API_KEY\t\n' ;;
    codex)  printf 'codex\t.codex/config.toml\tAGENTS.md\tOPENAI_API_KEY\t\n' ;;
    pi)     printf 'pi\t\tAGENTS.md\tANTHROPIC_API_KEY\t\n' ;;
    *)      return 1 ;;
  esac
}

flavor_attr()         { flavor_row "$1" | cut -f1; }
flavor_settings_path() { flavor_row "$1" | cut -f2; }
flavor_context_file() { flavor_row "$1" | cut -f3; }
flavor_api_key_var()  { flavor_row "$1" | cut -f4; }
# Empty for a flavor whose bypass flag we have not verified: run says so rather
# than guessing a flag that might mean something else.
flavor_bypass_args()  { flavor_row "$1" | cut -f5; }

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

watermark_read() { # root ref -> the reviewed sha, or empty
  local file
  file="$(watermark_file "$1" "$2")"
  [ -f "$file" ] || return 0
  head -1 "$file" 2>/dev/null || true
}

watermark_write() { # root ref sha
  local file
  file="$(watermark_file "$1" "$2")"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$3" > "$file"
}

# Record every ref currently in the hub as reviewed. D16's mechanism: airlock
# performs the developer-side pushes, so the tips it wrote are by definition
# already seen. Anything that appears later did not come from us.
watermark_record_all() { # root hub
  local ref
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    watermark_write "$1" "$ref" "$(git -C "$2" rev-parse "$ref")"
  done < <(git -C "$2" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null)
}

# Resolve a workspace into the paths every command needs.
#
# `doctor` deliberately does not use this: its job is to report on a broken
# workspace, not to refuse to run on one.
# shellcheck disable=SC2034  # WS_* are read by the command libraries, not here
ws_open() { # name -> sets WS_*
  WS_NAME="$1"
  WS_ROOT="$(workspace_root "$1")"
  [ -d "$WS_ROOT" ] || die "no such workspace: $1 (try: airlock doctor)"
  WS_CONFIG="$WS_ROOT/config"
  [ -f "$WS_CONFIG" ] || die "workspace $1 has no config (try: airlock doctor $1 --fix)"
  WS_PROJECT="$(config_get "$WS_CONFIG" project)"
  [ -n "$WS_PROJECT" ] || die "workspace $1 declares no project"
  WS_FLAVOR="$(config_get "$WS_CONFIG" flavor claude)"
  WS_BRANCH="$(config_get "$WS_CONFIG" default_branch)"
  WS_WORK_DIR="$WS_ROOT/work_dir"
  WS_HUB="$WS_WORK_DIR/$WS_PROJECT.git"
  WS_CLONE="$WS_WORK_DIR/$WS_PROJECT"
  is_git_repo "$WS_HUB" || die "workspace $1 has no hub at $WS_HUB (try: airlock doctor $1)"
}

short_sha() { printf '%s' "${1:0:12}"; }

# Where a branch's unreviewed range starts when it has no watermark.
#
# A branch airlock never pushed is the agent's own work, so fall back to the
# merge base with the default branch: a topic shows as the topic, not as the
# whole history. Empty output means "use the whole history".
branch_review_base() { # hub ref tip default_branch
  local hub="$1" ref="$2" tip="$3" default="$4" base
  [ -n "$default" ] || return 0
  [ "$ref" != "refs/heads/$default" ] || return 0
  base="$(git -C "$hub" merge-base "refs/heads/$default" "$tip" 2>/dev/null || true)"
  [ -n "$base" ] || return 0
  [ "$base" != "$tip" ] || return 0
  printf '%s\n' "$base"
}

# Classify one hub branch against its watermark (D16). The single definition of
# what "unreviewed" means: `review` and `status` both read it from here so the
# two can never disagree about what you still have to look at.
#
# Sets BRANCH_STATE to one of:
#   clean   nothing new since the watermark
#   ahead   new commits on top of what you accepted
#   new     no watermark: airlock never pushed this, so it is the agent's
#   tamper  the watermark is missing from the hub, or is no longer an ancestor
#           of the tip — which a push cannot do, but a write through the share
#           can (D17)
# shellcheck disable=SC2034  # BRANCH_* are read by review.sh and status.sh
branch_state() { # root hub ref default_branch
  local root="$1" hub="$2" ref="$3" default="$4" wm
  BRANCH_TIP="$(git -C "$hub" rev-parse "$ref")"
  BRANCH_BASE=""
  BRANCH_COUNT=0
  BRANCH_NOTE=""
  wm="$(watermark_read "$root" "$ref")"

  if [ -n "$wm" ]; then
    if ! git -C "$hub" rev-parse --verify --quiet "$wm^{commit}" >/dev/null 2>&1; then
      BRANCH_STATE=tamper
      BRANCH_NOTE="the commit you reviewed ($(short_sha "$wm")) is no longer in the hub"
      return 0
    fi
    if [ "$wm" = "$BRANCH_TIP" ]; then
      BRANCH_STATE=clean
      return 0
    fi
    if ! git -C "$hub" merge-base --is-ancestor "$wm" "$BRANCH_TIP" 2>/dev/null; then
      BRANCH_STATE=tamper
      BRANCH_NOTE="history was rewritten; $(short_sha "$wm") is no longer an ancestor of the tip"
      return 0
    fi
    BRANCH_BASE="$wm"
    BRANCH_STATE=ahead
  else
    BRANCH_BASE="$(branch_review_base "$hub" "$ref" "$BRANCH_TIP" "$default")"
    BRANCH_STATE=new
  fi

  if [ -n "$BRANCH_BASE" ]; then
    BRANCH_COUNT="$(git -C "$hub" rev-list --count "$BRANCH_BASE..$BRANCH_TIP")"
  else
    BRANCH_COUNT="$(git -C "$hub" rev-list --count "$BRANCH_TIP")"
  fi
  [ "$BRANCH_COUNT" != "0" ] || BRANCH_STATE=clean
}

# The empty tree. Diffing a root history in a bare repository has nothing to
# diff against — `git diff <tip>` means "compare the working tree", which a
# bare repo does not have — so the empty tree stands in for "before anything".
# Computed rather than hard-coded, so it is correct under sha1 and sha256 both.
empty_tree() { git -C "$1" hash-object -t tree /dev/null; }

# --- user-level defaults -------------------------------------------------
#
# Settings a person wants on every workspace they create: their committer
# identity, a settings dotfile, resource caps. Same `key = value` format as a
# workspace config, so there is one syntax to learn.
#
# Read by `init` only, and baked into the workspace config it writes. Not
# layered underneath at every read: a workspace's config is meant to be the
# whole statement of what that workspace does (D9), and that stops being true
# the moment half of it lives somewhere else. Changing these defaults therefore
# affects the next workspace, never an existing one.

user_config_path() {
  if [ -n "${AIRLOCK_CONFIG:-}" ]; then
    printf '%s\n' "$AIRLOCK_CONFIG"
  else
    printf '%s/airlock/config\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
  fi
}

user_default() { # key [fallback]
  local file
  file="$(user_config_path)"
  [ -f "$file" ] || { printf '%s\n' "${2-}"; return 0; }
  config_get "$file" "$1" "${2-}"
}

# The keys a defaults file may set. Anything else is a typo that would
# otherwise do nothing quietly.
USER_DEFAULT_KEYS="flavor user_name user_email prompts devshell cpus memory_mb substrate env_forward agent_args settings cri store_size_mb"

user_config_warn_unknown() {
  local file key
  file="$(user_config_path)"
  [ -f "$file" ] || return 0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    case " $USER_DEFAULT_KEYS " in
      *" $key "*) ;;
      *) warn "$file: '$key' is not a key airlock reads; it has no effect" ;;
    esac
  done < <(awk -F= '/^[[:space:]]*#/ { next } /=/ {
             name = $1
             sub(/^[[:space:]]+/, "", name); sub(/[[:space:]]+$/, "", name)
             if (name != "") print name
           }' "$file")
}

# Keys a workspace config may carry. The structural ones come first: they are
# set from the source at init and name things that already exist on disk.
# shellcheck disable=SC2034  # read by config.sh, not here
WORKSPACE_KEYS="project flavor default_branch upstream user_name user_email prompts devshell cpus memory_mb substrate env_forward agent_args settings cri store_size_mb"

# What a value has to look like. Checked when it is typed rather than when it is
# used, so a typo fails at the keyboard and not at the next launch.
validate_config_value() { # key value -> dies on a bad one
  local key="$1" value="$2"
  [ -n "$value" ] || return 0        # empty always means "use the default"
  case "$key" in
    flavor)
      flavor_row "$value" >/dev/null 2>&1 \
        || die "flavor must be one of claude, gemini, codex, pi (got: $value)" ;;
    prompts)
      case "$value" in bypass|prompt) ;; *) die "prompts must be 'bypass' or 'prompt' (got: $value)" ;; esac ;;
    devshell)
      case "$value" in off|host-eval) ;; *) die "devshell must be 'off' or 'host-eval' (got: $value)" ;; esac ;;
    cpus|memory_mb|store_size_mb)
      case "$value" in
        ''|*[!0-9]*) die "$key must be a whole number (got: $value)" ;;
        0)           die "$key must be greater than zero" ;;
      esac ;;
    cri)
      local runtime
      for runtime in ${value//,/ }; do
        case "$runtime" in
          containerd|crun|crio|docker|podman) ;;
          *) die "cri must be a comma-separated list of containerd, crun, crio, docker, podman (got: $runtime)" ;;
        esac
      done ;;
    env_forward)
      local entry
      for entry in ${value//,/ }; do
        case "${entry%%=*}" in
          ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
            die "env_forward entries must be NAME or NAME=value (got: $entry)" ;;
        esac
      done ;;
  esac
}

# Set a key in a `key = value` file, in place, leaving every comment and every
# other line exactly as it was — these files are meant to be read.
config_set_in_file() { # file key value
  local file="$1" key="$2" value="$3" tmp
  tmp="$file.tmp.$$"
  if grep -qE "^${key}[[:space:]]*=" "$file" 2>/dev/null; then
    awk -v k="$key" -v v="$value" '
      {
        name = $0
        sub(/[[:space:]]*=.*$/, "", name)
        gsub(/[[:space:]]/, "", name)
        if (name == k && $0 ~ /=/) {
          # Keep the original padding so the file stays aligned.
          pad = $0
          sub(/=.*$/, "=", pad)
          print (v == "" ? pad : pad " " v)
          next
        }
        print
      }' "$file" > "$tmp"
    mv "$tmp" "$file"
  else
    printf '%s = %s\n' "$key" "$value" >> "$file"
  fi
}

# Remove a key's line entirely. Used for the global defaults file, which is
# sparse; a workspace config keeps the line and blanks the value instead, so it
# stays the complete statement D9 asks it to be.
config_remove_from_file() { # file key
  local file="$1" key="$2" tmp
  tmp="$file.tmp.$$"
  awk -v k="$key" '
    {
      name = $0
      sub(/[[:space:]]*=.*$/, "", name)
      gsub(/[[:space:]]/, "", name)
      if (name == k && $0 ~ /=/ && $0 !~ /^[[:space:]]*#/) next
      print
    }' "$file" > "$tmp"
  mv "$tmp" "$file"
}
