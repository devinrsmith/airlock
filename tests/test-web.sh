# shellcheck shell=bash
# Behaviour of airlock web (D35): every workspace's hub, read-only, through
# cgit behind lighttpd, on 127.0.0.2.
#
# The service is started by `airlock web start` as it would be, with stub
# systemd-run and systemctl that run lighttpd as an ordinary background process
# on a port of the test's own; requests go over bash's /dev/tcp. What systemd
# would enforce is checked as the properties handed to it; that a unit with
# them really sees only the hubs, read-only, was probed by hand (D35).

TMP="$(mktemp -d)"
trap '[ -f "$TMP/stub/pid" ] && kill "$(cat "$TMP/stub/pid")" 2>/dev/null; rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = Test Developer
	email = dev@example.invalid
[init]
	defaultBranch = main
EOF
export AIRLOCK_WEB_PORT=$(( 20000 + RANDOM % 20000 ))
AIRLOCK="$REPO_ROOT/bin/airlock"
OUT="$TMP/out"
run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

case_begin "path --web is the workspace's address, running or not"
src="$TMP/src-alpha"
git init --quiet -b main "$src"
( cd "$src" && echo one > file.txt && git add file.txt && git commit --quiet -m one )
"$AIRLOCK" init alpha --from-local "$src" --project widget >/dev/null 2>&1
assert_ok "path" run path alpha --web
assert_eq "http://127.0.0.2:$AIRLOCK_WEB_PORT/alpha/" "$(cat "$OUT")" "the URL"

if [ -z "${AIRLOCK_CGIT:-}" ] || [ ! -x "$AIRLOCK_CGIT/cgit/cgit.cgi" ] \
   || [ -z "${AIRLOCK_LIGHTTPD:-}" ] || [ ! -x "$AIRLOCK_LIGHTTPD/bin/lighttpd" ]; then
  case_begin "web"
  skip "no cgit and lighttpd (AIRLOCK_CGIT, AIRLOCK_LIGHTTPD)"
  return 0   # sourced by run-tests.sh
fi

setup() { # name -> echoes the workspace root
  local src="$TMP/src-$1"
  {
    git init --quiet -b main "$src"
    ( cd "$src" || exit 1; echo one > file.txt; git add file.txt; git commit --quiet -m one )
    PATH="$TMP/stub:$PATH" "$AIRLOCK" init "$1" --from-local "$src" --project widget
  } >/dev/null 2>&1
  printf '%s/ws/%s\n' "$AIRLOCK_DATA_HOME" "$1"
}

mkdir -p "$TMP/stub"
cat > "$TMP/stub/systemd-run" <<EOF
#!$BASH
printf '%s\n' "\$@" > "$TMP/stub/run-args"
while [ \$# -gt 0 ] && [ "\$1" != "--" ]; do shift; done
shift
"\$@" > "$TMP/stub/lighttpd.log" 2>&1 &
echo \$! > "$TMP/stub/pid"
EOF
cat > "$TMP/stub/systemctl" <<EOF
#!$BASH
case "\$*" in
  "--user show-environment") exit 0 ;;
  "--user is-active airlock-web")
    if [ -f "$TMP/stub/pid" ] && kill -0 "\$(cat "$TMP/stub/pid")" 2>/dev/null; then echo active; else echo inactive; exit 3; fi ;;
  "--user stop airlock-web")
    pid="\$(cat "$TMP/stub/pid")"; kill "\$pid"; rm -f "$TMP/stub/pid"
    while kill -0 "\$pid" 2>/dev/null; do sleep 0.1; done ;;
  "--user is-active "*) echo inactive; exit 3 ;;
esac
EOF
chmod +x "$TMP/stub/systemd-run" "$TMP/stub/systemctl"
webctl() { PATH="$TMP/stub:$PATH" AIRLOCK_WEB_SETTLE=1 "$AIRLOCK" web "$@"; }

# One request, HTTP/1.0 so the server closes: the response, headers and all,
# into $OUT.
get() { # path [host]
  local host="${2:-127.0.0.2:$AIRLOCK_WEB_PORT}"
  : > "$OUT"
  exec 3<>"/dev/tcp/127.0.0.2/$AIRLOCK_WEB_PORT" || return 1
  printf 'GET %s HTTP/1.0\r\nHost: %s\r\n\r\n' "$1" "$host" >&3
  tr -d '\r' <&3 > "$OUT"
  exec 3<&-
}
status_of() { head -1 "$OUT" | cut -d' ' -f2; }

A="$(setup alpha2)"
B="$(setup beta)"
DH="$AIRLOCK_DATA_HOME/ws"

# Agent work, pushed to alpha2's hub the way the hub service would land it.
git clone --quiet "$A/widget.git" "$TMP/guest" 2>/dev/null
(
  cd "$TMP/guest" || exit 1
  git checkout --quiet -b agent/fix
  printf '<script>alert(1)</script>\n' > evil.html
  git add evil.html
  git commit --quiet -m 'add <b>markup</b>'
  git push --quiet origin agent/fix
) >/dev/null 2>&1

case_begin "web start runs lighttpd sandboxed, seeing each hub read-only and nothing else"
assert_ok "starts" webctl start
assert_contains "$TMP/stub/run-args" "ProtectSystem=strict" "system read-only"
assert_contains "$TMP/stub/run-args" "ProtectHome=tmpfs" "home hidden"
assert_contains "$TMP/stub/run-args" "NoNewPrivileges=yes" "no new privileges"
assert_contains "$TMP/stub/run-args" "TemporaryFileSystem=$DH:ro" "workspaces emptied"
assert_contains "$TMP/stub/run-args" "BindReadOnlyPaths=$A/widget.git" "alpha2's hub, read-only"
assert_contains "$TMP/stub/run-args" "BindReadOnlyPaths=$B/widget.git" "beta's hub, read-only"
assert_contains "$TMP/stub/run-args" "BindReadOnlyPaths=$AIRLOCK_WEB_HOME" "its own config, read-only"
if grep -qE "^BindReadOnlyPaths=$A\$|^BindPaths=" "$TMP/stub/run-args"; then
  _fail "a workspace root, or anything writable, is bound in"; else _pass; fi
assert_contains "$AIRLOCK_WEB_HOME/lighttpd.conf" "server.bind = \"127.0.0.2\"" "not 127.0.0.1"
assert_contains "$AIRLOCK_WEB_HOME/cgitrc" "enable-http-clone=0" "no git over HTTP"
if grep -q 'filter=' "$AIRLOCK_WEB_HOME/cgitrc"; then _fail "a cgit filter is configured"; else _pass; fi
webctl status > "$OUT" 2>&1
assert_contains "$OUT" "web: active — http://127.0.0.2:$AIRLOCK_WEB_PORT/" "status says so"

case_begin "it lists the workspaces and shows their hubs"
get /
assert_eq "200" "$(status_of)" "index"
assert_contains "$OUT" "href='/alpha2/'" "alpha2 listed"
assert_contains "$OUT" "href='/beta/'" "beta listed"
get /alpha2/log/?h=agent/fix
assert_eq "200" "$(status_of)" "an agent branch's log"
assert_contains "$OUT" "add &lt;b&gt;markup&lt;/b&gt;" "the agent's subject, escaped"
get "/alpha2/diff/?id=agent/fix&id2=main"
assert_contains "$OUT" "evil.html" "the branch against the default branch"

case_begin "what the agent wrote cannot run in the browser"
get /alpha2/
assert_contains "$OUT" "Content-Security-Policy: default-src 'none'; style-src 'self' 'unsafe-inline'" "airlock's CSP"
assert_contains "$OUT" "X-Content-Type-Options: nosniff" "no sniffing"
if grep -qi '<script' "$OUT"; then _fail "a page carries a script"; else _pass; fi
get /alpha2/plain/evil.html?h=agent/fix
assert_contains "$OUT" "Content-Type: text/plain" "an agent's HTML file is plain text"
assert_contains "$OUT" "frame-ancestors 'none'" "with airlock's CSP too, not only cgit's own"
get /cgit.css
assert_eq "200" "$(status_of)" "the stylesheet"
assert_contains "$OUT" "Content-Type: text/css" "as CSS"

case_begin "no git over HTTP, and no name that is not loopback"
get /alpha2/info/refs?service=git-upload-pack
assert_eq "404" "$(status_of)" "no clone"
get /alpha2/ "evil.example:$AIRLOCK_WEB_PORT"
assert_eq "403" "$(status_of)" "a rebound name is refused"
get /alpha2/ "localhost:8080"
assert_eq "200" "$(status_of)" "a tunnel's localhost is not"

case_begin "status shows a workspace's page while the service serves it"
PATH="$TMP/stub:$PATH" "$AIRLOCK" status alpha2 > "$OUT" 2>&1
assert_contains "$OUT" "browse it     http://127.0.0.2:$AIRLOCK_WEB_PORT/alpha2/" "the URL"

case_begin "init and rm restart it, so it shows the workspaces there are"
C="$(setup gamma)"
assert_contains "$TMP/stub/run-args" "BindReadOnlyPaths=$C/widget.git" "gamma bound in"
get /
assert_contains "$OUT" "href='/gamma/'" "gamma listed"
PATH="$TMP/stub:$PATH" "$AIRLOCK" rm beta --yes >/dev/null 2>&1
if grep -qF "$B/widget.git" "$TMP/stub/run-args"; then _fail "beta is still bound"; else _pass; fi
get /
if grep -qF "href='/beta/'" "$OUT"; then _fail "beta is still listed"; else _pass; fi

case_begin "web stop stops it"
assert_ok "stops" webctl stop
webctl status > "$OUT" 2>&1
assert_contains "$OUT" "web: inactive" "status says so"
PATH="$TMP/stub:$PATH" "$AIRLOCK" status alpha2 > "$OUT" 2>&1
if grep -q "browse it" "$OUT"; then _fail "status shows a URL with nothing serving it"; else _pass; fi
