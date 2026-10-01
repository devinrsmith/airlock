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

WS="$AIRLOCK_DATA_HOME/demo"
HUB="$WS/work_dir/widget.git"
CLONE="$WS/work_dir/widget"

assert_dir "$WS/work_dir"
assert_symlink_not "$WS/agent_home"
assert_dir "$WS/watermarks"
assert_file "$WS/config"
assert_dir "$HUB"
assert_dir "$CLONE"

case_begin "workspace root is not itself a share (D3)"
# Anything the guest must not see has to live outside work_dir/.
assert_absent "$WS/work_dir/config"
assert_absent "$WS/work_dir/watermarks"

case_begin "hub HEAD points at the seeded branch"
# git init --bare would leave this at refs/heads/master and the clone would
# come up with no checkout at all.
assert_eq "refs/heads/develop" "$(git -C "$HUB" symbolic-ref HEAD)" "hub HEAD"
assert_file "$CLONE/file.txt"

case_begin "hub guardrails are set (D17: anti-accident)"
assert_eq "true" "$(git -C "$HUB" config --get receive.denyNonFastForwards)" "denyNonFastForwards"
assert_eq "true" "$(git -C "$HUB" config --get receive.denyDeletes)" "denyDeletes"

case_begin "tags are seeded too"
assert_eq "v0.1.0" "$(git -C "$HUB" tag)" "hub tags"

case_begin "clone origin is the guest path, not the host path"
assert_eq "/work/widget.git" "$(git -C "$CLONE" remote get-url origin)" "origin url"

case_begin "clone can read upstream refs but has no remote to push them to (D8)"
assert_eq "+refs/upstream/*:refs/remotes/upstreams/*" \
  "$(git -C "$CLONE" config --get-all remote.origin.fetch | tail -1)" "upstream refspec"
assert_eq "origin" "$(git -C "$CLONE" remote)" "clone has exactly one remote"

case_begin "hub inherits the source checkout's origin as an upstream"
assert_eq "git@example.invalid:acme/widget.git" \
  "$(git -C "$HUB" remote get-url upstream)" "inherited upstream url"
assert_eq "+refs/heads/*:refs/upstream/upstream/*" \
  "$(git -C "$HUB" config --get remote.upstream.fetch)" "hub upstream refspec"

case_begin "agent has a commit identity"
assert_eq "Test Developer" "$(git -C "$CLONE" config --get user.name)" "clone user.name"

case_begin "context file is emitted at the share root, outside the repo (D14)"
assert_file "$WS/work_dir/CLAUDE.md"
assert_absent "$CLONE/CLAUDE.md"
assert_contains "$WS/work_dir/CLAUDE.md" "agent/<topic>" "branch convention documented"
assert_contains "$WS/work_dir/CLAUDE.md" "/work/widget.git" "hub path documented"

case_begin "config records the workspace's policy"
assert_contains "$WS/config" "project        = widget" "project"
assert_contains "$WS/config" "flavor         = claude" "flavor"
assert_contains "$WS/config" "default_branch = develop" "default branch"
assert_contains "$WS/config" "prompts        = bypass" "D12 default"
assert_contains "$WS/config" "devshell       = off" "D18 default"

# --- the agent's round trip ----------------------------------------------

case_begin "agent can push a branch to the hub"
git -C "$CLONE" remote set-url origin "$HUB"   # stand in for the guest's /work path
( cd "$CLONE" || exit 1
  git checkout --quiet -b agent/topic
  echo two > other.txt
  git add other.txt
  git commit --quiet -m "agent work" ) >/dev/null 2>&1
assert_ok "push agent branch" git -C "$CLONE" push --quiet origin agent/topic
assert_ok "branch is in the hub" git -C "$HUB" rev-parse --verify refs/heads/agent/topic

case_begin "hub refuses a rewrite and a deletion over push (D17)"
( cd "$CLONE" && git commit --quiet --amend -m "amended" ) >/dev/null 2>&1
assert_fails "force push refused" git -C "$CLONE" push --force origin agent/topic
assert_fails "deletion refused"   git -C "$CLONE" push origin :agent/topic

# --- seeding from a remote -----------------------------------------------

case_begin "init --from-remote"
git init --quiet --bare -b trunk "$TMP/remote.git"
make_source_repo "$TMP/remote-src" main
( cd "$TMP/remote-src" || exit 1
  git branch --quiet -m main trunk
  git push --quiet "$TMP/remote.git" trunk ) >/dev/null 2>&1
assert_ok "init from remote" "$AIRLOCK" init fromremote --from-remote "$TMP/remote.git"

RWS="$AIRLOCK_DATA_HOME/fromremote"
RHUB="$RWS/work_dir/remote.git"
case_begin "default branch comes from the remote's advertised HEAD"
# The remote's default is `trunk`, not `main`: init must not assume.
assert_eq "refs/heads/trunk" "$(git -C "$RHUB" symbolic-ref HEAD)" "hub HEAD"
assert_file "$RWS/work_dir/remote/file.txt"
assert_contains "$RWS/config" "default_branch = trunk" "config default branch"
assert_eq "$TMP/remote.git" "$(git -C "$RHUB" remote get-url upstream)" "upstream url"

case_begin "upstream refs reach the clone read-only (D8, end to end)"
( cd "$TMP/remote-src" || exit 1
  echo three > upstream-only.txt
  git add upstream-only.txt
  git commit --quiet -m "upstream moves on"
  git push --quiet "$TMP/remote.git" trunk ) >/dev/null 2>&1
assert_ok "hub fetches upstream" git -C "$RHUB" fetch --quiet upstream
assert_ok "upstream ref lands in the hub namespace" \
  git -C "$RHUB" rev-parse --verify refs/upstream/upstream/trunk
RCLONE="$RWS/work_dir/remote"
git -C "$RCLONE" remote set-url origin "$RHUB"
assert_ok "clone fetches it" git -C "$RCLONE" fetch --quiet origin
assert_ok "visible as a remote-tracking ref" \
  git -C "$RCLONE" rev-parse --verify refs/remotes/upstreams/upstream/trunk

# --- flavors --------------------------------------------------------------

case_begin "flavor selects the context filename (D11/D14)"
assert_ok "init codex workspace" "$AIRLOCK" init cx --from-local "$TMP/src" --project widget --flavor codex
assert_file "$AIRLOCK_DATA_HOME/cx/work_dir/AGENTS.md"
assert_absent "$AIRLOCK_DATA_HOME/cx/work_dir/CLAUDE.md"

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
assert_absent "$AIRLOCK_DATA_HOME/leftovers"

case_begin "detached HEAD is refused with a usable message"
git -C "$TMP/src" checkout --quiet --detach HEAD
assert_fails "detached HEAD refused" "$AIRLOCK" init detached --from-local "$TMP/src"
assert_absent "$AIRLOCK_DATA_HOME/detached"

case_begin "--branch decides what the agent starts on"
# Which branch the clone is checked out at is also what a host-eval dev shell
# gets evaluated from (D18), so this is how you say "work against this branch,
# with this branch's requirements".
make_source_repo "$TMP/multi" develop
( cd "$TMP/multi" || exit 1
  git checkout --quiet -b feature/other
  echo marker > marker.txt
  git add marker.txt
  git commit --quiet -m "on the feature branch"
  git checkout --quiet develop ) >/dev/null 2>&1

assert_ok "default follows the source" "$AIRLOCK" init br-default --from-local "$TMP/multi" --project widget
assert_eq "develop" \
  "$(git -C "$AIRLOCK_DATA_HOME/br-default/work_dir/widget" symbolic-ref --short HEAD)" "the source's branch"

assert_ok "--branch overrides" \
  "$AIRLOCK" init br-chosen --from-local "$TMP/multi" --project widget --branch feature/other
assert_eq "feature/other" \
  "$(git -C "$AIRLOCK_DATA_HOME/br-chosen/work_dir/widget" symbolic-ref --short HEAD)" "the chosen branch"
assert_file "$AIRLOCK_DATA_HOME/br-chosen/work_dir/widget/marker.txt"
assert_eq "refs/heads/feature/other" \
  "$(git -C "$AIRLOCK_DATA_HOME/br-chosen/work_dir/widget.git" symbolic-ref HEAD)" "hub HEAD follows too"
assert_contains "$AIRLOCK_DATA_HOME/br-chosen/config" "default_branch = feature/other" \
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
assert_absent "$AIRLOCK_DATA_HOME/br-missing"
