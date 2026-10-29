# shellcheck shell=bash
# Git LFS in the hub (D25).
#
# A repository that tracks files with LFS keeps their content outside git, so
# seeding a hub with git alone leaves it with pointers whose objects are
# nowhere a worktree can reach: the clone's LFS endpoint is the hub, and a
# checkout fails with "remote missing object". These carry the objects into
# the hub's own lfs/ store, which git-lfs reaches over a local path both from
# the host and, at /work/<project>.git, from the guest.
#
# Only for what an agent starts from: the default branch at init and fetch,
# and a task's own starting point at `task new`. Every branch's tips can be far
# more than that — on a repository with hundreds of branches, fetching them all
# is what made init look hung — and a commit whose objects the hub lacks is
# fetched in when a task is made from it. Checking out some other commit in the
# guest fails the same way until the developer fetches its objects in:
# `git -C <hub> lfs fetch <upstream> <commit>`.

# Whether any tip under the given ref prefixes marks a path filter=lfs: whether
# the repository uses LFS at all, which decides how the repository is set up. Tips
# rather than history: a repository that stopped using LFS needs nothing now.
lfs_used() { # repo refprefix...
  local repo="$1"; shift
  local tips=()
  mapfile -t tips < <(git -C "$repo" for-each-ref --format='%(objectname)' "$@")
  lfs_used_at "$repo" ${tips[@]+"${tips[@]}"}
}

# Whether any of these revisions marks a path filter=lfs.
lfs_used_at() { # repo rev...
  local repo="$1"; shift
  [ "$#" -gt 0 ] || return 1
  # `*` in a pathspec crosses slashes, so this is every .gitattributes in the tree.
  git -C "$repo" grep -q -e 'filter=lfs' "$@" -- '*.gitattributes' 2>/dev/null
}

lfs_require() {
  git lfs version >/dev/null 2>&1 \
    || die "this repository uses Git LFS, and git-lfs is not on PATH"
}

# Fetch into repo the LFS objects of these revisions, from source. On a large
# repository over a slow link this is the step that takes the time, so it says
# so up front; git-lfs's own output goes to LFS_FETCH_LOG rather than the
# terminal, where it would print a line or two and then seem to stop. A caller
# that gives up shows the log with lfs_fetch_log.
#
# A source that is a local path must be given as file://: git-lfs takes a bare
# path for a named remote but not as an argument, where it fails with "no
# valid file:// URLs found".
LFS_FETCH_LOG=""
lfs_fetch() { # repo source what rev...
  local repo="$1" source="$2" what="$3"; shift 3
  [ "$#" -gt 0 ] || return 0
  info "fetching the Git LFS objects of $what from $source — this can take a while"
  [ -z "$LFS_FETCH_LOG" ] || rm -f "$LFS_FETCH_LOG"
  LFS_FETCH_LOG="$(mktemp)"
  if git -C "$repo" lfs fetch "$source" "$@" > "$LFS_FETCH_LOG" 2>&1; then
    rm -f "$LFS_FETCH_LOG"
    LFS_FETCH_LOG=""
    return 0
  fi
  return 1
}

# What git-lfs said about the fetch that failed last, on stderr.
lfs_fetch_log() {
  [ -n "$LFS_FETCH_LOG" ] && [ -s "$LFS_FETCH_LOG" ] || return 0
  tail -n 20 "$LFS_FETCH_LOG" | sed 's/^/  git-lfs: /' >&2
  rm -f "$LFS_FETCH_LOG"
  LFS_FETCH_LOG=""
}
