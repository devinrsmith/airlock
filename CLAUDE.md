# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
./tests/run-tests.sh                # the whole suite (~25s, no VM, no network)
./tests/run-tests.sh status         # one file: tests/test-status.sh
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

`REQUIREMENTS.md` is the design record: numbered decisions (D1–D23) with
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
└── lock                       one VM per workspace, held with flock; the pid, then the launch record
```

Two directories are mounted; the root is not. That asymmetry is load-bearing
(D3): everything airlock relies on for its own integrity — the lock, the
config — lives where the guest cannot write it. Anything moved into
`work_dir/` or `agent_home/` becomes agent-writable. The hypervisor's control
socket is the substrate's, in its per-launch directory under
`$XDG_RUNTIME_DIR/airlock-vm/vms/<id>/` — which only the claude-microvm
fork airlock pins has so far; upstream would put it back in the root.

### The exchange model

The agent pushes branches to the hub. The developer fetches the hub into their
own checkout and reviews it there with ordinary git, against their own remotes;
publishing is their act from that checkout — airlock never holds a forge
credential (D6). **airlock keeps no review state** (D16): there is no `review`
command and nothing records what has been read.

`status` and `rm` share one measure, `status_scan()` in `lib/status.sh`: the
hub branches carrying commits the default branch does not have, with distinct
commits counted once across stacked branches.

The hub lives inside the share, so the guest can rewrite its refs directly;
`receive.denyNonFastForwards` and `receive.denyDeletes` bind `receive-pack`
only and do not stop it (D17). airlock does not detect that. The developer's
own remote-tracking refs do: `git fetch` reports a rewritten branch as a
forced update.

### Code layout

`bin/airlock` sources every `lib/*.sh` and dispatches to one `cmd_<name>` per
command. `lib/common.sh` holds everything shared: the flavor table, config
parsing, the lock, `ws_open()`.

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
hands (D9). `NO_PAUSE` (from `pause = off`) is added in `cmd_run` rather than
the plan: it only decides whether the substrate waits for Enter before boot,
so it is not something `status` should report as drift.

Which claude-microvm gets launched resolves in three steps: the workspace's own
`substrate` key, then `AIRLOCK_SUBSTRATE` (baked into an installed build's
wrapper from `flake.lock`), then the reference read out of `flake.lock` directly
for a source checkout. An install and a checkout therefore launch the same
microVM. Both rebuild the **whole** reference from the input's `locked` entry
(type, owner, repo, rev) — `lockedRef` in `flake.nix`, `flake_lock_ref()` in
`lib/common.sh` — never a hard-coded owner with the locked revision, which
once turned a fork in `flake.nix` into the upstream repository at the fork's
commit. The same goes for nixpkgs. A build whose inputs were overridden past
the lock bakes `path:<store path>` instead. `flake_lock_locked()` is a
deliberate small awk parser rather than a jq dependency. It reads
`nodes.<node>.locked.<field>` and nothing else, in pretty-printed or one-line
JSON.

That default substrate runs on airlock's nixpkgs, not the one in
claude-microvm's own lock: `run` launches it with `--override-input nixpkgs`
set to `nixpkgs_ref()` (`AIRLOCK_NIXPKGS`, baked in from `nixpkgs.rev`, else
read from `flake.lock`). claude-microvm's own inputs follow its `nixpkgs`, so
the whole guest moves with it. `follows` cannot do this from our side — the
input is `flake = false`, and the substrate is evaluated by reference at launch,
against its own lock, never through ours. A workspace that pins a `substrate`
of its own gets it exactly as locked, with no override.

`run_plan()` is the launch as `flavor`/`substrate`/`nixpkgs`/`env` lines,
computed from the config alone. `run` executes it and writes it into the lock
after the pid, with `cwd`, `args` (everything after `--`) and, on a real launch,
`substrate.rev`/`substrate.narHash`. `status` reads that record to report what a
running VM is on, and re-runs `run_plan()` (from the recorded cwd, in a
subshell, since it dies on a bad config) to report what changed since. So
anything new that decides the launch belongs in `run_plan()`, or `status` will
not notice it changing.

### Stopping a VM (D22)

`airlock stop` does not talk to QEMU. It finds the workspace's launch in the
substrate's runtime directory (`$XDG_RUNTIME_DIR/airlock-vm/vms/<id>/`, D23):
the one whose lock is held and whose `instance.json` gives its own directory
name as `id` and this workspace's `work_dir/` — realpath'd, as the substrate
writes it — as `work`. It then runs `nix run <substrate>#microvm-stop -- <id>`
with the substrate, nixpkgs and `MICROVM_NAMESPACE` from the launch record (a
record from before D23 has no namespace, and its VM is in the default one), so
the stopper comes from the substrate that launched the VM and looks where it
put it. Only the claude-microvm fork airlock
pins has per-launch directories; on any other substrate `stop` finds nothing
and says to exit the agent.

### Registry caches (D21)

`lib/registry.sh` is the one part of airlock that is not about a workspace. It
runs one `distribution` per upstream in pull-through proxy mode, as a transient
`systemd --user` unit named `airlock-registry-<upstream>`. The unit's
existence is the whole "is it running" state; there is no lockfile. The
upstream table is `registry_row()`, shaped like the flavor table.

Each unit is sandboxed: `ProtectSystem=strict`, `ProtectHome=tmpfs`,
`PrivateTmp`, `NoNewPrivileges`, and `BindPaths=` for that upstream's own
directory only. Both `Protect*` settings are needed, because in a user unit
`strict` leaves `$HOME` writable. Test a sandbox change by probing what a
process inside it can read and write (`systemd-run --user --wait --pipe … sh
-c …`). Seeing the setting in `systemctl show` doesn't show it is enforced.

Which `distribution` it runs comes from `nixpkgs_ref()`, the same nixpkgs the
substrate is launched on. `AIRLOCK_REGISTRY_PKG` names a package outright and
exists for tests. All lock readers go through `flake_lock_locked()` in
`lib/common.sh`.

Its data lives under `$XDG_CACHE_HOME/airlock/registry`, deliberately **not**
under `data_home`. `status` and `doctor` treat every directory there as a
workspace.

Command substitutions do not inherit `set -e`, so a `die` inside `$(…)` ends
only the subshell. Every substitution in `lib/registry.sh` that can die is
followed by `|| exit 1`, and a test covers each one.

A workspace with `registry = on` and a non-empty `cri` gets
`REGISTRY_MIRRORS` in its plan, built by `registry_mirrors_value()` from the
same table, so the ports are defined once. It always lists every cache, running
or not, so the plan depends on config alone and `status` drift detection keeps
working. Whether a cache is actually running is checked only in `cmd_run`, as
a warning. `registry_running_count()` prints nothing when systemd can't be
asked, which is different from `0`. The guest side is claude-microvm's
`cri-registry-mirrors`, which airlock's pinned substrate has; a workspace
`substrate` without it is handed the variable and ignores it.

Where each cache pulls from is the table's remote unless the remotes file
(`registry_config_path()`, `$XDG_CONFIG_HOME/airlock/registry`) overrides it.
`registry_check_config()` validates the whole file and dies on any bad line.
`start`, `restart` and `status` call it before doing anything, so a typo
never reaches a cache config or stops a working cache. `stop` does not call
it, so a broken file can't trap a cache running. What a running cache uses
is read back from its `config.yml`, which is written only at start: that is
how `status` and `start` notice a cache the file has moved on from. The
remotes never reach a workspace's plan.

`airlock registry import` reads the host's `registries.conf` through
registries-conf (`github:devinrsmith/registries-conf`, a flake input), a CLI
around `go.podman.io/image/v5` — no rule of that library is restated here.
`config --json` gives the merged entries and the paths searched; `resolve
--json` on a probe image under each upstream gives which entry applies, so
prefix and wildcard matching are the library's too. One upstream is resolved
at a time, because resolving fails outright for an entry the tools cannot
pull through, and that should cost only that upstream. What is airlock's own
is the question asked of the answer: which mirror a cache can take
(`registry_import()`). The installed wrapper sets `AIRLOCK_REGISTRIES_CONF` and
puts `jq` on `PATH`; a source checkout builds both from `flake.lock`
(`registry_rc_bin()`, and `jq_bin()` in `lib/common.sh`), so the "no jq" rule above holds
for everything but import and `stop`. `AIRLOCK_CONTAINERS_ROOT` is passed as its `--root`
for tests. The tests skip without registries-conf and jq, so the flake check
has both.

`distribution` 3 exports OpenTelemetry traces to `localhost:4318` by default
and logs every failure. Units set `OTEL_TRACES_EXPORTER=none`.

## Testing

No VM is launched by the suite. `run` is covered two ways: `--dry-run` prints
the environment and command, and `AIRLOCK_LAUNCHER` points the launch at a stub
that records what it received. Booting a real guest is a manual check, because
CI has no KVM — so a change that breaks the boot can still pass every test
here. `run` is in real use against real guests; the gap is in the automation,
not the command.

These environment variables keep tests hermetic, and new tests should set all
that apply: `AIRLOCK_DATA_HOME`, `AIRLOCK_CONFIG`, `AIRLOCK_SUBSTRATE`,
`AIRLOCK_NIXPKGS`, `AIRLOCK_LAUNCHER`, for `stop` `AIRLOCK_STOPPER` and
`XDG_RUNTIME_DIR`, and for `registry` `AIRLOCK_REGISTRY_HOME`,
`AIRLOCK_REGISTRY_CONFIG`, `AIRLOCK_REGISTRY_PKG`,
`AIRLOCK_REGISTRY_SETTLE=0`, and for `registry import` `AIRLOCK_REGISTRIES_CONF`,
`AIRLOCK_CONTAINERS_ROOT`, `XDG_CONFIG_HOME` and `XDG_CACHE_HOME`, with
`CONTAINERS_REGISTRIES_CONF*` unset. Tests also `cd` into
their own temp directory, because a stray relative path once created
directories inside the repository.

`registry` talks to systemd and nix rather than to a launcher, so its tests put
stub `systemctl`, `systemd-run` and `nix` first on `PATH`; a running unit is a
file. The suite therefore never starts a real registry. Starting one and
pulling through it from a guest was checked by hand on 2026-10-15.

Interactive paths (`rm`'s confirmation) are tested under a real pty with
`script(1)`, feeding keystrokes on stdin; `util-linux` is in the flake check so
those cases run in CI rather than skipping.

**Mutation-test anything load-bearing.** Break the behaviour deliberately, run
the suite, confirm it goes red, restore. Several tests in this repo passed
against mutated code until strengthened — a two-branch fixture could not tell
"stop asking" from "answer no" in the since-removed `review`; appending a config
key instead of replacing it still read back correctly. Verify the mutation
actually applied before believing a green result: `sed`/`perl` edits have
silently failed to match here.

## Gotchas, all verified the hard way

- `git init --bare` points `HEAD` at `refs/heads/master` whatever branch you
  seed, and a clone of such a hub comes up with **no checkout at all**. `init`
  sets it explicitly.
- `git diff <tip>` with one argument means "compare the working tree", which a
  bare repo does not have. Diff a root history from the empty tree
  (`git hash-object -t tree /dev/null`).
- `receive.denyDeletes` blocks the developer too: prune hub branches with
  `git -C <hub> update-ref -d`, not a push.
- airlock sets `GIT_PAGER=cat`. A pager takes the alternate screen mid-report
  and wipes everything printed after it (it once swallowed what the
  since-removed `review --accept` said it had accepted).
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
