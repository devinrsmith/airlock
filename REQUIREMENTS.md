# airlock — requirements

Status: **draft for review.** Derived from requirements conversations on 2026-09-25.
No implementation has begun.

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
> as a Nix flake from our own org, so the collision is cosmetic — but docs should not
> assume an unqualified search finds us.

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
| Prompt injection steering the agent | No forge credentials, no SSH keys, no host secrets in the guest. Code leaves only as commits the developer reviews before pushing anywhere real. A steered agent **can** rewrite or destroy hub history (D17); host-side watermarks (D16) detect it after the fact but do not prevent it. |
| Hostile code executed inside the guest | VM boundary: separate kernel, separate process tree, no host port binding. Guest-internal user separation is explicitly **not** a boundary. |
| VM escape | Accepted risk in v1: an escape lands in the launching user's account. §9 defines the upgrade path. |

Accepted knowingly in v1: an escape is the launching user. The judgment is that a VM
boundary is already a high bar, and shipping the simpler rootless design first is worth
more than the marginal containment of a service account.

## 3. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Same-user, fully rootless.** The developer launches the VM; no dedicated account, no group, no ACLs, no privileged install step. | Simplest thing that keeps the VM boundary. Removes every cross-uid workaround in `CLAUDEINIT.md`. |
| D2 | **The bare git hub is the only write channel** between developer and agent. Neither side writes into the other's working tree. | Under D1 this is policy, not a permissions workaround: it bounds the agent's reach and makes every transfer a reviewable commit. |
| D3 | **The workspace root is never mounted.** Only its `work_dir/` (→ `/work`) and `agent_home/` (→ `/home/agent`) children are; airlock's own state sits beside them, and the developer's checkout is outside the workspace entirely. | The two mounts *are* the blast-radius limit, and an unmounted root gives airlock somewhere the guest cannot reach — which is what D16 depends on. |
| D4 | **Tool-owned workspace directories**, seeded from either a forge URL or an existing local checkout. | Predictable layout makes `doctor`, maintenance, and cleanup tractable. |
| D5 | **Only the agent's API credential lives in the guest.** No SSH keys, no forge tokens. | An injected or malicious command can burn tokens; it cannot touch the developer's forge account. |
| D6 | **Publish path: agent pushes to hub → developer reviews → developer pushes to forge** from their own account. | Human review is the gate on anything leaving the machine. |
| D7 | **Unrestricted guest network.** The guest may fetch public remotes and pull packages directly. | It already needs the network for the agent API and dependencies; pretending otherwise buys little. |
| D8 | **Private upstreams reach the agent only through the hub.** The developer configures remotes on the hub and fetches into it; the agent reads them read-only from its clone. | Credentials stay host-side. This is *uncredentialed*, not *enforced* — anything public the guest can always reach directly. |
| D9 | **Single CLI + per-workspace config file.** Substrate env vars and Nix invocations never appear in the user's hands. | The config file is also what a reviewer reads to see what a workspace may do. |
| D10 | **Bash, packaged as a Nix flake**, with the substrate vendored as a git submodule under `substrate/`. | Matches the substrate's idiom; the tool is largely orchestration of `git` and the launcher. Auditable line-by-line. The submodule pins the VM's version to a commit in airlock's own history rather than to whatever github serves today — at the cost of `?submodules=1` on any flake reference used to install airlock, because flakes otherwise leave submodules out of the source tree. A build without it keeps working for everything except `run`, which fails loudly rather than reaching for github behind your back. |
| D11 | **All four agent flavors supported** (Claude Code default; Gemini, Codex, Pi documented as less-exercised). | The substrate normalizes them to one interface; a flavor differs for airlock in exactly three facts — flake attribute, settings path, context filename. A four-row table. |
| D12 | **Agent runs with permission prompts disabled by default.** Per-workspace opt-out in config. | The ergonomic payoff of virtualizing. The VM is the boundary, so in-guest prompts are asking the wrong layer for consent. (Originally justified as "paired with hub guardrails" — see D17 for why that pairing does not hold.) |
| D13 | **One VM per workspace, enforced by a lockfile.** Parallel work means a second workspace. | Two agents sharing one clone corrupts it. |
| D14 | **Three-layer context composition** (§6); airlock owns only `work_dir/CLAUDE.md`. | Three files, three owners, no overlap, and airlock never writes inside the clone. |
| D15 | **No audit trail in v1.** The hub's reflog already records what arrived and when. | Least to build; the agent's own transcripts persist in agent home regardless. |
| D16 | **Agent branches are `agent/<topic>` by convention; `review` diffs against a host-side watermark and `--accept` advances it and nothing else.** Watermarks live in `<workspace>/watermarks/`, a sibling of `work_dir/` in the unmounted workspace root (D3). Full model in §4. | Exact incremental review across sessions. Kept outside the share because the hub is agent-writable (D17) — a watermark stored there could be forged to hide work from review. Outside, it also becomes tamper *detection*: a reviewed commit no longer reachable in the hub means history was rewritten or pruned. |
| D17 | **The hub lives inside `work_dir/` and its `receive.*` guardrails are anti-accident, not enforcement.** Documented as such rather than engineered around. | Verified: `receive.denyNonFastForwards` and `receive.denyDeletes` bind `receive-pack` only. The agent has filesystem write access to the hub via `/work`, so `git -C /work/<project>.git update-ref` rewrites or deletes any ref with both settings `true` and neither consulted. Alternatives (a host-only canonical hub mirrored inward; a protocol-only write path over the slirp gateway) were considered and declined for v1 complexity. |
| D18 | **Dev shells are off by default, with a per-workspace opt-in** that pre-evaluates on the host. Without it, the agent uses `nix develop` in the guest. | Cheapest option that keeps the convenience available. The opt-in knowingly reopens a guest→host evaluation path (§9.1) for workspaces that choose it; the alternative considered was evaluating only trusted sources (the developer's checkout, or a reviewed commit exported out of the share), which stays available later — airlock picks the evaluated path, so it is a change of source, not a redesign. |
| D19 | **User-level defaults for new workspaces** live in `$XDG_CONFIG_HOME/airlock/config` and are **baked into a workspace's config at `init`**, not layered underneath it at every read. | A person should not have to retype their committer identity or settings dotfile for every workspace. Baked rather than layered because D9 makes the workspace config the statement of what that workspace does — that stops being true the moment half of it lives somewhere else, and a reviewer reading one config would be reading an incomplete answer. The consequence is deliberate: changing the defaults affects the next workspace and never an existing one. |

## 4. Workspace model

A workspace root is **not itself shared**. It holds two directories that are mounted
into the guest — named after the substrate's own environment variables, so the mapping
is legible without reading airlock's source — plus airlock's private state alongside
them:

```
<data-dir>/<workspace>/                  # workspace root — NEVER mounted into the guest
├── work_dir/                            # → WORK_DIR, mounted at /work (virtiofs, rw)
│   ├── CLAUDE.md                        #   emitted by airlock; per-flavor filename
│   ├── <project>.git/                   #   bare hub — the airlock itself
│   └── <project>/                       #   agent's clone, origin = /work/<project>.git
├── agent_home/                          # → AGENT_HOME, mounted at /home/agent (virtiofs, rw)
├── agent_home-cri/                      #   substrate-derived; only if CRI is enabled
├── agent_home-store/                    #   substrate-derived; per-run, removed on exit
├── config                               # workspace config (§5)
├── watermarks/                          # review state (D16) — unreachable from the guest
├── lock                                 # one-VM-per-workspace lock (D13)
└── <hostname>.sock                      # hypervisor control socket, while a VM runs
```

The control socket is there because `run` launches with this directory as its
working directory. microvm.nix defaults `microvm.socket` to `"<hostName>.sock"`,
a *relative* path, and QEMU opens it relative to its cwd — so without that it
lands wherever the developer happened to invoke airlock from. The unmounted root
is the right home for it: the guest must not be able to reach the socket that
controls its own VM, which is also why it does not go in `work_dir/` or
`agent_home/`. (The substrate rewrites the two virtiofs sockets to absolute
paths under `XDG_RUNTIME_DIR`; this is the one it leaves relative.)

Two mounts, two blast radii, and a root that is neither. Everything the guest can write
lives under `work_dir/` or `agent_home/`; everything airlock relies on for its own
integrity lives beside them and is never exposed. This is what makes D16's watermarks
tamper-proof rather than merely inconvenient to forge.

Consequences worth encoding in `init` and `doctor`:

- **`agent_home` must never be a symlink.** The substrate does
  `AGENT_DIR="$(realpath "$AGENT_HOME")"` and then derives `"$AGENT_DIR-cri"` and
  `"$AGENT_DIR-store"` by string suffix. A symlinked `agent_home` puts those disks
  next to the *target*, outside the workspace.
- **The two `agent_home-*` directories are the substrate's names, not ours.** They
  break the `snake_case` convention and cannot be renamed without patching the
  substrate. They stay inside the workspace root, which keeps `airlock rm` a single
  directory removal.
- **`agent_home/` is a second guest-writable share**, not private state. The dev-shell
  cache (D18), seeded settings, and the agent's credential all live there and can be
  rewritten from inside the VM.

Outside the workspace entirely: the **developer's own checkout** — anywhere, with a
`hub` remote pointing at `<workspace>/work_dir/<project>.git`.


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
`/work/<project>.git` is within the agent's reach, including the object store. The
compensating control is detection, not prevention: host-side watermarks (D16) live
in the unmounted workspace root (§4), so a reviewed commit gone missing from the hub is
evidence.

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
directly, so airlock cannot require a prefix and must never depend on one. What
identifies agent work is that airlock performs every developer-side push into the hub
itself and records the tips it wrote; any ref in the hub that airlock did not put there
is the agent's, whatever it is named. *No check may be built on the branch name.*

**Watermarks** are stored one file per ref, mirroring the ref path, containing the
reviewed commit:

```
<workspace>/watermarks/refs/heads/agent/fix-parser   ->  <sha>
```

Mirroring the hierarchy avoids escaping the slashes in branch names, and the whole tree
sits in the unmounted workspace root, so the guest can neither read nor forge it.

**What `review` diffs:**

- Watermark present → `<watermark>..<tip>`; only what arrived since you last accepted.
- No watermark (first sight of a branch) → merge-base with the hub's default branch,
  i.e. the whole branch.
- Watermark present but **the commit is no longer reachable** from any hub ref → refuse
  to diff and report tampering. Under D17 this is the expected signature of an agent
  that rewrote or pruned history, and it is the one condition `review` and `doctor`
  should surface loudly rather than repair.

**`--accept` advances the watermark and does nothing else.** It means "I have read up
to here." Publishing stays a separate, deliberate act from the developer's own checkout
(D6) — airlock never promotes branches, never creates a second copy that can drift, and
never touches a forge credential.
## 5. CLI surface (sketch)

```
airlock init <name> --from-remote <url> | --from-local <path>
airlock run <name>                      launch the agent VM
airlock status [<name>]                 workspaces, running VMs, branches ahead of watermark
airlock fetch <name>                    refresh hub from configured upstreams
airlock review <name> [--accept]        diff since watermark; --accept advances it
airlock doctor <name> [--fix]           verify invariants, report drift
airlock rm <name>                       tear down, with confirmation
```

The per-workspace config file declares at least: project name, upstream remotes, agent
flavor, resource caps, forwarded host environment variables, and the D12 opt-out.

## 6. Context composition (D14)

| Layer | Path | Owner |
|---|---|---|
| Substrate guidance (microVM disk-space rules) | guest `~/.claude/CLAUDE.md` — host `<workspace>/agent_home/.claude/CLAUDE.md` | `claude-microvm`, appended at boot |
| Workspace pointer (where to work, hub conventions, publish path) | guest `/work/CLAUDE.md` — host `<workspace>/work_dir/CLAUDE.md`, **outside the repo** | airlock, regenerated each launch |
| Project instructions | guest `/work/<project>/CLAUDE.md` — committed | the project |

Agents inherit context from parent directories, so the three compose without airlock
ever writing inside the clone. Per flavor, the middle row becomes `AGENTS.md` (Codex)
or `GEMINI.md` (Gemini).

## 7. Operational requirements

- **`doctor` / drift detection** — hub config (including both guardrails and `HEAD`),
  clone `origin`, remote definitions and refspecs, orphaned VMs, leftover virtiofsd
  daemons, share health, stale locks, missing host prerequisites. Reports; `--fix`
  repairs what is safely repairable.

  Layout invariants from §4 belong here too: `work_dir/` and `agent_home/` both present
  and both real directories (never symlinks — see the `realpath` note), no stray files
  at the workspace root that the guest might be assumed to see, `watermarks/` intact,
  and an `agent_home-store/` left behind by a crashed run rather than removed on exit.
  Watermark consistency is the security-relevant one: a watermarked commit that is no
  longer reachable in the hub means history was rewritten or pruned (D16/D17), and
  `doctor` should say so loudly rather than repair it.
- **Resource caps** — CPU, RAM, and disk ceilings per workspace, declared in config, so
  a runaway build cannot take the host down.
- **Hub maintenance** — `git gc` / `git maintenance` on the hub; pruning branches from
  finished sessions.

## 8. Testing

Mirrors the substrate's own approach — it tests behavior by extracting marked regions
from the *built* runner and executing them in a `runCommand`, without booting a VM. A
bash CLI doing git plumbing is more testable still.

- **Shell tests against real throwaway git repos** — `init`, hub configuration, upstream
  refspecs, review watermarks, and every `doctor` drift check. No VM required.
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
   `CLAUDE.md`, `<project>.git/` and `<project>/` and has no flake of its own. Opening the path
   requires deliberately pointing evaluation at the guest-writable clone, which is
   exactly what the D18 opt-in does. A workspace that enables it accepts a guest→host
   evaluation path; the config flag exists so that acceptance is visible to a reviewer.

   Without the opt-in, the agent runs `nix develop` inside the guest instead. Measured:
   a trivial one-package dev shell cost **488 MB** of guest store overlay, and because
   that overlay is a per-run disposable disk, the cost recurs on **every launch**.

   Implementation note: the substrate caches the evaluated environment at
   `$AGENT_HOME/.microvm-devshell` (plus a `.hash` sibling) and sources it at boot, so
   the opt-in is airlock writing that file — under the new layout,
   `<workspace>/agent_home/.microvm-devshell` — from an evaluation of its own choosing,
   rather than setting `DIRENV_ALLOW=1` and letting the substrate evaluate `$WORK`.
   That cache is inside a guest-writable share, so the guest can rewrite it; the blast
   radius is the guest's own shell.
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
