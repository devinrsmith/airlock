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
usage: airlock status [<name>] [--json]

  With no name, lists every workspace. With one, shows its detail.
  Exits non-zero if any workspace is too broken to read.

  --json   the same report as one JSON object, for programs (airlock ui);
           the list also carries the hub service and registry caches
EOF
}

# One value from a running VM's launch record — the lines `run` writes into
# the lock after the pid (see cmd_run). Empty when the key is absent.
status_record_get() { # lockfile key
  awk -v k="$2 " 'NR > 1 && index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$1" 2>/dev/null
}

# The part of a launch record that a plan computed now can be compared with.
status_record_plan() { # lockfile
  tail -n +2 "$1" 2>/dev/null | grep -E '^(flavor|substrate|nixpkgs|env) ' || true
}

# The config key a plan line comes from, for saying what changed in the terms
# the developer edits rather than the substrate's variables (D9).
status_plan_key() { # flavor | substrate | nixpkgs | <env NAME>
  case "$1" in
    VM_VCPU)          printf 'cpus' ;;
    VM_MEM)           printf 'memory_mb' ;;
    AGENTS_ARGS)      printf 'prompts/agent_args' ;;
    AGENT_SETTINGS)   printf 'settings' ;;
    DIRENV_ALLOW)     printf 'devshell' ;;
    VM_STORE_SIZE)    printf 'store_size_mb' ;;
    ENABLE_CRI)       printf 'cri' ;;
    CRI_STORAGE_SIZE) printf 'cri_storage_mb' ;;
    REGISTRY_MIRRORS) printf 'registry' ;;
    EXTRA_ENV)        printf 'env_forward' ;;
    WORK_DIR|AGENT_HOME|MICROVM_CONTEXT|MICROVM_START_DIR) printf 'workspace location' ;;
    WORK_CACHE)       printf "airlock's work cache (D27)" ;;
    *)                printf '%s' "$1" ;;
  esac
}

# What a running task's VM was launched with, against what the task's plan is
# now.
#   STATUS_DRIFT        the config keys whose effect differs, comma-separated
#   STATUS_PLAN_BROKEN  1 when the config as it stands would not launch at all
# The plan is computed from the cwd the run was started in, which is what
# relative paths in the config were resolved against then.
status_launch() { # name lockfile task
  local name="$1" lock="$2" task="$3" cwd now key label
  STATUS_DRIFT=""
  STATUS_PLAN_BROKEN=0
  [ -n "$(status_record_get "$lock" substrate)" ] || return 0

  cwd="$(status_record_get "$lock" cwd)"
  if ! now="$(
    exec 2>/dev/null   # the plan's warnings are for `run`, not for this report
    ws_open "$name"
    task_open "$task"
    if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || exit 1; fi
    run_plan
  )"; then
    STATUS_PLAN_BROKEN=1
    return 0
  fi

  # The keys whose value differs or exists on one side only, in plan order.
  # An env line is keyed by its variable's name.
  while IFS= read -r key; do
    label="$(status_plan_key "$key")"
    case ", $STATUS_DRIFT, " in *", $label, "*) continue ;; esac
    STATUS_DRIFT="${STATUS_DRIFT:+$STATUS_DRIFT, }$label"
  done < <(awk '
    function split_line(line) {
      key = substr(line, 1, index(line, " ") - 1)
      value = substr(line, index(line, " ") + 1)
      if (key == "env") { key = substr(value, 1, index(value, "=") - 1); value = substr(value, index(value, "=") + 1) }
    }
    $0 == "" { next }
    FNR == NR { split_line($0); was[key] = value; if (!(key in seen)) { seen[key]; order[++n] = key }; next }
    { split_line($0); is[key] = value; if (!(key in seen)) { seen[key]; order[++n] = key } }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (!(k in was) || !(k in is) || was[k] != is[k]) print k
      }
    }
  ' <(status_record_plan "$lock") <(printf '%s\n' "$now"))
}

# Which substrate a workspace's config launches, resolved the way `run`
# resolves it. A running task's own launch record says what it was started
# with; a change since shows as drift (status_launch).
#   STATUS_SUBSTRATE          the ref (empty: nothing pins one)
#   STATUS_SUBSTRATE_DEFAULT  the ref a workspace pinning none of its own
#                             would launch now
#   STATUS_SUBSTRATE_OVERRIDE 1 when the ref is not that default; a key that
#                             merely restates the default is not an override
#   STATUS_NIXPKGS            the nixpkgs its input is overridden to (empty:
#                             the substrate keeps its own), as `run` decides
status_substrate() { # config
  local configured
  STATUS_SUBSTRATE_DEFAULT="$(substrate_default_ref || true)"
  configured="$(config_get "$1" substrate)"
  if [ -n "$configured" ]; then
    STATUS_SUBSTRATE="$(run_abs_flake_ref "$configured")"
  else
    STATUS_SUBSTRATE="$STATUS_SUBSTRATE_DEFAULT"
  fi
  STATUS_SUBSTRATE_OVERRIDE=0
  [ -z "$STATUS_SUBSTRATE" ] || [ "$STATUS_SUBSTRATE" = "$STATUS_SUBSTRATE_DEFAULT" ] \
    || STATUS_SUBSTRATE_OVERRIDE=1
  STATUS_NIXPKGS=""
  if [ -n "$STATUS_SUBSTRATE" ] && [ "$STATUS_SUBSTRATE_OVERRIDE" = "0" ]; then
    STATUS_NIXPKGS="$(nixpkgs_ref || true)"
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

# A workspace's tasks (D26), for the list view: how many, how many running,
# and a `!` when a running one was launched with a config that has changed
# since. Empty when there are none.
status_tasks_summary() { # name root
  local name="$1" root="$2" d task lock total=0 running=0 drift=""
  for d in "$root"/tasks/*/; do
    [ -d "$d" ] || continue
    task="$(basename "$d")"
    total=$((total + 1))
    lock="$(lock_file "${d%/}")"
    lock_is_live "$lock" || continue
    running=$((running + 1))
    status_launch "$name" "$lock" "$task"
    if [ -n "$STATUS_DRIFT" ] || [ "$STATUS_PLAN_BROKEN" = "1" ]; then drift="!"; fi
  done
  [ "$total" -gt 0 ] || return 0
  printf '%s' "$total"
  [ "$running" = "0" ] || printf ', %s running%s' "$running" "$drift"
}

status_list() {
  local dh ws name config project flavor branch hub tasks broken=0 any=0 overridden=0 drifted=0
  dh="$(workspaces_home)"
  if [ ! -d "$dh" ]; then
    printf 'no workspaces yet (%s does not exist)\n' "$dh"
    return 0
  fi

  printf '%-14s %-14s %-8s %-14s %s\n' NAME PROJECT AGENT TASKS AHEAD
  for ws in "$dh"/*/; do
    [ -d "$ws" ] || continue
    any=1
    name="$(basename "$ws")"
    config="$ws/config"
    project="$(config_get "$config" project)"
    flavor="$(config_get "$config" flavor)"
    hub="$ws/$project.git"
    # A broken workspace is reported, not skipped and not fatal: doctor is the
    # command that explains it.
    if [ ! -f "$config" ] || [ -z "$project" ] || ! is_git_repo "$hub"; then
      printf '%-14s %-14s %-8s %-14s %s\n' "$name" "${project:-?}" "${flavor:-?}" "?" \
        "broken — run airlock doctor $name"
      broken=1
      continue
    fi
    branch="$(config_get "$config" default_branch)"
    status_scan "$hub" "$branch"
    # Only markers here; the detail view names the ref and what changed.
    status_substrate "$config"
    if [ "$STATUS_SUBSTRATE_OVERRIDE" = "1" ]; then
      flavor="$flavor*"
      overridden=1
    fi
    tasks="$(status_tasks_summary "$name" "${ws%/}")"
    case "$tasks" in *'!') drifted=1 ;; esac
    printf '%-14s %-14s %-8s %-14s %s\n' \
      "$name" "$project" "$flavor" "${tasks:-none}" "$(status_summary "$branch")"
  done
  [ "$any" = "1" ] || printf '(none)\n'
  if [ "$overridden" = "1" ] || [ "$drifted" = "1" ]; then
    printf '\n'
    [ "$overridden" = "0" ] ||
      printf '* on a substrate other than the default; airlock status <name> names it\n'
    [ "$drifted" = "0" ] ||
      printf '! config changed since a running task launched; airlock status <name> says what\n'
  fi
  [ "$broken" = "0" ]
}

status_detail() { # name
  local name="$1"
  ws_open "$name"

  printf 'workspace %s\n' "$name"
  printf '  root         %s\n' "$WS_ROOT"
  printf '  project      %s (default branch %s)\n' "$WS_PROJECT" "${WS_BRANCH:-unknown}"
  printf '  agent        %s\n' "$WS_FLAVOR"

  status_substrate "$WS_CONFIG"
  local how="default"
  if [ "$STATUS_SUBSTRATE_OVERRIDE" = "1" ]; then
    how="overrides default ${STATUS_SUBSTRATE_DEFAULT:-none}"
  fi
  printf '  substrate    %s (%s)\n' "${STATUS_SUBSTRATE:-none pinned}" "$how"
  if [ -n "$STATUS_NIXPKGS" ]; then
    printf "  nixpkgs      %s (airlock's, overriding the substrate's own)\n" "$STATUS_NIXPKGS"
  elif [ -n "$STATUS_SUBSTRATE" ]; then
    printf "  nixpkgs      the substrate's own lock\n"
  fi

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
  wd_is_repo "$WS_WORK_DIR" "$WS_REPO" || printf '  repository   missing — run airlock doctor %s\n' "$name"

  # The workspace's tasks (D26): each a VM of its own, on a branch of its own.
  # Uncommitted work in a worktree has not reached the hub, so there is nothing
  # of it to fetch yet — but it is worth seeing.
  local task troot tlock tvm tworktree ton tdirty tstate rev any_task=0
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    any_task=1
    troot="$(task_root "$task")"
    tlock="$(lock_file "$troot")"
    tworktree="$(task_worktree "$task")"
    rev=""
    if lock_is_live "$tlock"; then
      tvm="running (pid $(head -1 "$tlock"))"
      rev="$(status_record_get "$tlock" substrate.rev)"
      status_launch "$name" "$tlock" "$task"
      if [ "$STATUS_PLAN_BROKEN" = "1" ]; then
        tvm="$tvm, config changed and would not launch now (airlock run $name $task --dry-run says why)"
      elif [ -n "$STATUS_DRIFT" ]; then
        tvm="$tvm, config changed since launch: $STATUS_DRIFT"
      fi
    else
      tvm="stopped"
    fi
    if wd_is_repo "$WS_WORK_DIR" "$tworktree"; then
      ton="$(wd_git "$WS_WORK_DIR" --repo "$tworktree" -- -C "$tworktree" symbolic-ref --quiet --short HEAD 2>/dev/null || echo 'detached')"
      tdirty="$(wd_git "$WS_WORK_DIR" --repo "$tworktree" -- -C "$tworktree" status --porcelain 2>/dev/null | wc -l)"
      if [ "$tdirty" -gt 0 ]; then tstate="$tdirty uncommitted change(s)"; else tstate="clean"; fi
      printf '  task         %s: %s; on %s, %s\n' "$task" "$tvm" "$ton" "$tstate"
    else
      printf '  task         %s: %s; worktree missing — run airlock doctor %s\n' "$task" "$tvm" "$name"
    fi
    [ -z "$rev" ] || printf '                 substrate rev %s\n' "$rev"
  done < <(task_names)
  [ "$any_task" = "1" ] || printf '  task         none — airlock task new %s <task>\n' "$name"

  status_scan "$WS_HUB" "$WS_BRANCH"
  printf '  hub          %s branch(es)\n' "$STATUS_BRANCHES"
  # Nobody should have to learn the layout to fetch from their own workspace.
  # shellcheck disable=SC2016  # the substitution is literal text to copy, not ours to expand
  printf '  fetch it      git remote add hub "$(airlock path %s)"\n' "$name"
  ! web_serving || printf '  browse it     %s\n' "$(web_url "$name")"

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

# --- JSON (D36) ----------------------------------------------------------
#
# `status --json` is the same report for a program to read. `airlock ui` learns
# nothing about a workspace any other way, so what the UI shows, the CLI
# computed, through the same sandboxed git (D34). Absent facts are null rather
# than missing keys.

# The comma-joined labels status_launch leaves in STATUS_DRIFT, as an array.
status_json_drift() {
  local first=1 label rest="$STATUS_DRIFT"
  printf '['
  while [ -n "$rest" ]; do
    label="${rest%%, *}"
    if [ "$label" = "$rest" ]; then rest=""; else rest="${rest#*, }"; fi
    [ "$first" = "1" ] || printf ','
    first=0
    json_str "$label"
  done
  printf ']'
}

# STATUS_LINES (see status_scan) as an array of {branch, commits}.
status_json_ahead() {
  local first=1 short count
  printf '['
  while IFS=$'\t' read -r short count; do
    [ -n "$short" ] || continue
    [ "$first" = "1" ] || printf ','
    first=0
    printf '{"branch":%s,"commits":%s}' "$(json_str "$short")" "$count"
  done <<< "$STATUS_LINES"
  printf ']'
}

# What a workspace's hub holds beyond its default branch (status_scan), as
# fields of the workspace's object.
status_json_hub() { # hub default_branch
  status_scan "$1" "$2"
  printf '"branches":%s,"commits":%s,"ahead":%s' \
    "$STATUS_BRANCHES" "$STATUS_COMMITS" "$(status_json_ahead)"
}

# One task of the open workspace. The summary is what the list view needs and
# runs no git in the worktree. With detail, the worktree's state as `status
# <name>` reports it, and the commits on agent/<task> that the repository has
# not seen reach the hub — `task rm`'s measure, but without its fetch, since
# status is offline: a push from somewhere other than the worktree can make it
# overcount, never undercount.
status_json_task() { # task detail(0|1)
  local task="$1" detail="$2" lock running=0 pid="" rev="" worktree on dirty unpushed
  lock="$(lock_file "$(task_root "$task")")"
  STATUS_DRIFT=""
  STATUS_PLAN_BROKEN=0
  if lock_is_live "$lock"; then
    running=1
    pid="$(head -1 "$lock")"
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    rev="$(status_record_get "$lock" substrate.rev)"
    status_launch "$WS_NAME" "$lock" "$task"
  fi
  printf '{"name":%s,"running":%s,"pid":%s,"drift":%s,"plan_broken":%s' \
    "$(json_str "$task")" "$(json_bool "$running")" "${pid:-null}" \
    "$(status_json_drift)" "$(json_bool "$STATUS_PLAN_BROKEN")"
  if [ "$detail" = "1" ]; then
    worktree="$(task_worktree "$task")"
    printf ',"substrate_rev":%s' "$(json_str_or_null "$rev")"
    if wd_is_repo "$WS_WORK_DIR" "$worktree"; then
      on="$(wd_git "$WS_WORK_DIR" --repo "$worktree" -- -C "$worktree" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
      dirty="$(wd_git "$WS_WORK_DIR" --repo "$worktree" -- -C "$worktree" status --porcelain 2>/dev/null | wc -l)"
      unpushed=0
      if repo_git show-ref --verify --quiet "refs/heads/agent/$task"; then
        unpushed="$(repo_git rev-list --count "refs/heads/agent/$task" --not --remotes=origin 2>/dev/null || echo 0)"
      fi
      printf ',"worktree":true,"on":%s,"changes":%s,"unpushed":%s' \
        "$(json_str_or_null "$on")" "$dirty" "$unpushed"
    else
      printf ',"worktree":false,"on":null,"changes":null,"unpushed":null'
    fi
  fi
  printf '}'
}

# The services guests use (D21, D33), which the text leaves to `hub status`
# and `registry status`. systemd's word for each unit, verbatim; null when
# systemd cannot be asked, which is not the same as stopped.
status_json_services() {
  local hub="" u first=1 asked=0
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    asked=1
    hub="$(hub_state)"
  fi
  printf '{"hub":{"state":%s,"port":%s},"registry":[' "$(json_str_or_null "$hub")" "$(hub_port)"
  for u in $REGISTRY_UPSTREAMS; do
    [ "$first" = "1" ] || printf ','
    first=0
    printf '{"upstream":%s,"port":%s,"state":' "$(json_str "$u")" "$(registry_port "$u")"
    if [ "$asked" = "1" ]; then json_str_or_null "$(registry_state "$u")"; else printf null; fi
    printf '}'
  done
  printf ']}'
}

# Every workspace, as status_list reports them. A broken one is an entry with
# "ok": false, and the exit status is non-zero, as for the text.
status_json_list() {
  local ws name config project flavor branch task first=1 tfirst broken=0
  printf '{"data_home":%s,"workspaces":[' "$(json_str "$(data_home)")"
  for ws in "$(workspaces_home)"/*/; do
    [ -d "$ws" ] || continue
    name="$(basename "$ws")"
    config="$ws/config"
    project="$(config_get "$config" project)"
    flavor="$(config_get "$config" flavor)"
    [ "$first" = "1" ] || printf ','
    first=0
    printf '{"name":%s,"project":%s,"flavor":%s' \
      "$(json_str "$name")" "$(json_str_or_null "$project")" "$(json_str_or_null "$flavor")"
    if [ ! -f "$config" ] || [ -z "$project" ] || ! is_git_repo "$ws/$project.git"; then
      printf ',"ok":false}'
      broken=1
      continue
    fi
    # What status_json_task needs of ws_open, without its dying on a workspace
    # the checks above have already passed.
    WS_NAME="$name"; WS_ROOT="${ws%/}"; WS_WORK_DIR="$WS_ROOT/work_dir"; WS_REPO="$WS_WORK_DIR/.repo"
    branch="$(config_get "$config" default_branch)"
    status_substrate "$config"
    printf ',"ok":true,"default_branch":%s,"substrate":%s,"substrate_override":%s,' \
      "$(json_str_or_null "$branch")" "$(json_str_or_null "$STATUS_SUBSTRATE")" \
      "$(json_bool "$STATUS_SUBSTRATE_OVERRIDE")"
    status_json_hub "$ws/$project.git" "$branch"
    printf ',"tasks":['
    tfirst=1
    while IFS= read -r task; do
      [ -n "$task" ] || continue
      [ "$tfirst" = "1" ] || printf ','
      tfirst=0
      status_json_task "$task" 0
    done < <(task_names)
    printf ']}'
  done
  printf '],"services":'
  status_json_services
  printf '}\n'
  [ "$broken" = "0" ]
}

# One workspace in detail, as status_detail reports it.
status_json_detail() { # name
  local name="$1" remote url refs first=1 task repo=0
  ws_open "$name"
  status_substrate "$WS_CONFIG"
  wd_is_repo "$WS_WORK_DIR" "$WS_REPO" && repo=1
  printf '{"name":%s,"root":%s,"project":%s,"flavor":%s,"default_branch":%s' \
    "$(json_str "$name")" "$(json_str "$WS_ROOT")" "$(json_str "$WS_PROJECT")" \
    "$(json_str "$WS_FLAVOR")" "$(json_str_or_null "$WS_BRANCH")"
  printf ',"substrate":%s,"substrate_default":%s,"substrate_override":%s,"nixpkgs":%s' \
    "$(json_str_or_null "$STATUS_SUBSTRATE")" "$(json_str_or_null "$STATUS_SUBSTRATE_DEFAULT")" \
    "$(json_bool "$STATUS_SUBSTRATE_OVERRIDE")" "$(json_str_or_null "$STATUS_NIXPKGS")"
  printf ',"repository":%s,"upstreams":[' "$(json_bool "$repo")"
  for remote in $(git -C "$WS_HUB" remote 2>/dev/null); do
    url="$(git -C "$WS_HUB" remote get-url "$remote" 2>/dev/null || true)"
    refs="$(git -C "$WS_HUB" for-each-ref --format='x' "refs/upstream/$remote/" 2>/dev/null | wc -l)"
    [ "$first" = "1" ] || printf ','
    first=0
    printf '{"name":%s,"url":%s,"refs":%s}' "$(json_str "$remote")" "$(json_str_or_null "$url")" "$refs"
  done
  printf '],'
  status_json_hub "$WS_HUB" "$WS_BRANCH"
  printf ',"tasks":['
  first=1
  while IFS= read -r task; do
    [ -n "$task" ] || continue
    [ "$first" = "1" ] || printf ','
    first=0
    status_json_task "$task" "$repo"
  done < <(task_names)
  printf ']}\n'
}

cmd_status() {
  local name="" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) status_usage; return 0 ;;
      --json)    json=1; shift ;;
      -*)        die "unknown option: $1" ;;
      *)         [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done

  if [ -n "$name" ]; then
    validate_workspace_name "$name"
    if [ "$json" = "1" ]; then status_json_detail "$name"; else status_detail "$name"; fi
  elif [ "$json" = "1" ]; then
    status_json_list
  else
    status_list
  fi
}
