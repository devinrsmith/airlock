# shellcheck shell=bash
# airlock version — the release and the commit it was built from.
#
# There are no releases yet, so AIRLOCK_VERSION is a sentinel and the commit is
# what actually identifies a build. An installed build has it baked into its
# wrapper as AIRLOCK_COMMIT, from the flake's own revision; a source checkout
# asks git; anything else (a tarball, the Nix check sandbox) says "unknown"
# rather than guessing.

# The commit this airlock came from, with a "-dirty" suffix when tracked files
# differ from it — the same shape Nix gives a dirty flake's revision.
version_commit() {
  if [ -n "${AIRLOCK_COMMIT:-}" ]; then
    printf '%s\n' "$AIRLOCK_COMMIT"
    return
  fi

  local src top rev
  src="$(cd "$AIRLOCK_LIB/.." && pwd -P)"
  # Only a repository rooted at the source tree is ours: a copy of airlock
  # dropped inside some other checkout must not report that checkout's HEAD.
  top="$(git -C "$src" rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$src" ] \
    || ! rev="$(git -C "$src" rev-parse --verify --quiet HEAD 2>/dev/null)"; then
    printf 'unknown\n'
    return
  fi
  if ! git -C "$src" diff --quiet HEAD -- 2>/dev/null; then
    rev="$rev-dirty"
  fi
  printf '%s\n' "$rev"
}

cmd_version() {
  [ $# -eq 0 ] || die "version takes no arguments"
  printf 'airlock %s (%s)\n' "$AIRLOCK_VERSION" "$(version_commit)"
}
