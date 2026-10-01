#!/usr/bin/env bash
# Runs every tests/test-*.sh, or just the ones named. No VM, no network: these
# cover the git plumbing, which is most of what airlock is.
#
#   ./tests/run-tests.sh                 everything
#   ./tests/run-tests.sh review          just tests/test-review.sh
#   ./tests/run-tests.sh review doctor   both
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

declare -a FILES=()
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    # Accept a bare name, a filename, or a path — whichever is to hand.
    for candidate in "$arg" "$REPO_ROOT/tests/$arg" "$REPO_ROOT/tests/test-$arg.sh"; do
      if [ -f "$candidate" ]; then FILES+=("$candidate"); continue 2; fi
    done
    printf 'no such test: %s\n' "$arg" >&2
    exit 2
  done
else
  FILES=("$REPO_ROOT"/tests/test-*.sh)
fi

total=0
failed=0
status=0

for t in "${FILES[@]}"; do
  name="$(basename "$t")"
  printf '== %s\n' "$name"
  # Each file runs in its own shell so a failure cannot poison the next.
  out="$(
    set +e
    # shellcheck source=/dev/null
    . "$REPO_ROOT/tests/lib.sh"
    # shellcheck source=/dev/null
    . "$t"
    printf 'TOTALS %d %d\n' "$TESTS_RUN" "$TESTS_FAILED"
  )" || status=1
  printf '%s\n' "$out" | grep -v '^TOTALS ' || true
  line="$(printf '%s\n' "$out" | grep '^TOTALS ' | tail -1)"
  if [ -z "$line" ]; then
    printf '  FAIL %s exited before reporting totals\n' "$name" >&2
    status=1
    continue
  fi
  # shellcheck disable=SC2086
  set -- $line
  total=$((total + $2))
  failed=$((failed + $3))
  printf '   %d assertions, %d failed\n' "$2" "$3"
done

printf '\n%d assertions, %d failed\n' "$total" "$failed"
[ "$failed" -eq 0 ] && [ "$status" -eq 0 ] || exit 1
