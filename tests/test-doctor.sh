# shellcheck shell=bash
# Behaviour of `airlock doctor` (§7).
#
# Every check is exercised by breaking a real workspace and watching doctor
# notice — and, where it should not repair, watching --fix leave it alone.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

# Run from the temp directory: a stray relative path in a test then lands here
# rather than in the repository (it has happened).
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

AIRLOCK="$REPO_ROOT/bin/airlock"
OUT="$TMP/doctor.out"

# A fresh workspace per case: a doctor test that shares state with the previous
# case reports the previous case's damage.
fresh() { # name -> echoes the workspace root, and nothing else
  local name="$1"
  local src="$TMP/src-$name"   # separate `local`: $name is not set yet in the first
  # Everything is muted: this runs in a command substitution, so a stray line
  # of git chatter would be captured as part of the path.
  {
    git init --quiet -b develop "$src"
    ( cd "$src" || exit 1
      echo one > file.txt
      git add file.txt
      git commit --quiet -m "initial commit" )
    "$AIRLOCK" init "$name" --from-local "$src" --project widget
  } >/dev/null 2>&1
  printf '%s/%s\n' "$AIRLOCK_DATA_HOME" "$name"
}

doctor() { # args... -> exit code, output in $OUT
  local rc=0
  "$AIRLOCK" doctor "$@" > "$OUT" 2>&1 || rc=$?
  return $rc
}

# --- a healthy workspace --------------------------------------------------

case_begin "clean workspace passes"
WS="$(fresh clean)"
assert_ok "doctor exits 0" doctor clean
assert_contains "$OUT" "0 failure(s)" "no failures"
assert_contains "$OUT" "hub HEAD -> refs/heads/develop" "reports the real HEAD"

# --- repairable drift -----------------------------------------------------

case_begin "hub guardrails are repaired"
WS="$(fresh guards)"
git -C "$WS/work_dir/widget.git" config receive.denyDeletes false
assert_fails "drift fails" doctor guards
assert_contains "$OUT" "receive.denyDeletes is not true" "names the guardrail"
assert_ok "--fix repairs" doctor guards --fix
assert_eq "true" "$(git -C "$WS/work_dir/widget.git" config --get receive.denyDeletes)" "guardrail restored"

case_begin "dangling hub HEAD is repaired from config"
WS="$(fresh head)"
git -C "$WS/work_dir/widget.git" symbolic-ref HEAD refs/heads/master
assert_fails "dangling HEAD fails" doctor head
assert_contains "$OUT" "does not exist" "explains why"
assert_ok "--fix repairs" doctor head --fix
assert_eq "refs/heads/develop" "$(git -C "$WS/work_dir/widget.git" symbolic-ref HEAD)" "HEAD restored"

case_begin "clone origin pointing at the host is repaired"
WS="$(fresh origin)"
git -C "$WS/work_dir/widget" remote set-url origin "$WS/work_dir/widget.git"
assert_fails "host-path origin fails" doctor origin
assert_contains "$OUT" "clone origin is not the guest path" "names the problem"
assert_ok "--fix repairs" doctor origin --fix
assert_eq "/work/widget.git" "$(git -C "$WS/work_dir/widget" remote get-url origin)" "origin restored"

case_begin "missing upstream refspec is repaired"
WS="$(fresh refspec)"
git -C "$WS/work_dir/widget" config --unset-all remote.origin.fetch 'upstreams'
assert_fails "missing refspec fails" doctor refspec
assert_ok "--fix repairs" doctor refspec --fix
assert_ok "refspec restored" sh -c "git -C '$WS/work_dir/widget' config --get-all remote.origin.fetch | grep -qF 'refs/remotes/upstreams'"

case_begin "hub remote with the wrong refspec is repaired"
WS="$(fresh hubremote)"
git -C "$WS/work_dir/widget.git" remote add upstream "https://example.invalid/w.git"
git -C "$WS/work_dir/widget.git" config remote.upstream.fetch '+refs/heads/*:refs/remotes/upstream/*'
assert_fails "wrong refspec fails" doctor hubremote
assert_contains "$OUT" "wrong fetch refspec" "names the problem"
assert_ok "--fix repairs" doctor hubremote --fix
assert_eq "+refs/heads/*:refs/upstream/upstream/*" \
  "$(git -C "$WS/work_dir/widget.git" config --get remote.upstream.fetch)" "refspec restored"

case_begin "missing emitted context file is regenerated"
WS="$(fresh ctx)"
rm "$WS/work_dir/CLAUDE.md"
assert_fails "missing context file fails" doctor ctx
assert_ok "--fix regenerates" doctor ctx --fix
assert_file "$WS/work_dir/CLAUDE.md"
assert_contains "$WS/work_dir/CLAUDE.md" "agent/<topic>" "regenerated content is right"

case_begin "missing watermarks directory is recreated"
WS="$(fresh wmdir)"
rmdir "$WS/watermarks"
assert_fails "missing watermarks fails" doctor wmdir
assert_ok "--fix recreates" doctor wmdir --fix
assert_dir "$WS/watermarks"

case_begin "stale lock is cleared, live lock is left alone"
WS="$(fresh lock)"
echo 999999 > "$WS/lock"          # a pid that is not running
assert_fails "stale lock fails" doctor lock
assert_contains "$OUT" "stale lock" "names it as stale"
assert_ok "--fix clears it" doctor lock --fix
assert_absent "$WS/lock"
echo $$ > "$WS/lock"              # this test's own shell: definitely alive
assert_ok "live lock is not a failure" doctor lock
assert_contains "$OUT" "a run holds the lock" "reported as held"
assert_file "$WS/lock"
rm -f "$WS/lock"

# --- findings doctor must NOT repair --------------------------------------

case_begin "a symlinked agent_home is reported and never repaired"
WS="$(fresh symlink)"
rmdir "$WS/agent_home"
ln -s "$TMP/elsewhere" "$WS/agent_home"
mkdir -p "$TMP/elsewhere"
assert_fails "symlink fails" doctor symlink
assert_contains "$OUT" "agent_home is a symlink" "names it"
assert_contains "$OUT" "outside the workspace" "explains the consequence"
assert_fails "--fix does not silence it" doctor symlink --fix
assert_ok "still a symlink" test -L "$WS/agent_home"

case_begin "airlock state inside the share is reported and never repaired"
WS="$(fresh stray)"
cp "$WS/config" "$WS/work_dir/config"
assert_fails "stray state fails" doctor stray
assert_contains "$OUT" "work_dir/config is inside the share" "names the file"
assert_fails "--fix does not remove it" doctor stray --fix
assert_file "$WS/work_dir/config"

# --- the security-relevant check (D16/D17) --------------------------------

case_begin "a watermark whose commit is still reachable is fine"
WS="$(fresh wmok)"
HUB="$WS/work_dir/widget.git"
SHA="$(git -C "$HUB" rev-parse refs/heads/develop)"
mkdir -p "$WS/watermarks/refs/heads"
echo "$SHA" > "$WS/watermarks/refs/heads/develop"
assert_ok "reachable watermark passes" doctor wmok
assert_contains "$OUT" "1 watermarked commit(s) still reachable" "counted"

case_begin "a rewritten hub is reported as tampering, loudly, and never repaired"
WS="$(fresh wmtamper)"
HUB="$WS/work_dir/widget.git"
CLONE="$WS/work_dir/widget"
# Push straight at the hub path rather than rewriting origin: origin must stay
# the guest path, or doctor would (correctly) fail on that instead.
( cd "$CLONE" || exit 1
  git checkout --quiet -b agent/topic
  echo two > other.txt
  git add other.txt
  git commit --quiet -m "agent work"
  git push --quiet "$HUB" HEAD:refs/heads/agent/topic ) >/dev/null 2>&1
SHA="$(git -C "$HUB" rev-parse refs/heads/agent/topic)"
mkdir -p "$WS/watermarks/refs/heads/agent"
echo "$SHA" > "$WS/watermarks/refs/heads/agent/topic"
assert_ok "reviewed state is healthy" doctor wmtamper
# What an agent with filesystem access to the hub can do, which the receive.*
# guardrails do not prevent (D17).
git -C "$HUB" update-ref refs/heads/agent/topic "$(git -C "$HUB" rev-parse refs/heads/develop)"
assert_fails "tamper fails" doctor wmtamper
assert_contains "$OUT" "TAMPER" "says tamper"
assert_contains "$OUT" "history was rewritten" "explains it"
assert_fails "--fix refuses to make it go away" doctor wmtamper --fix
assert_contains "$OUT" "TAMPER" "still reported after --fix"

case_begin "a watermark whose object is gone entirely is tampering too"
WS="$(fresh wmgone)"
mkdir -p "$WS/watermarks/refs/heads"
echo "0000000000000000000000000000000000000000" > "$WS/watermarks/refs/heads/develop"
assert_fails "missing object fails" doctor wmgone
assert_contains "$OUT" "TAMPER" "says tamper"

# --- crashed-run leftovers ------------------------------------------------

case_begin "a leftover store disk warns without failing"
WS="$(fresh leftover)"
mkdir -p "$WS/agent_home-store"
assert_ok "warning does not fail the run" doctor leftover
assert_contains "$OUT" "did not exit cleanly" "explains the leftover"

# --- host and multi-workspace modes ---------------------------------------

case_begin "no argument checks the host and every workspace"
assert_ok "host section present" sh -c "'$AIRLOCK' doctor > '$OUT' 2>&1 || true; grep -q '^host' '$OUT'"
assert_contains "$OUT" "workspace clean" "includes a workspace"

case_begin "unknown workspace is refused"
assert_fails "unknown name" doctor nosuchworkspace
