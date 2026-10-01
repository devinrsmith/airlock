#!/usr/bin/env bash
# Runs every tests/test-*.sh. No VM, no network: these cover the git plumbing,
# which is most of what airlock is.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

total=0
failed=0
status=0

for t in "$REPO_ROOT"/tests/test-*.sh; do
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
