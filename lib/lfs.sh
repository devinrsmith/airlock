# shellcheck shell=bash
# Git LFS in the hub (D25).
#
# A repository that tracks files with LFS keeps their content outside git, so
# seeding a hub with git alone leaves it with pointers whose objects are
# nowhere the agent's clone can reach: the clone's LFS endpoint is the hub, and
# its checkout fails with "remote missing object". These carry the objects into
# the hub's own lfs/ store, which git-lfs reaches over a local path both from
# the host and, at /work/<project>.git, from the guest.
#
# Only for branch tips. A repository's whole LFS history can be far larger than
# its checkout, and it is the tips the agent works from. Checking out an older
# commit whose objects the hub lacks fails in the guest the same way, until the
# developer fetches them in: `git -C <hub> lfs fetch <upstream> <commit>`.

# Whether any tip under the given ref prefixes marks a path filter=lfs. Tips
# rather than history: a repository that stopped using LFS needs nothing now.
lfs_used() { # repo refprefix...
  local repo="$1"; shift
  local tips=()
  mapfile -t tips < <(git -C "$repo" for-each-ref --format='%(objectname)' "$@")
  [ "${#tips[@]}" -gt 0 ] || return 1
  # `*` in a pathspec crosses slashes, so this is every .gitattributes in the tree.
  git -C "$repo" grep -q -e 'filter=lfs' "${tips[@]}" -- '*.gitattributes' 2>/dev/null
}

lfs_require() {
  git lfs version >/dev/null 2>&1 \
    || die "this repository uses Git LFS, and git-lfs is not on PATH"
}

# Fetch into repo the LFS objects of every ref under the given prefixes.
# A source that is a local path must be given as file://: git-lfs takes a bare
# path for a named remote but not as an argument, where it fails with "no
# valid file:// URLs found".
lfs_fetch() { # repo source refprefix...
  local repo="$1" source="$2"; shift 2
  local refs=()
  mapfile -t refs < <(git -C "$repo" for-each-ref --format='%(refname)' "$@")
  [ "${#refs[@]}" -gt 0 ] || return 0
  git -C "$repo" lfs fetch "$source" "${refs[@]}" >/dev/null
}
