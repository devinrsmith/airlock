# shellcheck shell=bash
# airlock git — git in a task's worktree, run the way airlock runs its own
# (D34).
#
# The worktree and the repository behind it are the agent's to write, so plain
# git there runs whatever their config and hooks name, on the host, as the
# developer. This gives the developer the confined git airlock uses itself:
# the same overrides, the same sandbox, the hub bound read-only so `fetch
# origin` works and a push from here cannot change it. Pushing to the hub is
# the agent's; the developer's own checkout is where work goes on from.

git_usage() {
  cat <<'EOF'
usage: airlock git <name> <task> [--] <git args...>

Runs git in the task's worktree, confined the way airlock's own git is:
hooks, fsmonitor and filter drivers other than Git LFS's do not run, and git
sees only the workspace's work_dir and, read-only, its hub. No network, no
home directory, no pager or editor: give commit messages with -m.

  airlock git demo fix-parser status
  airlock git demo fix-parser log --oneline origin/main..
  airlock git demo fix-parser -- diff --stat

Paths are relative to the worktree. git's exit status is airlock's.
EOF
}

cmd_git() {
  case "${1:-}" in -h|--help|help) git_usage; return 0 ;; esac
  [ $# -ge 2 ] || { git_usage >&2; exit 2; }
  local name="$1" task="$2"; shift 2
  [ "${1:-}" != "--" ] || shift
  validate_workspace_name "$name"
  ws_open "$name"
  task_open "$task"
  wd_is_repo "$WS_WORK_DIR" "$TASK_WORKTREE" \
    || die "task $task has no worktree at $TASK_WORKTREE (airlock doctor $name)"
  # LFS content comes from the hub by its host path: the worktree's relative
  # origin is not a URL git-lfs resolves.
  wd_git "$WS_WORK_DIR" --hub "$WS_HUB" --repo "$TASK_WORKTREE" -- \
    -C "$TASK_WORKTREE" -c "lfs.url=file://$WS_HUB" "$@"
}
