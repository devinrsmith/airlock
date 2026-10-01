# shellcheck shell=bash
# Behaviour of `airlock review` and `airlock fetch` (D6/D8/D16).

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

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
OUT="$TMP/out"

# An upstream, a developer checkout cloned from it, and a workspace seeded from
# that checkout — the real shape, so the hub inherits a usable upstream remote.
setup() { # name -> echoes the workspace root
  local name="$1"
  local up="$TMP/up-$name"
  local src="$TMP/src-$name"
  {
    git init --quiet -b main "$up"
    ( cd "$up" || exit 1
      echo one > file.txt
      git add file.txt
      git commit --quiet -m "upstream one" )
    git clone --quiet "$up" "$src"
    "$AIRLOCK" init "$name" --from-local "$src" --project widget
  } >/dev/null 2>&1
  printf '%s/%s\n' "$AIRLOCK_DATA_HOME" "$name"
}

# Stand in for the agent: commit in the clone and push to the hub. Pushes at
# the hub path directly, so origin keeps pointing at the guest path.
agent_push() { # clone hub branch message file
  ( cd "$1" || exit 1
    if git rev-parse --verify --quiet "$3" >/dev/null 2>&1; then
      git checkout --quiet "$3"
    else
      git checkout --quiet -b "$3"
    fi
    echo "$5" > "$5"
    git add "$5"
    git commit --quiet -m "$4"
    git push --quiet "$2" "HEAD:refs/heads/$3" ) >/dev/null 2>&1
}

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

# --- init records what it seeded (D16) ------------------------------------

case_begin "init records the tips it pushed as already reviewed"
WS="$(setup seeded)"
assert_file "$WS/watermarks/refs/heads/main"
assert_eq "$(git -C "$WS/work_dir/widget.git" rev-parse refs/heads/main)" \
  "$(cat "$WS/watermarks/refs/heads/main")" "watermark is the seeded tip"
assert_ok "nothing to review on a fresh workspace" run review seeded
assert_contains "$OUT" "nothing new to review" "says so"

# --- review ---------------------------------------------------------------

case_begin "a branch airlock never pushed shows as the agent's work"
WS="$(setup newbranch)"
agent_push "$WS/work_dir/widget" "$WS/work_dir/widget.git" agent/parser "teach the parser" a.txt
assert_ok "review succeeds" run review newbranch
assert_contains "$OUT" "agent/parser" "names the branch"
assert_contains "$OUT" "new branch" "identifies it as new"
assert_contains "$OUT" "teach the parser" "shows the commit subject"
assert_contains "$OUT" "1 file changed" "shows a diffstat"

case_begin "review without --accept does not move the watermark"
assert_absent "$WS/watermarks/refs/heads/agent/parser"
assert_contains "$OUT" "Accept with" "tells you how to accept"

case_begin "--accept advances the watermark and nothing else"
HUB="$WS/work_dir/widget.git"
TIP="$(git -C "$HUB" rev-parse refs/heads/agent/parser)"
assert_ok "accept succeeds" run review newbranch --accept
assert_eq "$TIP" "$(cat "$WS/watermarks/refs/heads/agent/parser")" "watermark is the tip"
assert_contains "$OUT" "Publishing stays yours" "does not pretend to publish"
assert_ok "nothing left to review" run review newbranch
assert_contains "$OUT" "nothing new to review" "quiet once accepted"

case_begin "a second push shows only what is new since the watermark"
agent_push "$WS/work_dir/widget" "$HUB" agent/parser "cover the empty case" b.txt
assert_ok "review succeeds" run review newbranch
assert_contains "$OUT" "1 new commit(s) since you last accepted" "incremental, not the whole branch"
assert_contains "$OUT" "cover the empty case" "the new commit"
if grep -qF "teach the parser" "$OUT"; then
  _fail "already-accepted commit shown again"
else
  _pass
fi

case_begin "--patch shows the diff, default shows a summary"
assert_ok "patch review" run review newbranch --patch
assert_contains "$OUT" "+b.txt" "patch body present"

case_begin "branches can be named explicitly"
WS="$(setup named)"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/one "first" one.txt
agent_push "$WS/work_dir/widget" "$HUB" agent/two "second" two.txt
assert_ok "review one branch" run review named agent/one
assert_contains "$OUT" "agent/one" "shows the named branch"
if grep -qF "agent/two" "$OUT"; then _fail "unnamed branch leaked in"; else _pass; fi

# --- the tamper path (D17) -------------------------------------------------

case_begin "a rewritten branch is refused, not quietly re-reviewed"
WS="$(setup tamper)"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/topic "agent work" x.txt
run review tamper --accept >/dev/null 2>&1
# What a guest with filesystem access to the hub can do; receive.denyNonFastForwards
# binds receive-pack only.
git -C "$HUB" update-ref refs/heads/agent/topic "$(git -C "$HUB" rev-parse refs/heads/main)"
assert_fails "review refuses" run review tamper
assert_contains "$OUT" "TAMPER" "says tamper"
assert_contains "$OUT" "history was rewritten" "explains it"
assert_contains "$OUT" "will not quietly move it forward" "refuses to advance"
assert_fails "--accept does not launder it" run review tamper --accept
assert_eq "$(git -C "$HUB" rev-parse refs/heads/main)" \
  "$(git -C "$HUB" rev-parse refs/heads/agent/topic)" "hub untouched"
# The watermark must still point at the commit that is now missing from history.
if [ "$(cat "$WS/watermarks/refs/heads/agent/topic")" = "$(git -C "$HUB" rev-parse refs/heads/agent/topic)" ]; then
  _fail "watermark was advanced despite the rewrite"
else
  _pass
fi

# --- fetch (D8) ------------------------------------------------------------

case_begin "fetch brings upstream history into the hub's namespace"
WS="$(setup fetching)"
HUB="$WS/work_dir/widget.git"
assert_ok "fetch succeeds" run fetch fetching
assert_contains "$OUT" "upstream/main" "reports the ref"
assert_ok "ref landed in refs/upstream" git -C "$HUB" rev-parse --verify refs/upstream/upstream/main

case_begin "a second fetch with no upstream change says so"
assert_ok "fetch succeeds" run fetch fetching
assert_contains "$OUT" "already up to date" "no churn"

case_begin "new upstream commits are reported with their range"
( cd "$TMP/up-fetching" || exit 1
  echo more > new.txt
  git add new.txt
  git commit --quiet -m "upstream moves on" ) >/dev/null 2>&1
assert_ok "fetch succeeds" run fetch fetching
assert_contains "$OUT" ".." "shows an old..new range"
assert_contains "$OUT" "1 ref(s) updated" "counts it"

case_begin "fetch never touches the branches under review"
assert_ok "still nothing to review" run review fetching
assert_contains "$OUT" "nothing new to review" "upstream refs are not review candidates"

case_begin "the agent can read upstream refs but has no remote to push them to"
CLONE="$WS/work_dir/widget"
assert_ok "clone fetches the namespace" \
  git -C "$CLONE" fetch --quiet "$HUB" '+refs/upstream/*:refs/remotes/upstreams/*'
assert_ok "visible read-only" git -C "$CLONE" rev-parse --verify refs/remotes/upstreams/upstream/main
assert_eq "origin" "$(git -C "$CLONE" remote)" "still exactly one remote"

case_begin "fetch refuses an unknown remote and a workspace with none"
assert_fails "unknown remote" run fetch fetching --remote nosuch
assert_contains "$OUT" "no such upstream remote" "explains"
WS="$(setup noupstream)"
git -C "$WS/work_dir/widget.git" remote remove upstream
assert_fails "no remotes configured" run fetch noupstream
assert_contains "$OUT" "no upstream remotes configured" "explains"

case_begin "both commands refuse an unknown workspace"
assert_fails "review" run review nosuchworkspace
assert_fails "fetch" run fetch nosuchworkspace

case_begin "a tamper finding shows the finding and nothing else"
# The rewrite above landed on an ancestor, so the unreviewed range came out
# empty either way. Rewriting onto unrelated work is what distinguishes
# "refuse and say so" from "refuse but still print a misleading diff".
WS="$(setup tamper2)"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/topic "real work" r.txt
run review tamper2 --accept >/dev/null 2>&1
( cd "$WS/work_dir/widget" || exit 1
  git checkout --quiet main
  git checkout --quiet -b decoy
  echo d > d.txt
  git add d.txt
  git commit --quiet -m "decoy work"
  git push --quiet "$HUB" HEAD:refs/heads/decoy ) >/dev/null 2>&1
git -C "$HUB" update-ref refs/heads/agent/topic "$(git -C "$HUB" rev-parse refs/heads/decoy)"
# Restricted to the tampered branch: `decoy` is itself legitimately new, and
# its own listing would otherwise be indistinguishable from a spurious one.
assert_fails "review refuses" run review tamper2 agent/topic
assert_contains "$OUT" "TAMPER" "says tamper"
if grep -qF "decoy work" "$OUT"; then
  _fail "printed a commit listing for the tampered branch instead of only the finding"
else
  _pass
fi

# --- regressions ----------------------------------------------------------

case_begin "a workspace with no watermarks can still be reviewed and accepted"
# What an init from before watermarking left behind. The default branch then
# has no base, and `git diff <tip>` in a bare repo means "diff the working
# tree", which aborted the whole command before anything was accepted.
WS="$(setup oldinit)"
HUB="$WS/work_dir/widget.git"
agent_push "$WS/work_dir/widget" "$HUB" agent/topic "agent work" t.txt
rm -rf "$WS/watermarks"
mkdir -p "$WS/watermarks"
assert_ok "review succeeds" run review oldinit
assert_contains "$OUT" "main" "the default branch shows as a whole history"
if grep -qF "must be run in a work tree" "$OUT"; then
  _fail "diffed against a working tree the bare hub does not have"
else
  _pass
fi
assert_ok "--patch succeeds too" run review oldinit --patch
assert_ok "accept succeeds" run review oldinit --accept
assert_file "$WS/watermarks/refs/heads/main"
assert_file "$WS/watermarks/refs/heads/agent/topic"
assert_ok "quiet afterwards" run review oldinit
assert_contains "$OUT" "nothing new to review" "accepting really took"

case_begin "a pager never swallows the accept"
if command -v script >/dev/null 2>&1 && command -v less >/dev/null 2>&1; then
  WS="$(setup paged)"
  HUB="$WS/work_dir/widget.git"
  ( cd "$WS/work_dir/widget" || exit 1
    git checkout --quiet -b agent/lots
    for i in $(seq 1 30); do
      echo "$i" > "f$i"
      git add "f$i"
      git commit --quiet -m "commit number $i"
    done
    git push --quiet "$HUB" HEAD:refs/heads/agent/lots ) >/dev/null 2>&1
  # A real terminal and a real pager, with `q` typed at it. Output longer than
  # the pty's 24 rows, so an un-neutralised pager would take the screen and the
  # confirmation would be lost behind it.
  printf 'q' | script -qec "GIT_PAGER=less $AIRLOCK review paged --accept" /dev/null > "$TMP/pty.out" 2>&1
  assert_contains "$TMP/pty.out" "accepted agent/lots" "the confirmation is visible"
  assert_file "$WS/watermarks/refs/heads/agent/lots"
  # less announces itself by switching the terminal to its own screen. If that
  # sequence is in the stream a pager ran, and everything printed after it was
  # wiped from view when the screen was restored — which is what makes an
  # accept look like it did nothing.
  if LC_ALL=C grep -q $'\x1b\[?1h' "$TMP/pty.out"; then
    _fail "a pager took the screen"
  else
    _pass
  fi
else
  skip "needs script(1) and less"
fi
