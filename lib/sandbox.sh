# shellcheck shell=bash
# Host-side git on guest-writable repositories, confined (D34).
#
# Everything under work_dir/ is the agent's to write: .repo's config and
# hooks, the worktrees, their .gitattributes. Git trusts all of it, and under
# D1 the agent writes as the developer's user, so git's safe.directory check
# never fires. A config key or a hook can name a program, and some of what
# airlock runs there starts one: core.fsmonitor at `git status`, filter drivers
# at status and checkout, hooks at checkout and at every ref update.
#
# wd_git runs git there two ways at once:
#   - with overrides that keep the known traps from running at all — hooks,
#     fsmonitor, every filter driver but LFS's, transports other than local
#     files, submodule recursion, automatic gc; and
#   - inside bubblewrap, so whatever the overrides miss can reach only what the
#     agent already can: the host's read-only system directories, work_dir,
#     and, read-only, the hub when a fetch needs it. No home, no other
#     workspace, no network, no environment but PATH.
#
# Where bubblewrap cannot make namespaces (some build sandboxes, a distribution
# that restricts them), wd_git refuses; AIRLOCK_GIT_SANDBOX=off runs git
# unconfined instead, overrides still applied, and says so.

# bubblewrap: AIRLOCK_BWRAP (an installed build pins one), else bwrap on PATH —
# a distribution's own may be the one its user-namespace policy allows — else
# built from airlock's nixpkgs.
sandbox_bwrap() {
  local nixpkgs out
  if [ -n "${AIRLOCK_BWRAP:-}" ]; then printf '%s\n' "$AIRLOCK_BWRAP"; return 0; fi
  if command -v bwrap >/dev/null 2>&1; then command -v bwrap; return 0; fi
  nixpkgs="$(nixpkgs_ref)" || die "bubblewrap is not on PATH, and there is no nixpkgs to build it from"
  command -v nix >/dev/null 2>&1 || die "bubblewrap is not on PATH, and neither is nix to build it with"
  out="$(nix build --no-link --print-out-paths "$nixpkgs#bubblewrap" | head -1)" \
    || die "could not build $nixpkgs#bubblewrap"
  printf '%s\n' "$out/bin/bwrap"
}

SANDBOX_BWRAP=""
SANDBOX_CHECKED=""
SANDBOX_BINDS=()

# Whether git runs confined, decided once per invocation. Off only when asked;
# a bubblewrap that cannot start is a refusal, not a silent fallback.
sandbox_ready() {
  [ -z "$SANDBOX_CHECKED" ] || return 0
  SANDBOX_CHECKED=1
  if [ "${AIRLOCK_GIT_SANDBOX:-on}" = "off" ]; then
    warn "AIRLOCK_GIT_SANDBOX=off: running git on agent-writable repositories unconfined (D34)"
    return 0
  fi
  SANDBOX_BWRAP="$(sandbox_bwrap)" || exit 1
  local -a sys=()
  # shellcheck disable=SC2207  # "--ro-bind <dir> <dir>" per line, no spaces
  sys=($(sandbox_system_binds))
  "$SANDBOX_BWRAP" --unshare-all --die-with-parent --tmpfs /tmp \
      "${sys[@]}" --proc /proc --dev /dev -- "$(sandbox_git)" --version >/dev/null 2>&1 \
    || die "bubblewrap ($SANDBOX_BWRAP) cannot make a sandbox here, which airlock runs git on agent-writable repositories in (D34).
  Usually unprivileged user namespaces are disabled or restricted (Ubuntu's AppArmor allows only its own /usr/bin/bwrap: set AIRLOCK_BWRAP=/usr/bin/bwrap).
  AIRLOCK_GIT_SANDBOX=off runs git unconfined instead, accepting that the agent can make it run commands on this host."
}

# The host's read-only system directories the git in the sandbox needs: the
# Nix store, and a distribution's own, for a git that is not in the store.
# Never home, /etc beyond what loading a program needs, or /run.
sandbox_system_binds() {
  local d
  for d in /nix/store /usr /bin /sbin /lib /lib32 /lib64 /etc/ld.so.cache /etc/alternatives; do
    [ ! -e "$d" ] || printf -- '--ro-bind %s %s\n' "$d" "$d"
  done
  return 0
}

# By where it really is: a PATH entry may be a symlink into a directory the
# sandbox does not bind (a profile, a trimmed PATH of links).
sandbox_git() { realpath "$(command -v git)"; }

# PATH inside: git's directory; git-lfs's, if there is one, which LFS's
# filter needs at checkout; and sh's, which git-lfs starts its local-file
# transfer through. Code planted in the repository can already run the Nix
# store's bash by path, so a shell on PATH gives it nothing new.
sandbox_path() {
  local p d
  p="$(dirname "$(sandbox_git)")"
  if d="$(command -v git-lfs 2>/dev/null)"; then p="$p:$(dirname "$(realpath "$d")")"; fi
  if d="$(command -v sh 2>/dev/null)"; then p="$p:$(dirname "$(realpath "$d")")"; fi
  printf '%s\n' "$p"
}

# The overrides every sandboxed git call carries: the known ways a repository's
# config or files make git start a program — hooks, fsmonitor, transports
# other than local files (ext::, or ssh through core.sshCommand), submodule
# recursion, automatic gc — and LFS's filter, set to its known commands.
SANDBOX_FIXED_OVERRIDES=(
  -c core.fsmonitor=false -c core.hooksPath=/dev/null
  -c protocol.allow=never -c protocol.file.allow=always
  -c core.alternateRefsCommand= -c submodule.recurse=false -c fetch.recurseSubmodules=false
  -c gc.auto=0 -c maintenance.auto=false -c core.sshCommand=false
  -c "filter.lfs.clean=git-lfs clean -- %f" -c "filter.lfs.smudge=git-lfs smudge -- %f"
  -c "filter.lfs.process=git-lfs filter-process" -c filter.lfs.required=true
)

# A path and, if it differs, where it really is, appended to SANDBOX_BINDS:
# bound at both, so arguments given through a symlinked data home still
# resolve inside. An array, so a path with spaces stays one word.
sandbox_bind() { # flag path
  local real
  SANDBOX_BINDS+=("$1" "$2" "$2")
  real="$(realpath "$2" 2>/dev/null || printf '%s' "$2")"
  [ "$real" = "$2" ] || SANDBOX_BINDS+=("$1" "$real" "$real")
}

# git with the fixed overrides, confined to work_dir (and the hub, read-only,
# when given) — or unconfined when AIRLOCK_GIT_SANDBOX=off. The building block
# for wd_git, which adds the filter overrides.
sandbox_exec_git() { # work_dir hub(or "") -- git-args...
  local wd="$1" hub="$2"; shift 3
  if [ "${AIRLOCK_GIT_SANDBOX:-on}" = "off" ]; then
    GIT_TERMINAL_PROMPT=0 git "${SANDBOX_FIXED_OVERRIDES[@]}" "$@"
    return
  fi
  # System directories have no spaces; the workspace's paths may.
  local -a sys=()
  # shellcheck disable=SC2207  # "--ro-bind <dir> <dir>" per line, no spaces
  sys=($(sandbox_system_binds))
  SANDBOX_BINDS=()
  sandbox_bind --bind "$wd"
  [ -z "$hub" ] || sandbox_bind --ro-bind "$hub"
  # /tmp first: bubblewrap applies these in order, and a workspace under /tmp
  # would otherwise be hidden by it.
  "$SANDBOX_BWRAP" --unshare-all --die-with-parent --new-session \
    --tmpfs /tmp "${sys[@]}" "${SANDBOX_BINDS[@]}" --proc /proc --dev /dev \
    --clearenv --setenv PATH "$(sandbox_path)" --setenv HOME /nonexistent \
    --setenv GIT_CONFIG_NOSYSTEM 1 --setenv GIT_CONFIG_GLOBAL /dev/null \
    --setenv GIT_TERMINAL_PROMPT 0 --setenv GIT_PAGER cat \
    --chdir "$wd" \
    -- "$(sandbox_git)" "${SANDBOX_FIXED_OVERRIDES[@]}" "$@"
}

# The filter drivers repo's config defines, other than LFS's, each emptied: a
# .gitattributes names the driver, which is the agent's to choose, and the
# config its command. Read inside the sandbox like everything else.
sandbox_filter_overrides() { # work_dir repo
  local key
  while IFS= read -r key; do
    case "$key" in
      filter.lfs.*) ;;
      filter.*.clean|filter.*.smudge|filter.*.process) printf '%s\n' -c "$key=" ;;
      filter.*.required) printf '%s\n' -c "$key=false" ;;
    esac
  # No filters configured is git config's exit 1, and no repository yet (init)
  # its error: neither is a failure here, and must not look like one to an
  # ERR trap a caller has set (init's removes the half-made workspace).
  done < <( { sandbox_exec_git "$1" "" -- -C "$2" config --name-only --get-regexp '^filter\.' 2>/dev/null || true; } | sort -u)
}

# Every git call on a repository inside work_dir goes through here — .repo and
# the task worktrees, reads included: a future git may give any command a new
# way to run what a repository's config names. repo is where the filter list is
# read from (.repo, or a worktree of it); every argument after -- is git's.
wd_git() { # work_dir [--hub <hub>] [--repo <repo>] -- git-args...
  local wd="$1"; shift
  local hub="" repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --hub)  hub="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --)     shift; break ;;
      *)      die "wd_git: unexpected $1" ;;
    esac
  done
  sandbox_ready
  local -a filters=()
  mapfile -t filters < <(sandbox_filter_overrides "$wd" "${repo:-$wd}")
  sandbox_exec_git "$wd" "$hub" -- ${filters[@]+"${filters[@]}"} "$@"
}

# The two forms nearly every caller wants, in an opened workspace (ws_open):
# git on .repo, and whether a path inside work_dir is a repository.
repo_git() { wd_git "$WS_WORK_DIR" --repo "$WS_REPO" -- -C "$WS_REPO" "$@"; }

wd_is_repo() { # work_dir path
  [ -e "$2" ] || return 1
  wd_git "$1" --repo "$2" -- -C "$2" rev-parse --git-dir >/dev/null 2>&1
}
