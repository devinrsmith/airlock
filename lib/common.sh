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

# The substrate's MICROVM_NAMESPACE for airlock's VMs (D23): their units are
# airlock-vm-<id>.* in airlock-vm.slice, which the dash puts inside
# airlock.slice beside the registry caches' airlock-registry.slice, and their
# launch directories are under $XDG_RUNTIME_DIR/airlock-vm/vms/. airlock's
# own, not a setting.
# shellcheck disable=SC2034  # read by run.sh, which records it for stop
AIRLOCK_VM_NAMESPACE=airlock-vm

# The substrate's MICROVM_NAME for a workspace's VM (D24): the workspace name,
# which is what people see in microvm-list, the unit descriptions and the
# session contract. The substrate wants a letter or digit first, which a
# workspace name need not have, so a leading run of '.' and '_' is dropped;
# a name that is nothing else gets none, and the substrate names it itself.
workspace_vm_name() { # workspace name
  local name="$1"
  while [[ "$name" == [._]* ]]; do name="${name:1}"; done
  printf '%s' "$name"
}

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

# --- flake.lock ----------------------------------------------------------

# One field of an input's `locked` entry in a flake.lock — nodes.<node>.locked
# .<field> and nowhere else, so neither the node's `original` nor another node
# can answer for it. Deliberately a small parser rather than a jq dependency:
# braces and commas become token boundaries and a stack of object keys tracks
# where each "key": value sits, which holds for both the pretty-printed lock
# `nix flake lock` writes and a one-line one. Returns 1 when the field is absent.
flake_lock_locked() { # lockfile node field
  local value
  value="$(awk -v node="$2" -v field="$3" '
    function token(t,   k, v) {
      sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
      if (t == "") return
      if (t == "{") { depth++; path[depth] = pending; pending = ""; return }
      if (t == "}") { depth--; return }
      if (!match(t, /^"[^"]*"[[:space:]]*:/)) return
      k = substr(t, 2, index(substr(t, 2), "\"") - 1)
      v = substr(t, RLENGTH + 1); sub(/^[[:space:]]+/, "", v)
      if (v == "") { pending = k; return }
      if (depth == 4 && path[2] == "nodes" && path[3] == node && path[4] == "locked" && k == field) {
        gsub(/^"|"$/, "", v)
        print v
        found = 1
        exit
      }
    }
    {
      line = $0
      gsub(/[{}]/, "\n&\n", line)
      gsub(/,/, "\n", line)
      n = split(line, parts, "\n")
      for (i = 1; i <= n; i++) token(parts[i])
    }
  ' "$1" 2>/dev/null)"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

flake_lock_rev() { flake_lock_locked "$1" "$2" rev; } # lockfile node

# The flake reference an input is locked to, rebuilt whole from its `locked`
# entry — owner and repository included, so a fork in flake.nix stays a fork
# here instead of becoming the upstream repository at the fork's revision.
# Returns 1 when the node is absent; dies on a type there is no reference form
# for here yet, rather than guessing one.
flake_lock_ref() { # lockfile node
  local lock="$1" node="$2" type owner repo rev host url
  type="$(flake_lock_locked "$lock" "$node" type)" || return 1
  rev="$(flake_lock_locked "$lock" "$node" rev)" || return 1
  case "$type" in
    github|gitlab|sourcehut)
      owner="$(flake_lock_locked "$lock" "$node" owner)" \
        || die "$lock: $node is a $type input with no owner"
      repo="$(flake_lock_locked "$lock" "$node" repo)" \
        || die "$lock: $node is a $type input with no repo"
      host="$(flake_lock_locked "$lock" "$node" host || true)"
      printf '%s:%s/%s/%s%s\n' "$type" "$owner" "$repo" "$rev" "${host:+?host=$host}" ;;
    git)
      url="$(flake_lock_locked "$lock" "$node" url)" \
        || die "$lock: $node is a git input with no url"
      printf 'git+%s?rev=%s\n' "$url" "$rev" ;;
    *)
      die "$lock: $node is locked as a '$type' input, which airlock cannot turn into a reference; pin it with an explicit flake ref instead" ;;
  esac
}

# The nixpkgs airlock is locked against, as a flake reference: baked into an
# installed build's wrapper as AIRLOCK_NIXPKGS, else read out of the checkout's
# flake.lock. It is the one nixpkgs for the whole stack — the registry builds
# from it, and the default substrate is launched with its own nixpkgs input
# overridden to it. Returns 1 when nothing names one.
nixpkgs_ref() {
  if [ -n "${AIRLOCK_NIXPKGS:-}" ]; then
    printf '%s\n' "$AIRLOCK_NIXPKGS"
    return 0
  fi
  flake_lock_ref "${AIRLOCK_FLAKE_LOCK:-$AIRLOCK_LIB/../flake.lock}" nixpkgs
}

# jq, for reading JSON other tools write — registries-conf's answers, the
# substrate's instance.json: the one on PATH (an installed build puts one
# there), else built from airlock's nixpkgs.
jq_bin() {
  local nixpkgs out
  if command -v jq >/dev/null 2>&1; then command -v jq; return 0; fi
  nixpkgs="$(nixpkgs_ref)" || die "jq is not on PATH, and there is no nixpkgs to build it from"
  command -v nix >/dev/null 2>&1 || die "jq is not on PATH, and neither is nix to build it with"
  out="$(nix build --no-link --print-out-paths "$nixpkgs#jq.bin" | head -1)" \
    || die "could not build $nixpkgs#jq"
  printf '%s\n' "$out/bin/jq"
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

# One VM per workspace (D13). A run holds the lock with flock(1) on a
# descriptor every process it starts inherits — nix, the launcher, QEMU — so it
# stays held until the last of them has gone, and the kernel lets go of it
# however they exit. Its first line is the pid of the `airlock run` that took
# it, for people to read; nothing decides liveness from it, since a pid can be
# reused and the VM can outlive that process.
lock_file() { printf '%s/lock\n' "$1"; }

lock_need_flock() {
  command -v flock >/dev/null 2>&1 \
    || die "flock is not on PATH (util-linux); it is how airlock tells whether a VM is running"
}

# Whether a run holds the lock. Opened read-only and never created: a missing
# file is no run, and a check must not leave one behind. The probe holds the
# lock for an instant when it is free, so a run starting at that very moment
# can be turned away; its refusal says to try again.
lock_is_live() { # lockfile
  local fd
  [ -e "$1" ] || return 1
  lock_need_flock
  # Braces: `exec` with only redirections keeps them, so a 2>/dev/null on it
  # would apply to the rest of the shell.
  { exec {fd}<"$1"; } 2>/dev/null || return 1
  if flock -n "$fd"; then exec {fd}<&-; return 1; fi
  exec {fd}<&-
  return 0
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
USER_DEFAULT_KEYS="flavor user_name user_email prompts devshell cpus memory_mb substrate env_forward agent_args settings cri cri_storage_mb store_size_mb registry pause"

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
WORKSPACE_KEYS="project flavor default_branch upstream user_name user_email prompts devshell cpus memory_mb substrate env_forward agent_args settings cri cri_storage_mb store_size_mb registry pause"

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
    registry)
      case "$value" in off|on) ;; *) die "registry must be 'off' or 'on' (got: $value)" ;; esac ;;
    pause)
      case "$value" in on|off) ;; *) die "pause must be 'on' or 'off' (got: $value)" ;; esac ;;
    cpus|memory_mb|store_size_mb)
      case "$value" in
        ''|*[!0-9]*) die "$key must be a whole number (got: $value)" ;;
        0)           die "$key must be greater than zero" ;;
      esac ;;
    # Zero is meaningful here and nowhere else: it runs the container runtime
    # with no storage disk at all, putting container storage in the VM's RAM.
    cri_storage_mb)
      case "$value" in
        ''|*[!0-9]*) die "$key must be a whole number, or 0 for no disk (got: $value)" ;;
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
