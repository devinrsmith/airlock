# shellcheck shell=bash
# airlock init — create a workspace (§4, D3/D4).

init_usage() {
  cat <<'EOF'
usage: airlock init <name> (--from-remote <url> | --from-local <path>) [options]

  --from-remote <url>    seed the hub by fetching from a git remote
  --from-local <path>    seed the hub from an existing local checkout
  --branch <name>        branch the agent starts on (default: the source's own)
  --project <name>       project name (default: derived from the source)
  --flavor <flavor>      claude (default), gemini, codex, pi
  --upstream <name>      name for the hub's remote (default: upstream)
EOF
}


write_config() {
  local dest="$1" project="$2" flavor="$3" branch="$4" upstream="$5" uname="$6" uemail="$7"
  # Everything from here down can be set once in the user defaults file and is
  # baked in at init — see user_default() in common.sh for why baked and not
  # layered.
  local prompts devshell cpus memory substrate env_forward agent_args settings
  local cri cri_storage store_size registry pause
  prompts="$(user_default prompts bypass)"
  devshell="$(user_default devshell off)"
  cpus="$(user_default cpus 4)"
  memory="$(user_default memory_mb 8192)"
  substrate="$(user_default substrate)"
  env_forward="$(user_default env_forward)"
  agent_args="$(user_default agent_args)"
  settings="$(user_default settings)"
  cri="$(user_default cri)"
  cri_storage="$(user_default cri_storage_mb)"
  store_size="$(user_default store_size_mb)"
  registry="$(user_default registry off)"
  pause="$(user_default pause on)"
  cat > "$dest" <<EOF
# airlock workspace configuration.
# Read by a human as much as by the tool: this file is the statement of what
# this workspace is allowed to do.

project        = $project
flavor         = $flavor
default_branch = $branch
upstream       = $upstream

# Identity the agent commits under, inside the VM.
user_name      = $uname
user_email     = $uemail

# D12: the VM is the security boundary, so in-guest permission prompts ask the
# wrong layer for consent. Set to "prompt" to restore the agent's own defaults.
prompts        = $prompts

# D18: "host-eval" pre-evaluates this project's dev shell on the host and hands
# the result to the guest. That evaluates guest-writable Nix code outside the
# VM — a guest-to-host path that needs no kernel bug. Left off deliberately.
devshell       = $devshell

# Resource ceilings (§7). A runaway build should not take the host down.
cpus           = $cpus
memory_mb      = $memory

# Cap on the VM's writable Nix store disk, in MiB. Empty uses the substrate's
# default. That disk is per-run and removed when the VM exits.
store_size_mb  = $store_size

# Container runtimes to activate inside the VM: any of containerd, crun, crio,
# docker, podman, comma separated. Empty runs without them.
#
# A task's first run with this set creates a container storage disk beside its
# agent home, at <workspace>/tasks/<task>/agent_home-cri/. Unlike the store
# disk it persists, and it is sparse — cri_storage_mb is a ceiling, not an
# allocation. 0 runs with no disk at all, putting container storage in the
# VM's RAM.
cri            = $cri
cri_storage_mb = $cri_storage

# D21: "on" points those runtimes at the pull-through caches \`airlock
# registry\` runs on this host — each tries its cache first and falls back to
# the registry itself, so a cache that is not running costs nothing. It hands
# the guest the address of host services (10.0.2.2), so it is off unless asked.
registry       = $registry

# Which claude-microvm to launch. Empty means the one airlock's flake.lock
# pins, run on airlock's nixpkgs. Set a flake reference to pin this workspace
# to something else instead — run exactly as its own lock has it — e.g.
# github:<owner>/claude-microvm/<rev>, or ?ref=<branch> to follow a branch
substrate      = $substrate

# Host environment variables forwarded into the guest, comma separated. A bare
# name forwards that variable's value; NAME=value assigns a literal. The
# agent's API key is already forwarded by the substrate — anything added here
# is another secret inside the VM, so add deliberately (D5).
env_forward    = $env_forward

# Extra arguments appended to the agent's own command line.
agent_args     = $agent_args

# Before it boots, the substrate prints the session contract (what this launch
# hands the guest) and waits for Enter. "off" still prints it but boots straight
# away, for launching from tmux, scripts or IDE tasks. Either way the wait only
# happens at a terminal.
pause          = $pause

# A settings file on this host to start the agent from — your own dotfile,
# say. It is copied into the agent home at the flavor's own config path
# (.claude/settings.json for Claude Code) before boot, and re-copied whenever
# this file changes. A seed, not a sync: settings changed inside the VM survive
# until you edit the file named here, which then replaces them wholesale.
settings       = $settings
EOF
}

cmd_init() {
  local name="" from_remote="" from_local="" project="" flavor="" upstream="upstream" branch=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)      init_usage; return 0 ;;
      --from-remote)  from_remote="${2-}"; [ -n "$from_remote" ] || die "--from-remote needs a url"; shift 2 ;;
      --from-local)   from_local="${2-}";  [ -n "$from_local" ]  || die "--from-local needs a path"; shift 2 ;;
      --project)      project="${2-}";     [ -n "$project" ]     || die "--project needs a name"; shift 2 ;;
      --flavor)       flavor="${2-}";      [ -n "$flavor" ]      || die "--flavor needs a name"; shift 2 ;;
      --upstream)     upstream="${2-}";    [ -n "$upstream" ]    || die "--upstream needs a name"; shift 2 ;;
      --branch)       branch="${2-}";      [ -n "$branch" ]      || die "--branch needs a name"; shift 2 ;;
      -*)             die "unknown option: $1" ;;
      *)              [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done

  [ -n "$name" ] || { init_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"

  # A typo in the defaults file would otherwise do nothing, quietly.
  user_config_warn_unknown
  # --flavor beats the user's default, which beats claude.
  [ -n "$flavor" ] || flavor="$(user_default flavor claude)"
  validate_flavor "$flavor"

  if [ -n "$from_remote" ] && [ -n "$from_local" ]; then
    die "--from-remote and --from-local are mutually exclusive"
  fi
  [ -n "$from_remote$from_local" ] || die "one of --from-remote or --from-local is required"

  # Resolve the source before creating anything, so a bad source fails cleanly.
  local src="" default_branch="" inherited_upstream=""
  if [ -n "$from_local" ]; then
    [ -d "$from_local" ] || die "not a directory: $from_local"
    src="$(cd "$from_local" && pwd -P)"   # absolute: a local remote resolved
    is_git_repo "$src" || die "not a git repository: $src"   # against -C bites (prior art)
    git -C "$src" rev-parse --verify HEAD >/dev/null 2>&1 \
      || die "$src has no commits to seed from"
    default_branch="$(git -C "$src" symbolic-ref --short HEAD 2>/dev/null || true)"
    [ -n "$default_branch" ] || die "$src has a detached HEAD; check out a branch first"
    inherited_upstream="$(git -C "$src" remote get-url origin 2>/dev/null || true)"
    [ -n "$project" ] || project="$(basename "$src")"
  else
    info "asking $from_remote for its default branch"
    default_branch="$(remote_default_branch "$from_remote")"
    [ -n "$default_branch" ] || die "$from_remote advertises no default branch (is it empty, or unreachable?)"
    [ -n "$project" ] || { project="$(basename "${from_remote%/}")"; project="${project%.git}"; }
  fi
  validate_workspace_name "$project"

  # --branch beats whichever branch the source happened to be on. It decides
  # what tasks start from (task new), which is in turn what a host-eval dev
  # shell is evaluated from (D18) — so it is how you say "work against this
  # branch, with this branch's requirements".
  [ -z "$branch" ] || default_branch="$branch"

  local root work_dir hub repo
  root="$(workspace_root "$name")"
  [ -e "$root" ] && die "workspace already exists: $root"
  work_dir="$root/work_dir"
  # The hub is in the root, which no VM mounts: guests reach it only over the
  # hub service (D33), so its refs and its config are the host's alone.
  hub="$root/$project.git"
  repo="$work_dir/.repo"

  # A half-built workspace is worse than none: it would make `init` look
  # non-idempotent and leave `doctor` diagnosing our own mess.
  #
  # EXIT as well as ERR, because `die` exits rather than returning non-zero —
  # without it, any refusal after this point left the workspace behind. Both are
  # cleared on the success path below.
  #
  # Expanded now rather than when it fires: `root` is local, and a failing git
  # command under `set -e` runs the EXIT trap after this function has unwound,
  # where `set -u` makes "$root" an unbound-variable error of its own.
  # shellcheck disable=SC2064
  trap "rm -rf -- $(printf '%q' "$root")" ERR EXIT
  set -o errtrace

  mkdir -p "$work_dir"

  # Seeding is the step that takes the time on a large repository or a slow
  # link, so each step says what it is doing, and at a terminal git shows its
  # own progress for the transfers; otherwise it stays quiet.
  local -a progress=(--quiet)
  [ ! -t 2 ] || progress=(--quiet --progress)   # the meter, without a line per ref

  git init --quiet --bare "$hub"
  git -C "$hub" config receive.denyNonFastForwards true
  git -C "$hub" config receive.denyDeletes true

  if [ -n "$src" ]; then
    # --no-verify: the source's hooks are about publishing to its own remotes,
    # not seeding a hub. git-lfs's pre-push in particular fails outright on a
    # bare-path destination; its objects are carried over below instead.
    info "copying $src's branches and tags into the hub"
    git -C "$src" push "${progress[@]}" --no-verify "$hub" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
    if [ -n "$inherited_upstream" ]; then
      git -C "$hub" remote add "$upstream" "$inherited_upstream"
      git -C "$hub" config "remote.$upstream.fetch" "+refs/heads/*:refs/upstream/$upstream/*"
    fi
  else
    info "fetching $from_remote's branches and tags into the hub — this can take a while"
    git -C "$hub" fetch "${progress[@]}" --tags "$from_remote" '+refs/heads/*:refs/heads/*'
    git -C "$hub" remote add "$upstream" "$from_remote"
    git -C "$hub" config "remote.$upstream.fetch" "+refs/heads/*:refs/upstream/$upstream/*"
  fi

  git -C "$hub" rev-parse --verify --quiet "refs/heads/$default_branch" >/dev/null \
    || die "no branch '$default_branch' in the seeded hub. Seeding copies the source's
  own branches, so a branch that only exists on its remote is not there yet;
  these are: $(git -C "$hub" for-each-ref --format='%(refname:short)' refs/heads/ | tr '\n' ' ')"

  # Verified requirement: `git init --bare` points HEAD at refs/heads/master
  # whatever we seeded, and a clone of a hub whose HEAD dangles comes up with
  # no checkout at all.
  git -C "$hub" symbolic-ref HEAD "refs/heads/$default_branch"

  # D25: LFS objects travel into the hub, from the same place its commits came
  # from — for the default branch, which is what tasks start from; a task made
  # from another branch fetches that one's (task new). A local checkout need not
  # have every object (it may have been cloned with smudging skipped), so its
  # upstream fills in whatever it lacks. Whether the repository uses LFS at all
  # is asked of every branch, since that decides how the repository is set up.
  local lfs=0 tip="refs/heads/$default_branch"
  if lfs_used "$hub" refs/heads/; then
    lfs=1
    lfs_require
  fi
  if [ "$lfs" = 1 ] && lfs_used_at "$hub" "$tip"; then
    if [ -z "$src" ]; then
      lfs_fetch "$hub" "$upstream" "$default_branch" "$tip" \
        || { lfs_fetch_log; die "could not fetch the Git LFS objects of $default_branch from $from_remote"; }
    elif [ -n "$inherited_upstream" ]; then
      lfs_fetch "$hub" "file://$src" "$default_branch" "$tip" \
        || lfs_fetch "$hub" "$upstream" "what $src lacks of $default_branch" "$tip" \
        || { lfs_fetch_log; die "some Git LFS objects of $default_branch are neither in $src nor on $inherited_upstream"; }
    else
      lfs_fetch "$hub" "file://$src" "$default_branch" "$tip" \
        || { lfs_fetch_log; die "$src lacks Git LFS objects $default_branch needs, and has no origin to fetch them from"; }
    fi
  fi

  # The repository the tasks' worktrees belong to (D26): bare, since no agent
  # works in it, and with no branches of its own — a task makes its own, and
  # the hub's are remote-tracking refs, as in any clone. A clone of a local
  # path hardlinks its objects, so this costs next to no disk.
  #
  # Its git runs confined like every git call on work_dir (D34), though no agent
  # has run yet: one rule is easier to keep than a list of exceptions. The hub
  # is bound read-only for the clone and its first fetch.
  info "setting up the repository the tasks' worktrees share"
  INIT_WD="$work_dir" INIT_HUB="$hub" INIT_REPO="$repo"
  init_repo_git clone --quiet --bare "$hub" "$repo"
  init_repo_git -C "$repo" for-each-ref --format='delete %(refname)' refs/heads/ \
    | init_repo_git -C "$repo" update-ref --stdin
  init_repo_git -C "$repo" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  # D8: upstream refs are readable from the worktrees, and there is no remote
  # the agent could push them back to.
  init_repo_git -C "$repo" config --add remote.origin.fetch '+refs/upstream/*:refs/remotes/upstreams/*'
  init_repo_git -C "$repo" fetch --quiet origin
  if [ "$lfs" = 1 ]; then
    # The filter, installed locally rather than relying on the host's global
    # config, so it is the repository's own, every worktree shares it, and the
    # guest sees it too (the substrate puts git-lfs on its PATH): checkouts get
    # content, and new LFS files are stored as pointers. Not git-lfs's hooks
    # (--skip-repo): its pre-push hook demands an LFS server for the remote on
    # every push, and the hub serves none (D33), so it would refuse every push,
    # with LFS changes or without. And git-lfs reinstalls its hooks itself
    # whenever it runs in a repository that has none — at any checkout, in a
    # guest too — so the pre-push is taken by airlock's own, which does
    # nothing, and which git-lfs does not overwrite (lfs_write_prepush). An
    # agent's new LFS objects stay in this repository's lfs/ store, and reach
    # the hub only as pointers.
    init_repo_git -C "$repo" lfs install --local --skip-repo >/dev/null
    lfs_write_prepush "$repo"
  fi

  # The identity the agent commits under: an airlock default if the person set
  # one, else their git identity, else something obviously a placeholder.
  local uname uemail
  uname="$(user_default user_name)"
  uemail="$(user_default user_email)"
  [ -n "$uname" ]  || uname="$(git config --global user.name 2>/dev/null || true)"
  [ -n "$uemail" ] || uemail="$(git config --global user.email 2>/dev/null || true)"
  [ -n "$uname" ]  || uname="airlock agent"
  [ -n "$uemail" ] || uemail="agent@airlock.invalid"
  init_repo_git -C "$repo" config user.name "$uname"
  init_repo_git -C "$repo" config user.email "$uemail"

  # Last, because everything above fetched through the host path. Relative,
  # and to a worktree: git resolves it from a worktree's top, which is always
  # work_dir/tasks/<task>/, so on the host it names the hub in the root, and the
  # developer can run what an agent runs. In a guest the hub is not there: the
  # repository includes, only when its git dir is under /work, the config each
  # launch puts in the task's context, which reaches the hub over SSH instead
  # (D33). Run from .repo itself the URL points elsewhere; airlock never does.
  init_repo_git -C "$repo" remote set-url origin "../../../$project.git"
  init_repo_git -C "$repo" config "includeIf.gitdir:/work/.path" /run/microvm/context/.airlock/gitconfig

  # The workspace's key to its hub, and its line in the service's keys.
  hub_ensure_home
  hub_ensure_key "$root" "$name"

  write_context_file "$work_dir/$(flavor_context_file "$flavor")"
  write_config "$root/config" "$project" "$flavor" "$default_branch" "$upstream" "$uname" "$uemail"

  trap - ERR EXIT

  info "created workspace '$name' at $root"
  info "  project        $project  (default branch $default_branch)"
  info "  agent          $flavor"
  if [ -n "$(git -C "$hub" remote 2>/dev/null)" ]; then
    info "  upstream       $upstream -> $(git -C "$hub" remote get-url "$upstream")"
  else
    info "  upstream       none configured"
  fi
  # Its key is authorised once the config names the project.
  hub_sync_keys
  # A running web view shows only the hubs it started with (D35).
  web_sync
  hub_running 2>/dev/null || info "  hub service    not running — start it before running a task: airlock hub start"
  info ""
  info "next: airlock task new $name <task> --prompt \"what it is for\""
}

# git on the repository init is building inside work_dir, through the sandbox
# (D34), with the hub readable for the clone and the first fetch.
INIT_WD="" INIT_HUB="" INIT_REPO=""
init_repo_git() {
  wd_git "$INIT_WD" --hub "$INIT_HUB" --repo "$INIT_REPO" -- "$@"
}
