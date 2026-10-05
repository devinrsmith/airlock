# shellcheck shell=bash
# airlock run — launch the agent's VM.
#
# This is the one command that cannot be tested without KVM, so the launch is
# kept to a single call at the end: everything before it (preflight, the lock,
# the environment the substrate is handed) is ordinary shell and is covered by
# `--dry-run` and by pointing AIRLOCK_LAUNCHER at a stub.

run_usage() {
  cat <<'EOF'
usage: airlock run <name> [--dry-run] [-- <agent args>...]

  --dry-run   print the launch environment and command, and exit
  --          everything after is appended to the agent's own command line

The VM powers off when the agent exits.
EOF
}

# One VM per workspace (D13). The lock holds our pid, so a lock left behind by
# a crashed run is distinguishable from one a live run holds.
run_lock_acquire() { # root
  local lock
  lock="$(lock_file "$1")"
  if ( set -o noclobber; printf '%s\n' "$$" > "$lock" ) 2>/dev/null; then
    return 0
  fi
  if lock_is_live "$lock"; then
    die "a run is already in progress for this workspace (pid $(head -1 "$lock"))"
  fi
  warn "clearing a stale lock from a run that is no longer alive"
  rm -f "$lock"
  ( set -o noclobber; printf '%s\n' "$$" > "$lock" ) 2>/dev/null \
    || die "could not take the lock at $lock"
}

run_lock_release() { # root
  local lock
  lock="$(lock_file "$1")"
  # Only ever remove our own: a stale-lock takeover elsewhere must not have its
  # lock deleted by a late trap from this process.
  [ "$(head -1 "$lock" 2>/dev/null || true)" = "$$" ] && rm -f "$lock"
  return 0
}

# Is this workspace fit to launch? Checked for --dry-run too: what would happen
# is a refusal, and that is worth showing.
run_preflight_workspace() { # name
  local name="$1"
  # A symlinked agent_home sends the substrate's -cri and -store disks next to
  # the link target instead of into the workspace (§4). doctor reports it; run
  # refuses, because launching is what creates those disks.
  [ ! -L "$WS_ROOT/agent_home" ] \
    || die "agent_home is a symlink; its disks would land outside the workspace (airlock doctor $name)"
  [ -d "$WS_ROOT/agent_home" ] \
    || die "agent_home is missing (airlock doctor $name --fix)"
  is_git_repo "$WS_CLONE" \
    || die "the agent's clone is missing (airlock doctor $name)"
}

# Can this host launch at all? Only asked when actually launching: --dry-run
# prints a mapping and has no business demanding KVM.
run_preflight_host() { # flavor
  local flavor="$1" keyvar
  if [ -z "${AIRLOCK_LAUNCHER:-}" ]; then
    command -v nix >/dev/null 2>&1 || die "nix is not on PATH; it is what builds and launches the guest"
    [ -e /dev/kvm ] || die "/dev/kvm is missing; this host cannot run a VM"
    { [ -r /dev/kvm ] && [ -w /dev/kvm ]; } \
      || die "/dev/kvm is not readable and writable by you (are you in the kvm group?)"
  fi

  # Not fatal: the agent may already have a stored session in agent_home. But
  # a first run with neither is a boot into a login prompt you cannot answer.
  keyvar="$(flavor_api_key_var "$flavor")"
  if [ -n "$keyvar" ] && [ -z "${!keyvar:-}" ]; then
    warn "$keyvar is not set; unless $flavor already has a session in agent_home it will not authenticate"
  fi
}

# The launcher is run from the workspace root, so anything the caller gave as a
# path relative to their own cwd has to be resolved before we move.
run_abs_path() { # path
  case "$1" in
    # The config file is parsed, not sourced, so nothing expands `~` for us —
    # and `~/dotfiles/...` is exactly how someone will write a path in it.
    # [~] rather than "~": a character class matches the literal tilde without
    # looking like a tilde we expected the shell to expand for us.
    [~])   printf '%s\n' "$HOME" ;;
    [~]/*) printf '%s/%s\n' "$HOME" "${1#[~]/}" ;;
    /*)    printf '%s\n' "$1" ;;
    ./*)   printf '%s/%s\n' "$PWD" "${1#./}" ;;
    .)     printf '%s\n' "$PWD" ;;
    *)     printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# Same, for a flake reference. Only the forms that are actually cwd-relative are
# touched: `github:`, `git+https:` and friends must be left exactly as written.
run_abs_flake_ref() { # ref
  case "$1" in
    .|./*|../*|[~]|[~]/*) printf '%s\n' "$(run_abs_path "$1")" ;;
    path:./*|path:../*) printf 'path:%s\n' "$(run_abs_path "${1#path:}")" ;;
    *)          printf '%s\n' "$1" ;;
  esac
}

# The revision of claude-microvm this airlock is locked against, read out of
# flake.lock. An installed build has the reference baked into its wrapper; a
# source checkout reads it from the lock so that it launches the same microVM an
# install would, rather than drifting to whatever github serves today.
#
# Deliberately a small parser rather than a jq dependency: the shape is fixed by
# `nix flake lock`, and a lock with no claude-microvm node means the lock and the
# flake disagree, which is worth saying out loud.
substrate_ref_from_lock() { # lockfile
  local rev
  rev="$(awk '
    /"claude-microvm"[[:space:]]*:[[:space:]]*\{/ { inside = 1 }
    inside && /"rev"[[:space:]]*:/ {
      match($0, /"rev"[[:space:]]*:[[:space:]]*"[0-9a-f]+"/)
      if (RSTART) {
        s = substr($0, RSTART, RLENGTH)
        sub(/.*"rev"[[:space:]]*:[[:space:]]*"/, "", s)
        sub(/"$/, "", s)
        print s
        exit
      }
    }
  ' "$1" 2>/dev/null)"
  [ -n "$rev" ] || return 1
  printf 'github:systemstart/claude-microvm/%s\n' "$rev"
}

# Which claude-microvm to launch, in order: what this workspace pins, what this
# build was locked against, what the checkout's flake.lock says.
run_substrate_ref() {
  local configured lock
  configured="$(config_get "$WS_CONFIG" substrate)"
  if [ -n "$configured" ]; then
    run_abs_flake_ref "$configured"
    return 0
  fi
  if [ -n "${AIRLOCK_SUBSTRATE:-}" ]; then
    run_abs_flake_ref "$AIRLOCK_SUBSTRATE"
    return 0
  fi
  lock="${AIRLOCK_FLAKE_LOCK:-$AIRLOCK_LIB/../flake.lock}"
  if [ -f "$lock" ] && substrate_ref_from_lock "$lock"; then
    return 0
  fi
  die "no substrate: nothing pins which claude-microvm to launch.
  In a checkout:  flake.lock should carry a claude-microvm revision
  Installed:      the build should have baked one in; reinstall
  Or pin this workspace explicitly with 'substrate = <flake ref>' in its config."
}

# Claude Code asks whether you trust the directory it starts in, once per
# directory, and records the answer in ~/.claude.json under projects.<dir>. The
# guest starts the agent in /work (the substrate's base.nix), where the only
# things are the hub and the clone that airlock itself created from a source the
# developer named — so the question has nothing in it for the person answering,
# and it blocks an unattended first boot.
#
# Seeded only when there is no file yet. That file is the agent's own state and
# is guest-writable; rewriting one that exists would throw away its history to
# answer a question it has already answered.
run_seed_trust() { # flavor agent_home project
  [ "$1" = "claude" ] || return 0   # the only flavor whose mechanism is verified
  local file="$2/.claude.json"
  if [ -e "$file" ]; then
    grep -q '"hasTrustDialogAccepted"' "$file" 2>/dev/null \
      || warn "$file records no trust decision; claude may ask about /work on this launch"
    return 0
  fi
  cat > "$file" <<EOF
{
  "projects": {
    "/work": { "hasTrustDialogAccepted": true },
    "/work/$3": { "hasTrustDialogAccepted": true }
  }
}
EOF
}

# D18. Two halves, and they are gated separately.
#
# The substrate's *detection* half runs on the host when DIRENV_ALLOW=1 and
# looks for a flake in $WORK. Under airlock's layout $WORK is `work_dir/`, whose
# only contents are the hub and the clone, so that half finds nothing and says
# so — the project is one level down, at work_dir/<project>/.
#
# The *loading* half runs in the guest and is gated on DIRENV_ALLOW too
# (modules/base.nix: `if [ "${DIRENV_ALLOW:-0}" = "1" ]` around sourcing
# ~/.microvm-devshell). So writing the cache is necessary but not sufficient:
# the variable has to reach the guest as well, which is why cmd_run sets it
# alongside calling this. The host warning about $WORK having no flake is
# expected and harmless — an ineligible $WORK only warns, it never clears a
# cache we wrote.
#
# It evaluates the agent's clone on the host, which is the hazard the config
# flag exists to make visible (§9.1).
# What kind of dev shell a directory holds, mirroring the substrate's own
# detection so the two cannot disagree about what a project is:
#
#   flake         flake.nix alone
#   flake-impure  flake.nix and devenv.nix — devenv's flake needs --impure
#   devenv        devenv.nix (or the older .devenv.flake.nix) with no flake.nix,
#                 which `nix print-dev-env` has nothing to evaluate
#   (empty)       none of those
devshell_kind() { # dir
  local dir="$1"
  if [ -f "$dir/flake.nix" ]; then
    if [ -f "$dir/devenv.nix" ]; then printf 'flake-impure\n'; else printf 'flake\n'; fi
  elif [ -f "$dir/devenv.nix" ] || [ -f "$dir/.devenv.flake.nix" ]; then
    printf 'devenv\n'
  fi
}

run_devshell_cache() { # clone agent_home
  local clone="$1" cache="$2/.microvm-devshell" kind
  kind="$(devshell_kind "$clone")"
  if [ -z "$kind" ]; then
    warn "devshell = host-eval, but $clone has no flake.nix or devenv.nix — nothing to evaluate"
    return 0
  fi
  if [ "$kind" = "devenv" ] && ! command -v devenv >/dev/null 2>&1; then
    warn "$clone is a devenv project, but devenv is not on PATH — no dev shell for the guest"
    return 0
  fi

  info "evaluating the dev shell on the host (devshell = host-eval, $kind)"
  local -a dev_cmd
  case "$kind" in
    flake)        dev_cmd=(nix print-dev-env --no-update-lock-file "$clone") ;;
    flake-impure) dev_cmd=(nix print-dev-env --no-update-lock-file --impure "$clone") ;;
    devenv)       dev_cmd=(devenv print-dev-env) ;;
  esac

  # From inside the clone: devenv reads the project it is standing in, and the
  # nix forms are unharmed by it.
  if ( cd "$clone" && "${dev_cmd[@]}" ) > "$cache.tmp" 2>"$cache.err"; then
    mv "$cache.tmp" "$cache"
    rm -f "$cache.err"
  else
    rm -f "$cache.tmp"
    warn "could not evaluate the dev shell; see $cache.err"
  fi
}

cmd_run() {
  local name="" dry=0
  local -a extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)  run_usage; return 0 ;;
      --dry-run)  dry=1; shift ;;
      --)         shift; extra_args=("$@"); break ;;
      -*)         die "unknown option: $1" ;;
      *)          [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { run_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"
  ws_open "$name"
  validate_flavor "$WS_FLAVOR"
  run_preflight_workspace "$name"

  # --- the agent's own command line ---
  local agent_args prompts bypass
  agent_args="$(config_get "$WS_CONFIG" agent_args)"
  prompts="$(config_get "$WS_CONFIG" prompts bypass)"
  if [ "$prompts" = "bypass" ]; then
    bypass="$(flavor_bypass_args "$WS_FLAVOR")"
    if [ -n "$bypass" ]; then
      agent_args="$bypass${agent_args:+ $agent_args}"
    else
      warn "prompts = bypass, but no bypass flag is known for $WS_FLAVOR; it will prompt inside the VM"
    fi
  fi
  if [ "${#extra_args[@]}" -gt 0 ]; then
    agent_args="${agent_args:+$agent_args }${extra_args[*]}"
  fi

  # --- the environment the substrate reads ---
  local -a env_pairs=(
    "WORK_DIR=$WS_WORK_DIR"
    "AGENT_HOME=$WS_ROOT/agent_home"
    "VM_VCPU=$(config_get "$WS_CONFIG" cpus 4)"
    "VM_MEM=$(config_get "$WS_CONFIG" memory_mb 8192)"
  )
  [ -z "$agent_args" ] || env_pairs+=("AGENTS_ARGS=$agent_args")

  # The substrate's own pre-seeding: a settings file on the host copied into the
  # agent home at the flavor's config path. Resolved here, before the launcher's
  # working directory moves (§4), and checked here so a typo fails now rather
  # than after the guest has started building.
  local settings
  settings="$(config_get "$WS_CONFIG" settings)"
  if [ -n "$settings" ]; then
    settings="$(run_abs_path "$settings")"
    [ -f "$settings" ] || die "settings file not found: $settings"
    [ -r "$settings" ] || die "settings file is not readable: $settings"
    if [ -n "$(flavor_settings_path "$WS_FLAVOR")" ]; then
      env_pairs+=("AGENT_SETTINGS=$settings")
    else
      warn "$WS_FLAVOR has no settings path; the workspace's 'settings' is ignored"
    fi
  fi

  # The guest gates loading the dev-shell cache on DIRENV_ALLOW, so writing the
  # cache is only half of D18's opt-in; without this the file is written and
  # then ignored.
  [ "$(config_get "$WS_CONFIG" devshell off)" != "host-eval" ] || env_pairs+=("DIRENV_ALLOW=1")

  local store cri forward
  store="$(config_get "$WS_CONFIG" store_size_mb)"
  [ -z "$store" ] || env_pairs+=("VM_STORE_SIZE=$store")
  cri="$(config_get "$WS_CONFIG" cri)"
  [ -z "$cri" ] || env_pairs+=("ENABLE_CRI=$cri")
  local cri_storage
  cri_storage="$(config_get "$WS_CONFIG" cri_storage_mb)"
  [ -z "$cri_storage" ] || env_pairs+=("CRI_STORAGE_SIZE=$cri_storage")
  forward="$(config_get "$WS_CONFIG" env_forward)"
  [ -z "$forward" ] || env_pairs+=("EXTRA_ENV=$forward")

  # --- the launcher ---
  #
  # It runs with the workspace root as its working directory, because the
  # hypervisor's control socket is a relative path: microvm.nix defaults
  # `microvm.socket` to "<hostName>.sock" and QEMU opens it relative to its cwd,
  # so without this it lands wherever you happened to invoke airlock from. The
  # root is the right home for it — unmounted, so the guest cannot reach the
  # socket that controls its own VM, and `airlock rm` takes it with everything
  # else. (The substrate already rewrites the two virtiofs sockets to absolute
  # paths under XDG_RUNTIME_DIR; this is the one it leaves relative.)
  #
  # Anything that was relative to the caller's cwd has to be resolved first.
  local substrate
  substrate="$(run_substrate_ref)"
  local -a launcher
  if [ -n "${AIRLOCK_LAUNCHER:-}" ]; then
    launcher=("$(run_abs_path "$AIRLOCK_LAUNCHER")")
  else
    launcher=(nix run "$substrate#$(flavor_attr "$WS_FLAVOR")")
  fi

  if [ "$dry" = "1" ]; then
    local pair
    for pair in "${env_pairs[@]}"; do printf '%s\n' "$pair"; done
    printf 'cwd: %s\n' "$WS_ROOT"
    printf 'launcher: %s\n' "${launcher[*]}"
    return 0
  fi

  run_preflight_host "$WS_FLAVOR"
  run_seed_trust "$WS_FLAVOR" "$WS_ROOT/agent_home" "$WS_PROJECT"

  if [ "$(config_get "$WS_CONFIG" devshell off)" = "host-eval" ]; then
    run_devshell_cache "$WS_CLONE" "$WS_ROOT/agent_home"
  fi

  run_lock_acquire "$WS_ROOT"
  # shellcheck disable=SC2064  # $WS_ROOT is wanted at trap-definition time
  trap "run_lock_release '$WS_ROOT'" EXIT INT TERM

  # We hold the lock, so one VM per workspace (D13) means any control socket
  # still sitting in the root is from a run that died. QEMU will not bind over
  # one. Bounded deliberately: socket files only, directly in the unmounted
  # root, and only while the lock is ours.
  local stale
  for stale in "$WS_ROOT"/*.sock; do
    [ -S "$stale" ] || continue
    warn "removing a control socket left by an earlier run: $(basename "$stale")"
    rm -f "$stale"
  done

  info "launching $WS_FLAVOR for $name — the VM powers off when the agent exits"
  local rc=0
  ( cd "$WS_ROOT" && env "${env_pairs[@]}" "${launcher[@]}" ) || rc=$?
  return "$rc"
}
