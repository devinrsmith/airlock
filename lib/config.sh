# shellcheck shell=bash
# airlock config — read and edit the two config files.
#
# Modelled on `git config`, with one deliberate difference. git resolves a key
# through a hierarchy of scopes; airlock's two scopes are not a hierarchy. The
# global file is a template that `init` reads once, and nothing else ever reads
# it (D19). So there is no merged view here: a listing is always of exactly one
# file, and the global listing says what it is for.

config_usage() {
  cat <<'EOF'
usage: airlock config [--global | --workspace <name>] <action>

  --list              print the scope's settings (the default action)
  --edit              open the file in $VISUAL or $EDITOR
  <key>               print one value
  <key> <value>       set one value
  --unset <key>       clear it

Scopes:
  --global            defaults for workspaces created from now on (the default)
  --workspace <name>  one workspace's own config

The global file is read only when a workspace is created. Changing it affects
the next workspace, never an existing one.
EOF
}

config_scope_keys() { # scope
  if [ "$1" = "global" ]; then printf '%s\n' "$USER_DEFAULT_KEYS"; else printf '%s\n' "$WORKSPACE_KEYS"; fi
}

config_known_key() { # scope key
  case " $(config_scope_keys "$1") " in
    *" $2 "*) return 0 ;;
    *)        return 1 ;;
  esac
}

# The global defaults file, created on first use with every settable key
# present and empty, so the file itself is the list of what can be set.
config_write_global_template() { # path
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<'EOF'
# airlock defaults for new workspaces.
#
# These are baked into a workspace's own config when `airlock init` writes it.
# Nothing reads this file afterwards, so changing it affects the next workspace
# and never an existing one. An empty value means "use airlock's built-in".

# Identity the agent commits under. Falls back to your git identity.
user_name      =
user_email     =

# claude (default), gemini, codex, pi.
flavor         =

# bypass (default) or prompt.
prompts        =

# off (default) or host-eval. host-eval evaluates a workspace's Nix code on
# this host before boot; see REQUIREMENTS.md §9.1 before turning it on.
devshell       =

# Resource ceilings for the VM.
cpus           =
memory_mb      =
store_size_mb  =

# Container runtimes to activate: containerd, crun, crio, docker, podman.
cri            =

# A flake reference pinning which claude-microvm to launch. Empty means the
# copy vendored in airlock.
substrate      =

# Host environment variables forwarded into the guest, comma separated.
env_forward    =

# Extra arguments appended to the agent's own command line.
agent_args     =

# A settings file on this host, copied into the agent home before boot.
settings       =
EOF
}

config_file_for() { # scope name -> path, creating the global template if needed
  local scope="$1" name="$2" file
  if [ "$scope" = "global" ]; then
    file="$(user_config_path)"
    [ -f "$file" ] || config_write_global_template "$file"
    printf '%s\n' "$file"
  else
    file="$(workspace_root "$name")/config"
    [ -f "$file" ] || die "workspace $name has no config (try: airlock doctor $name)"
    printf '%s\n' "$file"
  fi
}

config_list() { # scope file
  local scope="$1" file="$2" key value
  if [ "$scope" = "global" ]; then
    printf '# %s\n' "$file"
    printf '# defaults for workspaces created from now on; nothing else reads them\n'
  else
    printf '# %s\n' "$file"
  fi
  for key in $(config_scope_keys "$scope"); do
    value="$(config_get "$file" "$key")"
    [ -n "$value" ] || continue
    printf '%s=%s\n' "$key" "$value"
  done
}

config_edit() { # file
  local editor="${VISUAL:-${EDITOR:-}}"
  [ -n "$editor" ] || die "no editor: set \$VISUAL or \$EDITOR"
  eval "$editor \"\$1\""
}

# Keys airlock applied somewhere else at init and will not re-apply here: the
# identity is in the clone's git config, the flavor decided which context file
# was emitted. `config` edits text only; `doctor` is what notices the drift.
config_note_side_effects() { # scope key
  [ "$1" = "workspace" ] || return 0
  case "$2" in
    user_name|user_email)
      info "note: the clone still commits under its old identity — airlock doctor <name> --fix" ;;
    flavor)
      info "note: the emitted context file still matches the old flavor — airlock doctor <name> --fix" ;;
    project|default_branch|upstream)
      info "note: this names something that already exists on disk; airlock doctor <name> will report the mismatch" ;;
  esac
}

cmd_config() {
  local scope="global" ws="" action="" key="" value="" have_value=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)    config_usage; return 0 ;;
      --global)     scope="global"; shift ;;
      --workspace)  scope="workspace"; ws="${2-}"; [ -n "$ws" ] || die "--workspace needs a name"; shift 2 ;;
      --list)       action="list"; shift ;;
      --edit)       action="edit"; shift ;;
      --unset)      action="unset"; key="${2-}"; [ -n "$key" ] || die "--unset needs a key"; shift 2 ;;
      -*)           die "unknown option: $1" ;;
      *)
        if [ -z "$key" ]; then key="$1"
        elif [ "$have_value" = "0" ]; then value="$1"; have_value=1
        else die "unexpected argument: $1"
        fi
        shift ;;
    esac
  done

  [ "$scope" = "global" ] || validate_workspace_name "$ws"
  local file
  file="$(config_file_for "$scope" "$ws")"

  case "$action" in
    list) config_list "$scope" "$file"; return 0 ;;
    edit) config_edit "$file"; return 0 ;;
    unset)
      config_known_key "$scope" "$key" || die "not a key airlock reads: $key"
      if [ "$scope" = "global" ]; then
        config_remove_from_file "$file" "$key"
      else
        # A workspace config keeps every key present, so it stays the whole
        # statement of what that workspace does (D9).
        config_set_in_file "$file" "$key" ""
      fi
      config_note_side_effects "$scope" "$key"
      return 0 ;;
  esac

  [ -n "$key" ] || { config_list "$scope" "$file"; return 0; }
  config_known_key "$scope" "$key" || die "not a key airlock reads: $key"

  if [ "$have_value" = "0" ]; then
    local current
    current="$(config_get "$file" "$key")"
    [ -n "$current" ] || return 1     # unset: like `git config`, nothing and non-zero
    printf '%s\n' "$current"
    return 0
  fi

  [ "$key" != "project" ] \
    || die "project names the directories this workspace is built from; it cannot be changed after init"
  validate_config_value "$key" "$value"
  [ "$key" != "settings" ] || [ -f "$value" ] \
    || warn "no file at $value yet; run will refuse to launch until there is one"
  config_set_in_file "$file" "$key" "$value"
  config_note_side_effects "$scope" "$key"
}
