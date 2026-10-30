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

**No backward compatibility until a release.** airlock has one user. Don't write
code, tests or decision text to keep older workspaces, configs, launch records
or substrates working: change the layout or format, say in the commit message
what it breaks, and remove compatibility handling you come across. A broken
workspace is recreated (`rm`, then `init`), not migrated.

`REQUIREMENTS.md` is the design record: numbered decisions (D1–D34) with
the reasoning and the trade accepted for each. Code comments reference them by
number. **Read the relevant decision before changing behaviour it describes** —
several look like arbitrary choices and are not.

## Architecture

### The workspace is the whole model

```
<data-dir>/ws/<workspace>/     workspace root — NEVER mounted into the guest
├── work_dir/                  → WORK_DIR, mounted at /work
│   ├── CLAUDE.md              emitted by airlock; per-flavor filename
│   ├── .repo/                 bare repository the worktrees belong to, origin = ../../../<project>.git
│   └── tasks/<task>/          a task's worktree, on agent/<task> (D26)
├── <project>.git/             the hub; guests reach it only over the hub service (D33)
├── hub_key{,.pub}             this workspace's key to its hub
├── tasks/<task>/              a task's own state
│   ├── context/               → MICROVM_CONTEXT, read-only at /run/microvm/context
│   ├── agent_home/            → AGENT_HOME, mounted at /home/agent
│   ├── agent_home-{cri,store}/  substrate-derived, by string suffix on the path
│   └── lock                   one VM per task, held with flock; the pid, then the launch record
└── config                     this workspace's settings
```

### Tasks (D26–D31)

Every run is a task's: `run` and `stop` need one. The worktrees belong to a
bare repository, `work_dir/.repo` (`$WS_REPO`), with no branches of its own. `lib/task.sh` holds `task new/ls/rm` and `task_open()`, which sets
`TASK_*` the way `ws_open()` sets `WS_*`; `run_plan()` needs both. A task's
agent is asked by `run_task_args()` to read its context, or passed
`--continue` once its home holds a conversation. `stop` tells launches apart
by `instance.json`'s `context` (D31), since every task shares `work`. The
repository's `origin` is `../../../<project>.git`, relative to a worktree: the
hub in the root, on the host. In a guest, an `includeIf "gitdir:/work/"` pulls
in the launch's `.airlock/gitconfig`, which rewrites it to the hub service. It
does not resolve from `.repo` itself, so host-side git run there
(`task_fetch_hub()`) names `$WS_HUB` instead.

### The hub service (D33)

`lib/hub.sh`: one unprivileged `sshd`, the `systemd --user` unit `airlock-hub`,
sandboxed like the registry, on `127.0.0.1:5100` (`AIRLOCK_HUB_PORT`). Its host
key, `sshd_config`, forced command (`shell`) and `authorized_keys` live in
`hub_home()` (`$XDG_STATE_HOME/airlock/hub`, or `AIRLOCK_HUB_HOME`). Each key's
line is `restrict,command="<shell> <its hub>"`: the shell serves upload-pack or
receive-pack on that hub and ignores the path the client sent. `hub_sync_keys`
rewrites `authorized_keys` from every workspace's `hub_key.pub`; `init`, `rm`,
`run` and `hub start` call it. `run` writes the guest's side into the task's
context with `hub_write_context`. Tests give each file its own `AIRLOCK_HUB_HOME`
(`run-tests.sh`) and use `AIRLOCK_OPENSSH`; `test-hub.sh` runs the real sshd
through stub `systemd-run`/`systemctl`, and skips its live sessions where the
user has no login shell, as in the build sandbox. No LFS: in an LFS repository
`.repo`'s `pre-push` hook is airlock's no-op, which keeps git-lfs's hooks out
(`lfs_write_prepush`).

### Host-side git on work_dir (D34)

**Never call plain `git` on `.repo` or a worktree**, not even a read. Everything
under `work_dir/` is the agent's to write, and git runs what a repository's
config and hooks name. Use `wd_git <work_dir> [--hub <hub>] [--repo <repo>] --
<git args>` from `lib/sandbox.sh`, or its short forms `repo_git` (on `$WS_REPO`,
after `ws_open`) and `wd_is_repo`. It adds `SANDBOX_FIXED_OVERRIDES` and empties
every non-LFS filter driver the repository defines, then runs git in bubblewrap
with only the system directories, `work_dir` and, given `--hub`, the hub
read-only. Pass `--hub` to anything that reads the hub, `file://` LFS URLs
included. Git on the hub stays plain: only the host writes it.

`bin/airlock` calls `sandbox_ready` at dispatch for the commands that use it, so
a refusal is never lost inside a `$(...)` or a `2>/dev/null`. A new command
that runs git on `work_dir` must be added to that list. The sandbox's `PATH` is
the real directories of git, git-lfs and `sh`; git-lfs starts its local-file
transfer through `sh -c`. bubblewrap comes from `AIRLOCK_BWRAP` (a default in
the installed wrapper, and set by `run-tests.sh`), else `PATH`, else a build
from nixpkgs. `AIRLOCK_GIT_SANDBOX=off` runs git unconfined with the overrides
and a warning. `tests/test-sandbox.sh` plants fsmonitor, filter and hook traps,
checks first that plain git springs them, and runs it in a temp directory, not
under `/home` or `/work`: git disables fsmonitor on network filesystems such as
virtiofs, which once hid that trap.

Two directories are mounted, `work_dir/` and the task's `agent_home/`; the root
is not. That asymmetry is load-bearing (D3): everything airlock relies on for
its own integrity — the hub, the locks, the contexts, the config — lives where
the guest cannot write it. Anything moved into `work_dir/` or an `agent_home/`
becomes agent-writable. The hypervisor's control socket is the substrate's, in
its per-launch directory under `$XDG_RUNTIME_DIR/airlock-vm/vms/<id>/`.

airlock requires the claude-microvm fork it pins (D32): per-launch directories
and `microvm-stop`, `MICROVM_NAMESPACE`, `MICROVM_NAME`, `MICROVM_CONTEXT`,
`MICROVM_START_DIR`. Don't add handling for a substrate without them; a
`substrate` key names another revision or a checkout of the fork.

### The exchange model

The agent pushes branches to the hub. The developer fetches the hub into their
own checkout and reviews it there with ordinary git, against their own remotes;
publishing is their act from that checkout — airlock never holds a forge
credential (D6). **airlock keeps no review state** (D16): there is no `review`
command and nothing records what has been read.

`status` and `rm` share one measure, `status_scan()` in `lib/status.sh`: the
hub branches carrying commits the default branch does not have, with distinct
commits counted once across stacked branches.

The hub lives in the root, and a guest's only way to write it is a push
through the hub service, so `receive.denyNonFastForwards` and
`receive.denyDeletes`, which bind `receive-pack`, are enforced (D17, D33).

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
into the worktrees' repository's git config, flavor into which context file was emitted — so
`doctor` carries checks for that drift instead (D20).

### The substrate boundary

`run` maps the workspace onto the environment claude-microvm reads — `WORK_DIR`,
`AGENT_HOME`, `VM_VCPU`, `VM_MEM`, `AGENTS_ARGS`, `AGENT_SETTINGS`,
`ENABLE_CRI`, `VM_STORE_SIZE`, `EXTRA_ENV` — and launches it with the workspace
root as its working directory. Substrate env vars never appear in the user's
hands (D9). `NO_PAUSE` (from `pause = off`) is added in `cmd_run` rather than
the plan: it only decides whether the substrate waits for Enter before boot,
so it is not something `status` should report as drift. `MICROVM_NAMESPACE`
(D23) and `MICROVM_NAME`, the workspace name (D24), are added there too: they
are airlock's, not the config's.

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

`airlock stop` does not talk to QEMU. It finds the task's launch in the
substrate's runtime directory (`$XDG_RUNTIME_DIR/airlock-vm/vms/<id>/`, D23):
the one whose lock is held and whose `instance.json` gives its own directory
name as `id`, this workspace's `work_dir/` as `work` and the task's context as
`context` — both realpath'd, as the substrate writes them. It then runs `nix run <substrate>#microvm-stop -- <id>`
with the substrate, nixpkgs and `MICROVM_NAMESPACE` from the launch record, so
the stopper comes from the substrate that launched the VM and looks where it
put it.

### Registry caches (D21)

`lib/registry.sh` is the one part of airlock that is not about a workspace. It
runs one `distribution` per upstream in pull-through proxy mode, as a transient
`systemd --user` unit named `airlock-registry-<upstream>`, in
`airlock-registry.slice` (inside `airlock.slice`, beside the VMs'
`airlock-vm.slice`). The unit's
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

Its data lives under `$XDG_CACHE_HOME/airlock/registry`: it is disposable, so
cache, not `data_home`.

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
- git-lfs takes a bare local path for a named remote, but given one as an
  argument (`git lfs fetch /path`, or a push to `/path` through its pre-push
  hook) it fails with "no valid file:// URLs found". Pass `file:///path`.
- A trap that names a function's `local` must expand it when set: under
  `set -e` the EXIT trap runs after the function has unwound, and `set -u`
  makes the variable an error of its own.
- Prefer the edit tool over `sed`/`perl` for prose containing em-dashes;
  `perl` has corrupted `REQUIREMENTS.md` into invalid UTF-8 more than once here.
  `iconv -f UTF-8 -t UTF-8 <file>` checks.
