# shellcheck shell=bash
# Behaviour of `airlock init` (§4, D3/D4/D8/D11/D14).
#
# Everything here runs against real git repositories in a temp directory. No VM
# is involved, which is the point: init is git plumbing.

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

# A source checkout to seed from, standing in for the developer's own repo.
make_source_repo() { # path branch [remote-url]
  local path="$1" branch="$2" remote="${3-}"
  # Deliberately not `main` anywhere it can be helped: a hub HEAD bug hides
  # behind a seed branch that happens to match init.defaultBranch.
  git init --quiet -b "$branch" "$path"
  ( cd "$path" || exit 1
    echo one > file.txt
    git add file.txt
    git commit --quiet -m "initial commit"
    git tag v0.1.0
    [ -z "$remote" ] || git remote add origin "$remote"
  )
}

# --- seeding from a local checkout ---------------------------------------

case_begin "init --from-local"
make_source_repo "$TMP/src" develop "git@example.invalid:acme/widget.git"
assert_ok "init succeeds" "$AIRLOCK" init demo --from-local "$TMP/src" --project widget

WS="$AIRLOCK_DATA_HOME/ws/demo"
HUB="$WS/widget.git"
REPO="$WS/work_dir/.repo"

assert_dir "$WS/work_dir"
assert_absent "$WS/agent_home"   # each task has its own (D28)
assert_absent "$WS/watermarks"   # airlock keeps no review state (D16)
assert_file "$WS/config"
assert_dir "$HUB"
assert_dir "$REPO"
assert_eq "true" "$(git -C "$REPO" rev-parse --is-bare-repository)" "the worktrees' repository is bare"
assert_absent "$WS/work_dir/widget"   # no checkout nobody works in (D26)
assert_eq "" "$(git -C "$REPO" for-each-ref refs/heads/)" "and has no branches of its own"

case_begin "workspace root is not itself a share (D3)"
# Anything the guest must not see has to live outside work_dir/.
assert_absent "$WS/work_dir/config"

case_begin "hub HEAD points at the seeded branch"
# git init --bare would leave this at refs/heads/master, and a clone of the
# hub would come up with no checkout at all.
assert_eq "refs/heads/develop" "$(git -C "$HUB" symbolic-ref HEAD)" "hub HEAD"
assert_ok "the repository sees it" git -C "$REPO" rev-parse --verify --quiet refs/remotes/origin/develop

case_begin "hub guardrails are set (D17: anti-accident)"
assert_eq "true" "$(git -C "$HUB" config --get receive.denyNonFastForwards)" "denyNonFastForwards"
assert_eq "true" "$(git -C "$HUB" config --get receive.denyDeletes)" "denyDeletes"

case_begin "tags are seeded too"
assert_eq "v0.1.0" "$(git -C "$HUB" tag)" "hub tags"

case_begin "the repository's origin is the hub, relative to a worktree"
# Relative, so it names the hub from the guest and from the host alike.
assert_eq "../../../widget.git" "$(git -C "$REPO" remote get-url origin)" "origin url"

case_begin "the repository can read upstream refs but has no remote to push them to (D8)"
assert_eq "+refs/upstream/*:refs/remotes/upstreams/*" \
  "$(git -C "$REPO" config --get-all remote.origin.fetch | tail -1)" "upstream refspec"
assert_eq "origin" "$(git -C "$REPO" remote)" "exactly one remote"

case_begin "hub inherits the source checkout's origin as an upstream"
assert_eq "git@example.invalid:acme/widget.git" \
  "$(git -C "$HUB" remote get-url upstream)" "inherited upstream url"
assert_eq "+refs/heads/*:refs/upstream/upstream/*" \
  "$(git -C "$HUB" config --get remote.upstream.fetch)" "hub upstream refspec"

case_begin "agent has a commit identity"
assert_eq "Test Developer" "$(git -C "$REPO" config --get user.name)" "user.name"

case_begin "context file is emitted at the share root, outside the repo (D14)"
assert_file "$WS/work_dir/CLAUDE.md"
assert_contains "$WS/work_dir/CLAUDE.md" "agent/<task>" "branch convention documented"
assert_contains "$WS/work_dir/CLAUDE.md" "is your worktree's \`origin\`, reached over SSH" "the hub documented as origin"

case_begin "config records the workspace's policy"
assert_contains "$WS/config" "project        = widget" "project"
assert_contains "$WS/config" "flavor         = claude" "flavor"
assert_contains "$WS/config" "default_branch = develop" "default branch"
assert_contains "$WS/config" "prompts        = bypass" "D12 default"
assert_contains "$WS/config" "devshell       = off" "D18 default"

# --- the agent's round trip ----------------------------------------------

case_begin "a task's agent can push its branch to the hub"
"$AIRLOCK" task new demo topic >/dev/null 2>&1
WT="$WS/work_dir/tasks/topic"
# No stand-in for the guest's /work: the relative origin resolves here too,
# so the developer can run from the host what an agent runs.
assert_ok "fetch from the host, as the agent would" git -C "$WT" fetch --quiet origin
( cd "$WT" || exit 1
  echo two > other.txt
  git add other.txt
  git commit --quiet -m "agent work" ) >/dev/null 2>&1
assert_ok "push agent branch" git -C "$WT" push --quiet origin agent/topic
assert_ok "branch is in the hub" git -C "$HUB" rev-parse --verify refs/heads/agent/topic

case_begin "hub refuses a rewrite and a deletion over push (D17)"
( cd "$WT" && git commit --quiet --amend -m "amended" ) >/dev/null 2>&1
assert_fails "force push refused" git -C "$WT" push --force origin agent/topic
assert_fails "deletion refused"   git -C "$WT" push origin :agent/topic

# --- seeding from a remote -----------------------------------------------

case_begin "init --from-remote"
git init --quiet --bare -b trunk "$TMP/remote.git"
make_source_repo "$TMP/remote-src" main
( cd "$TMP/remote-src" || exit 1
  git branch --quiet -m main trunk
  git push --quiet "$TMP/remote.git" trunk ) >/dev/null 2>&1
assert_ok "init from remote" "$AIRLOCK" init fromremote --from-remote "$TMP/remote.git"

RWS="$AIRLOCK_DATA_HOME/ws/fromremote"
RHUB="$RWS/remote.git"
case_begin "default branch comes from the remote's advertised HEAD"
# The remote's default is `trunk`, not `main`: init must not assume.
assert_eq "refs/heads/trunk" "$(git -C "$RHUB" symbolic-ref HEAD)" "hub HEAD"
assert_ok "the repository sees it" git -C "$RWS/work_dir/.repo" rev-parse --verify --quiet refs/remotes/origin/trunk
assert_contains "$RWS/config" "default_branch = trunk" "config default branch"
assert_eq "$TMP/remote.git" "$(git -C "$RHUB" remote get-url upstream)" "upstream url"

case_begin "upstream refs reach the repository read-only (D8, end to end)"
( cd "$TMP/remote-src" || exit 1
  echo three > upstream-only.txt
  git add upstream-only.txt
  git commit --quiet -m "upstream moves on"
  git push --quiet "$TMP/remote.git" trunk ) >/dev/null 2>&1
assert_ok "hub fetches upstream" git -C "$RHUB" fetch --quiet upstream
assert_ok "upstream ref lands in the hub namespace" \
  git -C "$RHUB" rev-parse --verify refs/upstream/upstream/trunk
RREPO="$RWS/work_dir/.repo"
git -C "$RREPO" remote set-url origin "$RHUB"
assert_ok "the repository fetches it" git -C "$RREPO" fetch --quiet origin
assert_ok "visible as a remote-tracking ref" \
  git -C "$RREPO" rev-parse --verify refs/remotes/upstreams/upstream/trunk

# --- saying what it is doing ------------------------------------------------

case_begin "init says what each slow step is doing"
OUT_STEPS="$TMP/steps"
"$AIRLOCK" init steps --from-remote "$TMP/remote.git" > "$OUT_STEPS" 2>&1
assert_contains "$OUT_STEPS" "asking $TMP/remote.git for its default branch" "the network question"
assert_contains "$OUT_STEPS" "fetching $TMP/remote.git's branches and tags into the hub" "the fetch"
assert_contains "$OUT_STEPS" "setting up the repository the tasks' worktrees share" "the repository"
"$AIRLOCK" init steps-local --from-local "$TMP/remote-src" --project widget > "$OUT_STEPS" 2>&1
assert_contains "$OUT_STEPS" "copying $TMP/remote-src's branches and tags into the hub" "a local source's copy"
# With no terminal, git keeps quiet: its meter is for a person watching.
if grep -q "objects:" "$OUT_STEPS"; then _fail "git progress with no terminal"; else _pass; fi

case_begin "at a terminal, git shows its progress, but not a line per ref"
if command -v script >/dev/null 2>&1; then
  script -qec "\"$AIRLOCK\" init steps-tty --from-local \"$TMP/remote-src\" --project widget" /dev/null \
    > "$OUT_STEPS" 2>&1 < /dev/null
  assert_contains "$OUT_STEPS" "Writing objects" "the meter"
  if grep -q -- "->" "$OUT_STEPS"; then _fail "listed refs: $(grep -m1 -- "->" "$OUT_STEPS")"; else _pass; fi
else
  skip "script(1) is not on PATH"
fi

# --- flavors --------------------------------------------------------------

case_begin "flavor selects the context filename (D11/D14)"
assert_ok "init codex workspace" "$AIRLOCK" init cx --from-local "$TMP/src" --project widget --flavor codex
assert_file "$AIRLOCK_DATA_HOME/ws/cx/work_dir/AGENTS.md"
assert_absent "$AIRLOCK_DATA_HOME/ws/cx/work_dir/CLAUDE.md"

# --- refusals and cleanup -------------------------------------------------

case_begin "argument validation"
assert_fails "existing workspace refused"  "$AIRLOCK" init demo --from-local "$TMP/src"
assert_fails "both sources refused"        "$AIRLOCK" init x --from-local "$TMP/src" --from-remote "$TMP/remote.git"
assert_fails "no source refused"           "$AIRLOCK" init x
assert_fails "unknown flavor refused"      "$AIRLOCK" init x --from-local "$TMP/src" --flavor emacs
assert_fails "path traversal refused"      "$AIRLOCK" init ../escape --from-local "$TMP/src"
assert_fails "non-repo source refused"     "$AIRLOCK" init x --from-local "$TMP"
assert_fails "unknown option refused"      "$AIRLOCK" init x --from-local "$TMP/src" --nope

case_begin "a failed init leaves nothing behind"
# A half-built workspace would make init look non-idempotent and leave doctor
# diagnosing our own mess.
git init --quiet -b main "$TMP/empty"
assert_fails "empty repo refused" "$AIRLOCK" init leftovers --from-local "$TMP/empty"
assert_absent "$AIRLOCK_DATA_HOME/ws/leftovers"

case_begin "a git step failing mid-init cleans up without a trap error"
# The shape of a real failure: a git step failed after the workspace was
# begun (git-lfs's smudge filter, then), init failed under set -e, and its EXIT
# trap then died on `root: unbound variable` because the function's locals were
# already gone. Here the seeding push fails, refused the file transport.
make_source_repo "$TMP/filtered" main
if out="$(GIT_ALLOW_PROTOCOL=https "$AIRLOCK" init smudged --from-local "$TMP/filtered" 2>&1)"; then
  _fail "init with a failing push succeeded"
else
  _pass
fi
assert_absent "$AIRLOCK_DATA_HOME/ws/smudged"
case "$out" in
  *"unbound variable"*) _fail "trap error leaked: $out" ;;
  *) _pass ;;
esac

case_begin "detached HEAD is refused with a usable message"
git -C "$TMP/src" checkout --quiet --detach HEAD
assert_fails "detached HEAD refused" "$AIRLOCK" init detached --from-local "$TMP/src"
assert_absent "$AIRLOCK_DATA_HOME/ws/detached"

case_begin "--branch decides what tasks start from"
# Which branch a task starts from is also what a host-eval dev shell gets
# evaluated from (D18), so this is how you say "work against this branch, with
# this branch's requirements".
make_source_repo "$TMP/multi" develop
( cd "$TMP/multi" || exit 1
  git checkout --quiet -b feature/other
  echo marker > marker.txt
  git add marker.txt
  git commit --quiet -m "on the feature branch"
  git checkout --quiet develop ) >/dev/null 2>&1

assert_ok "default follows the source" "$AIRLOCK" init br-default --from-local "$TMP/multi" --project widget
assert_contains "$AIRLOCK_DATA_HOME/ws/br-default/config" "default_branch = develop" "the source's branch"

assert_ok "--branch overrides" \
  "$AIRLOCK" init br-chosen --from-local "$TMP/multi" --project widget --branch feature/other
"$AIRLOCK" task new br-chosen t >/dev/null 2>&1
assert_file "$AIRLOCK_DATA_HOME/ws/br-chosen/work_dir/tasks/t/marker.txt"
assert_eq "refs/heads/feature/other" \
  "$(git -C "$AIRLOCK_DATA_HOME/ws/br-chosen/widget.git" symbolic-ref HEAD)" "hub HEAD follows too"
assert_contains "$AIRLOCK_DATA_HOME/ws/br-chosen/config" "default_branch = feature/other" \
  "and so does the review baseline"

case_begin "a branch the hub does not have names the ones it does"
OUT_BR="$TMP/branch-err"
if "$AIRLOCK" init br-missing --from-local "$TMP/multi" --project widget --branch nope > "$OUT_BR" 2>&1; then
  _fail "accepted a missing branch"
else
  _pass
fi
assert_contains "$OUT_BR" "no branch 'nope'" "names what was asked for"
assert_contains "$OUT_BR" "feature/other" "and lists what is there"
assert_absent "$AIRLOCK_DATA_HOME/ws/br-missing"
