# shellcheck shell=bash
# airlock path — where a workspace keeps something.
#
# Exists so nobody has to know the layout. The output is one bare line with no
# decoration, because its whole job is to be used inside a command
# substitution:
#
#   git remote add hub "$(airlock path demo)"

path_usage() {
  cat <<'EOF'
usage: airlock path <name> [--hub | --clone | --root | --agent-home | --config]

  --hub          the bare repository you fetch from (the default)
  --clone        the agent's working clone, inside the share
  --root         the workspace directory itself
  --agent-home   the agent's home, inside the share
  --config       this workspace's config file

Prints one path and nothing else:

  git remote add hub "$(airlock path demo)"
EOF
}

cmd_path() {
  local name="" what="hub"
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)     path_usage; return 0 ;;
      --hub)         what="hub"; shift ;;
      --clone)       what="clone"; shift ;;
      --root)        what="root"; shift ;;
      --agent-home)  what="agent_home"; shift ;;
      --config)      what="config"; shift ;;
      -*)            die "unknown option: $1" ;;
      *)             [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { path_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"
  ws_open "$name"

  local target
  case "$what" in
    hub)        target="$WS_HUB" ;;
    clone)      target="$WS_CLONE" ;;
    root)       target="$WS_ROOT" ;;
    agent_home) target="$WS_ROOT/agent_home" ;;
    config)     target="$WS_CONFIG" ;;
  esac

  # Printing a path to something that is not there would be handed straight to
  # another command, which would then fail further from the cause.
  [ -e "$target" ] || die "$name has no $what at $target (try: airlock doctor $name)"
  printf '%s\n' "$target"
}
