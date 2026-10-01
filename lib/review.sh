# shellcheck shell=bash
# airlock review — what arrived in the hub since you last looked (D16).
#
# `--accept` advances the watermark and does nothing else. It means "I have
# read up to here", not "publish this": publishing stays a deliberate act from
# your own checkout (D6), and airlock never holds a forge credential.

review_usage() {
  cat <<'EOF'
usage: airlock review <name> [--accept] [--patch] [--all] [<branch>...]

  --accept   advance the watermark to the tip of everything shown
  --patch    show the full diff, not just a summary
  --all      include branches with nothing new
  <branch>   restrict to these branches (default: all with unreviewed commits)
EOF
}

# Where a branch's unreviewed range starts.
#
# A watermark is exact. Without one — a branch airlock never pushed, which is
# the agent's own work — fall back to the merge base with the default branch,
# so a new topic shows as the topic rather than as the whole history.
review_base() { # hub ref tip default_branch watermark -> base sha, or empty for "whole history"
  local hub="$1" ref="$2" tip="$3" default="$4" wm="$5" base
  if [ -n "$wm" ]; then printf '%s\n' "$wm"; return 0; fi
  [ -n "$default" ] || return 0
  [ "$ref" != "refs/heads/$default" ] || return 0
  base="$(git -C "$hub" merge-base "refs/heads/$default" "$tip" 2>/dev/null || true)"
  [ "$base" != "$tip" ] || return 0
  printf '%s\n' "$base"
}

cmd_review() {
  local name="" accept=0 patch=0 show_all=0
  local -a wanted=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) review_usage; return 0 ;;
      --accept)  accept=1; shift ;;
      --patch)   patch=1; shift ;;
      --all)     show_all=1; shift ;;
      -*)        die "unknown option: $1" ;;
      *)         if [ -z "$name" ]; then name="$1"; else wanted+=("$1"); fi; shift ;;
    esac
  done
  [ -n "$name" ] || { review_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"
  ws_open "$name"

  local ref short tip wm base range shown=0 tampered=0
  local -a accepted_refs=() accepted_shas=()

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    short="${ref#refs/heads/}"
    if [ "${#wanted[@]}" -gt 0 ] && ! review_wanted "$short" "${wanted[@]}"; then
      continue
    fi
    tip="$(git -C "$WS_HUB" rev-parse "$ref")"
    wm="$(watermark_read "$WS_ROOT" "$ref")"

    if [ -n "$wm" ]; then
      if ! git -C "$WS_HUB" rev-parse --verify --quiet "$wm^{commit}" >/dev/null 2>&1; then
        printf '%s — TAMPER: the commit you reviewed (%s) is no longer in the hub\n' "$short" "${wm:0:12}"
        tampered=1
        continue
      fi
      if [ "$wm" = "$tip" ]; then
        [ "$show_all" = "1" ] && printf '%s — up to date\n' "$short"
        continue
      fi
      # A watermark that is not an ancestor means the branch was rewritten.
      # Push cannot do that (receive.denyNonFastForwards), but a write straight
      # into the hub through the share can — which is the point of D17.
      if ! git -C "$WS_HUB" merge-base --is-ancestor "$wm" "$tip" 2>/dev/null; then
        printf '%s — TAMPER: history was rewritten; %s is no longer an ancestor of the tip\n' \
          "$short" "${wm:0:12}"
        tampered=1
        continue
      fi
    fi

    base="$(review_base "$WS_HUB" "$ref" "$tip" "$WS_BRANCH" "$wm")"
    if [ -n "$base" ]; then range="$base..$tip"; else range="$tip"; fi

    local count
    count="$(git -C "$WS_HUB" rev-list --count "$range")"
    [ "$count" != "0" ] || continue

    shown=$((shown + 1))
    if [ -n "$wm" ]; then
      printf '\n%s — %s new commit(s) since you last accepted\n' "$short" "$count"
    elif [ -n "$base" ]; then
      printf '\n%s — new branch, %s commit(s) since %s\n' "$short" "$count" "$WS_BRANCH"
    else
      printf '\n%s — new branch, %s commit(s)\n' "$short" "$count"
    fi
    git -C "$WS_HUB" log --format='  %h %s' "$range"
    if [ "$patch" = "1" ]; then
      git -C "$WS_HUB" diff ${base:+"$base"} "$tip" | sed 's/^/  /'
    else
      git -C "$WS_HUB" diff --stat ${base:+"$base"} "$tip" | sed 's/^/  /'
    fi

    accepted_refs+=("$ref")
    accepted_shas+=("$tip")
  done < <(git -C "$WS_HUB" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null)

  if [ "$tampered" = "1" ]; then
    printf '\nRefusing to review a rewritten history. Run "airlock doctor %s" for the detail;\n' "$name"
    printf 'the watermark is evidence, so airlock will not quietly move it forward.\n'
    return 1
  fi

  if [ "$shown" = "0" ]; then
    printf 'nothing new to review\n'
    return 0
  fi

  if [ "$accept" = "1" ]; then
    local i
    printf '\n'
    for i in "${!accepted_refs[@]}"; do
      watermark_write "$WS_ROOT" "${accepted_refs[$i]}" "${accepted_shas[$i]}"
      printf 'accepted %s at %s\n' "${accepted_refs[$i]#refs/heads/}" "${accepted_shas[$i]:0:12}"
    done
    printf '\nPublishing stays yours: push from your own checkout when you are ready.\n'
  else
    printf '\nAccept with: airlock review %s --accept\n' "$name"
  fi
}

review_wanted() { # short_name wanted...
  local short="$1"; shift
  local w
  for w in "$@"; do
    [ "$w" = "$short" ] || [ "$w" = "refs/heads/$short" ] || continue
    return 0
  done
  return 1
}
