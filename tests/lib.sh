# shellcheck shell=bash
# Minimal assertions. Each test file sources this and calls the assert_*
# helpers; the runner reports the totals.

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_CASE="(none)"

case_begin() { CURRENT_CASE="$1"; }

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL [%s] %s\n' "$CURRENT_CASE" "$1" >&2
}

assert_eq() { # want got label
  if [ "$1" = "$2" ]; then _pass; else _fail "$3: want '$1', got '$2'"; fi
}
assert_dir()     { if [ -d "$1" ]; then _pass; else _fail "expected directory: $1"; fi; }
assert_file()    { if [ -f "$1" ]; then _pass; else _fail "expected file: $1"; fi; }
assert_absent()  { if [ ! -e "$1" ]; then _pass; else _fail "expected absence: $1"; fi; }
assert_symlink_not() {
  if [ -d "$1" ] && [ ! -L "$1" ]; then _pass; else _fail "expected a real directory, not a symlink: $1"; fi
}
assert_contains() { # file needle label
  if grep -qF -- "$2" "$1"; then _pass; else _fail "$3: '$2' not found in $1"; fi
}
assert_ok() { # label cmd...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then _pass; else _fail "$label: command failed: $*"; fi
}
assert_fails() { # label cmd...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then _fail "$label: expected failure but command succeeded: $*"; else _pass; fi
}
