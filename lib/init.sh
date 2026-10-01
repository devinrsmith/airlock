# shellcheck shell=bash
# airlock init — create a workspace (§4, D3/D4).

init_usage() {
  cat <<'EOF'
usage: airlock init <name> (--from-remote <url> | --from-local <path>) [options]

  --from-remote <url>    seed the hub by fetching from a git remote
  --from-local <path>    seed the hub from an existing local checkout
  --project <name>       project name (default: derived from the source)
  --flavor <flavor>      claude (default), gemini, codex, pi
  --upstream <name>      name for the hub's remote (default: upstream)
EOF
}

# The emitted workspace pointer (D14, middle layer). airlock owns this file
# completely and regenerates it; it lives at the root of the share, outside the
# repository, so it never collides with the project's own committed context.
write_context_file() {
  local dest="$1" project="$2"
  cat > "$dest" <<EOF
# This workspace

You are running in an airlock workspace: an isolated microVM whose only channel
to the outside is a bare git repository. Nothing here is your developer's
working tree, and nothing you do reaches them until it is a commit in the hub.

## Where to work

- \`/work/$project\` — your clone. Do all work here.
- \`/work/$project.git\` — the **hub**. Push to it; never edit inside it, and
  never run commands that rewrite its refs directly. It is the record your
  developer reads.

Do not create or modify anything else under \`/work\`.

## Branches

Name your branches \`agent/<topic>\` — for example \`agent/fix-parser\`. Ordinary
git works normally:

\`\`\`sh
git checkout -b agent/<topic>
git push -u origin HEAD
\`\`\`

The hub refuses force-pushes and branch deletions. If you need to correct a
commit you already pushed, add a new commit — do not amend and force.

## Getting work out

Your developer reviews what arrives in the hub and publishes it themselves from
their own machine. There are no forge credentials in this VM and pushing to
GitHub or any other forge will not work — pushing to \`origin\` is the whole job.

## Upstream code

Branches from configured upstream remotes appear as read-only remote-tracking
refs under \`upstreams/<remote>/<branch>\`. Fetch \`origin\` to refresh them. You
cannot push to an upstream, and private upstreams are only visible if your
developer has fetched them into the hub.
EOF
}

write_config() {
  local dest="$1" project="$2" flavor="$3" branch="$4" upstream="$5" uname="$6" uemail="$7"
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
prompts        = bypass

# D18: "host-eval" pre-evaluates this project's dev shell on the host and hands
# the result to the guest. That evaluates guest-writable Nix code outside the
# VM — a guest-to-host path that needs no kernel bug. Left off deliberately.
devshell       = off

# Resource ceilings (§7). A runaway build should not take the host down.
cpus           = 4
memory_mb      = 8192
EOF
}

cmd_init() {
  local name="" from_remote="" from_local="" project="" flavor="claude" upstream="upstream"

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)      init_usage; return 0 ;;
      --from-remote)  from_remote="${2-}"; [ -n "$from_remote" ] || die "--from-remote needs a url"; shift 2 ;;
      --from-local)   from_local="${2-}";  [ -n "$from_local" ]  || die "--from-local needs a path"; shift 2 ;;
      --project)      project="${2-}";     [ -n "$project" ]     || die "--project needs a name"; shift 2 ;;
      --flavor)       flavor="${2-}";      [ -n "$flavor" ]      || die "--flavor needs a name"; shift 2 ;;
      --upstream)     upstream="${2-}";    [ -n "$upstream" ]    || die "--upstream needs a name"; shift 2 ;;
      -*)             die "unknown option: $1" ;;
      *)              [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done

  [ -n "$name" ] || { init_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"
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

  local root work_dir hub clone
  root="$(workspace_root "$name")"
  [ -e "$root" ] && die "workspace already exists: $root"
  work_dir="$root/work_dir"
  hub="$work_dir/$project.git"
  clone="$work_dir/$project"

  # A half-built workspace is worse than none: it would make `init` look
  # non-idempotent and leave `doctor` diagnosing our own mess.
  trap 'rm -rf -- "$root"' ERR
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
    || die "seeding did not produce refs/heads/$default_branch in the hub"

  # Verified requirement: `git init --bare` points HEAD at refs/heads/master
  # whatever we seeded, and a clone of a hub whose HEAD dangles comes up with
  # no checkout at all.
  git -C "$hub" symbolic-ref HEAD "refs/heads/$default_branch"

  git clone --quiet "$hub" "$clone"

  # D8: upstream refs are readable from the clone, and there is no remote the
  # agent could push them back to.
  git -C "$clone" config --add remote.origin.fetch '+refs/upstream/*:refs/remotes/upstreams/*'
  git -C "$clone" fetch --quiet origin

  local uname uemail
  uname="$(git config --global user.name 2>/dev/null || true)"
  uemail="$(git config --global user.email 2>/dev/null || true)"
  [ -n "$uname" ]  || uname="airlock agent"
  [ -n "$uemail" ] || uemail="agent@airlock.invalid"
  git -C "$clone" config user.name "$uname"
  git -C "$clone" config user.email "$uemail"

  # Last, because everything above needs a remote that resolves on the host.
  # Inside the guest the hub is at /work/<project>.git; the host never uses
  # this remote, so it is correct for it to be a guest-only path.
  git -C "$clone" remote set-url origin "/work/$project.git"

  write_context_file "$work_dir/$(flavor_context_file "$flavor")" "$project"
  write_config "$root/config" "$project" "$flavor" "$default_branch" "$upstream" "$uname" "$uemail"

  trap - ERR

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
