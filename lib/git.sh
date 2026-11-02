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
home directory, no editor: give commit messages with -m. Viewers like log
and diff are paged by your own pager, in colour, at a terminal.

  airlock git demo fix-parser status
  airlock git demo fix-parser log --oneline origin/main..
  airlock git demo fix-parser -- diff --stat

Your own git aliases (system and global config) work here; a `!` alias runs
inside the sandbox, so it sees only what git does. Shell aliases do not: point
one at this command, e.g. alias glol='airlock git demo fix-parser log --graph'.

Paths are relative to the worktree. git's exit status is airlock's.
EOF
}

# The developer's own git aliases and display settings (colours, pretty
# formats), as NUL-separated `-c` `<key>=<value>` words. The sandbox has no
# home directory, so its git sees none of them.
# Read from the system and global config files only (never a repository's:
# `--global` and `--system` do not look for one), global last so it wins. Given
# as -c, they also win over an alias of the same name in the agent's repository
# config. A `!` alias runs, as everything in there does, inside the sandbox.
git_host_settings() {
  local scope key value entry
  for scope in --system --global; do
    # No aliases is exit 1; a scope with no file likewise.
    while IFS= read -r -d '' entry; do
      key="${entry%%$'\n'*}"
      value="${entry#*$'\n'}"
      [ "$value" != "$entry" ] || value=""
      printf '%s\0%s\0' -c "$key=$value"
    done < <(git config "$scope" -z --get-regexp '^(alias|color|pretty)\.' 2>/dev/null || true)
  done
}

# The pager command to page through, or nothing for none: what the caller's
# GIT_PAGER was (airlock overrides it for its own reports), else core.pager from
# the system and global config, else PAGER, else less. It runs on the host, as
# the developer's own command, over the sandboxed git's output.
git_pager() {
  local p
  if [ -n "${AIRLOCK_USER_GIT_PAGER_SET:-}" ]; then p="$AIRLOCK_USER_GIT_PAGER"
  elif p="$(git config --global --get core.pager 2>/dev/null)" \
    || p="$(git config --system --get core.pager 2>/dev/null)"; then :
  else p="${PAGER:-less}"; fi
  case "$p" in ""|cat) ;; *) printf '%s\n' "$p" ;; esac
}

# Whether git itself would page this command: one of the read-only viewers,
# named directly or through an alias of the developer's, and not --no-pager.
# Everything else — commit, add -p, fetch with its progress — talks to the
# terminal and must not wait behind a pager.
git_pages() {
  local cmd="" val n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -P|--no-pager) return 1 ;;
      -C|-c) shift ;;
      -*) ;;
      *) cmd="$1"; break ;;
    esac
    shift
  done
  # Follow plain aliases (`glol` -> `log --graph ...`), a few deep.
  while [ "$n" -lt 5 ] && val="$(git config --global --get "alias.$cmd" 2>/dev/null)"; do
    case "$val" in '!'*) return 1 ;; esac
    cmd="${val%%[[:space:]]*}"; n=$((n + 1))
  done
  case "$cmd" in
    log|diff|show|blame|shortlog|reflog|grep|whatchanged|range-diff|help) return 0 ;;
  esac
  return 1
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
  local -a aliases=()
  local word
  while IFS= read -r -d '' word; do aliases+=("$word"); done < <(git_host_settings)
  # At a terminal, page the output the way git would — through the host's
  # pager, since the sandbox has none — keeping the colour a terminal gets.
  local pager=""
  if [ -t 1 ]; then
    pager="$(git_pager)"
    git_pages "$@" || pager=""
  fi
  if [ -z "$pager" ]; then
    wd_git "$WS_WORK_DIR" --hub "$WS_HUB" --repo "$TASK_WORKTREE" -- \
      ${aliases[@]+"${aliases[@]}"} -C "$TASK_WORKTREE" -c "lfs.url=file://$WS_HUB" "$@"
    return
  fi
  local -a color=()
  # Piped, git would see no terminal: decide from the developer's config here.
  ! git config --global --get-colorbool color.ui || color=(-c color.ui=always)
  local -a st
  set +e
  wd_git "$WS_WORK_DIR" --hub "$WS_HUB" --repo "$TASK_WORKTREE" -- \
    ${aliases[@]+"${aliases[@]}"} ${color[@]+"${color[@]}"} -C "$TASK_WORKTREE" \
    -c "lfs.url=file://$WS_HUB" "$@" | LESS="${LESS:-FRX}" sh -c "$pager"
  st=("${PIPESTATUS[@]}")
  set -e
  # A pager quit early closes the pipe: git's own status for that is no failure.
  local rc="${st[0]}"
  [ "$rc" -ne 141 ] || rc=0
  return "$rc"
}
