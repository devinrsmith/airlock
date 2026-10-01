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

# D18. The guest sources ~/.microvm-devshell at boot whether or not the host
# asked for it, so the opt-in is simply airlock writing that file — from a
# source of its own choosing rather than letting the substrate evaluate $WORK.
#
# It still evaluates the agent's clone on the host, which is the hazard the
# config flag exists to make visible (§9.1).
run_devshell_cache() { # clone agent_home
  local clone="$1" cache="$2/.microvm-devshell"
  if [ ! -f "$clone/flake.nix" ]; then
    warn "devshell = host-eval, but $clone has no flake.nix — nothing to evaluate"
    return 0
  fi
  info "evaluating the dev shell on the host (devshell = host-eval)"
  if nix print-dev-env --no-update-lock-file "$clone" > "$cache.tmp" 2>"$cache.err"; then
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

  local store cri forward
  store="$(config_get "$WS_CONFIG" store_size_mb)"
  [ -z "$store" ] || env_pairs+=("VM_STORE_SIZE=$store")
  cri="$(config_get "$WS_CONFIG" cri)"
  [ -z "$cri" ] || env_pairs+=("ENABLE_CRI=$cri")
  forward="$(config_get "$WS_CONFIG" env_forward)"
  [ -z "$forward" ] || env_pairs+=("EXTRA_ENV=$forward")

  # --- the launcher ---
  local substrate
  substrate="$(config_get "$WS_CONFIG" substrate "github:systemstart/claude-microvm")"
  local -a launcher
  if [ -n "${AIRLOCK_LAUNCHER:-}" ]; then
    launcher=("$AIRLOCK_LAUNCHER")
  else
    launcher=(nix run "$substrate#$(flavor_attr "$WS_FLAVOR")")
  fi

  if [ "$dry" = "1" ]; then
    local pair
    for pair in "${env_pairs[@]}"; do printf '%s\n' "$pair"; done
    printf 'launcher: %s\n' "${launcher[*]}"
    return 0
  fi

  run_preflight_host "$WS_FLAVOR"

  [ "$(config_get "$WS_CONFIG" devshell off)" != "host-eval" ] \
    || run_devshell_cache "$WS_CLONE" "$WS_ROOT/agent_home"

  run_lock_acquire "$WS_ROOT"
  # shellcheck disable=SC2064  # $WS_ROOT is wanted at trap-definition time
  trap "run_lock_release '$WS_ROOT'" EXIT INT TERM

  info "launching $WS_FLAVOR for $name — the VM powers off when the agent exits"
  local rc=0
  env "${env_pairs[@]}" "${launcher[@]}" || rc=$?
  return "$rc"
}
