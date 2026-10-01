# shellcheck shell=bash
# airlock fetch — refresh the hub from its configured upstreams (D8).
#
# This is the developer's action, deliberately: the credentials for a private
# upstream live on the host and never enter the guest. What lands here becomes
# readable to the agent as refs/upstream/<remote>/*, through a remote it has no
# way to push back to.

fetch_usage() {
  cat <<'EOF'
usage: airlock fetch <name> [--remote <remote>] [--prune]

  --remote <remote>   fetch only this upstream (default: all configured)
  --prune             drop upstream refs that have disappeared from the remote
EOF
}

# refname<TAB>sha for one upstream's namespace, for before/after comparison.
fetch_snapshot() { # hub remote
  git -C "$1" for-each-ref --format='%(refname)%09%(objectname)' "refs/upstream/$2/" 2>/dev/null || true
}

cmd_fetch() {
  local name="" only="" prune=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) fetch_usage; return 0 ;;
      --remote)  only="${2-}"; [ -n "$only" ] || die "--remote needs a name"; shift 2 ;;
      --prune)   prune=1; shift ;;
      -*)        die "unknown option: $1" ;;
      *)         [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { fetch_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"
  ws_open "$name"

  local remotes
  remotes="$(git -C "$WS_HUB" remote 2>/dev/null || true)"
  [ -n "$remotes" ] || die "workspace $name has no upstream remotes configured"
  if [ -n "$only" ]; then
    printf '%s\n' "$remotes" | grep -qx -- "$only" \
      || die "no such upstream remote: $only (configured: $(printf '%s' "$remotes" | tr '\n' ' '))"
    remotes="$only"
  fi

  local remote before after failed=0 changed=0
  for remote in $remotes; do
    printf 'fetching %s (%s)\n' "$remote" "$(git -C "$WS_HUB" remote get-url "$remote")"
    before="$(fetch_snapshot "$WS_HUB" "$remote")"
    if [ "$prune" = "1" ]; then
      git -C "$WS_HUB" fetch --quiet --prune "$remote" || { ck_fetch_failed "$remote"; failed=1; continue; }
    else
      git -C "$WS_HUB" fetch --quiet "$remote" || { ck_fetch_failed "$remote"; failed=1; continue; }
    fi
    after="$(fetch_snapshot "$WS_HUB" "$remote")"
    fetch_report "$before" "$after"
    changed=$((changed + FETCH_CHANGED))
  done

  if [ "$changed" = "0" ]; then
    printf 'already up to date\n'
  else
    printf '%d ref(s) updated — visible to the agent as upstreams/<remote>/<branch>\n' "$changed"
  fi
  [ "$failed" -eq 0 ]
}

ck_fetch_failed() { printf 'airlock: error: fetching %s failed\n' "$1" >&2; }

# Prints the per-ref changes; leaves the count in FETCH_CHANGED rather than on
# stdout, so the human-facing lines stay on stdout where they belong.
fetch_report() { # before after
  local before="$1" after="$2" count=0 ref sha old
  while IFS=$'\t' read -r ref sha; do
    [ -n "$ref" ] || continue
    old="$(printf '%s\n' "$before" | awk -F'\t' -v r="$ref" '$1 == r { print $2 }')"
    if [ -z "$old" ]; then
      printf '  %-40s new  %s\n' "${ref#refs/upstream/}" "${sha:0:12}"
      count=$((count + 1))
    elif [ "$old" != "$sha" ]; then
      printf '  %-40s %s..%s\n' "${ref#refs/upstream/}" "${old:0:12}" "${sha:0:12}"
      count=$((count + 1))
    fi
  done <<< "$after"
  # Refs that vanished (only possible with --prune).
  while IFS=$'\t' read -r ref sha; do
    [ -n "$ref" ] || continue
    if ! printf '%s\n' "$after" | awk -F'\t' -v r="$ref" '$1 == r { found = 1 } END { exit !found }'; then
      printf '  %-40s pruned\n' "${ref#refs/upstream/}"
      count=$((count + 1))
    fi
  done <<< "$before"
  FETCH_CHANGED="$count"
}
