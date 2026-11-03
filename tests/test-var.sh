# shellcheck shell=bash
# `airlock var` and its forwarding at launch (D37).

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
export AIRLOCK_CONFIG="$TMP/airlock-config"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
cat > "$GIT_CONFIG_GLOBAL" <<'EOF2'
[user]
	name = Test Developer
	email = dev@example.invalid
[init]
	defaultBranch = main
EOF2

AIRLOCK="$REPO_ROOT/bin/airlock"
OUT="$TMP/out"
run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

mkdir -p "$TMP/substrate"
echo "{ outputs = _: { }; }" > "$TMP/substrate/flake.nix"
export AIRLOCK_SUBSTRATE="$TMP/substrate"
export AIRLOCK_NIXPKGS="github:NixOS/nixpkgs/0000000000000000000000000000000000000000"

case_begin "set, get, ls and rm"
assert_ok "set with a value" run var set TOKEN_A s3cret
assert_ok "set from stdin" bash -c "printf 'from-stdin\n' | '$AIRLOCK' var set TOKEN_B"
assert_eq "s3cret" "$("$AIRLOCK" var get TOKEN_A)" "get returns the value"
assert_eq "from-stdin" "$("$AIRLOCK" var get TOKEN_B)" "stdin's trailing newline is not part of it"
assert_eq "TOKEN_A
TOKEN_B" "$("$AIRLOCK" var ls)" "ls lists names"
assert_ok "ls" run var ls
if grep -q 's3cret' "$OUT"; then _fail "ls printed a value"; else _pass; fi
assert_ok "set replaces in place" run var set TOKEN_A rotated
assert_eq "rotated" "$("$AIRLOCK" var get TOKEN_A)" "new value"
assert_ok "rm" run var rm TOKEN_B
assert_fails "get after rm" run var get TOKEN_B
assert_fails "rm of a missing one" run var rm TOKEN_B

case_begin "names and values are checked"
assert_fails "bad name" run var set 'bad-name' x
assert_fails "leading digit" run var set 1X x
assert_fails "empty value" run var set EMPTY ''

case_begin "secret and description are metadata, never the value"
assert_ok "set with metadata" run var set META_A v1 --secret --description "a token, for tests"
assert_eq "v1" "$("$AIRLOCK" var get META_A)" "get still prints a secret"
assert_ok "ls --json" run var ls --json
assert_contains "$OUT" '"name":"META_A","secret":true,"description":"a token, for tests"' "json carries the metadata"
if grep -q 'v1' "$OUT"; then _fail "json carried a value"; else _pass; fi
assert_ok "ls -l" run var ls -l
assert_contains "$OUT" "META_A	secret	a token, for tests" "long listing"
assert_ok "rotate keeps metadata" run var set META_A v2
assert_ok "ls --json again" run var ls --json
assert_contains "$OUT" '"name":"META_A","secret":true,"description":"a token, for tests"' "still secret and described"
assert_ok "edit clears secret" run var edit META_A --no-secret
assert_ok "ls --json after edit" run var ls --json
assert_contains "$OUT" '"name":"META_A","secret":false,"description":"a token, for tests"' "secret cleared, value untouched"
assert_eq "v2" "$("$AIRLOCK" var get META_A)" "edit left the value"
assert_ok "clear description" run var edit META_A --description ''
assert_ok "ls --json plain" run var ls --json
assert_contains "$OUT" '"name":"META_A","secret":false,"description":null' "absent is null"
assert_fails "edit of a missing one" run var edit NOPE --secret
assert_fails "multi-line description" run var set META_B x --description $'a\nb'
assert_ok "set --secret from stdin" bash -c "printf 'sv\n' | '$AIRLOCK' var set META_C --secret"
assert_ok "rm removes metadata" run var rm META_C
assert_ok "re-set after rm is not secret" run var set META_C again
assert_ok "ls --json after re-set" run var ls --json
assert_contains "$OUT" '"name":"META_C","secret":false' "no stale metadata"
assert_ok "cleanup" run var rm META_A META_C
assert_eq "TOKEN_A" "$("$AIRLOCK" var ls)" "only TOKEN_A remains"

case_begin "the files are private"
assert_eq "700" "$(stat -c %a "$AIRLOCK_DATA_HOME/vars/.meta")" "meta directory mode" 
assert_eq "700" "$(stat -c %a "$AIRLOCK_DATA_HOME/vars")" "directory mode"
assert_eq "600" "$(stat -c %a "$AIRLOCK_DATA_HOME/vars/TOKEN_A")" "file mode"
assert_eq "TOKEN_A" "$(cd "$AIRLOCK_DATA_HOME/vars" && echo *)" "no temporary file was left"

case_begin "a forwarded name takes its stored value at launch, out of the plan and the lock"
{
  git init --quiet -b main "$TMP/src"
  ( cd "$TMP/src" || exit 1
    echo one > f && git add f && git commit --quiet -m init )
  "$AIRLOCK" init demo --from-local "$TMP/src" --project widget
  "$AIRLOCK" task new demo t
} >/dev/null 2>&1
WS="$AIRLOCK_DATA_HOME/ws/demo"
"$AIRLOCK" config --workspace demo env_forward "TOKEN_A,HOSTONLY,LIT=x" >/dev/null 2>&1
cat > "$TMP/stub" <<EOF2
#!$BASH
env | grep -E '^(TOKEN_A|HOSTONLY|LIT)=' | sort > "$TMP/stub.env"
cat "\$AIRLOCK_TEST_WS/lock" > "$TMP/stub.lock"
EOF2
chmod +x "$TMP/stub"
export AIRLOCK_TEST_WS="$WS/tasks/t"
TOKEN_A=host-value HOSTONLY=host-only AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run" run run demo t
assert_contains "$TMP/stub.env" "TOKEN_A=rotated" "the stored value wins over the host's"
assert_contains "$TMP/stub.env" "HOSTONLY=host-only" "an unstored name still comes from the host"
if grep -q 'LIT=' "$TMP/stub.env"; then _fail "a literal assignment was handled as a variable"; else _pass; fi
if grep -q 'rotated' "$TMP/stub.lock"; then _fail "the value reached the lock"; else _pass; fi

case_begin "dry run shows names, not values"
assert_ok "dry run" run run demo t --dry-run
assert_contains "$OUT" "EXTRA_ENV=TOKEN_A,HOSTONLY,LIT=x" "the names"
if grep -q 'rotated' "$OUT"; then _fail "dry run printed a value"; else _pass; fi

case_begin "changing a value needs no config change"
"$AIRLOCK" var set TOKEN_A second >/dev/null 2>&1
AIRLOCK_LAUNCHER="$TMP/stub" assert_ok "run" run run demo t
assert_contains "$TMP/stub.env" "TOKEN_A=second" "the next launch sees it"
