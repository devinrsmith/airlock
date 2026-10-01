# shellcheck shell=bash
# airlock review — what arrived in the hub since you last looked (D16).
#
# `--accept` advances the watermark and does nothing else. It means "I have
# read up to here", not "publish this": publishing stays a deliberate act from
# your own checkout (D6), and airlock never holds a forge credential.
#
# What counts as unreviewed is decided by branch_state() in common.sh, which
# `status` reads too.

review_usage() {
  cat <<'EOF'
usage: airlock review <name> [--accept] [--patch] [--all] [<branch>...]

  --accept   advance the watermark to the tip of everything shown
  --patch    show the full diff, not just a summary
  --all      include branches with nothing new
  <branch>   restrict to these branches (default: all with unreviewed commits)
EOF
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

  local ref short range shown=0 tampered=0
  local -a accepted_refs=() accepted_shas=()

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    short="${ref#refs/heads/}"
    if [ "${#wanted[@]}" -gt 0 ] && ! review_wanted "$short" "${wanted[@]}"; then
      continue
    fi

    branch_state "$WS_ROOT" "$WS_HUB" "$ref" "$WS_BRANCH"
    case "$BRANCH_STATE" in
      tamper)
        # Reported alone: printing a range computed from a watermark that is
        # not an ancestor would be describing history that no longer exists.
        printf '%s — TAMPER: %s\n' "$short" "$BRANCH_NOTE"
        tampered=1
        continue
        ;;
      clean)
        [ "$show_all" = "1" ] && printf '%s — up to date\n' "$short"
        continue
        ;;
    esac

    shown=$((shown + 1))
    if [ "$BRANCH_STATE" = "ahead" ]; then
      printf '\n%s — %s new commit(s) since you last accepted\n' "$short" "$BRANCH_COUNT"
    elif [ -n "$BRANCH_BASE" ]; then
      printf '\n%s — new branch, %s commit(s) since %s\n' "$short" "$BRANCH_COUNT" "$WS_BRANCH"
    else
      printf '\n%s — new branch, %s commit(s)\n' "$short" "$BRANCH_COUNT"
    fi

    if [ -n "$BRANCH_BASE" ]; then range="$BRANCH_BASE..$BRANCH_TIP"; else range="$BRANCH_TIP"; fi
    git -C "$WS_HUB" log --format='  %h %s' "$range"
    # A branch with no base is a whole history. Diff it from the empty tree:
    # `git diff <tip>` alone means "compare the working tree to <tip>", and the
    # hub is bare, so that aborts the command before anything is accepted.
    local dbase="${BRANCH_BASE:-$(empty_tree "$WS_HUB")}"
    if [ "$patch" = "1" ]; then
      git -C "$WS_HUB" diff "$dbase" "$BRANCH_TIP" | sed 's/^/  /'
    else
      git -C "$WS_HUB" diff --stat "$dbase" "$BRANCH_TIP" | sed 's/^/  /'
    fi

    accepted_refs+=("$ref")
    accepted_shas+=("$BRANCH_TIP")
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
      printf 'accepted %s at %s\n' "${accepted_refs[$i]#refs/heads/}" "$(short_sha "${accepted_shas[$i]}")"
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
