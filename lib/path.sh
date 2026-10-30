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
usage: airlock path <name> [--hub | --repo | --root | --config]
       airlock path <name> --task <task> [--context | --worktree | --root | --agent-home]

  --hub          the bare repository you fetch from (the default)
  --repo         the repository the tasks' worktrees belong to, inside the share
  --root         the workspace directory itself
  --config       this workspace's config file

  --task <task>  one of the workspace's tasks: --context (the default) is the
                 directory its agent reads its task from, --worktree its working
                 tree, --agent-home its home, --root its own directory

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
      --repo)        what="repo"; shift ;;
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
      repo)       target="$WS_REPO" ;;
      root)       target="$WS_ROOT" ;;
      config)     target="$WS_CONFIG" ;;
      *)          die "--$what is a task's; name one with --task <task>" ;;
    esac
  fi

  # Printing a path to something that is not there would be handed straight to
  # another command, which would then fail further from the cause.
  [ -e "$target" ] || die "$name has no $what at $target (try: airlock doctor $name)"
  printf '%s\n' "$target"
}
