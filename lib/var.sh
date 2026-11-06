# shellcheck shell=bash
# airlock var — named values airlock holds for you (D37).
#
# A variable is data you set once and name in a workspace's env_forward, so the
# value can change without touching any config and without being exported in a
# login shell. It is a file per variable under $data_home/vars, in the root and
# so out of the guests' reach (D3), mode 0600 in a 0700 directory. Not
# encrypted: an exported environment variable is no better protected.

var_usage() {
  cat <<'EOF2'
usage: airlock var set <NAME> [<value>] [--secret|--no-secret] [--description <text>]
                                          store a value (read from stdin if omitted)
       airlock var edit <NAME> [--secret|--no-secret] [--description <text>]
                                          change the metadata, not the value
       airlock var get <NAME>             print a value
       airlock var ls [-l|--json [--values]]
                                          list the names; --values adds the value
                                          of each non-secret variable, never a secret's
       airlock var rm <NAME>...           delete

A variable may be marked secret and may have a one-line description. Secret is
a hint, not a protection: `get` still prints the value. Tools that read
variables programmatically (see `ls --json`) should not display a secret's
value; `ls --json --values` leaves it out. Changing a value keeps its metadata; --no-secret and
--description '' clear it.

Name a variable in a workspace's env_forward to forward it:

  airlock var set CLAUDE_CODE_OAUTH_TOKEN
  airlock config --workspace demo env_forward CLAUDE_CODE_OAUTH_TOKEN

At launch a bare NAME in env_forward takes the stored value when there is one,
and the host's environment otherwise. Changing the value needs no config change;
it applies to the next launch (status reports a running VM as unchanged).
Omit the value on `set` so it stays out of your shell history: it is read from
stdin, with no echo at a terminal.
EOF2
}

vars_home() { printf '%s/vars\n' "$(data_home)"; }

var_validate_name() {
  case "$1" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) die "a variable name is letters, digits and underscores, not starting with a digit (got: $1)" ;;
  esac
}

# Prints the value of a stored variable; fails if there is none.
var_value() { # NAME
  local file
  file="$(vars_home)/$1"
  [ -f "$file" ] || return 1
  # $(...) drops trailing newlines, which a value never carries.
  printf '%s' "$(cat "$file")"
}

var_exists() { [ -f "$(vars_home)/$1" ]; }

# Metadata lives beside the values in vars/.meta/<NAME>: `secret=0|1`, then
# `description=<text>`. Read with `read`, never sourced.
var_meta_file() { printf '%s/.meta/%s\n' "$(vars_home)" "$1"; }

# Sets VAR_SECRET (0|1) and VAR_DESCRIPTION for a stored variable.
var_meta_read() { # NAME
  local file line
  VAR_SECRET=0 VAR_DESCRIPTION=""
  file="$(var_meta_file "$1")"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      secret=1) VAR_SECRET=1 ;;
      description=*) VAR_DESCRIPTION="${line#description=}" ;;
    esac
  done < "$file"
}

var_meta_write() { # NAME SECRET DESCRIPTION
  local dir file tmp
  file="$(var_meta_file "$1")"
  dir="${file%/*}"
  ( umask 077; mkdir -p "$dir" )
  tmp="$dir/.$1.tmp.$$"
  ( umask 077; printf 'secret=%s\ndescription=%s\n' "$2" "$3" > "$tmp" )
  mv -f -- "$tmp" "$file"
}

# Parses --secret/--no-secret/--description into VAR_NEW_SECRET (""|0|1) and
# VAR_NEW_DESC (unset when not given); leaves the positionals in VAR_ARGS.
var_parse_flags() {
  VAR_NEW_SECRET="" VAR_ARGS=()
  unset VAR_NEW_DESC
  while [ $# -gt 0 ]; do
    case "$1" in
      --secret) VAR_NEW_SECRET=1 ;;
      --no-secret) VAR_NEW_SECRET=0 ;;
      --description)
        [ $# -ge 2 ] || die "--description needs a value"
        case "$2" in *$'\n'*) die "a description is one line" ;; esac
        VAR_NEW_DESC="$2"; shift ;;
      --description=*)
        VAR_NEW_DESC="${1#--description=}"
        case "$VAR_NEW_DESC" in *$'\n'*) die "a description is one line" ;; esac ;;
      --) shift; VAR_ARGS+=("$@"); break ;;
      -*) die "unknown option: $1" ;;
      *) VAR_ARGS+=("$1") ;;
    esac
    shift
  done
}

# Applies parsed flags over what NAME already has.
var_meta_apply() { # NAME
  var_meta_read "$1"
  [ -z "$VAR_NEW_SECRET" ] || VAR_SECRET="$VAR_NEW_SECRET"
  [ -z "${VAR_NEW_DESC+x}" ] || VAR_DESCRIPTION="$VAR_NEW_DESC"
  if [ "$VAR_SECRET" = 0 ] && [ -z "$VAR_DESCRIPTION" ]; then
    rm -f -- "$(var_meta_file "$1")"
  else
    var_meta_write "$1" "$VAR_SECRET" "$VAR_DESCRIPTION"
  fi
}

var_ls() {
  local mode="names" values=0 f n first=1 value usage="usage: airlock var ls [-l|--json [--values]]"
  case "${1:-}" in
    '') ;;
    -l|--long) mode=long ;;
    --json) mode=json ;;
    *) die "$usage" ;;
  esac
  if [ "${2:-}" = --values ] && [ "$mode" = json ]; then values=1; shift; fi
  [ $# -le 1 ] || die "$usage"
  [ "$mode" != json ] || printf '['
  for f in "$(vars_home)"/*; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    var_meta_read "$n"
    case "$mode" in
      names) printf '%s\n' "$n" ;;
      long)
        printf '%s\t%s\t%s\n' "$n" "$([ "$VAR_SECRET" = 1 ] && echo secret || echo -)" "$VAR_DESCRIPTION" ;;
      json)
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"name":%s,"secret":%s,"description":%s' \
          "$(json_str "$n")" "$(json_bool "$VAR_SECRET")" "$(json_str_or_null "$VAR_DESCRIPTION")"
        if [ "$values" = 1 ]; then
          # A secret's value is never printed here, whatever was asked.
          if [ "$VAR_SECRET" = 1 ]; then value=null; else value="$(json_str "$(var_value "$n")")"; fi
          printf ',"value":%s' "$value"
        fi
        printf '}' ;;
    esac
  done
  [ "$mode" != json ] || printf ']\n'
}

cmd_var() {
  local action="${1:-}"
  [ $# -eq 0 ] || shift
  case "$action" in
    -h|--help|help) var_usage ;;
    set)  var_set "$@" ;;
    get)
      [ $# -eq 1 ] || die "usage: airlock var get <NAME>"
      var_validate_name "$1"
      var_value "$1" || die "no variable named $1"
      printf '\n' ;;
    edit)
      var_parse_flags "$@"
      [ "${#VAR_ARGS[@]}" -eq 1 ] || die "usage: airlock var edit <NAME> [--secret|--no-secret] [--description <text>]"
      var_validate_name "${VAR_ARGS[0]}"
      var_exists "${VAR_ARGS[0]}" || die "no variable named ${VAR_ARGS[0]}"
      var_meta_apply "${VAR_ARGS[0]}" ;;
    ls|list) var_ls "$@" ;;
    rm)
      [ $# -ge 1 ] || die "usage: airlock var rm <NAME>..."
      local n
      for n in "$@"; do
        var_validate_name "$n"
        var_exists "$n" || die "no variable named $n"
      done
      for n in "$@"; do rm -f -- "$(vars_home)/$n" "$(var_meta_file "$n")"; done ;;
    '') var_usage >&2; exit 2 ;;
    *)  var_usage >&2; die "unknown var action: $action" ;;
  esac
}

var_set() {
  local usage="usage: airlock var set <NAME> [<value>] [--secret|--no-secret] [--description <text>]"
  var_parse_flags "$@"
  set -- "${VAR_ARGS[@]}"
  [ $# -ge 1 ] && [ $# -le 2 ] || die "$usage"
  local name="$1" value dir
  var_validate_name "$name"
  if [ $# -eq 2 ]; then
    value="$2"
  elif [ -t 0 ]; then
    printf '%s: ' "$name" >&2
    IFS= read -rs value || true
    printf '\n' >&2
  else
    value="$(cat)"
  fi
  [ -n "$value" ] || die "empty value; to delete $name use: airlock var rm $name"
  dir="$(vars_home)"
  ( umask 077; mkdir -p "$dir" )
  chmod 700 "$dir"
  # Written beside and renamed, so a launch never reads half a value.
  local tmp="$dir/.$name.tmp.$$"
  ( umask 077; printf '%s\n' "$value" > "$tmp" )
  mv -f -- "$tmp" "$dir/$name"
  var_meta_apply "$name"
}
