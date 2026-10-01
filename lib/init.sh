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
  local cri cri_storage store_size
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
# The first run with this set creates a container storage disk beside the agent
# home, at <workspace>/agent_home-cri/. Unlike the store disk it persists, and
# it is sparse — cri_storage_mb is a ceiling, not an allocation. 0 runs with no
# disk at all, putting container storage in the VM's RAM.
cri            = $cri
cri_storage_mb = $cri_storage

# Which claude-microvm to launch. Empty means the copy vendored in airlock as a
# git submodule, whose version is pinned by a commit in airlock's own history.
# Set a flake reference to pin this workspace to something else instead, e.g.
# github:systemstart/claude-microvm/<rev>
substrate      = $substrate

# Host environment variables forwarded into the guest, comma separated. A bare
# name forwards that variable's value; NAME=value assigns a literal. The
# agent's API key is already forwarded by the substrate — anything added here
# is another secret inside the VM, so add deliberately (D5).
env_forward    = $env_forward

# Extra arguments appended to the agent's own command line.
agent_args     = $agent_args

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
    default_branch="$(remote_default_branch "$from_remote")"
    [ -n "$default_branch" ] || die "$from_remote advertises no default branch (is it empty, or unreachable?)"
    [ -n "$project" ] || { project="$(basename "${from_remote%/}")"; project="${project%.git}"; }
  fi
  validate_workspace_name "$project"

  # --branch beats whichever branch the source happened to be on. It decides
  # what the agent's clone is checked out at, which is in turn what a host-eval
  # dev shell is evaluated from (D18) — so it is how you say "work against this
  # branch, with this branch's requirements".
  [ -z "$branch" ] || default_branch="$branch"

  local root work_dir hub clone
  root="$(workspace_root "$name")"
  [ -e "$root" ] && die "workspace already exists: $root"
  work_dir="$root/work_dir"
  hub="$work_dir/$project.git"
  clone="$work_dir/$project"

  # A half-built workspace is worse than none: it would make `init` look
  # non-idempotent and leave `doctor` diagnosing our own mess.
  #
  # EXIT as well as ERR, because `die` exits rather than returning non-zero —
  # without it, any refusal after this point left the workspace behind. Both are
  # cleared on the success path below.
  trap 'rm -rf -- "$root"' ERR EXIT
  set -o errtrace

  mkdir -p "$work_dir" "$root/agent_home" "$root/watermarks"

  git init --quiet --bare "$hub"
  git -C "$hub" config receive.denyNonFastForwards true
  git -C "$hub" config receive.denyDeletes true

  if [ -n "$src" ]; then
    git -C "$src" push --quiet "$hub" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
    if [ -n "$inherited_upstream" ]; then
      git -C "$hub" remote add "$upstream" "$inherited_upstream"
      git -C "$hub" config "remote.$upstream.fetch" "+refs/heads/*:refs/upstream/$upstream/*"
    fi
  else
    git -C "$hub" fetch --quiet --tags "$from_remote" '+refs/heads/*:refs/heads/*'
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

  git clone --quiet "$hub" "$clone"

  # D8: upstream refs are readable from the clone, and there is no remote the
  # agent could push them back to.
  git -C "$clone" config --add remote.origin.fetch '+refs/upstream/*:refs/remotes/upstreams/*'
  git -C "$clone" fetch --quiet origin

  # The identity the agent commits under: an airlock default if the person set
  # one, else their git identity, else something obviously a placeholder.
  local uname uemail
  uname="$(user_default user_name)"
  uemail="$(user_default user_email)"
  [ -n "$uname" ]  || uname="$(git config --global user.name 2>/dev/null || true)"
  [ -n "$uemail" ] || uemail="$(git config --global user.email 2>/dev/null || true)"
  [ -n "$uname" ]  || uname="airlock agent"
  [ -n "$uemail" ] || uemail="agent@airlock.invalid"
  git -C "$clone" config user.name "$uname"
  git -C "$clone" config user.email "$uemail"

  # Last, because everything above needs a remote that resolves on the host.
  # Inside the guest the hub is at /work/<project>.git; the host never uses
  # this remote, so it is correct for it to be a guest-only path.
  git -C "$clone" remote set-url origin "/work/$project.git"

  # Every ref in the hub right now was put there by us, so it is already seen
  # (D16). Anything that appears later is the agent's.
  watermark_record_all "$root" "$hub"

  write_context_file "$work_dir/$(flavor_context_file "$flavor")" "$project"
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
  info ""
  info "next: airlock run $name"
}
