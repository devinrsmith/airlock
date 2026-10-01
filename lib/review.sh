# shellcheck shell=bash
# airlock review — what arrived in the hub since you last looked (D16).
#
# Interactive by default: each branch is shown and then offered, so the thing
# you accept is the thing you just read. `--accept` is the pre-approval for
# that prompt, for when you have already looked or do not want to be asked.
#
# Accepting means "I have read up to here" and nothing more. Publishing stays a
# deliberate act from your own checkout (D6); airlock never holds a credential.
#
# What counts as unreviewed is decided by branch_state() in common.sh, which
# `status` reads too.

review_usage() {
  cat <<'EOF'
usage: airlock review <name> [--accept] [--patch] [--all] [<branch>...]

  --accept   accept everything shown without asking (pre-approval)
  --patch    show the full diff, not just a summary
  --all      include branches with nothing new
  <branch>   restrict to these branches (default: all with unreviewed commits)

With a terminal and without --accept, each branch is offered as it is shown:
  y  accept this branch      a  accept this and all remaining
  n  leave it (default)      q  stop asking
EOF
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

# Both a terminal to print to and a terminal to read from. Either one missing
# means nobody is there to answer, so the command stays non-interactive.
review_can_prompt() { [ -t 0 ] && [ -t 1 ]; }

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

  # --- pass 1: classify everything before showing or offering anything ---
  #
  # Tamper has to be known before the first prompt: one rewritten ref makes the
  # whole hub suspect, and nothing should be offered for acceptance until that
  # is resolved.
  local ref short
  local -a show_refs=() show_tips=() show_bases=() show_counts=() show_states=()
  local -a clean_refs=()
  local tampered=0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    short="${ref#refs/heads/}"
    if [ "${#wanted[@]}" -gt 0 ] && ! review_wanted "$short" "${wanted[@]}"; then
      continue
    fi
    branch_state "$WS_ROOT" "$WS_HUB" "$ref" "$WS_BRANCH"
    case "$BRANCH_STATE" in
      tamper)
        printf '%s — TAMPER: %s\n' "$short" "$BRANCH_NOTE"
        tampered=1
        ;;
      clean)
        clean_refs+=("$short")
        ;;
      *)
        show_refs+=("$ref")
        show_tips+=("$BRANCH_TIP")
        show_bases+=("$BRANCH_BASE")
        show_counts+=("$BRANCH_COUNT")
        show_states+=("$BRANCH_STATE")
        ;;
    esac
  done < <(git -C "$WS_HUB" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null)

  if [ "$tampered" = "1" ]; then
    printf '\nRefusing to review a rewritten history. Run "airlock doctor %s" for the detail;\n' "$name"
    printf 'the watermark is evidence, so airlock will not quietly move it forward.\n'
    return 1
  fi

  if [ "$show_all" = "1" ] && [ "${#clean_refs[@]}" -gt 0 ]; then
    for short in "${clean_refs[@]}"; do printf '%s — up to date\n' "$short"; done
  fi

  if [ "${#show_refs[@]}" -eq 0 ]; then
    printf 'nothing new to review\n'
    return 0
  fi

  # --- pass 2: show each branch, and offer it ---
  local interactive=0 stop_asking=0 accept_rest=0
  if [ "$accept" = "1" ]; then
    accept_rest=1
  elif review_can_prompt; then
    interactive=1
  fi

  local i tip base count state range dbase reply
  local -a accepted_refs=() accepted_shas=()
  for i in "${!show_refs[@]}"; do
    ref="${show_refs[$i]}"
    short="${ref#refs/heads/}"
    tip="${show_tips[$i]}"
    base="${show_bases[$i]}"
    count="${show_counts[$i]}"
    state="${show_states[$i]}"

    if [ "$state" = "ahead" ]; then
      printf '\n%s — %s new commit(s) since you last accepted\n' "$short" "$count"
    elif [ -n "$base" ]; then
      printf '\n%s — new branch, %s commit(s) since %s\n' "$short" "$count" "$WS_BRANCH"
    else
      printf '\n%s — new branch, %s commit(s)\n' "$short" "$count"
    fi

    if [ -n "$base" ]; then range="$base..$tip"; else range="$tip"; fi
    git -C "$WS_HUB" log --format='  %h %s' "$range"
    # A branch with no base is a whole history. Diff it from the empty tree:
    # `git diff <tip>` alone means "compare the working tree to <tip>", and the
    # hub is bare, so that aborts the command before anything is accepted.
    dbase="${base:-$(empty_tree "$WS_HUB")}"
    if [ "$patch" = "1" ]; then
      git -C "$WS_HUB" diff "$dbase" "$tip" | sed 's/^/  /'
    else
      git -C "$WS_HUB" diff --stat "$dbase" "$tip" | sed 's/^/  /'
    fi

    if [ "$accept_rest" = "1" ]; then
      accepted_refs+=("$ref"); accepted_shas+=("$tip")
    elif [ "$interactive" = "1" ] && [ "$stop_asking" = "0" ]; then
      printf '\naccept %s at %s? [y/N/a/q] ' "$short" "$(short_sha "$tip")"
      if ! read -r reply; then
        # stdin ended under us; treat it as "no" rather than as consent.
        printf '\n'
        stop_asking=1
        reply=n
      fi
      case "$reply" in
        y|Y|yes) accepted_refs+=("$ref"); accepted_shas+=("$tip") ;;
        a|A|all) accept_rest=1; accepted_refs+=("$ref"); accepted_shas+=("$tip") ;;
        q|Q)     stop_asking=1 ;;
        *)       ;;
      esac
    fi
  done

  if [ "${#accepted_refs[@]}" -eq 0 ]; then
    if [ "$interactive" = "1" ]; then
      printf '\nnothing accepted\n'
    else
      printf '\nAccept with: airlock review %s --accept\n' "$name"
    fi
    return 0
  fi

  printf '\n'
  for i in "${!accepted_refs[@]}"; do
    watermark_write "$WS_ROOT" "${accepted_refs[$i]}" "${accepted_shas[$i]}"
    printf 'accepted %s at %s\n' "${accepted_refs[$i]#refs/heads/}" "$(short_sha "${accepted_shas[$i]}")"
  done
  printf '\nPublishing stays yours: push from your own checkout when you are ready.\n'
}
