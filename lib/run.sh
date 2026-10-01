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
    /*)   printf '%s\n' "$1" ;;
    ./*)  printf '%s/%s\n' "$PWD" "${1#./}" ;;
    .)    printf '%s\n' "$PWD" ;;
    *)    printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# Same, for a flake reference. Only the forms that are actually cwd-relative are
# touched: `github:`, `git+https:` and friends must be left exactly as written.
run_abs_flake_ref() { # ref
  case "$1" in
    .|./*|../*) printf '%s\n' "$(run_abs_path "$1")" ;;
    path:./*|path:../*) printf 'path:%s\n' "$(run_abs_path "${1#path:}")" ;;
    *)          printf '%s\n' "$1" ;;
  esac
}

# Which claude-microvm to launch.
#
# The default is the copy vendored as a git submodule, so the VM's version is
# pinned by a commit in this repository and is visible in its diffs. A
# workspace can override it with `substrate = <flake ref>` to pin itself to
# something else.
#
# Note for anyone installing airlock with Nix: flakes do not include submodules
# unless the reference says so, which is why a build that omitted it has to fail
# loudly here rather than quietly reach for github.
run_substrate_ref() {
  local configured
  configured="$(config_get "$WS_CONFIG" substrate)"
  if [ -n "$configured" ]; then
    run_abs_flake_ref "$configured"
    return 0
  fi
  if [ -f "${AIRLOCK_SUBSTRATE:-}/flake.nix" ]; then
    printf '%s\n' "$AIRLOCK_SUBSTRATE"
    return 0
  fi
  die "no substrate: ${AIRLOCK_SUBSTRATE:-<unset>} has no flake.nix.
  In a checkout:  git submodule update --init
  Installed:      reinstall from a flake reference carrying ?submodules=1
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

  [ "$(config_get "$WS_CONFIG" devshell off)" != "host-eval" ] \
    || run_devshell_cache "$WS_CLONE" "$WS_ROOT/agent_home"

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
