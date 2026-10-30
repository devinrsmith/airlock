# shellcheck shell=bash
# Git LFS in the hub (D25).
#
# A repository that tracks files with LFS keeps their content outside git, so
# seeding a hub with git alone leaves it with pointers whose objects are
# nowhere a worktree can reach: the clone's LFS endpoint is the hub, and a
# checkout fails with "remote missing object". These carry the objects into
# the hub's own lfs/ store, which git-lfs reaches over a local path from the
# host, where the hub lives (D33). A guest cannot reach it for LFS: the hub's
# SSH service serves fetch and push only, so new LFS objects cannot be pushed.
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

# The repository's pre-push hook: airlock's, and it does nothing. git-lfs would
# otherwise install its own, which uploads LFS objects to the remote's LFS
# server before every push and fails the push without one — and the hub
# serves none (D33). git-lfs installs its hooks itself, at any checkout, into a
# repository that has none, but leaves an existing hook alone; this one being
# there is what keeps them all out.
LFS_PREPUSH_MARK="airlock: no Git LFS upload on push"
lfs_write_prepush() { # repo
  printf '#!/bin/sh\n# %s (D33). The hub serves no LFS, so an agent'"'"'s new LFS\n# objects stay in this repository'"'"'s lfs/ store. Written by airlock init;\n# while it is here, git-lfs installs none of its hooks.\nexit 0\n' \
    "$LFS_PREPUSH_MARK" > "$1/hooks/pre-push"
  chmod 755 "$1/hooks/pre-push"
}

# lfs_used_at, for a repository inside work_dir: through the sandbox (D34).
lfs_used_at_wd() { # work_dir repo rev...
  local wd="$1" repo="$2"; shift 2
  [ "$#" -gt 0 ] || return 1
  wd_git "$wd" --repo "$repo" -- -C "$repo" grep -q -e 'filter=lfs' "$@" -- '*.gitattributes' 2>/dev/null
}
