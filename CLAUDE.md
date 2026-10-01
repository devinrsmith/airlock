# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
./tests/run-tests.sh                # the whole suite (~25s, no VM, no network)
./tests/run-tests.sh review         # one file: tests/test-review.sh
./tests/run-tests.sh run doctor     # several

nix shell nixpkgs#shellcheck --command \
  shellcheck -x -P lib:tests bin/airlock lib/*.sh tests/*.sh

nix flake check                     # tests + shellcheck, in a sandbox
nix build                           # the package

nix flake update claude-microvm     # bump the microVM airlock launches
```

The repository is `github.com/devinrsmith/airlock`; a plain clone is enough,
and `nix profile install github:devinrsmith/airlock` installs it.

The `Makefile` wraps these as `make test`, `make shellcheck`, `make check` and
`make build` — but `make` is not always present (it is absent from the guest
this was developed in), so the direct commands above are the portable ones.

`nix flake check` is the gate — it runs the suite and shellcheck in a sandbox
that differs from the dev shell in ways that have caught real bugs (see
Gotchas). Run it before considering anything done.

## What this is

airlock runs a coding agent inside a microVM and keeps a bare git repository as
the only channel between that agent and the developer's own checkout. It is a
bash CLI wrapping [claude-microvm](https://github.com/systemstart/claude-microvm),
which is a flake input pinned in `flake.lock` — airlock never builds it, it
shells out to `nix run <ref>#<flavor>` at launch.

`REQUIREMENTS.md` is the design record: twenty numbered decisions (D1–D20) with
the reasoning and the trade accepted for each. Code comments reference them by
number. **Read the relevant decision before changing behaviour it describes** —
several look like arbitrary choices and are not.

## Architecture

### The workspace is the whole model

```
<data-dir>/<workspace>/        workspace root — NEVER mounted into the guest
├── work_dir/                  → WORK_DIR, mounted at /work
│   ├── CLAUDE.md              emitted by airlock; per-flavor filename
│   ├── <project>.git/         the hub — the agent pushes here
│   └── <project>/             the agent's clone, origin = /work/<project>.git
├── agent_home/                → AGENT_HOME, mounted at /home/agent
├── agent_home-{cri,store}/    substrate-derived, by string suffix on the path
├── config                     this workspace's settings
├── watermarks/                review state — unreachable from the guest
├── lock                       one VM per workspace; holds the pid
└── <hostname>.sock            hypervisor control socket, while a VM runs
```

Two directories are mounted; the root is not. That asymmetry is load-bearing
(D3): everything airlock relies on for its own integrity — watermarks, the
lock, the config — lives where the guest cannot write it. Anything moved into
`work_dir/` or `agent_home/` becomes agent-writable and stops being evidence.

### The exchange model

The agent pushes branches to the hub. `review` shows what arrived since the
last watermark; `--accept` advances it and does nothing else. Publishing is the
developer's act from their own checkout — airlock never holds a forge
credential (D6).

`branch_state()` in `lib/common.sh` is the single definition of "unreviewed".
`review` and `status` both read it so they cannot disagree. It returns one of
`clean`, `ahead`, `new`, or `tamper`.

**Tamper is not a theoretical state.** The hub lives inside the share, so the
guest can rewrite its refs directly; `receive.denyNonFastForwards` and
`receive.denyDeletes` bind `receive-pack` only and do not stop it (D17). A
watermark whose commit is missing or no longer an ancestor is the evidence, so
it is never quietly advanced — `review` refuses, `status` exits non-zero,
`doctor` reports it and `--fix` deliberately does not repair it.

### Code layout

`bin/airlock` sources every `lib/*.sh` and dispatches to one `cmd_<name>` per
command. `lib/common.sh` holds everything shared: the flavor table, config
parsing, watermarks, the lock, `ws_open()`.

`ws_open()` resolves a workspace into `WS_ROOT`, `WS_HUB`, `WS_CLONE`,
`WS_PROJECT`, `WS_FLAVOR`, `WS_BRANCH`, `WS_CONFIG` and dies on a broken one.
`doctor` deliberately does not use it: reporting on a broken workspace is its
whole job.

A flavor (claude/gemini/codex/pi) differs in five facts, all in `flavor_row()`:
flake attribute, settings path, context filename, API key variable, bypass
flag. Where a fact is unverified for a flavor the cell is empty and the code
says so rather than guessing — `codex` and `gemini` have no bypass flag listed
for that reason.

### Config: two scopes, not a hierarchy

`$XDG_CONFIG_HOME/airlock/config` holds defaults that `init` bakes into each
new workspace's config. Nothing else ever reads it. A workspace's config is
therefore the complete statement of what that workspace does (D9/D19), which is
why there is no merged view in `airlock config` and why changing the defaults
never affects an existing workspace.

`config` edits text only. Three keys were applied elsewhere at init — identity
into the clone's git config, flavor into which context file was emitted — so
`doctor` carries checks for that drift instead (D20).

### The substrate boundary

`run` maps the workspace onto the environment claude-microvm reads — `WORK_DIR`,
`AGENT_HOME`, `VM_VCPU`, `VM_MEM`, `AGENTS_ARGS`, `AGENT_SETTINGS`,
`ENABLE_CRI`, `VM_STORE_SIZE`, `EXTRA_ENV` — and launches it with the workspace
root as its working directory. Substrate env vars never appear in the user's
hands (D9).

Which claude-microvm gets launched resolves in three steps: the workspace's own
`substrate` key, then `AIRLOCK_SUBSTRATE` (baked into an installed build's
wrapper from `flake.lock`), then the revision read out of `flake.lock` directly
for a source checkout. An install and a checkout therefore launch the same
microVM. `substrate_ref_from_lock()` is a deliberate small awk parser rather
than a jq dependency.

## Testing

No VM is ever launched. `run` is covered two ways: `--dry-run` prints the
environment and command, and `AIRLOCK_LAUNCHER` points the launch at a stub that
records what it received. Booting a real guest is a manual smoke test — CI has
no KVM, and no guest has yet been booted through `run`.

Four environment variables keep tests hermetic, and new tests should set all
that apply: `AIRLOCK_DATA_HOME`, `AIRLOCK_CONFIG`, `AIRLOCK_SUBSTRATE`,
`AIRLOCK_LAUNCHER`. Tests also `cd` into their own temp directory, because a
stray relative path once created directories inside the repository.

Interactive paths (`review`'s prompt, `rm`'s confirmation) are tested under a
real pty with `script(1)`, feeding keystrokes on stdin; `util-linux` and `less`
are in the flake check so those cases run in CI rather than skipping.

**Mutation-test anything load-bearing.** Break the behaviour deliberately, run
the suite, confirm it goes red, restore. Several tests in this repo passed
against mutated code until strengthened — a two-branch fixture could not tell
"stop asking" from "answer no"; appending a config key instead of replacing it
still read back correctly. Verify the mutation actually applied before believing
a green result: `sed`/`perl` edits have silently failed to match here.

## Gotchas, all verified the hard way

- `git init --bare` points `HEAD` at `refs/heads/master` whatever branch you
  seed, and a clone of such a hub comes up with **no checkout at all**. `init`
  sets it explicitly.
- `git diff <tip>` with one argument means "compare the working tree", which a
  bare repo does not have. Diff a root history from `empty_tree()`.
- `receive.denyDeletes` blocks the developer too: prune hub branches with
  `git -C <hub> update-ref -d`, not a push.
- airlock sets `GIT_PAGER=cat`. A pager takes the alternate screen mid-report
  and wipes everything printed after it — which is where `review --accept` says
  what it accepted.
- The substrate was a git submodule once. It is a flake input now, because
  flakes exclude submodules unless the reference says `?submodules=1`, and only
  the `git+https://` fetcher honours that — a `github:` install silently got no
  substrate. Do not reintroduce one without re-reading D10.
- The Nix build sandbox has no `/usr/bin/env`, so files written at test time
  need the running `$BASH` in their shebang; `patchShebangs` only reaches files
  in the source tree.
- `local a="$1" b="$a/x"` does not see `a` (SC2318). Use two `local`s.
- Prefer the edit tool over `sed`/`perl` for prose containing em-dashes;
  `perl` has corrupted `REQUIREMENTS.md` into invalid UTF-8 more than once here.
  `iconv -f UTF-8 -t UTF-8 <file>` checks.
