# shellcheck shell=bash
# airlock run — launch a task's VM.
#
# This is the one command that cannot be tested without KVM, so the launch is
# kept to a single call at the end: everything before it (preflight, the lock,
# the environment the substrate is handed) is ordinary shell and is covered by
# `--dry-run` and by pointing AIRLOCK_LAUNCHER at a stub.

run_usage() {
  cat <<'EOF'
usage: airlock run <name> <task> [--fresh] [--dry-run] [-- <agent args>...]

  <task>      the task to run (airlock task new), in a VM of its own, beside
              the workspace's other tasks
  --fresh     the agent starts a new conversation, asked to read its context,
              rather than continuing the last one
  --dry-run   print the launch environment and command, and exit
  --          everything after is appended to the agent's own command line

The VM powers off when the agent exits, or with `airlock stop <name> <task>`.
EOF
}

# One VM per task (D13), held with flock (see lock_is_live) on the lock in the
# task's directory. The
# descriptor stays open across exec, so the launcher and QEMU inherit it and
# the lock outlives this shell if they do. The file holds our pid, then the
# launch record (see cmd_run), written only once the lock is ours, so a held
# lock never shows another run's record. The lock lives in the unmounted root
# (D3), so the guest cannot rewrite what it says it runs on.
#
# The file is removed when the last holder lets go (run_lock_release), so one
# that is there but free was left by a run that was killed. A run that opened
# the path just before that removal locks a file no longer at it; the inode
# check catches that and it opens the path again.
RUN_LOCK_FD=""
run_lock_acquire() { # task_root record what
  local lock _ what="$3"
  lock="$(lock_file "$1")"
  lock_need_flock
  for _ in 1 2 3; do
    exec {RUN_LOCK_FD}<>"$lock" || die "could not open the lock at $lock"
    if ! flock -n "$RUN_LOCK_FD"; then
      exec {RUN_LOCK_FD}<&-; RUN_LOCK_FD=""
      die "a run is already in progress for $what (pid $(head -1 "$lock" 2>/dev/null)); if there is none, try again"
    fi
    [ /dev/fd/"$RUN_LOCK_FD" -ef "$lock" ] && break
    exec {RUN_LOCK_FD}<&-; RUN_LOCK_FD=""
  done
  [ -n "$RUN_LOCK_FD" ] || die "could not take the lock at $lock"
  [ ! -s "$lock" ] || warn "clearing a stale lock from a run that is no longer alive"
  # Truncated in place, not replaced: a new file would not be the one locked.
  printf '%s\n%s\n' "$$" "$2" > "$lock"
}

# Removes the lock only once nothing holds it. Ours is closed first; if the
# lock is still held then, the launcher exited and left QEMU running, and the
# lock stays until QEMU goes too. It is taken again before removal, so a run
# starting meanwhile either is refused or finds the file gone (the inode check
# above).
run_lock_release() { # root
  local lock fd
  [ -n "$RUN_LOCK_FD" ] || return 0
  lock="$(lock_file "$1")"
  exec {RUN_LOCK_FD}<&-; RUN_LOCK_FD=""
  { exec {fd}<"$lock"; } 2>/dev/null || return 0
  if flock -n "$fd"; then
    rm -f "$lock"
  else
    warn "the launcher exited but the VM it started has not; its lock stays held until the VM stops"
  fi
  exec {fd}<&-
  return 0
}

# Is this task fit to launch? Checked for --dry-run too: what would happen is a
# refusal, and that is worth showing.
#
# A symlinked agent_home sends the substrate's -cri and -store disks next to
# the link target instead of into the workspace (§4). doctor reports it; run
# refuses, because launching is what creates those disks. The context is
# copied into the guest, and the worktree is where the agent starts (D29).
run_preflight_task() { # name
  local name="$1"
  wd_is_repo "$WS_WORK_DIR" "$WS_REPO" \
    || die "the repository is missing (airlock doctor $name)"
  [ ! -L "$TASK_HOME" ] \
    || die "task $TASK_NAME's agent_home is a symlink; its disks would land outside the workspace"
  [ -d "$TASK_HOME" ] || die "task $TASK_NAME has no agent_home (airlock doctor $name --fix)"
  [ -d "$TASK_CONTEXT" ] || die "task $TASK_NAME has no context (airlock doctor $name --fix)"
  wd_is_repo "$WS_WORK_DIR" "$TASK_WORKTREE" \
    || die "task $TASK_NAME's worktree is missing (airlock doctor $name)"
}

# Can this host launch at all? Only asked when actually launching: --dry-run
# prints a mapping and has no business demanding KVM.
run_preflight_host() { # flavor
  local flavor="$1" keyvar tokvar
  if [ -z "${AIRLOCK_LAUNCHER:-}" ]; then
    command -v nix >/dev/null 2>&1 || die "nix is not on PATH; it is what builds and launches the guest"
    [ -e /dev/kvm ] || die "/dev/kvm is missing; this host cannot run a VM"
    { [ -r /dev/kvm ] && [ -w /dev/kvm ]; } \
      || die "/dev/kvm is not readable and writable by you (are you in the kvm group?)"
  fi

  # Not fatal: the agent may already have a stored session in agent_home. But
  # a first run with neither is a boot into a login prompt you cannot answer.
  keyvar="$(flavor_api_key_var "$flavor")"
  tokvar="$(flavor_token_var "$flavor")"
  if [ -z "$keyvar" ] || [ -n "$(run_credential "$flavor")" ]; then
    return 0
  elif [ -n "$tokvar" ] && run_forwards "$tokvar"; then
    warn "$tokvar is forwarded but not set; unless $flavor already has a session in agent_home it will not authenticate"
  elif [ -n "$tokvar" ]; then
    warn "neither $keyvar is set nor $tokvar forwarded; unless $flavor already has a session in agent_home it will not authenticate"
  else
    warn "$keyvar is not set; unless $flavor already has a session in agent_home it will not authenticate"
  fi
}

# Whether the workspace's env_forward names var, bare or as var=value.
run_forwards() { # var
  local entry
  for entry in $(config_get "$WS_CONFIG" env_forward | tr ',' ' '); do
    [ "${entry%%=*}" != "$1" ] || return 0
  done
  return 1
}

# Which credential this launch hands the agent (D5): "key" for the flavor's
# API key, which the substrate forwards when it is set, "token" for its
# subscription token when env_forward carries one, or nothing. The key first,
# as Claude Code prefers it when it has both.
run_credential() { # flavor
  local keyvar tokvar entry
  keyvar="$(flavor_api_key_var "$1")"
  tokvar="$(flavor_token_var "$1")"
  if [ -n "$keyvar" ] && [ -n "${!keyvar:-}" ]; then
    printf 'key\n'
    return 0
  fi
  [ -n "$tokvar" ] || return 0
  for entry in $(config_get "$WS_CONFIG" env_forward | tr ',' ' '); do
    case "$entry" in
      "$tokvar") [ -z "${!tokvar:-}" ] || { printf 'token\n'; return 0; } ;;
      "$tokvar"=?*) printf 'token\n'; return 0 ;;
    esac
  done
}

# The launcher is run from the workspace root, so anything the caller gave as a
# path relative to their own cwd has to be resolved before we move.
run_abs_path() { # path
  case "$1" in
    # The config file is parsed, not sourced, so nothing expands `~` for us —
    # and `~/dotfiles/...` is exactly how someone will write a path in it.
    # [~] rather than "~": a character class matches the literal tilde without
    # looking like a tilde we expected the shell to expand for us.
    [~])   printf '%s\n' "$HOME" ;;
    [~]/*) printf '%s/%s\n' "$HOME" "${1#[~]/}" ;;
    /*)    printf '%s\n' "$1" ;;
    ./*)   printf '%s/%s\n' "$PWD" "${1#./}" ;;
    .)     printf '%s\n' "$PWD" ;;
    *)     printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# Same, for a flake reference. Only the forms that are actually cwd-relative are
# touched: `github:`, `git+https:` and friends must be left exactly as written.
run_abs_flake_ref() { # ref
  case "$1" in
    .|./*|../*|[~]|[~]/*) printf '%s\n' "$(run_abs_path "$1")" ;;
    path:./*|path:../*) printf 'path:%s\n' "$(run_abs_path "${1#path:}")" ;;
    *)          printf '%s\n' "$1" ;;
  esac
}

# The claude-microvm this airlock is locked against, read out of flake.lock. An
# installed build has the reference baked into its wrapper; a source checkout
# reads it from the lock so that it launches the same microVM an install would,
# rather than drifting to whatever github serves today. Whole, not just the
# revision: flake.nix may point at a fork. A lock with no claude-microvm node
# means the lock and the flake disagree, which is worth saying out loud.
substrate_ref_from_lock() { # lockfile
  flake_lock_ref "$1" claude-microvm
}

# The claude-microvm a workspace launches when it pins none of its own: what
# this build was locked against, else what the checkout's flake.lock says.
# Returns 1 when nothing pins one at all.
substrate_default_ref() {
  local lock
  if [ -n "${AIRLOCK_SUBSTRATE:-}" ]; then
    run_abs_flake_ref "$AIRLOCK_SUBSTRATE"
    return 0
  fi
  lock="${AIRLOCK_FLAKE_LOCK:-$AIRLOCK_LIB/../flake.lock}"
  [ -f "$lock" ] && substrate_ref_from_lock "$lock"
}

# Which claude-microvm to launch, in order: what this workspace pins, then the
# default above.
run_substrate_ref() {
  local configured
  configured="$(config_get "$WS_CONFIG" substrate)"
  if [ -n "$configured" ]; then
    run_abs_flake_ref "$configured"
    return 0
  fi
  substrate_default_ref && return 0
  die "no substrate: nothing pins which claude-microvm to launch.
  In a checkout:  flake.lock should carry a claude-microvm revision
  Installed:      the build should have baked one in; reinstall
  Or pin this workspace explicitly with 'substrate = <flake ref>' in its config."
}

# Claude Code asks whether you trust the directory it starts in, once per
# directory, and records the answer in ~/.claude.json under projects.<dir>. A
# task's agent starts in its worktree (D29), a checkout airlock itself made,
# from a source the developer named, so the question has nothing in it for the
# person answering, and it blocks an unattended first boot.
#
# Its first-run onboarding, a theme picker, blocks it the same way, and is
# marked done there too when the launch forwards a subscription token. Only
# then: with no credential, the picker leads into the login, and skipping it
# leaves a prompt that says "Not logged in" and fails the first request instead
# (both verified 2026-10-30, Claude Code 2.1.296). With an API key it is left
# alone, unverified.
#
# Seeded only when there is no file yet. That file is the agent's own state and
# is guest-writable; rewriting one that exists would throw away its history to
# answer a question it has already answered.
run_seed_claude_state() { # flavor agent_home start_dir credential
  [ "$1" = "claude" ] || return 0   # the only flavor whose mechanism is verified
  local file="$2/.claude.json"
  if [ -e "$file" ]; then
    grep -q '"hasTrustDialogAccepted"' "$file" 2>/dev/null \
      || warn "$file records no trust decision; claude may ask about $3 on this launch"
    return 0
  fi
  {
    printf '{\n'
    if [ "$4" = "token" ]; then printf '  "hasCompletedOnboarding": true,\n'; fi
    printf '  "projects": {\n    "%s": { "hasTrustDialogAccepted": true }\n  }\n}\n' "$3"
  } > "$file"
}

# Whether Claude Code has a conversation to continue in dir: it keeps them
# under ~/.claude/projects/, in a directory named for the path with every
# character but letters and digits made "-", and --continue looks only in its
# start directory's, exiting when that has none. A conversation from another
# directory (a home carried over from before tasks, whose agent started in
# /work) is not one it would continue.
run_has_conversation() { # agent_home dir
  compgen -G "$1/.claude/projects/${2//[^A-Za-z0-9]/-}/*.jsonl" >/dev/null
}

# What a task's agent is asked to do this run (D29), as words to append to its
# command line, one per line; nothing when the flavor has no verified way.
# The first run gets a fixed pointer to its context, never the developer's own
# text: the substrate runs the agent's command line through `eval`, so only
# words airlock wrote go there. A later run continues the conversation the
# task's home holds, unless asked not to.
run_task_args() { # fresh
  local fresh="$1" cont
  cont="$(flavor_continue_args "$WS_FLAVOR")"
  if [ "$fresh" = "0" ] && run_has_conversation "$TASK_HOME" "$TASK_GUEST_DIR"; then
    if [ -n "$cont" ]; then
      printf '%s\n' "$cont"
      return 0
    fi
    warn "no verified way to continue a $WS_FLAVOR conversation; task $TASK_NAME starts a new one"
  fi
  if flavor_takes_prompt "$WS_FLAVOR"; then
    printf "'%s'\n" "Your task is described in /run/microvm/context/: read prompt.md and task.json there, and anything else it holds. Once you have read them, and before any other work, echo the contents of prompt.md back verbatim. Work in $TASK_GUEST_DIR, on branch $TASK_BRANCH, and push that branch to origin."
  else
    warn "no verified way to give $WS_FLAVOR a first prompt; tell the agent its task is in /run/microvm/context/"
  fi
}

# D18. Two halves, and they are gated separately.
#
# The substrate's *detection* half runs on the host when DIRENV_ALLOW=1 and
# looks for a flake in $WORK. Under airlock's layout $WORK is `work_dir/`, whose
# contents are the hub, the repository and the tasks' worktrees, so that half finds
# nothing and says so — the project is further down, in the task's worktree.
#
# The *loading* half runs in the guest and is gated on DIRENV_ALLOW too
# (modules/base.nix: `if [ "${DIRENV_ALLOW:-0}" = "1" ]` around sourcing
# ~/.microvm-devshell). So writing the cache is necessary but not sufficient:
# the variable has to reach the guest as well, which is why cmd_run sets it
# alongside calling this. The host warning about $WORK having no flake is
# expected and harmless — an ineligible $WORK only warns, it never clears a
# cache we wrote.
#
# It evaluates the task's worktree on the host, which is the hazard the config
# flag exists to make visible (§9.1).
# What kind of dev shell a directory holds, mirroring the substrate's own
# detection so the two cannot disagree about what a project is:
#
#   flake         flake.nix alone
#   flake-impure  flake.nix and devenv.nix — devenv's flake needs --impure
#   devenv        devenv.nix (or the older .devenv.flake.nix) with no flake.nix,
#                 which `nix print-dev-env` has nothing to evaluate
#   (empty)       none of those
devshell_kind() { # dir
  local dir="$1"
  if [ -f "$dir/flake.nix" ]; then
    if [ -f "$dir/devenv.nix" ]; then printf 'flake-impure\n'; else printf 'flake\n'; fi
  elif [ -f "$dir/devenv.nix" ] || [ -f "$dir/.devenv.flake.nix" ]; then
    printf 'devenv\n'
  fi
}

run_devshell_cache() { # worktree agent_home
  local worktree="$1" cache="$2/.microvm-devshell" kind
  kind="$(devshell_kind "$worktree")"
  if [ -z "$kind" ]; then
    warn "devshell = host-eval, but $worktree has no flake.nix or devenv.nix — nothing to evaluate"
    return 0
  fi
  if [ "$kind" = "devenv" ] && ! command -v devenv >/dev/null 2>&1; then
    warn "$worktree is a devenv project, but devenv is not on PATH — no dev shell for the guest"
    return 0
  fi

  info "evaluating the dev shell on the host (devshell = host-eval, $kind)"
  local -a dev_cmd
  case "$kind" in
    flake)        dev_cmd=(nix print-dev-env --no-update-lock-file "$worktree") ;;
    flake-impure) dev_cmd=(nix print-dev-env --no-update-lock-file --impure "$worktree") ;;
    devenv)       dev_cmd=(devenv print-dev-env) ;;
  esac

  # From inside the worktree: devenv reads the project it is standing in, and the
  # nix forms are unharmed by it.
  if ( cd "$worktree" && "${dev_cmd[@]}" ) > "$cache.tmp" 2>"$cache.err"; then
    mv "$cache.tmp" "$cache"
    rm -f "$cache.err"
  else
    rm -f "$cache.tmp"
    warn "could not evaluate the dev shell; see $cache.err"
  fi
}

# What a task's launch is, from its workspace's config, as one `key value` line per fact:
#   flavor     <flavor>
#   substrate  <flake ref>
#   nixpkgs    <flake ref> the substrate's nixpkgs input is overridden to;
#              absent when it keeps its own
#   env        <NAME=value>, one per variable the substrate is handed
# `run` launches exactly this and records it in the lock; `status` computes it
# again and compares, which is how it notices a config changed under a running
# VM. So everything that decides the launch belongs here, and nothing that only
# belongs to one run — arguments after `--` are recorded separately.
#
# Needs ws_open and task_open. Dies on a config that cannot launch, so callers that must not
# die (status) run it in a subshell.
run_plan() {
  validate_flavor "$WS_FLAVOR"

  # --- the agent's own command line ---
  local agent_args prompts bypass
  agent_args="$(config_get "$WS_CONFIG" agent_args)"
  prompts="$(config_get "$WS_CONFIG" prompts bypass)"
  if [ "$prompts" = "bypass" ]; then
    bypass="$(flavor_bypass_args "$WS_FLAVOR")"
    if [ -n "$bypass" ]; then
      agent_args="$bypass${agent_args:+ $agent_args}"
    else
      warn "prompts = bypass, but no bypass flag is known for $WS_FLAVOR; it will prompt inside the VM"
    fi
  fi

  # --- the environment the substrate reads ---
  # The task (D26) mounts its own home (D28), is handed its context and starts
  # in its worktree (D29). /work is uncached (D27): every worktree shares the
  # repository's .git, and a VM launched now cannot know whether another will
  # start beside it.
  local -a env_pairs=(
    "WORK_DIR=$WS_WORK_DIR"
    "AGENT_HOME=$TASK_HOME"
    "WORK_CACHE=never"
    "MICROVM_CONTEXT=$TASK_CONTEXT"
    "MICROVM_START_DIR=$TASK_GUEST_DIR"
    "VM_VCPU=$(config_get "$WS_CONFIG" cpus 4)"
    "VM_MEM=$(config_get "$WS_CONFIG" memory_mb 8192)"
  )
  [ -z "$agent_args" ] || env_pairs+=("AGENTS_ARGS=$agent_args")

  # The substrate's own pre-seeding: a settings file on the host copied into the
  # agent home at the flavor's config path. Resolved here, before the launcher's
  # working directory moves (§4), and checked here so a typo fails now rather
  # than after the guest has started building.
  local settings
  settings="$(config_get "$WS_CONFIG" settings)"
  if [ -n "$settings" ]; then
    settings="$(run_abs_path "$settings")"
    [ -f "$settings" ] || die "settings file not found: $settings"
    [ -r "$settings" ] || die "settings file is not readable: $settings"
    if [ -n "$(flavor_settings_path "$WS_FLAVOR")" ]; then
      env_pairs+=("AGENT_SETTINGS=$settings")
    else
      warn "$WS_FLAVOR has no settings path; the workspace's 'settings' is ignored"
    fi
  fi

  # The guest gates loading the dev-shell cache on DIRENV_ALLOW, so writing the
  # cache is only half of D18's opt-in; without this the file is written and
  # then ignored.
  [ "$(config_get "$WS_CONFIG" devshell off)" != "host-eval" ] || env_pairs+=("DIRENV_ALLOW=1")

  local store cri forward
  store="$(config_get "$WS_CONFIG" store_size_mb)"
  [ -z "$store" ] || env_pairs+=("VM_STORE_SIZE=$store")
  cri="$(config_get "$WS_CONFIG" cri)"
  [ -z "$cri" ] || env_pairs+=("ENABLE_CRI=$cri")
  local cri_storage
  cri_storage="$(config_get "$WS_CONFIG" cri_storage_mb)"
  [ -z "$cri_storage" ] || env_pairs+=("CRI_STORAGE_SIZE=$cri_storage")
  # D21. Only with runtimes to point at the caches; whether any cache is
  # running is the launch's business (cmd_run warns), not the plan's.
  if [ "$(config_get "$WS_CONFIG" registry off)" = "on" ] && [ -n "$cri" ]; then
    env_pairs+=("REGISTRY_MIRRORS=$(registry_mirrors_value)")
  fi
  forward="$(config_get "$WS_CONFIG" env_forward)"
  [ -z "$forward" ] || env_pairs+=("EXTRA_ENV=$forward")

  local substrate nixpkgs="" pair
  substrate="$(run_substrate_ref)" || exit 1   # set -e does not reach here under ||
  # The default substrate runs on airlock's nixpkgs rather than the one in
  # claude-microvm's own lock, so the stack shares one. A workspace pinning a
  # substrate of its own gets that flake exactly as it is locked: it may not
  # even have a nixpkgs input, and testing its lock is often the point of the
  # pin. A pin that merely restates the default is not one (as in status).
  if [ "$substrate" = "$(substrate_default_ref || true)" ]; then
    nixpkgs="$(nixpkgs_ref || true)"
  fi
  printf 'flavor %s\n' "$WS_FLAVOR"
  printf 'substrate %s\n' "$substrate"
  [ -z "$nixpkgs" ] || printf 'nixpkgs %s\n' "$nixpkgs"
  for pair in "${env_pairs[@]}"; do printf 'env %s\n' "$pair"; done
}

# Exactly which substrate a ref resolved to at launch, as `substrate.rev` and
# `substrate.narHash` lines — a ref with no revision, or a local path, can name
# something else by the time anyone asks. Best effort: `nix run` is about to
# resolve the same ref, so this costs no extra fetch, and a failure here is
# left for the launch itself to report.
#
# A small match rather than a jq dependency, as substrate_ref_from_lock is:
# nix prints the keys sorted, so the top-level "locked" object comes before
# "locks" and every node inside it.
run_substrate_locked() { # ref
  nix flake metadata --json "$1" 2>/dev/null | awk '
    match($0, /"locked":\{[^}]*\}/) {
      s = substr($0, RSTART, RLENGTH)
      if (match(s, /"rev":"[0-9a-f]+"/)) print "substrate.rev " substr(s, RSTART + 7, RLENGTH - 8)
      if (match(s, /"narHash":"[^"]+"/)) print "substrate.narHash " substr(s, RSTART + 11, RLENGTH - 12)
      exit
    }
  ' || true
}

cmd_run() {
  local name="" task="" dry=0 fresh=0
  local -a extra_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)  run_usage; return 0 ;;
      --dry-run)  dry=1; shift ;;
      --fresh)    fresh=1; shift ;;
      --)         shift; extra_args=("$@"); break ;;
      -*)         die "unknown option: $1" ;;
      *)
        if [ -z "$name" ]; then name="$1"
        elif [ -z "$task" ]; then task="$1"
        else die "unexpected argument: $1"
        fi
        shift ;;
    esac
  done
  [ -n "$name" ] || { run_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"
  ws_open "$name"
  # Every run is a task's (D26).
  [ -n "$task" ] || { run_usage >&2; die "name the task to run (airlock task ls $name; airlock task new $name <task>)"; }
  task_open "$task"
  run_preflight_task "$name"

  local plan line substrate nixpkgs=""
  plan="$(run_plan)" || exit 1
  local -a env_pairs=()
  while IFS= read -r line; do
    case "$line" in
      "substrate "*) substrate="${line#substrate }" ;;
      "nixpkgs "*)   nixpkgs="${line#nixpkgs }" ;;
      "env "*)       env_pairs+=("${line#env }") ;;
    esac
  done <<< "$plan"

  # What the agent is asked to do this run (D29): read its context the first
  # time, continue after. Like arguments after `--`, these belong to the run
  # and not the config, so they go with them.
  local -a task_args=()
  while IFS= read -r line; do
    [ -z "$line" ] || task_args+=("$line")
  done < <(run_task_args "$fresh")
  extra_args=(${task_args[@]+"${task_args[@]}"} ${extra_args[@]+"${extra_args[@]}"})

  # Arguments after `--` belong to this run, not to the config: they reach the
  # agent's command line, but the plan status compares against leaves them out.
  if [ "${#extra_args[@]}" -gt 0 ]; then
    local i found=0
    for i in "${!env_pairs[@]}"; do
      if [ "${env_pairs[$i]%%=*}" = "AGENTS_ARGS" ]; then
        env_pairs[i]="${env_pairs[$i]} ${extra_args[*]}"
        found=1
      fi
    done
    [ "$found" = "1" ] || env_pairs+=("AGENTS_ARGS=${extra_args[*]}")
  fi

  # Whether the substrate waits for Enter on its session contract. Not in the
  # plan: it decides nothing about the VM once it has booted, so flipping it
  # under a running VM is not drift for status to report.
  [ "$(config_get "$WS_CONFIG" pause on)" != "off" ] || env_pairs+=("NO_PAUSE=1")

  # The substrate's namespace for airlock's VMs (D23): their units go in
  # airlock-vm.slice, inside airlock.slice beside airlock-registry.slice, and
  # their launch directories under $XDG_RUNTIME_DIR/airlock-vm/. Not in the
  # plan either: it is airlock's, never the config's, so it is nothing for
  # status to compare. The launch record keeps it, for stop.
  env_pairs+=("MICROVM_NAMESPACE=$AIRLOCK_VM_NAMESPACE")

  # The VM's name, where people see it (D24, D31): <workspace>.<task>, rather
  # than the directory the substrate would take it from, which is work_dir for
  # every task of every workspace. Outside the plan for the same reason as the
  # namespace.
  local vm_name
  vm_name="$(workspace_vm_name "$name")"
  env_pairs+=("MICROVM_NAME=${vm_name:+$vm_name.}$task")

  # --- the launcher ---
  #
  # It runs with the workspace root as its working directory. The substrate
  # rewrites every relative path microvm.nix emits — the hypervisor's control
  # socket among them, which goes in the launch's own directory under
  # $XDG_RUNTIME_DIR/airlock-vm/vms/<id>/ (D23) — so nothing is expected to land
  # here. Should a relative path slip through, the root is where it belongs:
  # unmounted, so the guest cannot reach it, and `airlock rm` takes it with
  # everything else, rather than wherever you happened to invoke airlock from.
  #
  # Anything that was relative to the caller's cwd has been resolved by the plan.
  #
  # The nixpkgs override replaces the substrate's top-level input, and the
  # substrate's own inputs (microvm.nix and the rest) follow that one, so the
  # whole guest moves with it. Nix warns that it is "not writing modified lock
  # file" on every such launch; that is the override, said out loud.
  local -a launcher
  if [ -n "${AIRLOCK_LAUNCHER:-}" ]; then
    launcher=("$(run_abs_path "$AIRLOCK_LAUNCHER")")
  else
    launcher=(nix run)
    [ -z "$nixpkgs" ] || launcher+=(--override-input nixpkgs "$nixpkgs")
    launcher+=("$substrate#$(flavor_attr "$WS_FLAVOR")")
  fi

  if [ "$dry" = "1" ]; then
    local pair
    for pair in "${env_pairs[@]}"; do printf '%s\n' "$pair"; done
    printf 'cwd: %s\n' "$WS_ROOT"
    printf 'launcher: %s\n' "${launcher[*]}"
    return 0
  fi

  run_preflight_host "$WS_FLAVOR"
  run_seed_claude_state "$WS_FLAVOR" "$TASK_HOME" "$TASK_GUEST_DIR" "$(run_credential "$WS_FLAVOR")"

  # The workspace pointer is airlock's to keep current (D14): written afresh at
  # each launch, so it always says what this airlock does.
  write_context_file "$WS_WORK_DIR/$(flavor_context_file "$WS_FLAVOR")"

  # The guest's way to its hub (D33): the workspace's key and the service's
  # address and host key, in the task's context, which the guest reads only.
  # The key list is refreshed too, so a workspace made since the service
  # started is served. Not fatal when the service is down — the agent can work,
  # but cannot fetch or push until it is up.
  hub_ensure_home
  hub_ensure_key "$WS_ROOT" "$name"
  hub_sync_keys
  hub_write_context "$TASK_CONTEXT" "$WS_ROOT" "$WS_PROJECT"
  hub_running || warn "the hub is not running; the agent cannot fetch or push until it is (airlock hub start)"

  # Not fatal: with no cache up, the guest's runtimes fall back to the
  # registries themselves. But a developer who turned this on expects caching,
  # and the fix is one command. Silent when systemd cannot be asked.
  case "$plan" in
    *"env REGISTRY_MIRRORS="*)
      [ "$(registry_running_count)" != "0" ] \
        || warn "registry = on, but no cache is running; pulls will go to the registries directly (airlock registry start)" ;;
  esac

  if [ "$(config_get "$WS_CONFIG" devshell off)" = "host-eval" ]; then
    run_devshell_cache "$TASK_WORKTREE" "$TASK_HOME"
  fi

  # The launch record, kept in the lock beside the pid: what this VM was
  # started with, for status to report and to compare with the config as it
  # stands later. `cwd` is where relative paths in the config were resolved
  # from, so status can resolve them from the same place; `namespace` is
  # where the substrate keeps this launch, so stop can find it.
  local record
  record="cwd $PWD"$'\n'"namespace $AIRLOCK_VM_NAMESPACE"$'\n'"$plan"
  [ -n "${AIRLOCK_LAUNCHER:-}" ] || record="$record"$'\n'"$(run_substrate_locked "$substrate")"
  [ "${#extra_args[@]}" -eq 0 ] || record="$record"$'\n'"args ${extra_args[*]}"

  run_lock_acquire "$TASK_ROOT" "$record" "task $task"
  # shellcheck disable=SC2064  # $TASK_ROOT is wanted at trap-definition time
  trap "run_lock_release '$TASK_ROOT'" EXIT INT TERM

  info "launching $WS_FLAVOR for $name $task — the VM powers off when the agent exits, or with airlock stop $name $task"
  local rc=0
  # The launcher inherits this shell's environment, so a substrate variable the
  # developer happens to have exported reaches it whatever the config says.
  # REGISTRY_MIRRORS is airlock's to decide (D21), and NO_PAUSE is the `pause`
  # key's: each is cleared first, then set above if it applies. `env` applies
  # -u before the assignments. Everything else airlock owns is always set above.
  ( cd "$WS_ROOT" && env -u REGISTRY_MIRRORS -u NO_PAUSE "${env_pairs[@]}" "${launcher[@]}" ) || rc=$?
  return "$rc"
}
