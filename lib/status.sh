# shellcheck shell=bash
# airlock status — what exists, what is running, and what the agent has pushed.
#
# Strictly read-only and strictly offline: it never fetches and never repairs.
# `fetch` and `doctor` are the commands that change things.
#
# airlock keeps no review state (D16). What status reports is the hub as it is:
# the branches carrying commits the default branch does not have. Reading them
# is done from your own checkout, with your own git.

status_usage() {
  cat <<'EOF'
usage: airlock status [<name>]

  With no name, lists every workspace. With one, shows its detail.
  Exits non-zero if any workspace is too broken to read.
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
#   STATUS_AHEAD        branches carrying commits the default branch lacks
#   STATUS_COMMITS      DISTINCT such commits across them — not the sum of the
#                       per-branch counts. Agents stack branches on each other,
#                       and a commit is one commit to read however many
#                       branches contain it.
#   STATUS_LINES        one "<short>\t<count>" per branch ahead
status_scan() { # hub default_branch
  local hub="$1" default="$2" ref short count
  local -a tips=() not=()
  STATUS_BRANCHES=0
  STATUS_AHEAD=0
  STATUS_COMMITS=0
  STATUS_LINES=""
  # A hub whose default branch is gone has nothing to measure against, so
  # every commit counts; doctor is the command that explains why.
  if [ -n "$default" ] && git -C "$hub" rev-parse --verify --quiet "refs/heads/$default" >/dev/null; then
    not=(--not "refs/heads/$default")
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    STATUS_BRANCHES=$((STATUS_BRANCHES + 1))
    [ "$ref" != "refs/heads/$default" ] || continue
    short="${ref#refs/heads/}"
    count="$(git -C "$hub" rev-list --count "$ref" "${not[@]}" 2>/dev/null || echo 0)"
    [ "$count" != "0" ] || continue
    STATUS_AHEAD=$((STATUS_AHEAD + 1))
    tips+=("$ref")
    STATUS_LINES="${STATUS_LINES}${short}"$'\t'"${count}"$'\n'
  done < <(git -C "$hub" for-each-ref --format='%(refname)' refs/heads/ 2>/dev/null)

  # One rev-list over every branch at once, so a commit carried by two stacked
  # branches is counted once.
  if [ "${#tips[@]}" -gt 0 ]; then
    STATUS_COMMITS="$(git -C "$hub" rev-list --count "${tips[@]}" "${not[@]}" 2>/dev/null || echo 0)"
  fi
}

status_summary() { # default_branch -> short human phrase for the list view
  if [ "$STATUS_AHEAD" = "0" ]; then
    printf 'nothing ahead of %s' "${1:-the default branch}"
  elif [ "$STATUS_AHEAD" = "1" ]; then
    printf '1 branch, %s commit(s)' "$STATUS_COMMITS"
  else
    printf '%s branches, %s commit(s)' "$STATUS_AHEAD" "$STATUS_COMMITS"
  fi
}

status_list() {
  local dh ws name config project flavor branch hub broken=0 any=0
  dh="$(data_home)"
  if [ ! -d "$dh" ]; then
    printf 'no workspaces yet (%s does not exist)\n' "$dh"
    return 0
  fi

  printf '%-14s %-14s %-8s %-9s %s\n' NAME PROJECT AGENT VM AHEAD
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
    branch="$(config_get "$config" default_branch)"
    status_scan "$hub" "$branch"
    printf '%-14s %-14s %-8s %-9s %s\n' \
      "$name" "$project" "$flavor" "$(status_vm "${ws%/}")" "$(status_summary "$branch")"
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
  # hub, so there is nothing of it to fetch yet — but it is worth seeing.
  if is_git_repo "$WS_CLONE"; then
    local on dirty
    on="$(git -C "$WS_CLONE" symbolic-ref --quiet --short HEAD 2>/dev/null || echo 'detached')"
    dirty="$(git -C "$WS_CLONE" status --porcelain 2>/dev/null | wc -l)"
    if [ "$dirty" -gt 0 ]; then
      printf '  clone        on %s, %s uncommitted change(s) — not pushed to the hub\n' "$on" "$dirty"
    else
      printf '  clone        on %s, clean\n' "$on"
    fi
  else
    printf '  clone        missing — run airlock doctor %s\n' "$name"
  fi

  status_scan "$WS_HUB" "$WS_BRANCH"
  printf '  hub          %s branch(es)\n' "$STATUS_BRANCHES"
  # Nobody should have to learn the layout to fetch from their own workspace.
  # shellcheck disable=SC2016  # the substitution is literal text to copy, not ours to expand
  printf '  fetch it      git remote add hub "$(airlock path %s)"\n' "$name"

  if [ -z "$STATUS_LINES" ]; then
    printf '\nnothing ahead of %s\n' "${WS_BRANCH:-the default branch}"
  else
    printf '\nahead of %s\n' "${WS_BRANCH:-the default branch}"
    printf '%s' "$STATUS_LINES" | while IFS=$'\t' read -r short count; do
      [ -n "$short" ] || continue
      printf '  %-28s %s commit(s)\n' "$short" "$count"
    done
  fi
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
