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
usage: airlock var set <NAME> [<value>]   store a value (read from stdin if omitted)
       airlock var get <NAME>             print a value
       airlock var ls                     list the names, never the values
       airlock var rm <NAME>...           delete

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
    ls|list)
      [ $# -eq 0 ] || die "var ls takes no arguments"
      local f
      for f in "$(vars_home)"/*; do
        [ -f "$f" ] || continue
        printf '%s\n' "${f##*/}"
      done ;;
    rm)
      [ $# -ge 1 ] || die "usage: airlock var rm <NAME>..."
      local n
      for n in "$@"; do
        var_validate_name "$n"
        var_exists "$n" || die "no variable named $n"
      done
      for n in "$@"; do rm -f -- "$(vars_home)/$n"; done ;;
    '') var_usage >&2; exit 2 ;;
    *)  var_usage >&2; die "unknown var action: $action" ;;
  esac
}

var_set() {
  [ $# -ge 1 ] && [ $# -le 2 ] || die "usage: airlock var set <NAME> [<value>]"
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
}
