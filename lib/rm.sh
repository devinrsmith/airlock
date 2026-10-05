# shellcheck shell=bash
# airlock rm — tear a workspace down.
#
# The hub is the only copy of anything the agent pushed and you have not
# published, so this command's job is less "delete a directory" than "make sure
# you know what you are deleting first".

rm_usage() {
  cat <<'EOF'
usage: airlock rm <name> [--yes] [--rescue-into <repo>]

  --yes                  do not ask (required when there is no terminal)
  --rescue-into <repo>   first fetch every hub branch into <repo> as
                         refs/remotes/<name>/*, so nothing is lost

Everything a workspace owns lives under one directory, including the
substrate's agent_home-cri and agent_home-store disks, so removal takes it all.
EOF
}

# Fetch the whole hub into a repository you keep, under a namespace of its own.
rm_rescue() { # hub repo name
  local hub="$1" repo="$2" name="$3"
  is_git_repo "$repo" || die "--rescue-into needs a git repository: $repo"
  info "rescuing every hub branch into $repo as refs/remotes/$name/*"
  git -C "$repo" fetch --quiet "$hub" "+refs/heads/*:refs/remotes/$name/*" \
    || die "could not rescue into $repo; nothing has been removed"
  git -C "$repo" for-each-ref --format='  rescued %(refname:short)' "refs/remotes/$name/"
}

cmd_rm() {
  local name="" yes=0 rescue=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)      rm_usage; return 0 ;;
      --yes|-y)       yes=1; shift ;;
      --rescue-into)  rescue="${2-}"; [ -n "$rescue" ] || die "--rescue-into needs a path"; shift 2 ;;
      -*)             die "unknown option: $1" ;;
      *)              [ -z "$name" ] || die "unexpected argument: $1"; name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || { rm_usage >&2; die "workspace name is required"; }
  validate_workspace_name "$name"

  local root
  root="$(workspace_root "$name")"
  [ -d "$root" ] || die "no such workspace: $name"

  # Never rm -rf something that does not look like one of ours, however the
  # name validated.
  { [ -f "$root/config" ] || [ -d "$root/work_dir" ]; } \
    || die "$root does not look like an airlock workspace; remove it by hand if you mean to"

  local lock
  lock="$(lock_file "$root")"
  if lock_is_live "$lock"; then
    die "a run is in progress (pid $(head -1 "$lock")); exit the agent first"
  fi

  # --- what would be lost ---
  local project hub pending=0
  project="$(config_get "$root/config" project)"
  hub="$root/work_dir/$project.git"
  printf 'about to remove workspace %s\n' "$name"
  printf '  %s\n' "$root"
  if [ -n "$project" ] && is_git_repo "$hub"; then
    local branch
    branch="$(config_get "$root/config" default_branch)"
    status_scan "$hub" "$branch"
    printf '  hub: %s branch(es)\n' "$STATUS_BRANCHES"
    if [ "$STATUS_AHEAD" -gt 0 ]; then
      pending=1
      printf '\nThis hub holds branches with commits %s does not have:\n' "${branch:-the default branch}"
      printf '%s' "$STATUS_LINES" | while IFS=$'\t' read -r short count; do
        [ -n "$short" ] || continue
        printf '  %-28s %s commit(s)\n' "$short" "$count"
      done
      printf '\nThe hub is the only copy of anything the agent pushed and you have not\n'
      printf 'fetched. Rescue it first with --rescue-into <your checkout>, or fetch it\n'
      printf 'yourself from "airlock path %s".\n' "$name"
    fi
  else
    printf '  hub: missing or unreadable\n'
  fi

  [ -z "$rescue" ] || rm_rescue "$hub" "$rescue" "$name"

  # --- confirmation, proportional to what is at stake ---
  if [ "$yes" != "1" ]; then
    if ! { [ -t 0 ] && [ -t 1 ]; }; then
      die "refusing to remove without confirmation; pass --yes if you mean it"
    fi
    local reply
    if [ "$pending" = "1" ]; then
      printf '\nType the workspace name to confirm removal: '
      read -r reply || reply=""
      [ "$reply" = "$name" ] || { info "not removed"; return 1; }
    else
      printf '\nRemove it? [y/N] '
      read -r reply || reply=""
      case "$reply" in
        y|Y|yes) ;;
        *) info "not removed"; return 1 ;;
      esac
    fi
  fi

  rm -rf -- "$root"
  info "removed $root"
  info ""
  info "If your own checkout has a remote pointing at that hub, drop it:"
  info "  git -C <your checkout> remote remove hub"
}
