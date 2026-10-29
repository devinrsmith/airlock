# shellcheck shell=bash
# airlock task — named, persistent lines of work inside a workspace (D26).
#
# A task is a worktree of the workspace's repository (work_dir/.repo) on its
# own branch, an agent home and a context of its own, and a lock; `airlock run
# <name> <task>` launches it in a VM of its own, beside the workspace's other
# tasks. Everything a task owns on the host side is under tasks/<task>/ in the
# workspace root, which is never mounted (D3); its worktree is under
# work_dir/tasks/<task>/, where the guest can reach it.

task_usage() {
  cat <<'EOF'
usage: airlock task new <name> <task> [--base <ref>]
                        [--prompt <text> | --prompt-file <file>] [--context <dir>]
       airlock task ls <name>
       airlock task rm <name> <task> [--yes]

  new   make a worktree on agent/<task>, with a context and an
        agent home of its own; run it with `airlock run <name> <task>`
          --base <ref>        branch from <ref> — a hub branch, an upstream's
                              <remote>/<branch>, or a commit — rather than the
                              hub's default branch (or the hub's own
                              agent/<task>, if it has one)
          --prompt <text>     what the task is for, saved as the context's prompt.md
          --prompt-file <f>   the same, from a file
          --context <dir>     copy <dir>'s files into the context as well
  ls    list a workspace's tasks
  rm    remove a task: its worktree, local branch, agent home and context. The
        hub's agent/<task> branch stays.
          --yes               do not ask (required when there is no terminal)

A task's context is <workspace>/tasks/<task>/context/ (airlock path <name>
--task <task>). Edit it between runs; each launch takes a fresh copy, and the
agent reads it, read-only, at /run/microvm/context.
EOF
}

# A task name is a directory, the tail of a branch name and of a VM name, so it
# is held to the narrowest of the three: what git takes after agent/, from the
# workspace name's characters, with a letter or digit first as the substrate
# wants of a VM name.
validate_task_name() { # task
  local task="$1"
  [ -n "$task" ] || die "task name must not be empty"
  case "$task" in
    [!A-Za-z0-9]*)     die "task name must start with a letter or digit: $task" ;;
    *[!A-Za-z0-9._-]*) die "task name may only contain letters, digits, '.', '_' and '-': $task" ;;
  esac
  git check-ref-format "refs/heads/agent/$task" \
    || die "task name is not usable in a branch name (agent/$task): $task"
}

task_root()     { printf '%s/tasks/%s\n' "$WS_ROOT" "$1"; }      # task
task_worktree() { printf '%s/tasks/%s\n' "$WS_WORK_DIR" "$1"; }  # task
task_guest_dir() { printf '/work/tasks/%s\n' "$1"; }             # task

# Resolve a task of the open workspace into the paths it needs. Dies if there is
# none by that name.
# shellcheck disable=SC2034  # TASK_* are read by run, stop and status
task_open() { # task -> sets TASK_*
  validate_task_name "$1"
  TASK_NAME="$1"
  TASK_ROOT="$(task_root "$1")"
  [ -d "$TASK_ROOT" ] || die "workspace $WS_NAME has no task $1 (airlock task ls $WS_NAME)"
  TASK_CONTEXT="$TASK_ROOT/context"
  TASK_HOME="$TASK_ROOT/agent_home"
  TASK_WORKTREE="$(task_worktree "$1")"
  TASK_BRANCH="agent/$1"
  TASK_GUEST_DIR="$(task_guest_dir "$1")"
}

# The tasks of the open workspace, one name per line.
task_names() {
  local d
  for d in "$WS_ROOT"/tasks/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    basename "$d"
  done
}

# A JSON string. Task names and refs are narrow already; this keeps task.json
# well formed whatever a --base looks like.
task_json_str() { # text
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# Brings the repository's view of the hub up to date, from the host. Its
# origin is the guest's path to the hub (/work/<project>.git, see init), which
# the host cannot resolve, so the hub is named by its host path instead.
task_fetch_hub() {
  git -C "$WS_REPO" fetch --quiet "$WS_HUB" '+refs/heads/*:refs/remotes/origin/*' \
      '+refs/upstream/*:refs/remotes/upstreams/*' \
    || die "could not fetch the hub into the repository"
}

task_new() { # name task [options...]
  local name="$1" task="$2"; shift 2
  local base="" prompt="" prompt_file="" context_dir="" have_prompt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base)        [ $# -ge 2 ] || die "--base needs a ref"; base="$2"; shift 2 ;;
      --prompt)      [ $# -ge 2 ] || die "--prompt needs text"; prompt="$2"; have_prompt=$((have_prompt + 1)); shift 2 ;;
      --prompt-file) [ $# -ge 2 ] || die "--prompt-file needs a file"; prompt_file="$2"; have_prompt=$((have_prompt + 1)); shift 2 ;;
      --context)     [ $# -ge 2 ] || die "--context needs a directory"; context_dir="$2"; shift 2 ;;
      *)             die "unknown option: $1" ;;
    esac
  done
  [ "$have_prompt" -le 1 ] || die "give --prompt or --prompt-file, not both"
  validate_task_name "$task"
  ws_open "$name"
  is_git_repo "$WS_REPO" || die "the repository is missing (airlock doctor $name)"

  local root worktree branch="agent/$task"
  root="$(task_root "$task")"
  worktree="$(task_worktree "$task")"
  [ ! -e "$root" ] || die "workspace $name already has a task $task"
  [ ! -e "$worktree" ] || die "$worktree already exists, though there is no task $task; move it aside first"

  # Everything the developer handed over is checked before anything is made,
  # so a typo leaves nothing behind. The substrate copies the context into the
  # guest share and refuses anything but files and directories, so that is
  # checked here too, where it can be fixed; symlinks are followed when copying.
  if [ -n "$prompt_file" ]; then
    [ -f "$prompt_file" ] && [ -r "$prompt_file" ] || die "prompt file is not a readable file: $prompt_file"
  fi
  if [ -n "$context_dir" ]; then
    [ -d "$context_dir" ] || die "--context is not a directory: $context_dir"
    local odd
    odd="$(find -L "$context_dir" ! -type f ! -type d 2>/dev/null | head -n 3)"
    [ -z "$odd" ] || die "--context holds something other than files and directories, which the guest cannot be handed: ${odd//$'\n'/, }"
  fi

  # Where the branch starts: --base; else the hub's own agent/<task>, so a task
  # can pick up a branch an agent pushed before; else the hub's default branch.
  task_fetch_hub
  local start how
  if git -C "$WS_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    [ -z "$base" ] || die "the repository already has a branch $branch; drop --base to use it, or remove it first"
    start=""
    how="the existing $branch"
  elif [ -n "$base" ]; then
    if git -C "$WS_REPO" rev-parse --verify --quiet "refs/remotes/origin/$base^{commit}" >/dev/null; then
      start="origin/$base"
    elif git -C "$WS_REPO" rev-parse --verify --quiet "refs/remotes/upstreams/$base^{commit}" >/dev/null; then
      start="upstreams/$base"
    elif git -C "$WS_REPO" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
      start="$base"
    else
      die "--base $base names nothing in the hub or its upstreams"
    fi
    how="$start"
  elif git -C "$WS_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    start="origin/$branch"
    how="the hub's $branch"
  else
    [ -n "$WS_BRANCH" ] || die "workspace $name has no default branch; name one with --base"
    git -C "$WS_REPO" show-ref --verify --quiet "refs/remotes/origin/$WS_BRANCH" \
      || die "the hub has no $WS_BRANCH branch to start from; name one with --base"
    start="origin/$WS_BRANCH"
    how="$start"
  fi

  # Relative paths, so the links between worktree and repository resolve inside
  # the guest, where work_dir is /work, as well as here (git 2.48 or later).
  mkdir -p "$WS_WORK_DIR/tasks"
  local -a add=(worktree add --quiet --relative-paths)
  if [ -z "$start" ]; then
    add+=("$worktree" "$branch")
  else
    add+=(--no-track -b "$branch" "$worktree" "$start")
  fi
  # D25: the checkout smudges LFS files, so their objects have to be in the
  # hub first — the default branch's came at init, any other start's come now,
  # from the upstream (git-lfs fetches only what the hub lacks, so objects an
  # agent pushed there are not asked for). And git-lfs is pointed at the hub by
  # its host path for the checkout: the repository's origin is the guest's path to
  # it (task_fetch_hub), which git-lfs here cannot resolve.
  local rev="${start:-$branch}" upstream
  local -a lfs_url=()
  if lfs_used_at "$WS_REPO" "$rev"; then
    lfs_require
    upstream="$(config_get "$WS_CONFIG" upstream upstream)"
    local sha
    sha="$(git -C "$WS_REPO" rev-parse "$rev^{commit}")"
    # Only a commit the hub has can be scanned there; one only the repository has
    # was made in the guest, and its objects were pushed to the hub with it.
    if git -C "$WS_HUB" remote get-url "$upstream" >/dev/null 2>&1 \
       && git -C "$WS_HUB" cat-file -e "$sha^{commit}" 2>/dev/null; then
      lfs_fetch "$WS_HUB" "$upstream" "$how" "$sha" \
        || { lfs_fetch_log; die "could not fetch the Git LFS objects of $how from $upstream"; }
    fi
    lfs_url=(-c "lfs.url=file://$WS_HUB")
  fi
  info "checking out $how into $(task_guest_dir "$task")"
  git -C "$WS_REPO" ${lfs_url[@]+"${lfs_url[@]}"} "${add[@]}" \
    || die "could not make the worktree; git says why above (airlock needs git 2.48 or later, for --relative-paths)"
  # Pushing it is the agent's job, to origin like every agent branch, so the
  # branch tracks the hub's of the same name.
  git -C "$WS_REPO" config "branch.$branch.remote" origin
  git -C "$WS_REPO" config "branch.$branch.merge" "refs/heads/$branch"

  mkdir -p "$root/context" "$root/agent_home"
  if [ -n "$context_dir" ]; then
    cp -RL -- "$context_dir/." "$root/context/"
  fi
  if [ -n "$prompt_file" ]; then
    cp -- "$prompt_file" "$root/context/prompt.md"
  elif [ -n "$prompt" ]; then
    printf '%s\n' "$prompt" > "$root/context/prompt.md"
  fi
  # Last, so a task.json among the --context files does not stand in for it.
  {
    printf '{\n'
    printf '  "name": %s,\n' "$(task_json_str "$task")"
    printf '  "workspace": %s,\n' "$(task_json_str "$name")"
    printf '  "branch": %s,\n' "$(task_json_str "$branch")"
    printf '  "base": %s,\n' "$(task_json_str "$how")"
    printf '  "worktree": %s,\n' "$(task_json_str "$(task_guest_dir "$task")")"
    printf '  "created": %s\n' "$(task_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf '}\n'
  } > "$root/context/task.json"

  info "created task '$task' in workspace '$name'"
  info "  branch         $branch (from $how)"
  info "  worktree       $worktree"
  info "  context        $root/context"
  [ -f "$root/context/prompt.md" ] \
    || info "                 (no prompt.md yet: write one there before running it)"
  info ""
  info "next: airlock run $name $task"
}

# Uncommitted changes in the task's worktree, and its branch's commits the hub
# does not have. Run after task_fetch_hub, so "the hub" is as of now.
#   TASK_DIRTY     changed paths in the worktree (0 when it is gone)
#   TASK_UNPUSHED  commits on agent/<task> that no hub branch has
task_pending() { # task
  local worktree branch="agent/$1"
  worktree="$(task_worktree "$1")"
  TASK_DIRTY=0
  TASK_UNPUSHED=0
  if [ -d "$worktree" ]; then
    TASK_DIRTY="$(git -C "$worktree" status --porcelain 2>/dev/null | wc -l)"
  fi
  if git -C "$WS_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
    TASK_UNPUSHED="$(git -C "$WS_REPO" rev-list --count "refs/heads/$branch" --not --remotes=origin 2>/dev/null || echo 0)"
  fi
}

task_ls() { # name
  ws_open "$1"
  local task any=0 vm worktree on changes
  printf '%-20s %-26s %-9s %s\n' TASK BRANCH VM WORKTREE
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    any=1
    vm="stopped"
    lock_is_live "$(lock_file "$(task_root "$task")")" && vm="running"
    worktree="$(task_worktree "$task")"
    if is_git_repo "$worktree"; then
      on="$(git -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached)"
      changes="$(git -C "$worktree" status --porcelain 2>/dev/null | wc -l)"
      if [ "$changes" -gt 0 ]; then changes="$changes uncommitted change(s)"; else changes="clean"; fi
    else
      on="?"
      changes="missing — airlock doctor $1"
    fi
    printf '%-20s %-26s %-9s %s\n' "$task" "$on" "$vm" "$changes"
  done < <(task_names)
  [ "$any" = "1" ] || printf '(none — airlock task new %s <task>)\n' "$1"
}

task_rm() { # name task [--yes]
  local name="$1" task="$2"; shift 2
  local yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      *)        die "unknown option: $1" ;;
    esac
  done
  ws_open "$name"
  task_open "$task"

  local lock
  lock="$(lock_file "$TASK_ROOT")"
  if lock_is_live "$lock"; then
    die "task $task is running (pid $(head -1 "$lock")); stop it first (airlock stop $name $task)"
  fi

  local pending=0
  if is_git_repo "$WS_REPO"; then
    task_fetch_hub
    task_pending "$task"
  else
    TASK_DIRTY=0; TASK_UNPUSHED=0
  fi
  printf 'about to remove task %s of workspace %s\n' "$task" "$name"
  printf '  %s\n' "$TASK_ROOT" "$TASK_WORKTREE"
  if [ "$TASK_DIRTY" -gt 0 ] || [ "$TASK_UNPUSHED" -gt 0 ]; then
    pending=1
    printf '\nIt holds work the hub does not have:\n'
    [ "$TASK_DIRTY" = "0" ] || printf '  %s uncommitted change(s) in its worktree\n' "$TASK_DIRTY"
    [ "$TASK_UNPUSHED" = "0" ] || printf '  %s commit(s) on %s not pushed to the hub\n' "$TASK_UNPUSHED" "$TASK_BRANCH"
    printf 'Removing the task loses them. The hub keeps whatever was pushed.\n'
  fi

  if [ "$yes" != "1" ]; then
    if ! { [ -t 0 ] && [ -t 1 ]; }; then
      die "refusing to remove without confirmation; pass --yes if you mean it"
    fi
    local reply
    if [ "$pending" = "1" ]; then
      printf '\nType the task name to confirm removal: '
      read -r reply || reply=""
      [ "$reply" = "$task" ] || { info "not removed"; return 1; }
    else
      printf '\nRemove it? [y/N] '
      read -r reply || reply=""
      case "$reply" in
        y|Y|yes) ;;
        *) info "not removed"; return 1 ;;
      esac
    fi
  fi

  if is_git_repo "$WS_REPO"; then
    if [ -e "$TASK_WORKTREE" ]; then
      git -C "$WS_REPO" worktree remove --force "$TASK_WORKTREE" 2>/dev/null \
        || rm -rf -- "$TASK_WORKTREE"
    fi
    git -C "$WS_REPO" worktree prune
    if git -C "$WS_REPO" show-ref --verify --quiet "refs/heads/$TASK_BRANCH"; then
      git -C "$WS_REPO" branch --quiet -D "$TASK_BRANCH" \
        || warn "could not delete the repository's $TASK_BRANCH; it is checked out somewhere else"
    fi
  else
    rm -rf -- "$TASK_WORKTREE"
  fi
  rm -rf -- "$TASK_ROOT"
  # The parents, once nothing else is in them: an empty tasks/ in the share is
  # one more thing for an agent to wonder about.
  rmdir -- "$WS_ROOT/tasks" "$WS_WORK_DIR/tasks" 2>/dev/null || true
  info "removed task $task"
}

cmd_task() {
  [ $# -gt 0 ] || { task_usage >&2; exit 2; }
  local sub="$1"; shift
  case "$sub" in
    -h|--help|help) task_usage; return 0 ;;
  esac
  local name="" task=""
  local -a rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) task_usage; return 0 ;;
      --base|--prompt|--prompt-file|--context)
        [ $# -ge 2 ] || die "$1 needs a value"; rest+=("$1" "$2"); shift 2 ;;
      -*)        rest+=("$1"); shift ;;
      *)
        if [ -z "$name" ]; then name="$1"
        elif [ -z "$task" ]; then task="$1"
        else die "unexpected argument: $1"
        fi
        shift ;;
    esac
  done
  [ -n "$name" ] || { task_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"
  case "$sub" in
    new) [ -n "$task" ] || die "task name is required"; task_new "$name" "$task" "${rest[@]}" ;;
    ls)  [ -z "$task" ] || die "unexpected argument: $task"
         [ "${#rest[@]}" -eq 0 ] || die "unknown option: ${rest[0]}"
         task_ls "$name" ;;
    rm)  [ -n "$task" ] || die "task name is required"; task_rm "$name" "$task" "${rest[@]}" ;;
    *)   task_usage >&2; die "unknown task command: $sub" ;;
  esac
}
