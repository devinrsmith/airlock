# shellcheck shell=bash
# `airlock version` — the sentinel release plus the commit, from wherever this
# airlock came from: baked in by an installed build, or asked of git in a
# source checkout.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Test Developer
	email = dev@example.invalid
[init]
	defaultBranch = main
EOF
unset AIRLOCK_COMMIT AIRLOCK_LIB

VERSION="$(sed -n 's/^AIRLOCK_VERSION="\(.*\)"$/\1/p' "$REPO_ROOT/bin/airlock")"

# A copy of airlock's source at $1, as a checkout of its own or not.
copy_airlock() {
  mkdir -p "$1"
  cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$1/"
}
commit_all() {
  ( cd "$1" && git add -A && git commit --quiet -m "$2" ) >/dev/null 2>&1
}

case_begin "the sentinel release is the one the flake builds"
assert_eq "$VERSION" \
  "$(sed -n 's/^ *version = "\(.*\)";$/\1/p' "$REPO_ROOT/flake.nix")" \
  "bin/airlock and flake.nix agree"

case_begin "an installed build reports the commit baked into it"
assert_eq "airlock $VERSION (0123abc)" \
  "$(AIRLOCK_COMMIT=0123abc "$REPO_ROOT/bin/airlock" version)" "version"
assert_eq "airlock $VERSION (0123abc)" \
  "$(AIRLOCK_COMMIT=0123abc "$REPO_ROOT/bin/airlock" --version)" "--version"

case_begin "a source checkout reports its HEAD"
git init --quiet -b main "$TMP/clean"
copy_airlock "$TMP/clean"
commit_all "$TMP/clean" "airlock"
head="$(git -C "$TMP/clean" rev-parse HEAD)"
assert_eq "airlock $VERSION ($head)" "$("$TMP/clean/bin/airlock" version)" "clean"
# Untracked files are not part of the commit and do not make it dirty — the
# same rule Nix applies to a flake's dirtyRev.
touch "$TMP/clean/scratch"
assert_eq "airlock $VERSION ($head)" "$("$TMP/clean/bin/airlock" version)" "untracked file"

case_begin "a checkout with changes to tracked files says so"
printf '\n# local edit\n' >> "$TMP/clean/lib/path.sh"
assert_eq "airlock $VERSION ($head-dirty)" "$("$TMP/clean/bin/airlock" version)" "unstaged"
git -C "$TMP/clean" add lib/path.sh
assert_eq "airlock $VERSION ($head-dirty)" "$("$TMP/clean/bin/airlock" version)" "staged"

case_begin "a copy outside any repository has no commit to report"
copy_airlock "$TMP/loose"
assert_eq "airlock $VERSION (unknown)" "$("$TMP/loose/bin/airlock" version)" "no git"

case_begin "a copy inside someone else's repository does not borrow its HEAD"
git init --quiet -b main "$TMP/host"
echo x > "$TMP/host/x" && commit_all "$TMP/host" "host"
copy_airlock "$TMP/host/vendor/airlock"
commit_all "$TMP/host" "vendor airlock"
assert_eq "airlock $VERSION (unknown)" "$("$TMP/host/vendor/airlock/bin/airlock" version)" "nested"

case_begin "a repository with no commits yet has no commit to report"
git init --quiet -b main "$TMP/fresh"
copy_airlock "$TMP/fresh"
assert_eq "airlock $VERSION (unknown)" "$("$TMP/fresh/bin/airlock" version)" "unborn HEAD"

case_begin "version takes no arguments"
assert_fails "an argument is refused" "$REPO_ROOT/bin/airlock" version extra
