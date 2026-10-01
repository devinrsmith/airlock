# shellcheck shell=bash
# airlock status — what exists, what is running, and what is waiting for you.
#
# Strictly read-only and strictly offline: it never fetches, never repairs, and
# never advances a watermark. `fetch`, `doctor` and `review` are the commands
# that change things.

status_usage() {
  cat <<'EOF'
usage: airlock status [<name>]

  With no name, lists every workspace. With one, shows its detail.
  Exits non-zero if any branch shows evidence of tampering.
EOF
}

status_vm() { # root [detail]
  if lock_is_live "$(lock_file "$1")"; then
    if [ "${2-}" = "detail" ]; then
      printf 'running (pid %s)' "$(head -1 "$(lock_file "$1")")"
    else
      printf 'running'
    fi
  else
    printf 'stopped'
  fi
}

# Walks the hub once and summarises it.
#   STATUS_BRANCHES     branches in the hub
#   STATUS_PENDING      branches with unreviewed commits
#   STATUS_COMMITS      DISTINCT unreviewed commits across them — not the sum of
#                       the per-branch counts. Agents stack branches on each
#                       other, and a commit you have not read is one commit to
#                       read however many branches contain it.
#   STATUS_TAMPER       1 if any branch shows a rewritten or missing watermark
#   STATUS_LINES        one "<short>\t<count>\t<note>" per branch worth showing
status_scan() { # root hub default_branch
  local root="$1" hub="$2" default="$3" ref short
  local -a tips=() bases=()
  STATUS_BRANCHES=0
  STATUS_PENDING=0
  STATUS_COMMITS=0
  STATUS_TAMPER=0
  STATUS_LINES=""
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    STATUS_BRANCHES=$((STATUS_BRANCHES + 1))
    short="${ref#refs/heads/}"
    branch_state "$root" "$hub" "$ref" "$default"
    case "$BRANCH_STATE" in
      tamper)
        STATUS_TAMPER=1
        STATUS_LINES="${STATUS_LINES}${short}"$'\t'"-"$'\t'"TAMPER: ${BRANCH_NOTE}"$'\n'
        ;;
      ahead)
        STATUS_PENDING=$((STATUS_PENDING + 1))
        tips+=("$BRANCH_TIP"); bases+=("$BRANCH_BASE")
        STATUS_LINES="${STATUS_LINES}${short}"$'\t'"${BRANCH_COUNT}"$'\t'"since you last accepted"$'\n'
        ;;
      new)
        STATUS_PENDING=$((STATUS_PENDING + 1))
        tips+=("$BRANCH_TIP")
        [ -z "$BRANCH_BASE" ] || bases+=("$BRANCH_BASE")
        if [ -n "$BRANCH_BASE" ]; then
          STATUS_LINES="${STATUS_LINES}${short}"$'\t'"${BRANCH_COUNT}"$'\t'"new branch since ${default}"$'\n'
        else
          STATUS_LINES="${STATUS_LINES}${short}"$'\t'"${BRANCH_COUNT}"$'\t'"new branch"$'\n'
        fi
        ;;
    esac
  done < <(git -C "$hub" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null)

  # One rev-list over every pending range at once, so a commit carried by two
  # stacked branches is counted once.
  if [ "${#tips[@]}" -gt 0 ]; then
    local -a args=("${tips[@]}")
    [ "${#bases[@]}" -eq 0 ] || args+=(--not "${bases[@]}")
    STATUS_COMMITS="$(git -C "$hub" rev-list --count "${args[@]}" 2>/dev/null || echo 0)"
  fi
}

status_summary() { # -> short human phrase for the list view
  if [ "$STATUS_TAMPER" = "1" ]; then
    printf 'TAMPER — run airlock doctor'
  elif [ "$STATUS_PENDING" = "0" ]; then
    printf 'nothing to review'
  elif [ "$STATUS_PENDING" = "1" ]; then
    printf '1 branch, %s commit(s)' "$STATUS_COMMITS"
  else
    printf '%s branches, %s commit(s)' "$STATUS_PENDING" "$STATUS_COMMITS"
  fi
}

status_list() {
  local dh ws name config project flavor hub broken=0 any=0
  dh="$(data_home)"
  if [ ! -d "$dh" ]; then
    printf 'no workspaces yet (%s does not exist)\n' "$dh"
    return 0
  fi

  printf '%-14s %-14s %-8s %-9s %s\n' NAME PROJECT AGENT VM UNREVIEWED
  for ws in "$dh"/*/; do
    [ -d "$ws" ] || continue
    any=1
    name="$(basename "$ws")"
    config="$ws/config"
    project="$(config_get "$config" project)"
    flavor="$(config_get "$config" flavor)"
    hub="$ws/work_dir/$project.git"
    # A broken workspace is reported, not skipped and not fatal: doctor is the
    # command that explains it.
    if [ ! -f "$config" ] || [ -z "$project" ] || ! is_git_repo "$hub"; then
      printf '%-14s %-14s %-8s %-9s %s\n' "$name" "${project:-?}" "${flavor:-?}" "?" \
        "broken — run airlock doctor $name"
      broken=1
      continue
    fi
    status_scan "${ws%/}" "$hub" "$(config_get "$config" default_branch)"
    printf '%-14s %-14s %-8s %-9s %s\n' \
      "$name" "$project" "$flavor" "$(status_vm "${ws%/}")" "$(status_summary)"
    [ "$STATUS_TAMPER" = "0" ] || broken=1
  done
  [ "$any" = "1" ] || printf '(none)\n'
  [ "$broken" = "0" ]
}

status_detail() { # name
  local name="$1"
  ws_open "$name"

  printf 'workspace %s\n' "$name"
  printf '  root         %s\n' "$WS_ROOT"
  printf '  project      %s (default branch %s)\n' "$WS_PROJECT" "${WS_BRANCH:-unknown}"
  printf '  agent        %s\n' "$WS_FLAVOR"
  printf '  vm           %s\n' "$(status_vm "$WS_ROOT" detail)"

  local remote url refs
  if [ -n "$(git -C "$WS_HUB" remote 2>/dev/null)" ]; then
    for remote in $(git -C "$WS_HUB" remote); do
      url="$(git -C "$WS_HUB" remote get-url "$remote" 2>/dev/null || echo '?')"
      refs="$(git -C "$WS_HUB" for-each-ref --format='x' "refs/upstream/$remote/" 2>/dev/null | wc -l)"
      printf '  upstream     %s -> %s (%s ref(s) fetched)\n' "$remote" "$url" "$refs"
    done
  else
    printf '  upstream     none configured\n'
  fi

  # The agent's own working tree. Uncommitted work here has not reached the
  # hub, so it is not yours to review yet — but it is worth seeing.
  if is_git_repo "$WS_CLONE"; then
    local on dirty
    on="$(git -C "$WS_CLONE" symbolic-ref --quiet --short HEAD 2>/dev/null || echo 'detached')"
    dirty="$(git -C "$WS_CLONE" status --porcelain 2>/dev/null | wc -l)"
    if [ "$dirty" -gt 0 ]; then
      printf '  clone        on %s, %s uncommitted change(s) — not pushed, not reviewable\n' "$on" "$dirty"
    else
      printf '  clone        on %s, clean\n' "$on"
    fi
  else
    printf '  clone        missing — run airlock doctor %s\n' "$name"
  fi

  status_scan "$WS_ROOT" "$WS_HUB" "$WS_BRANCH"
  printf '  hub          %s branch(es)\n' "$STATUS_BRANCHES"
  # Nobody should have to learn the layout to fetch from their own workspace.
  # shellcheck disable=SC2016  # the substitution is literal text to copy, not ours to expand
  printf '  fetch it      git remote add hub "$(airlock path %s)"\n' "$name"

  if [ -z "$STATUS_LINES" ]; then
    printf '\nnothing to review\n'
  else
    printf '\nunreviewed\n'
    printf '%s' "$STATUS_LINES" | while IFS=$'\t' read -r short count note; do
      [ -n "$short" ] || continue
      if [ "$count" = "-" ]; then
        printf '  %-28s %s\n' "$short" "$note"
      else
        printf '  %-28s %-4s %s\n' "$short" "$count" "$note"
      fi
    done
    if [ "$STATUS_TAMPER" = "1" ]; then
      printf '\nRun "airlock doctor %s" — a watermarked commit is missing or rewritten.\n' "$name"
    else
      printf '\nRead it with: airlock review %s\n' "$name"
    fi
  fi

  [ "$STATUS_TAMPER" = "0" ]
}

cmd_status() {
  local name=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) status_usage; return 0 ;;
      -*)        die "unknown option: $1" ;;
      *)         [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done

  if [ -n "$name" ]; then
    validate_workspace_name "$name"
    status_detail "$name"
  else
    status_list
  fi
}
