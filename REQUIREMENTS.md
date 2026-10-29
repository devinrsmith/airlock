# airlock — requirements

Status: **pre-release, implemented, and used by its one developer.** Derived from
requirements conversations from 2026-09-25 on.

**No compatibility before a release.** A decision may change the workspace layout,
config keys, launch records or what the substrate must provide, without migrating
what exists. Neither the code nor this record carries handling for workspaces,
launches or substrates from before a change; a workspace an update breaks is
removed and made again.

`CLAUDEINIT.md` is the prior-art primer. It is superseded for the same-user design
adopted here; its cross-identity recipe remains the reference for the optional
hardened mode (§9).

## 1. What this is

**airlock** is a host-side CLI that stands up and manages isolated, virtualized
coding-agent workspaces for a team. Each workspace pairs a microVM running an agent
with a bare git hub that is the only channel between the agent and the developer's
own checkout — the airlock the name refers to: nothing passes without a deliberate cycle.

airlock owns the workspace lifecycle, the exchange layer, and the policy. The
virtualization substrate ([`claude-microvm`](https://github.com/systemstart/claude-microvm))
is an implementation detail it hides.

> **Name note.** [`besoeasy/airlock`](https://github.com/besoeasy/airlock) is an
> unrelated project in the same problem space (Podman-based agent isolation), and
> `airlock` is taken on the major package registries. Accepted knowingly: airlock ships
> as a Nix flake from [`devinrsmith/airlock`](https://github.com/devinrsmith/airlock),
> which is the name that resolves it, so the collision is cosmetic — but docs should
> not assume an unqualified search finds us.

### Goals

- An agent runs against a project without any ability to reach the developer's working
  tree, credentials, or host processes.
- Worst case — a malicious or mistaken command, up to and including a VM escape — the
  damage is bounded and legible.
- Installation and every subsequent launch require **no root and no sudo**.
- Usable by teammates on any Linux host with Nix and KVM, not just its author's machine.

### Non-goals (v1)

- macOS hosts (no KVM; would need a second backend).
- Network egress filtering — the guest gets unrestricted outbound access.
- Provisioning dedicated host service accounts (deferred; §9).
- Multi-tenant hosting of other people's agents.

## 2. Threat model

| Risk | Mitigation |
|---|---|
| Agent mistake (`rm -rf`, clobbering edits, runaway build) | The agent's tree is a disposable clone; the developer's checkout is never shared into the VM. Hub refuses rewrites and deletions **via push** (D17 — accident-level protection only). Resource caps bound runaway work. |
| Prompt injection steering the agent | No forge credentials, no SSH keys, no host secrets in the guest. Code leaves only as commits the developer reviews before pushing anywhere real. A steered agent **can** rewrite or destroy hub history (D17); airlock neither prevents nor detects it, and the developer's own remote-tracking refs are what show it (D16). |
| Hostile code executed inside the guest | VM boundary: separate kernel, separate process tree, no host port binding. Guest-internal user separation is explicitly **not** a boundary. |
| VM escape | Accepted risk in v1: an escape lands in the launching user's account. §9 defines the upgrade path. |
| Guest reaching host services | **Not mitigated.** The guest cannot *bind* host ports, but it can *connect* to anything listening on host loopback: its user-mode gateway, `10.0.2.2`, is host `127.0.0.1` under the substrate's open egress, which is what airlock launches. Verified 2026-10-15 with nested guests. A dev database or local web UI bound to loopback on the assumption that loopback is private is reachable from every guest. D21's caches rely on this path deliberately. The substrate's sealed egress modes close it. |

Accepted knowingly in v1: an escape is the launching user. The judgment is that a VM
boundary is already a high bar, and shipping the simpler rootless design first is worth
more than the marginal containment of a service account.

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Same-user, fully rootless.** The developer launches the VM; no dedicated account, no group, no ACLs, no privileged install step. | Simplest thing that keeps the VM boundary. Removes every cross-uid workaround in `CLAUDEINIT.md`. |
| D2 | **The bare git hub is the only write channel** between developer and agent. Neither side writes into the other's working tree. | Under D1 this is policy, not a permissions workaround: it bounds the agent's reach and makes every transfer a reviewable commit. |
| D3 | **The workspace root is never mounted.** Only `work_dir/` (→ `/work`) and the running task's `tasks/<t>/agent_home/` (→ `/home/agent`) are; airlock's own state sits beside them, and the developer's checkout is outside the workspace entirely. | The mounts *are* the blast-radius limit, and an unmounted root gives airlock somewhere the guest cannot reach — for its config, the tasks' contexts and their locks (D13). (The hypervisor's control socket is the substrate's, in its own runtime directory, likewise unmounted — §4.) |
| D4 | **Tool-owned workspace directories**, seeded from either a forge URL or an existing local checkout. | Predictable layout makes `doctor`, maintenance, and cleanup tractable. |
| D5 | **Only the agent's API credential lives in the guest.** No SSH keys, no forge tokens. It arrives as a forwarded environment variable (`ANTHROPIC_API_KEY` and the per-flavor equivalents), which the substrate hands each launch on its own read-only share; airlock does not copy a stored login into a workspace. | An injected or malicious command can burn tokens; it cannot touch the developer's forge account. Forwarding rather than copying keeps the credential re-derived from the developer's environment each launch instead of becoming a long-lived token the workspace owns: removing the workspace leaves nothing to revoke, and one credential stays one thing to rotate rather than one per workspace. An interactive login inside a guest is therefore per task by construction (D28), which is a cost accepted for that. |
| D6 | **Publish path: agent pushes to hub → developer reviews → developer pushes to forge** from their own account. | Human review is the gate on anything leaving the machine. |
| D7 | **Unrestricted guest network.** The guest may fetch public remotes and pull packages directly. | It already needs the network for the agent API and dependencies; pretending otherwise buys little. |
| D8 | **Private upstreams reach the agent only through the hub.** The developer configures remotes on the hub and fetches into it; the agent reads them read-only from its clone. | Credentials stay host-side. This is *uncredentialed*, not *enforced* — anything public the guest can always reach directly. |
| D9 | **Single CLI + per-workspace config file.** Substrate env vars and Nix invocations never appear in the user's hands. | The config file is also what a reviewer reads to see what a workspace may do. |
| D10 | **Bash, packaged as a Nix flake**, with the substrate as a `flake = false` input pinned in `flake.lock`. | Matches the substrate's idiom; the tool is largely orchestration of `git` and the launcher. Auditable line-by-line. The lock pins which microVM a build launches without building it: `run` shells out to `nix run <ref>#<flavor>`, so the only thing needed from the input is its revision — hence `flake = false`, which keeps the substrate's own inputs (microvm.nix, a second nixpkgs) out of our lock. Since `follows` therefore cannot reach the substrate, the default one is launched with `--override-input nixpkgs` set to the nixpkgs in our lock, so one nixpkgs serves airlock, its registry and the guest; claude-microvm's inputs follow its own `nixpkgs`, so the override reaches all of them. The cost accepted is running claude-microvm against a nixpkgs its upstream did not test it with, and building the guest's system closure locally after each bump. A workspace pinning its own `substrate` is launched exactly as that flake is locked. An install bakes the reference into its wrapper; a checkout reads the same revision from `flake.lock`, so the two cannot drift. **Previously a git submodule, and changed because that fought the ecosystem**: flakes omit submodules unless the reference carries `?submodules=1`, which only the `git+https://` fetcher honours, so `github:` installs silently produced an airlock whose `run` could not work. Pinning by lock costs nothing a submodule was buying — a checkout cannot launch a VM without Nix anyway. |
| D11 | **All four agent flavors supported** (Claude Code default; Gemini, Codex, Pi documented as less-exercised). | The substrate normalizes them to one interface; a flavor differs for airlock in exactly three facts — flake attribute, settings path, context filename. A four-row table. |
| D12 | **Agent runs with permission prompts disabled by default.** Per-workspace opt-out in config. | The ergonomic payoff of virtualizing. The VM is the boundary, so in-guest prompts are asking the wrong layer for consent. (Originally justified as "paired with hub guardrails" — see D17 for why that pairing does not hold.) |
| D13 | **One VM per task, enforced by a lockfile** in the task's directory (D26). | Two agents sharing one working tree corrupt it, and each task has one of its own. **Previously one VM per workspace**, parallel work meaning a second workspace; then, briefly, the workspace's own run beside its tasks. Every run is now a task's. |
| D14 | **Three-layer context composition** (§6); airlock owns only `work_dir/CLAUDE.md`. A task adds its read-only context (D29), which the developer writes. | Three files, three owners, no overlap, and airlock never writes inside the clone or a task's worktree. |
| D15 | **No audit trail in v1.** The hub's reflog already records what arrived and when. | Least to build; the agent's own transcripts persist in agent home regardless. |
| D16 | **Agent branches are `agent/<topic>` by convention; review is the developer's, done with their own git from their own checkout. airlock keeps no review state.** `status` reports the hub as it is — branches carrying commits the default branch lacks — and nothing more. Full model in §4. | The developer already has a better review tool than airlock could be: their checkout, their remotes, their diff and log habits, and whatever workflow they bring the work into. Fetching the hub as a remote puts agent work beside upstream with nothing new to learn, and their remote-tracking refs are a record of what they last saw: `git fetch` reports a rewritten branch as a forced update. **Previously host-side watermarks** in the unmounted root, with `airlock review` diffing since the last accepted commit and treating a vanished one as tamper evidence; removed 2026-10-05 as adding little in use: developers review against their own remotes and bring the work into their own workflows, which a diff against the hub's copy of the default branch, and a second airlock-specific notion of "reviewed", did not serve. The trade accepted: airlock no longer detects a hub rewrite on its own (D17), and `status` cannot tell work you have read from work you have not. |
| D17 | **The hub lives inside `work_dir/` and its `receive.*` guardrails are anti-accident, not enforcement.** Documented as such rather than engineered around. | Verified: `receive.denyNonFastForwards` and `receive.denyDeletes` bind `receive-pack` only. The agent has filesystem write access to the hub via `/work`, so `git -C /work/<project>.git update-ref` rewrites or deletes any ref with both settings `true` and neither consulted. Alternatives (a host-only canonical hub mirrored inward; a protocol-only write path over the slirp gateway) were considered and declined for v1 complexity. |
| D18 | **Dev shells are off by default, with a per-workspace opt-in** that pre-evaluates on the host. Without it, the agent uses `nix develop` in the guest. With it, airlock re-evaluates only when the Nix source has changed since the last evaluation, and asks the developer first when it has (§9.1). | Cheapest option that keeps the convenience available. The opt-in knowingly reopens a guest→host evaluation path (§9.1) for workspaces that choose it; the alternative considered was evaluating only trusted sources (the developer's checkout, or a reviewed commit exported out of the share), which stays available later — airlock picks the evaluated path, so it is a change of source, not a redesign. |
| D19 | **User-level defaults for new workspaces** live in `$XDG_CONFIG_HOME/airlock/config` and are **baked into a workspace's config at `init`**, not layered underneath it at every read. | A person should not have to retype their committer identity or settings dotfile for every workspace. Baked rather than layered because D9 makes the workspace config the statement of what that workspace does — that stops being true the moment half of it lives somewhere else, and a reviewer reading one config would be reading an incomplete answer. The consequence is deliberate: changing the defaults affects the next workspace and never an existing one. |
| D20 | **`airlock config` is per-scope, never merged**, validates keys and values when they are set, and edits text only — drift from what `init` applied elsewhere is `doctor`'s job. | `git config` resolves a key through a hierarchy; airlock's two scopes are not one (D19), so a merged view would imply a resolution order that does not exist. Validating at the keyboard beats failing at the next launch. Keeping side effects out of `config` means one command edits files and one command reconciles reality, rather than both doing half of each. |
| D21 | **Container images are cached by host-side, pull-only registry proxies that airlock runs as `systemd --user` units** (`airlock registry`): one `distribution` instance per upstream in proxy mode, each in `airlock-registry.slice`, on loopback, from the nixpkgs in `flake.lock`, with its data under the XDG cache directory. Guests reach them at `10.0.2.2`. | Every guest otherwise pulls every image from scratch. A transient user unit around a store path is how the substrate already runs virtiofsd: no root (D1), nothing to install, and the package is pinned the same way the substrate is (D10). Proxy mode refuses pushes, so the hub stays the only guest-to-host write channel (D2). The data is disposable, and living outside `data_home` keeps `status` and `doctor` from reading it as a broken workspace. **The trade accepted:** the registry parses requests guests control *outside* any VM. systemd narrows what a compromised one could reach: `ProtectSystem=strict`, `ProtectHome=tmpfs` (not `read-only`, which still lets it read keys and tokens it could then send upstream), `PrivateTmp`, `NoNewPrivileges`, and only its own directory bound back in. In a user unit `strict` alone leaves home writable; it takes both (verified 2026-10-15). These need unprivileged user namespaces, and without them a cache fails to start rather than running bare. Considered and declined for now: running it in a dedicated microVM, which would contain that parser but needs a service flavor the substrate does not have. A workspace opts its guest in with `registry = on` (off by default: it hands the guest the address of host services), which `run_plan()` turns into the substrate's `REGISTRY_MIRRORS` — every cache, running or not, since each runtime falls back to the registry itself; `run` warns when none is running. Built from the same table as the caches, so their ports are stated once. Each cache pulls from its upstream's public endpoint unless `$XDG_CONFIG_HOME/airlock/registry` names another, a mirror on the LAN say, so caches chain (guest → host cache → mirror → registry); its own file, not a key in the defaults, because those are read only at `init` (D19) and this is read at every start, and not per workspace, because which remote a host's cache uses is the host's business: guests and plans are unchanged by it. Remotes are `http(s)://host[:port]` only — `distribution` takes a base URL, so a path-prefixed mirror cannot be reached, and credentials would land in a file under the cache directory. A cache must reach its remote to start (proxy mode asks it for `/v2/` and exits without an answer; verified 2026-10-16). `airlock registry import` proposes remotes from the host's `registries.conf`, read through registries-conf, a CLI around `go.podman.io/image/v5` itself (the library Podman, Buildah, Skopeo and CRI-O share), so its rules are neither restated in airlock nor asked of Podman, and writes them only on `--write`: an explicit, reviewable step rather than the caches reading registries.conf at every start, because those rules change with the library (the file search order just did) and differ between the versions on one host, and a host drop-in added for something else should not silently move what the caches pull from. |
| D22 | **`airlock stop` delegates to the substrate's `microvm-stop`, run from the substrate the VM was launched with.** airlock finds the task's launch under `$XDG_RUNTIME_DIR/<namespace>/vms/`, the namespace being the one its launch record names (D23) — the one whose lock is held and whose `instance.json` names this `work_dir/`, the task's context (D31) and its own directory as its `id` — and hands its ID to `microvm-stop`, taken from the substrate and nixpkgs in the launch record, not the config. | The substrate owns its launch directory and its QMP socket, and already ships the tool that presses a launch's power button and waits for it to go, with a `--force` for a guest that ignores it; reimplementing that would mean airlock talking QMP and following the substrate's layout. Taking the substrate from the launch record means a VM is stopped by the same tool its launcher shipped beside, whatever the config says now. Matching on `instance.json`, not on whether a VM is the only one running, is what keeps one task's `stop` off another's VM. **The trade accepted:** it reads `instance.json` with `jq`, which an installed build has and a checkout builds from `flake.lock`. |
| D23 | **airlock launches every VM in the substrate namespace `airlock-vm`** (`MICROVM_NAMESPACE`), a fixed name rather than a setting. Its units are `airlock-vm-<id>.*` in `airlock-vm.slice`, which systemd nests, by the dash, in `airlock.slice` beside the registry caches' `airlock-registry.slice` (D21); its launch directories are under `$XDG_RUNTIME_DIR/airlock-vm/vms/`. `run` hands it to the substrate outside the plan, overriding any the caller exports, and keeps it in the launch record as `namespace`, which is where `stop` looks (D22). | airlock's VMs and daemons are then one tree under one slice — `systemctl --user status airlock.slice` shows all of it — apart from VMs launched by hand or by other tools, and `stop` searches only airlock's launches. Outside the plan because it is airlock's, not the config's, so it is nothing for `status` to compare. Recorded, because the record is where `stop` looks. |
| D24 | **airlock names every VM `<workspace>.<task>`** (`MICROVM_NAME`), with any leading `.` and `_` dropped from the workspace's name, since the substrate wants a letter or digit first; a workspace name that is nothing else leaves the task's alone. `run` hands it to the substrate outside the plan and never passes on one the caller exports; it is not in the launch record. airlock sets `AGENT_HOME` itself, so the substrate's default agent home, which follows the name, never applies. | Left to itself the substrate names a launch after its project directory, which under airlock is `work_dir` for every task of every workspace, so `microvm-list`, the unit descriptions and the session contract could not tell one VM from another. The names are the ones the developer typed. Outside the plan for the reason D23 gives: it follows the workspace and the task, not the config. Not recorded, because nothing finds a launch by its name: `stop` matches on `work` and the context (D22, D31). **The trade accepted:** a workspace whose name starts with `.` or `_` shows without them, so `_x` and `x` look alike in a listing; their launch IDs and directories still differ. |
| D25 | **The hub carries the Git LFS objects of what tasks start from.** When a branch tip marks a path `filter=lfs` in a `.gitattributes`, `init` fetches the LFS objects of the default branch into the hub's own `lfs/` store — from the remote for `--from-remote`, from the checkout (`file://`) for `--from-local` with its origin filling in whatever the checkout lacks — and `fetch` does the same for each upstream's default branch. `task new` fetches those of the task's own starting point from the upstream, and checks the worktree out with git-lfs pointed at the hub's host path, since the clone's origin is the guest's. Each step says that it is fetching LFS objects; git-lfs's own output is kept, and shown only when it fails. The agent's clone gets the LFS filter and hooks in its own `.git/config` (`git lfs install --local`), so they hold in the guest whatever the host's global config says; the guest needs `git-lfs` on `PATH`, which the substrate provides. `--from-local` seeds with `push --no-verify`. A repository without LFS gets none of this. `git-lfs` is on the installed wrapper's `PATH`. | The clone's LFS endpoint is its origin, the hub, so a hub with pointers but no objects fails the clone's checkout outright ("remote missing object"); skipping smudge instead would leave the agent unable to read or change any LFS file. A local path is something git-lfs serves itself (its standalone file transfer), from the host and from the guest at `/work/<project>.git`, so no LFS server is involved and the hub stays the only channel (D2): the agent's new LFS objects land in the hub with its push. The checkout is tried first because it is local and needs no credential. `--no-verify` because the source's hooks are about publishing to its own remotes, and git-lfs's pre-push fails on a bare-path destination ("no valid file:// URLs found"). Not every branch, because a repository's branches can hold far more LFS data than anything an agent starts from: seeding a repository with hundreds of branches spent long enough fetching all of theirs to look hung. **Previously every branch tip at `init` and `fetch`.** **The trades accepted:** checking out an older commit, or another branch than its task started from, in the guest fails the same way until the developer fetches its objects into the hub (`git -C <hub> lfs fetch <upstream> <commit>`); a guest without `git-lfs` cannot push from the clone at all, because the LFS pre-push hook refuses; and publishing agent work that adds LFS files needs the objects in the developer's checkout first (`git lfs fetch hub <branch>`), since pushing to the forge uploads only what is local. A `.lfsconfig` naming an `lfs.url` overrides the hub as the endpoint, and is untested. |
| D26 | **Tasks: several agents on one workspace, one VM each.** A task is named and persistent: a host-side directory `tasks/<t>/` in the workspace root, a git worktree `work_dir/tasks/<t>/` on branch `agent/<t>`, its own agent home (D28), a context (D29) and a lock (D13). `airlock run <name> <task>` launches one. Any number of a workspace's tasks run at once, each in its own VM. Every run is a task's: `airlock run` needs one, and the clone is only the repository the worktrees belong to, which no agent works in. | Parallel work on one project, a bug fix in one VM and a feature in another, without a clone per line of work: a worktree gives each VM its own working tree and index while the objects are shared. What D13 protected was the working tree, and tasks keep one per VM. **The trade accepted:** every VM mounts all of `work_dir/`, since a worktree's `.git` points back into the clone's, so an agent can reach other tasks' worktrees and stomp on their work. The damage stays inside the guest/host boundary, and the hub's guardrails are unchanged (D17). |
| D27 | **Every launch mounts `/work` uncached** (`WORK_CACHE=never`). | Every worktree shares the clone's `.git`, and when one VM launches there is no knowing whether a second will start beside it. Measured: virtiofs's default caching lost ref and config updates between VMs, and `never` lost none, at about 45% lower throughput, paid even with one VM running. Git coordinates through lock files created exclusively and renamed into place, which the host's filesystem arbitrates between VMs once no VM answers from a cache. |
| D28 | **Each task has its own agent home**, `tasks/<t>/agent_home/`, which starts empty and is seeded by airlock at each launch. The substrate derives a task's container-image, store and egress directories from that path, so each task has its own, and `cri` works for tasks running at once. | One writer per home. Tools guard their caches with kernel file locks (SQLite, Gradle, Maven's resolver), which do not reach across VMs, so a home shared by VMs running at once is damaged silently; separate homes need no substrate change. **The trade accepted:** a login, dotfiles and Claude's auto-memory are not shared between tasks; each task pulls its own container images (the registry caches, D21, keep that cheap); and disk use grows with the number of tasks. |
| D29 | **A task's context is host-written and read-only to its agent** (`MICROVM_CONTEXT`): `tasks/<t>/context/`, holding `task.json`, which airlock writes, and the prompt and files the developer supplies, copied fresh to `/run/microvm/context` at each launch. The agent starts in its worktree (`MICROVM_START_DIR=/work/tasks/<t>`). Its first run asks it to read the context; later runs continue its conversation (`--continue`, for claude), and `run --fresh` starts a new one. | Starting in the worktree loads the workspace's and the project's own instructions and settings, and Claude Code keys sessions on the start directory, so each task resumes its own. What a task is for is the developer's to state, so the agent cannot edit it; it carries its progress in its branch and its conversation. The first prompt is a fixed pointer to the context, not the developer's text, so nothing the developer writes passes through the substrate's `eval` of the agent's command line. A flavor with no verified continue flag starts fresh each run, and `run` says so. |
| D30 | **Tasks are never removed automatically.** `airlock task rm` removes one, with its worktree, local branch, home, disks and context, after the check `airlock rm` makes for what would be lost: uncommitted changes, and commits the hub does not have. The hub's `agent/<t>` branch is left alone. | A task may span many stop/start cycles, short or long, and only the developer knows when it is done. The hub branch is the record of the work (D16) and outlives the task. |
| D31 | **A launch is identified by its context as well as its work dir.** `stop` and `status` take a task's launch to be the one whose `instance.json` names the task's context directory as `context`, A task's VM is named `<workspace>.<task>` (`MICROVM_NAME`). | `work` is the same `work_dir/` for every task, so it no longer tells launches apart; the context path does, and the substrate records it in `instance.json`. |
| D32 | **airlock requires the claude-microvm fork's launcher features**: per-launch directories with `instance.json` and `microvm-stop`, `MICROVM_NAMESPACE`, `MICROVM_NAME`, `MICROVM_CONTEXT` and `MICROVM_START_DIR`. A workspace's `substrate` may name another revision or a local checkout of such a substrate, not upstream claude-microvm. | Each is load-bearing: without the context and start directory a task's agent starts in `/work` with no task, silently; without the namespace and per-launch directories `stop` cannot find a VM. Hedging for a substrate that lacks them gave every decision that used them a second, broken behaviour to describe. Upstreaming the features is the way back to `systemstart/claude-microvm`. |
## 4. Workspace model

A workspace root is **not itself shared**. A task's VM mounts two directories from
it — `work_dir/` and the task's own `agent_home/`, named after the substrate's own
environment variables so the mapping is legible without reading airlock's source —
and everything else in it is airlock's private state:

```
<data-dir>/<workspace>/                  # workspace root — NEVER mounted into the guest
├── work_dir/                            # → WORK_DIR, mounted at /work (virtiofs, rw, uncached: D27)
│   ├── CLAUDE.md                        #   emitted by airlock; per-flavor filename
│   ├── <project>.git/                   #   bare hub — the airlock itself
│   ├── <project>/                       #   the clone the worktrees belong to, origin = /work/<project>.git
│   └── tasks/<t>/                       #   a task's worktree of the clone, on agent/<t> (D26)
├── tasks/<t>/                           # a task's own state (D26)
│   ├── context/                         #   → MICROVM_CONTEXT, read-only at /run/microvm/context (D29)
│   ├── agent_home/                      #   → AGENT_HOME, mounted at /home/agent (virtiofs, rw; D28)
│   ├── agent_home-cri/                  #   substrate-derived; only if CRI is enabled
│   ├── agent_home-store/                #   substrate-derived; per-run, removed on exit
│   └── lock                             #   the task's one-VM lock (D13), and its launch record
└── config                               # workspace config (§5)
```

The hypervisor's control socket is not here. The substrate keeps every socket a
launch uses, QEMU's QMP socket included, in that launch's own directory under
`$XDG_RUNTIME_DIR/airlock-vm/vms/<id>/` (D23), beside its `instance.json`; that
directory is not mounted into the guest either, so the guest cannot reach the
socket that controls its own VM. microvm.nix makes the socket a relative
`"<hostName>.sock"`, and the substrate rewrites it (D32). `run` still launches with
the root as its working directory, so that anything a substrate leaves relative
lands in the unmounted root rather than wherever the developer happened to
invoke airlock from.

A run holds its task's lock with `flock(1)`, on a descriptor that the launcher and
QEMU inherit, so the lock is held for as long as any of them runs — including a VM
that outlives the `airlock run` that started it — and the kernel releases it
however they exit. The file is removed once nothing holds it; one that is
present but not held was left by a run that was killed. **Previously the pid
alone**, checked with `kill -0`: that tracked the `airlock run` process rather
than the VM, so killing it outright made a live VM look stopped and let a
second VM onto the same working tree, and a pid reused after a crash or a reboot
made a stopped one look running.

The lock holds the running `airlock run`'s pid on its first line, for people to
read. The lines after it are the launch record: the substrate ref the run resolved, the nixpkgs it
overrode the substrate's input to (if any), the environment it handed the
substrate, the directory relative config paths were resolved from,
and the arguments given after `--`. A real launch also records the substrate's
locked revision and narHash, because a ref with no revision, or a local path,
can name something else later. `status` reads the record to say what a running
VM is on, and computes the launch again from the current config to say what has
changed since. Writing the record into the lock rather than a separate file
means it lives exactly as long as the run it describes.

Two mounts, two blast radii, and a root that is neither. Everything the guest can write
lives under `work_dir/` or its task's `agent_home/`; everything airlock relies on for
its own integrity lives beside them and is never exposed: the config a reviewer reads
(D9), the contexts (D29) and the locks (D13) cannot be rewritten from inside the VM.

Consequences worth encoding in `doctor`:

- **A task's `agent_home` must never be a symlink.** The substrate does
  `AGENT_DIR="$(realpath "$AGENT_HOME")"` and then derives `"$AGENT_DIR-cri"` and
  `"$AGENT_DIR-store"` by string suffix. A symlinked `agent_home` puts those disks
  next to the *target*, outside the workspace.
- **The `agent_home-*` directories are the substrate's names, not ours.** They
  break the `snake_case` convention and cannot be renamed without patching the
  substrate. They stay inside the workspace root, which keeps `airlock rm` a single
  directory removal.
- **A task's `agent_home/` is a second guest-writable share**, not private state. The
  dev-shell cache (D18), seeded settings, and the agent's credential all live there and
  can be rewritten from inside the VM.

Outside the workspace entirely: the **developer's own checkout** — anywhere, with a
`hub` remote pointing at `<workspace>/work_dir/<project>.git`.

### Tasks (D26–D31)

`init` makes the hub and the clone; it makes no task. A task is created with
`airlock task new <name> <task>`, which:

- makes `work_dir/tasks/<task>/` a worktree of the clone with `git worktree add
  --relative-paths`, so its links resolve in the guest as well as on the host. Its
  branch `agent/<task>` starts at the hub's default branch, or at `--base <ref>`, or at
  the hub's own `agent/<task>` when that exists, so a task can pick up a branch an
  agent pushed earlier;
- writes `tasks/<task>/context/task.json` (the task's name, branch, base and worktree
  path in the guest), and the developer's prompt as `prompt.md` (`--prompt`,
  `--prompt-file`) and any files they name (`--context <dir>`). The developer can edit
  the context between runs; each launch takes a fresh copy;
- makes `tasks/<task>/agent_home/`, empty.

`airlock run <name> <task>` hands the substrate the task's agent home,
`MICROVM_CONTEXT` and `MICROVM_START_DIR`, and the name `<workspace>.<task>`, and takes
the task's lock. When the task's home holds no conversation yet, the agent is asked to
read its context; otherwise it continues the last one, unless `--fresh`.

No agent works in the clone; it is the repository the worktrees belong to. Git refuses
to check out one branch in two worktrees, which keeps two tasks off one branch.

Commands that act on the whole workspace treat its tasks as part of it: `rm` refuses
while any of them runs, counts their unpushed work among what removal would lose, and
removes them with everything else; `status` reports each task; `doctor` checks each
task's home, context, worktree and lock. `fetch` is unaffected.

### Hub configuration

| Setting | Value | Why |
|---|---|---|
| `receive.denyNonFastForwards` | `true` | History rewrites refused; a pushed mistake is fixed with a new commit. Caught a real accidental rewrite in prior art. |
| `receive.denyDeletes` | `true` | Under D12 the agent runs unattended — without this it can delete branches it already pushed. `denyNonFastForwards` alone does not cover deletion. |

Both verified against a scratch hub: a force-push of an amended commit is rejected
(`denying non-fast-forward`), a branch deletion is rejected (`denying ref deletion`),
and an ordinary fast-forward push still succeeds.

**These are accident-level protections only (D17).** They bind `receive-pack`, and the
agent does not need `receive-pack` — the hub sits inside `work_dir/`, which is mounted
rw at `/work`, so the guest writes its files directly. Verified: with both settings `true`,
`git -C <hub> update-ref refs/heads/<branch> <unrelated-commit>` rewrote the branch and
`update-ref -d` deleted it, neither consulting the guardrails. Anything reachable at
`/work/<project>.git` is within the agent's reach, including the object store. airlock
supplies no compensating control (D16). The developer's checkout does: it is outside the
workspace, its `hub/*` remote-tracking refs record what was last fetched, and `git fetch`
reports a non-fast-forward as a `(forced update)` while leaving a deleted branch's last
tip in place unless asked to prune.

`init` must also set the hub's `HEAD` explicitly. `git init --bare` points it at
`refs/heads/master` regardless of which branch is actually seeded, and the agent's clone
then comes up with **no checkout at all** (`warning: remote HEAD refers to nonexistent
ref, unable to checkout`). Observed, not theorised.

`denyDeletes` carries an operational consequence: the *developer* cannot prune hub
branches by pushing a deletion either. Hub maintenance (§7) must prune with
`git -C <hub> update-ref -d refs/heads/<branch>` on the host, which bypasses
receive-pack entirely. Verified.

Under D1 the hub needs **none** of `core.sharedRepository`, `receive.unpackLimit=0`,
setgid directories, or the `agentshare` group. Those were cross-uid workarounds and are
retained only in §9's deferred mode.

### Notes

- The agent clone's `origin` is the **VM path** (`/work/<project>.git`), not the host
  path. The clone is the agent's exclusively, so the host never uses that remote.
- Upstream visibility (D8) — **validated** on a scratch hub, 2026-09-25:

  ```sh
  # hub: fetch a private upstream into a namespace that clones can see
  git -C <hub> remote add upstream <url>
  git -C <hub> config remote.upstream.fetch '+refs/heads/*:refs/upstream/upstream/*'
  git -C <hub> fetch upstream

  # agent clone: map that namespace to read-only remote-tracking refs
  git -C <clone> config --add remote.origin.fetch '+refs/upstream/*:refs/remotes/upstreams/*'
  git -C <clone> fetch origin     # -> upstreams/upstream/main, full history readable
  ```

  The agent reads upstream history with no credential and with no remote it could push to.

### Review model (D16)

**Branch convention: `agent/<topic>`, flat under `refs/heads/`.** The agent uses
entirely ordinary git — `git checkout -b agent/fix-parser`, `git push -u origin HEAD`,
with `pull` and `status` behaving normally. The convention is carried in the emitted
`work_dir/CLAUDE.md` (D14).

**The convention is legibility, not mechanism.** D17 means the agent writes hub refs
directly, so airlock cannot require a prefix and must never depend on one. *No check
may be built on the branch name.*

**Review happens in the developer's checkout, not in airlock.** The hub is added there
as an ordinary remote (`airlock path` prints it) and read with ordinary git:

```sh
git remote add hub "$(airlock path <name>)"
git fetch hub
git log  origin/main..hub/agent/fix-parser
git diff origin/main...hub/agent/fix-parser
```

Diffing against the developer's own remotes rather than the hub's copy of the default
branch is the point: that is the history the work will land on. airlock records nothing
about what has been read. The `hub/*` remote-tracking refs are that record, and they sit
outside the workspace where the agent cannot reach them.

**What `status` reports** is the hub as it stands: for each branch other than the
default, the commits the default branch does not have, with commits shared by stacked
branches counted once. `rm` uses the same measure to decide whether a workspace holds
work that would be lost. Neither knows what you have already read, and a commit the
agent pushed straight onto the default branch is not counted by either.

Publishing stays a separate, deliberate act from the developer's own checkout (D6) —
airlock never promotes branches, never creates a second copy that can drift, and never
touches a forge credential.
## 5. CLI surface (sketch)

```
airlock init <name> --from-remote <url> | --from-local <path>
airlock task new <name> <task> [--base <ref>] [--prompt <text> | --prompt-file <f>] [--context <dir>]
airlock task ls <name>                  a workspace's tasks, their branches, and which run
airlock task rm <name> <task>           remove a task, with confirmation (D30)
airlock run <name> <task> [--fresh]     launch a task's VM (D26)
airlock stop <name> <task> [--force]    power it off from outside, via the substrate (D22)
airlock status [<name>]                 workspaces, their tasks, branches ahead of default
airlock fetch <name>                    refresh hub from configured upstreams
airlock path <name>                     where the hub is, for `git remote add`
airlock doctor <name> [--fix]           verify invariants, report drift
airlock rm <name>                       tear down, with confirmation
airlock registry [start|stop] [<upstream>...]   pull-through image caches (D21)
```

The per-workspace config file declares at least: project name, upstream remotes, agent
flavor, resource caps, forwarded host environment variables, and the D12 opt-out.

## 6. Context composition (D14)

| Layer | Path | Owner |
|---|---|---|
| Substrate guidance (microVM disk-space rules) | guest `~/.claude/CLAUDE.md` — host `<workspace>/tasks/<t>/agent_home/.claude/CLAUDE.md` | `claude-microvm`, appended at boot |
| Workspace pointer (where to work, hub conventions, publish path) | guest `/work/CLAUDE.md` — host `<workspace>/work_dir/CLAUDE.md`, **outside the repo** | airlock, regenerated each launch |
| Project instructions | guest `/work/tasks/<t>/CLAUDE.md` — committed | the project |
| A task's own context (D29) | guest `/run/microvm/context/` — host `<workspace>/tasks/<t>/context/`, read-only in the guest | the developer, with airlock's `task.json` |

Agents inherit context from parent directories. A task's agent starts in
`/work/tasks/<t>`, which is a checkout of the project and whose ancestor `/work` holds
the workspace pointer, so the first three compose without airlock ever writing inside a
worktree. The context is not a parent, so it is not loaded on its own: the
first run's prompt points the agent at it. Per flavor, the middle row becomes `AGENTS.md` (Codex)
or `GEMINI.md` (Gemini).

## 7. Operational requirements

- **`doctor` / drift detection** — hub config (including both guardrails and `HEAD`),
  clone `origin`, remote definitions and refspecs, each task's worktree, stale locks,
  missing host prerequisites. Reports; `--fix`
  repairs what is safely repairable.

  Layout invariants from §4 belong here too: `work_dir/` and each task's `agent_home/`
  present and real directories (never symlinks — see the `realpath` note), no airlock
  state inside the share, and an `agent_home-store/` left behind by a crashed run rather
  than removed on exit.
- **Resource caps** — CPU, RAM, and disk ceilings per workspace, declared in config, so
  a runaway build cannot take the host down.
- **Hub maintenance** — `git gc` / `git maintenance` on the hub; pruning branches from
  finished sessions.

## 8. Testing

Mirrors the substrate's own approach — it tests behavior by extracting marked regions
from the *built* runner and executing them in a `runCommand`, without booting a VM. A
bash CLI doing git plumbing is more testable still.

- **Shell tests against real throwaway git repos** — `init`, hub configuration, upstream
  refspecs, what `status` and `rm` count, and every `doctor` drift check. No VM required.
- **Static checks** — `shellcheck`, `nix flake check`.
- **Boot smoke test** — documented and manual. GitHub's runners do not provide KVM, so
  CI covers build plus the shell tests only.

## 9. Known hazards to design around

1. **Dev-shell evaluation runs on the host** (see D18). The substrate's dev-shell feature
   (`DIRENV_ALLOW=1`) evaluates the shared directory's Nix code *outside* the VM before
   boot. Since the guest can write `work_dir/`, that is a guest→host path needing no
   kernel bug: Nix evaluation reads arbitrary host files and, via import-from-derivation,
   can trigger builds.

   Under airlock's layout the feature is **inert by default** — the substrate evaluates
   `$WORK/flake.nix`, and `$WORK` is `<workspace>/work_dir/`, which holds only
   `CLAUDE.md`, the hub, the clone and `tasks/`, and has no flake of its own. Opening the
   path requires deliberately pointing evaluation at a guest-writable worktree, which is
   exactly what the D18 opt-in does. A workspace that enables it accepts a guest→host
   evaluation path; the config flag exists so that acceptance is visible to a reviewer.

   Without the opt-in, the agent runs `nix develop` inside the guest instead. Measured:
   a trivial one-package dev shell cost **488 MB** of guest store overlay, and because
   that overlay is a per-run disposable disk, the cost recurs on **every launch**.

   **When it re-evaluates, and when it asks** (decided 2026-10-28, not yet
   implemented: `run_devshell_cache` still evaluates on every launch). The opt-in is
   consent to evaluating the tree as it stood when it was given, not to whatever the
   agent writes afterwards. So:

   - **The cache is keyed on what Nix will read**: the tree of the working tree's
     `HEAD` plus `git diff HEAD --binary`. That is what Nix's git fetcher takes —
     tracked files with their uncommitted changes, nothing untracked. A launch whose
     key matches the last evaluation's reuses the cache and evaluates nothing. The
     substrate's own gate hashes only the top-level `flake.nix`, `flake.lock` and
     devenv files, which misses a change to any `.nix` file they import, so airlock
     does not reuse it. Nix code that reads outside the tree (`--impure`, devenv) is
     not covered by the key; that is accepted.
   - **A changed key is asked about.** It means the code about to run on the host may
     be the agent's. airlock shows what changed since the last approved commit,
     uncommitted changes included, and asks before evaluating. A `no`, no answer, or
     no terminal keeps the previous cache and launches with it, as the substrate's
     own prompt does.
   - **The first evaluation is not asked about.** With no previous key, the tree is
     the one the task's worktree was made from, and turning the opt-in on is the
     approval of it.
   - **Each task is evaluated on its own** (D26): its worktree, into its own agent
     home, with its key and approval in `tasks/<t>/`, which the guest cannot write
     (D3) — never beside the cache in its `agent_home/`, where a guest that could
     write the record could make its own change look approved. Each task's branch may
     carry a different dev shell, and one task's change is asked about once, for that
     task.

   Implementation note: `DIRENV_ALLOW` gates two separate halves, and the opt-in needs
   both. On the host it gates *detection* — the substrate looks for a flake in `$WORK`,
   which under airlock's layout is `work_dir/`, holding only the hub, the clone and the
   worktrees, so that half finds nothing and warns. In the guest it gates *loading*: `base.nix` sources
   `~/.microvm-devshell` only when `DIRENV_ALLOW=1`. So airlock writes the cache itself,
   from the task's worktree rather than `$WORK`, **and** passes `DIRENV_ALLOW=1` so the
   guest will read it. Writing the cache alone leaves it written and ignored — which it
   was, until a question about this exposed it. The expected host-side warning that
   `$WORK` has no flake is harmless: an ineligible `$WORK` only warns and never clears a
   cache airlock wrote.

   Detection mirrors the substrate's own, because the two must agree about what a
   project is: `flake.nix` alone evaluates plainly, `flake.nix` *with* `devenv.nix`
   needs `--impure`, and `devenv.nix` (or the older `.devenv.flake.nix`) with no
   `flake.nix` needs `devenv print-dev-env` instead, since there is nothing for
   `nix print-dev-env` to evaluate. A devenv project with no `devenv` on PATH is
   reported rather than attempted. That cache lives in a guest-writable share, so the guest can
   rewrite it; the blast radius is the guest's own shell.
2. **Guest user namespaces** give an unprivileged guest user a route toward guest root.
   The VM is the boundary; airlock must never present guest-internal user separation as one.
3. **virtiofsd descriptor exhaustion** — a large tree walk in the guest exhausts the
   daemon's file descriptors, after which every share operation fails with `Too many
   open files` while guest-side counters look healthy. It does not clear on its own and
   retrying worsens it. The substrate ships an in-guest recovery command; airlock should
   surface it, and `doctor` should detect the condition.
4. **Never copy files between host and guest.** `rsync -a` between the two silently
   reverted edited files twice in prior art by preserving mtimes from an older snapshot.
   Git is the only transport.
5. **Absolute paths for local remotes in scripts** — `git -C <dir> push … <relative>`
   resolves against `-C`, not the shell's cwd.
6. **Guard optional sysfs reads**; `set -e` plus a missing `intel_pstate` aborted
   host-state capture in prior art.
7. **First build may compile QEMU from source** (~20 min) unless a binary cache is
   enabled — and enabling one is a trust decision. `doctor` should detect and explain
   this before a teammate meets it as an unexplained hang.

## 10. Deferred: hardened identity mode

Under D1, a VM escape holds the developer's account. Two upgrade paths, neither in v1:

- **Dedicated unprivileged service account** (one privileged install step; runtime still
  unprivileged). An escape lands in an account with no sudo, no wheel, an empty home, no
  keys, and kernel-enforced separation from the developer. Requires the cross-identity
  exchange layer — exactly what `CLAUDEINIT.md` documents, including why
  `receive.unpackLimit=0` is load-bearing there.
- **Rootless subuid namespace** — QEMU inside a user namespace mapped to the developer's
  `/etc/subuid` range, so an escape is a nobody-uid. Same containment property with no
  root at all, but inherits the cross-identity file-ownership problem with less mature
  tooling.

Orthogonal to both, and cheap: hardening the launcher's own process —
`NoNewPrivileges`, a capability bounding set, `ProtectHome`, `RestrictNamespaces`,
seccomp. Worth doing even under D1.

## 11. Open items

None outstanding. All requirements questions raised in the 2026-09-25 conversations are
settled in §3.

*(Closed 2026-09-25: the upstream refspec scheme, both hub guardrails, and the hub-`HEAD` requirement were validated against a scratch hub — see §4. D16 ratified with watermarks relocated host-side; D17 added after verifying that filesystem access to the hub bypasses its guardrails; D18 settled after measuring the in-guest `nix develop` cost at 488 MB per launch. D16 fully ratified 2026-09-25: `agent/<topic>` convention, watermark semantics, and accept-only-advances — see §4 "Review model".)*

*(Revised 2026-10-05: D16's watermarks and the `review` command removed; review is the developer's own git against the hub. See D16 for the trade.)*

*(Revised 2026-10-28: D18 re-evaluates the dev shell only when the Nix source changes, and asks before evaluating a change the agent may have made. The key and approval live in the workspace root. See §9.1.)*

*(Revised 2026-10-28: tasks (D26–D31) run several agents on one workspace, each in its own VM, worktree and agent home. D13 is now one VM per working tree; D3, D14, D22 and D24 are amended to match.)*

*(Revised 2026-10-28: every run is a task's — the workspace's own run, its `agent_home/` and the root lock are gone (D13, D26) — and airlock requires the fork's launcher features (D32) rather than hedging for a substrate without them.)*

*(Revised 2026-10-29: D25 fetches LFS objects for the default branch at `init` and `fetch` and for a task's starting point at `task new`, rather than every branch tip, says when it is doing so, and keeps git-lfs's output out of the terminal unless it fails.)*
