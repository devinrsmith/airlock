# shellcheck shell=bash
# Host-side git on work_dir (D34). Everything there is the agent's to write, so
# the agent can plant what makes git start a program: core.fsmonitor and a
# filter driver in .repo's config, hooks in .repo/hooks, attributes naming the
# driver on a branch it pushed. Each trap here, if it runs, marks that it ran,
# then tries to write outside work_dir and to read a file outside it.
#
# Two layers, tested apart: airlock's overrides keep every trap from running at
# all; bubblewrap confines one the overrides do not know about. A control run
# with plain git shows each trap is armed, so "did not run" means something.

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
run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }

if [ -z "${AIRLOCK_BWRAP:-}" ] \
   || ! "$AIRLOCK_BWRAP" --unshare-all --ro-bind / / -- true >/dev/null 2>&1; then
  case_begin "sandbox"
  skip "no bubblewrap that can make namespaces here (AIRLOCK_BWRAP)"
  return 0   # sourced by run-tests.sh
fi

echo "host secret" > "$TMP/secret"
git init --quiet -b main "$TMP/src"
( cd "$TMP/src" && echo one > file.txt && git add file.txt && git commit --quiet -m one )
"$AIRLOCK" init demo --from-local "$TMP/src" --project widget >/dev/null 2>&1
"$AIRLOCK" task new demo t >/dev/null 2>&1
W="$AIRLOCK_DATA_HOME/demo"; WD="$W/work_dir"; R="$WD/.repo"; T="$WD/tasks/t"; HUB="$W/widget.git"

TRAPS="fsmonitor filter reference-transaction post-checkout"
# The trap programs live inside work_dir, where the agent would put them.
mkdir -p "$WD/.traps"
for n in $TRAPS; do
  printf '#!%s\necho ran > %q\necho pwned > %q 2>/dev/null\ncat %q > %q 2>/dev/null\nexit 0\n' \
    "$BASH" "$WD/.ran-$n" "$TMP/escaped-$n" "$TMP/secret" "$WD/.stolen-$n" > "$WD/.traps/$n"
  chmod +x "$WD/.traps/$n"
done
# What the agent pushes: attributes that send *.txt through its filter. Made
# with plain git before the traps are armed, as the agent would in the guest.
echo '*.txt filter=evil' > "$T/.gitattributes"
echo data > "$T/x.txt"
git -C "$T" add .gitattributes x.txt
git -C "$T" -c filter.evil.clean=cat commit --quiet -m attributes
git -C "$T" push --quiet "$HUB" HEAD:refs/heads/agent/evil

arm() {
  git -C "$R" config core.fsmonitor "$WD/.traps/fsmonitor"
  git -C "$R" config filter.evil.clean "$WD/.traps/filter"
  git -C "$R" config filter.evil.smudge "$WD/.traps/filter"
  git -C "$R" config filter.evil.required true
  cp "$WD/.traps/reference-transaction" "$WD/.traps/post-checkout" "$R/hooks/"
}
reset_marks() { rm -f "$WD"/.ran-* "$WD"/.stolen-* "$TMP"/escaped-*; }
ran()     { [ -e "$WD/.ran-$1" ]; }
escaped() { [ -e "$TMP/escaped-$1" ] || [ -s "$WD/.stolen-$1" ]; }
# The worktree's x.txt made to look changed, without git: status then has to
# ask the filter what it holds.
dirty() { echo changed >> "$T/x.txt"; }
arm

# --- the control: plain git springs every trap -------------------------------

case_begin "the traps are armed: plain git runs each, and it escapes"
reset_marks
dirty
git -C "$T" status --porcelain >/dev/null 2>&1
git -C "$R" fetch --quiet "$HUB" '+refs/heads/*:refs/remotes/origin/*' >/dev/null 2>&1
git -C "$R" worktree add --quiet --relative-paths -b control "$WD/control" origin/agent/evil >/dev/null 2>&1
for n in $TRAPS; do
  if ran "$n" && escaped "$n"; then _pass; else _fail "plain git did not spring $n; the cases below prove nothing"; fi
done
git -C "$R" -c core.hooksPath=/dev/null worktree remove --force "$WD/control" >/dev/null 2>&1
git -C "$R" -c core.hooksPath=/dev/null branch --quiet -D control >/dev/null 2>&1
git -C "$T" -c core.fsmonitor=false -c filter.evil.clean=cat -c filter.evil.smudge=cat checkout --quiet -- x.txt

# --- airlock: no trap runs ---------------------------------------------------

none_ran() { # label
  local n
  for n in $TRAPS; do
    if ran "$n"; then _fail "$1: $n ran"; else _pass; fi
    if escaped "$n"; then _fail "$1: $n reached outside work_dir"; else _pass; fi
  done
}

case_begin "airlock's own git calls run none of what the repository names"
reset_marks; dirty
assert_ok "status" run status demo
none_ran "status"
assert_ok "task ls" run task ls demo
none_ran "task ls"
assert_ok "task new, checking out the agent's branch" run task new demo evil
assert_file "$WD/tasks/evil/x.txt"
none_ran "task new"
assert_ok "doctor" run doctor demo
none_ran "doctor"
assert_ok "task rm" run task rm demo evil --yes
none_ran "task rm"
# A run builds its plan from the worktree; the launch itself is a stub.
printf '#!%s\nexit 0\n' "$BASH" > "$TMP/launcher"; chmod +x "$TMP/launcher"
AIRLOCK_LAUNCHER="$TMP/launcher" AIRLOCK_SUBSTRATE="$TMP" AIRLOCK_NIXPKGS="github:x/y/0" \
  ANTHROPIC_API_KEY=not-real run run demo t
none_ran "run"

# --- bubblewrap: what the overrides miss stays in work_dir -------------------

case_begin "a program the overrides do not stop runs confined to work_dir"
# A later override wins, so this stands in for a way to start a program that
# airlock does not know about: git runs the fsmonitor trap, inside the sandbox.
sbx() { ( . "$REPO_ROOT/lib/common.sh"; . "$REPO_ROOT/lib/sandbox.sh"
          sandbox_ready; wd_git "$WD" -- -C "$T" -c "core.fsmonitor=$WD/.traps/fsmonitor" status --porcelain ) >/dev/null 2>&1; }
reset_marks; dirty
sbx
if ran fsmonitor; then _pass; else _fail "the trap did not run, so confinement went untested"; fi
assert_absent "$TMP/escaped-fsmonitor"
if [ -s "$WD/.stolen-fsmonitor" ]; then _fail "read a file outside work_dir"; else _pass; fi

case_begin "AIRLOCK_GIT_SANDBOX=off runs it unconfined, and says so"
reset_marks
AIRLOCK_GIT_SANDBOX=off sbx
assert_file "$TMP/escaped-fsmonitor"
AIRLOCK_GIT_SANDBOX=off run status demo
assert_contains "$OUT" "AIRLOCK_GIT_SANDBOX=off" "warns"

case_begin "a bubblewrap that cannot start is a refusal, not a fallback"
printf '#!%s\nexit 1\n' "$BASH" > "$TMP/badbwrap"; chmod +x "$TMP/badbwrap"
if AIRLOCK_BWRAP="$TMP/badbwrap" "$AIRLOCK" status demo > "$OUT" 2>&1; then
  _fail "status succeeded without a sandbox"; else _pass; fi
assert_contains "$OUT" "cannot make a sandbox here" "says why"
assert_contains "$OUT" "AIRLOCK_GIT_SANDBOX=off" "names the way out"
