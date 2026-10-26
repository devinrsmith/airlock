# shellcheck shell=bash
# airlock stop — power a workspace's VM off from outside it.
#
# The substrate does the stopping: its `microvm-stop` presses the VM's power
# button over QMP, waits for the launch to go, and says so if the guest ignores
# it. airlock's part is finding which launch is this workspace's, and asking
# the substrate the VM was launched from — the launch record names it — so the
# tool and the launch it stops always agree on the layout.

stop_usage() {
  cat <<'EOF'
usage: airlock stop <name> [--force] [--timeout <seconds>]

  --force       stop QEMU at once, with no shutdown in the guest
  --timeout     how long to wait for the VM to go (default 60)

Presses the VM's power button: the guest shuts down cleanly and `airlock run`
returns as it does when the agent exits.
EOF
}

# Where the substrate keeps the launches of a namespace, one directory per
# launch ID, as it computes it: $XDG_RUNTIME_DIR/<namespace>/vms, or
# claude-microvm/vms for none. airlock launches in AIRLOCK_VM_NAMESPACE (D23);
# a VM started by an airlock from before that is in the default one.
stop_vms_dir() { # [namespace]
  printf '%s/%s/vms\n' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" "${1:-claude-microvm}"
}

# The IDs of the running launches whose work dir is $2, in namespace $1, one
# per line. A launch is running while its own lock is held (the substrate's
# rule, which is lock_is_live's too), and is this one's only if its
# instance.json is its own: the id it gives is its directory's name, as
# microvm-stop insists. A launch is matched by what instance.json says; the
# substrate resolved WORK_DIR with realpath before writing it, so $2 has to be
# resolved too.
stop_launches() { # namespace work_dir
  local vms d jq
  vms="$(stop_vms_dir "$1")"
  [ -d "$vms" ] || return 0
  for d in "$vms"/*/; do
    d="${d%/}"
    [ -f "$d/instance.json" ] || continue
    lock_is_live "$d/lock" || continue
    [ -n "${jq:-}" ] || { jq="$(jq_bin)" || exit 1; }
    [ "$("$jq" -r '"\(.id)\t\(.work)"' "$d/instance.json" 2>/dev/null)" = "$(basename "$d")"$'\t'"$2" ] \
      && basename "$d"
  done
  return 0
}

cmd_stop() {
  local name="" force=0 timeout="" timed=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)   stop_usage; return 0 ;;
      --force)     force=1; shift ;;
      --timeout)   [ $# -ge 2 ] || die "--timeout needs a number of seconds"; timeout="$2"; timed=1; shift 2 ;;
      --timeout=*) timeout="${1#--timeout=}"; timed=1; shift ;;
      -*)          die "unknown option: $1" ;;
      *)           [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { stop_usage >&2; die "workspace name is required"; }
  [ "$timed" = "0" ] || [[ "$timeout" =~ ^[0-9]+$ ]] \
    || die "--timeout wants whole seconds, not '$timeout'"
  validate_workspace_name "$name"
  ws_open "$name"

  local lock
  lock="$(lock_file "$WS_ROOT")"
  if ! lock_is_live "$lock"; then
    info "$name is not running"
    return 0
  fi

  # The namespace this VM was launched in, from its launch record; none for a
  # VM started before airlock set one.
  local namespace work ids
  namespace="$(status_record_get "$lock" namespace)"
  work="$(realpath "$WS_WORK_DIR")"
  ids="$(stop_launches "$namespace" "$work")" || exit 1
  [ -n "$ids" ] \
    || die "$name is running, but no launch under $(stop_vms_dir "$namespace") is for $work; a substrate from before claude-microvm's per-launch directory keeps none to find — exit the agent instead"
  [[ "$ids" != *$'\n'* ]] \
    || die "$name has more than one running launch, which airlock never starts (D13): ${ids//$'\n'/, }; stop the one you mean with microvm-stop <id>"

  local -a args=()
  [ "$force" = "0" ] || args+=(--force)
  [ "$timed" = "0" ] || args+=(--timeout "$timeout")
  args+=("$ids")

  # The substrate and nixpkgs this VM was launched with, from its launch
  # record: the stopper comes from the same substrate as the launcher did.
  local -a stopper
  if [ -n "${AIRLOCK_STOPPER:-}" ]; then
    stopper=("$AIRLOCK_STOPPER")
  else
    local substrate nixpkgs
    substrate="$(status_record_get "$lock" substrate)"
    nixpkgs="$(status_record_get "$lock" nixpkgs)"
    [ -n "$substrate" ] \
      || die "$name's launch was not recorded, so airlock cannot tell which substrate to stop it with; exit the agent instead"
    command -v nix >/dev/null 2>&1 || die "nix is not on PATH; it is what runs the substrate's microvm-stop"
    stopper=(nix run)
    [ -z "$nixpkgs" ] || stopper+=(--override-input nixpkgs "$nixpkgs")
    stopper+=("$substrate#microvm-stop" --)
  fi

  # microvm-stop looks for the ID in MICROVM_NAMESPACE's launches, so it gets
  # the recorded one, or none — never one this shell happens to export.
  local -a ns_env=(-u MICROVM_NAMESPACE)
  [ -z "$namespace" ] || ns_env=("MICROVM_NAMESPACE=$namespace")

  local rc=0
  env "${ns_env[@]}" "${stopper[@]}" "${args[@]}" || rc=$?
  return "$rc"
}
