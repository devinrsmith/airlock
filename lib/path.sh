# shellcheck shell=bash
# airlock path — where a workspace keeps something.
#
# Exists so nobody has to know the layout. The output is one bare line with no
# decoration, because its whole job is to be used inside a command
# substitution:
#
#   git remote add hub "$(airlock path demo)"

path_usage() {
  cat <<'EOF2'
usage: airlock path <name> [--hub | --clone | --root | --agent-home | --config]
       airlock path <name> --task <task> [--context | --worktree | --root | --agent-home]

  --hub          the bare repository you fetch from (the default)
  --clone        the agent's working clone, inside the share
  --root         the workspace directory itself
  --agent-home   the agent's home, inside the share
  --config       this workspace's config file

  --task <task>  the same for one of the workspace's tasks, where --context
                 (the default) is the directory the task's agent reads its
                 task from, and --worktree its working tree

Prints one path and nothing else:

  git remote add hub "$(airlock path demo)"
  $EDITOR "$(airlock path demo --task fix-parser)/prompt.md"
EOF2
}

cmd_path() {
  local name="" what="" task=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)     path_usage; return 0 ;;
      --hub)         what="hub"; shift ;;
      --clone)       what="clone"; shift ;;
      --root)        what="root"; shift ;;
      --agent-home)  what="agent_home"; shift ;;
      --config)      what="config"; shift ;;
      --context)     what="context"; shift ;;
      --worktree)    what="worktree"; shift ;;
      --task)        [ $# -ge 2 ] || die "--task needs a task name"; task="$2"; shift 2 ;;
      -*)            die "unknown option: $1" ;;
      *)             [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { path_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"
  ws_open "$name"

  local target
  if [ -n "$task" ]; then
    task_open "$task"
    what="${what:-context}"
    case "$what" in
      context)    target="$TASK_CONTEXT" ;;
      worktree)   target="$TASK_WORKTREE" ;;
      root)       target="$TASK_ROOT" ;;
      agent_home) target="$TASK_HOME" ;;
      *)          die "--$what is a workspace's, not a task's; drop --task" ;;
    esac
  else
    what="${what:-hub}"
    case "$what" in
      hub)        target="$WS_HUB" ;;
      clone)      target="$WS_CLONE" ;;
      root)       target="$WS_ROOT" ;;
      agent_home) target="$WS_ROOT/agent_home" ;;
      config)     target="$WS_CONFIG" ;;
      *)          die "--$what is a task's; name one with --task <task>" ;;
    esac
  fi

  # Printing a path to something that is not there would be handed straight to
  # another command, which would then fail further from the cause.
  [ -e "$target" ] || die "$name has no $what at $target (try: airlock doctor $name)"
  printf '%s\n' "$target"
}
