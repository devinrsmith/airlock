# airlock

Isolated, virtualized coding-agent workspaces. An agent runs in a microVM whose
only channel to your machine is a bare git repository — it never sees your
working tree, your credentials, or your processes.

**Status: pre-release, used by its one developer. Every command is implemented,
and `run` boots real guests.**

**Until there is a release, any change may break what exists**: workspace
layout, config keys, launch records, which substrate features are required.
Nothing is migrated and nothing older is kept working. When an update breaks a
workspace, fetch what you want from its hub, then `airlock rm` it and `airlock
init` it again.

[REQUIREMENTS.md](REQUIREMENTS.md) is the design: its decisions, the threat model,
and the hazards worth knowing before trusting any of this.

## Install

```sh
nix profile install github:devinrsmith/airlock
```

Or run it without installing:

```sh
nix run github:devinrsmith/airlock -- status
```

From a checkout:

```sh
git clone https://github.com/devinrsmith/airlock
cd airlock && ./bin/airlock status
```

## What a workspace is

```
<data-dir>/ws/<workspace>/     workspace root — never mounted into the guest
├── work_dir/                  → mounted at /work
│   ├── CLAUDE.md              emitted; tells the agent where to work
│   ├── .repo/                 the bare repository the tasks' worktrees share
│   └── tasks/<task>/          a task's worktree, where its agent works
├── <project>.git/             the hub — agents push here, over the hub service
├── agent_key                  its agents' key to the hub service
├── tasks/<task>/              a task's context, agent home and lock
│   └── agent_home/            → mounted at /home/agent, for that task's VM
└── config                     what this workspace is allowed to do
```

`<data-dir>` is `$XDG_DATA_HOME/airlock`, usually `~/.local/share/airlock`
(`AIRLOCK_DATA_HOME` overrides it). A task's VM mounts `work_dir/` and the task's own `agent_home/`; the root is
not mounted. Everything airlock relies on for its own integrity lives beside
them, out of the agent's reach — the hub included.

## Usage

```sh
airlock init <name> --from-local /path/to/checkout
airlock init <name> --from-remote https://github.com/acme/widget

airlock task new <name> <task> --prompt "what it is for"
airlock run <name> <task>         # launch the task's VM
airlock run <name> <task> --dry-run   # show the launch environment without booting
airlock stop <name> <task>        # power its VM off from outside (--force: at once)
airlock status                    # every workspace: its tasks, and what agents pushed
airlock status <name>             # one workspace in detail
airlock fetch <name>              # refresh the hub from its upstreams
airlock doctor <name> [--fix]     # verify invariants, repair safe drift
airlock rm <name>                 # tear it down, with confirmation
airlock path <name>               # where the hub is, for `git remote add`
airlock git <name> <task> status  # git in a task's worktree, sandboxed
airlock hub start                 # the service guests fetch from and push to
airlock registry start            # pull-through image caches for guests
```

Then, in your own checkout:

```sh
git remote add hub "$(airlock path <name>)"
git fetch hub
```

`airlock path` exists so the layout stays airlock's business and not yours. It
prints one bare line and nothing else, and takes `--repo`, `--root` or
`--config` when you want a different part of the workspace, and `--task <task>`
for one of its tasks.
`airlock status <name>` prints the `git remote add` line ready to copy.

Work the agent pushes arrives on `agent/*` branches in the hub. You review it
with your own git, against your own remotes, and publish it yourself: no forge
credential ever exists inside the VM.

```sh
git fetch hub
git log  origin/main..hub/agent/fix-parser
git diff origin/main...hub/agent/fix-parser
```

A repository that uses Git LFS works through the hub too: `init` and `fetch`
carry the LFS objects of the default branch into it, `task new` those of the
task's starting point, and the agent's new ones arrive with its pushes. On a
large repository or a slow link these are the slow steps, and each says so. Before publishing a branch that adds LFS files, fetch them into
your checkout, since a push uploads only the LFS objects you have locally:

```sh
git lfs fetch hub agent/fix-parser
```

airlock keeps no record of what you have read. Your checkout's `hub/*`
remote-tracking refs are that record. Agents cannot rewrite or delete a branch
in the hub: it refuses both. `airlock status` lists the hub branches carrying
commits its default branch does not have.

## Tasks

Every agent runs as a task: a named line of work with a VM of its own, so one
agent can fix a bug while another builds a feature on the same project.

```sh
airlock task new <name> fix-parser --prompt "The parser drops trailing commas; fix it."
airlock run <name> fix-parser          # its own VM, beside any others
airlock run <name> fix-parser --fresh  # a new conversation instead of the last one
airlock stop <name> fix-parser
airlock task ls <name>
airlock task rm <name> fix-parser      # asks first if it holds unpushed work
```

Each task gets:

- a worktree at `/work/tasks/<task>`, on the branch
  `agent/<task>`, which it pushes to the hub like any agent branch. It starts
  from the hub's default branch, or `--base <ref>`, or the hub's own
  `agent/<task>` if an agent pushed one before;
- a **context** the agent can read but not change, at `/run/microvm/context`:
  your prompt as `prompt.md`, any files you add with `--context <dir>`, and a
  `task.json` airlock writes. Edit it between runs at
  `$(airlock path <name> --task <task>)`; each launch takes a fresh copy;
- an agent home of its own, starting empty. Logins, dotfiles and Claude's
  memory are not shared between tasks, and a task with `cri` set has its own
  image disk.

The first run asks the agent to read its context. Later runs continue the same
conversation (claude only; other flavors start afresh and say so). A task stays
until you remove it, across as many runs as it takes.

Every VM of a workspace mounts all of `/work`, so an agent can see other
tasks' worktrees, and could damage them. The workspace instructions tell it to
keep to its own; nothing enforces that. `/work` is mounted without caching,
which keeps git consistent between VMs at some cost in speed.

## Showing and editing config

```sh
airlock config --list                        # your defaults for new workspaces
airlock config user_email you@example.com    # set one
airlock config --edit                        # open it in $EDITOR

airlock config --workspace demo --list       # one workspace's own config
airlock config --workspace demo cpus 2
airlock config --workspace demo --unset cri
```

There is no merged view, because there is no merge: the global file is a
template `init` reads once. A listing is always of exactly one file. Values are
checked when you type them, and setting a key leaves the file's comments alone.

A few keys were applied somewhere else at init — the committer identity is in
the git config the tasks' worktrees share, the flavor decided which context file was emitted.
`config` edits text only and says so; `airlock doctor <name> --fix` reconciles.

## Authenticating the agent

Each task has its own agent home, so an interactive login is per task: log in
once inside one task's VM and a *different* task will ask again. The way to
avoid that is an API key in your own environment, which airlock passes through
and the substrate hands to the guest:

```sh
export ANTHROPIC_API_KEY=...   # claude, and pi
export GEMINI_API_KEY=...      # gemini
export OPENAI_API_KEY=...      # codex
```

`run` warns when the variable for the workspace's flavor is unset, because a
first boot with neither a key nor a stored session is a login prompt nobody is
there to answer.

The key does not reach the workspace: the substrate hands it to each launch in
that launch's own directory under `$XDG_RUNTIME_DIR`, on a share the guest reads
but cannot write. The difference from a stored login is that it is re-derived
from your environment every time rather than being a long-lived token a task
owns — delete the workspace and there is nothing left to revoke.

airlock deliberately does not copy your `~/.claude/.credentials.json` into new
tasks. It could, but a long-lived token copied into every task is
several things to revoke instead of one, and the copies drift as the agent
refreshes them.

## Defaults for new workspaces

Settings you want on every workspace you create go in
`~/.config/airlock/config`, in the same `key = value` format as a workspace's
own config:

```
user_name  = Your Name
user_email = you@example.com
settings   = ~/dotfiles/claude-settings.json
cpus       = 8
```

They are baked into each workspace's config when `init` writes it, not consulted
afterwards. So changing this file affects the next workspace and never an
existing one, and a workspace's config stays the whole statement of what that
workspace does. A key airlock does not read is reported rather than ignored.

Settable: `flavor`, `user_name`, `user_email`, `prompts`, `devshell`, `cpus`,
`memory_mb`, `substrate`, `env_forward`, `agent_args`, `settings`, `cri`,
`cri_storage_mb`, `store_size_mb`, `registry`, `pause`. A command-line flag
still wins over any of them.

`pause = off` boots without waiting for Enter on the session contract the
substrate prints before launch (it still prints). Set it if you launch from
tmux, scripts or IDE tasks; the wait is already skipped when stdin is not a
terminal.

## The substrate

The microVM itself is a fork of
[claude-microvm](https://github.com/systemstart/claude-microvm) (the `airlock`
branch of `devinrsmith/claude-microvm`), a flake input pinned in `flake.lock`.
airlock needs what the fork adds: per-launch directories and `microvm-stop`, a
namespace and a name for each VM, and a per-launch context and start directory
for tasks. Upstream claude-microvm lacks them and will not work. airlock never builds it: `run` shells out
to `nix run <ref>#<flavor>` at launch, so all airlock needs from the lock is the
revision. Bump it deliberately:

```sh
nix flake update claude-microvm
```

An installed airlock has that reference baked into its wrapper, so it launches
the microVM its build was locked against. A source checkout reads the same
revision out of `flake.lock`, so the two cannot drift apart.

The microVM also runs on airlock's nixpkgs rather than the one claude-microvm
locks: `run` passes `--override-input nixpkgs` with the revision in airlock's
`flake.lock`, so `nix flake update nixpkgs` moves the registry and the guest
together. Nix says "not writing modified lock file" at each launch; that is the
override. The first launch after a bump builds the guest's system closure
locally.

A workspace can pin itself to another revision or a local checkout of the fork
with `substrate = <flake ref>` in its config, and then runs that flake exactly
as it is locked, on its own nixpkgs. `airlock status` marks such a workspace with `*`, and
`airlock status <name>` names the ref and the nixpkgs it launches.

A running task's VM was *launched* with whatever the config said then, which
`run` records in the task's lock: change the config under a running task and
`status` marks the workspace `!`, and `airlock status <name>` names the keys that
changed. They
take effect on the next `run`.

## The hub

The hub is the bare repository agents push to and you fetch from. It lives in
the workspace root, which no VM mounts, so nothing in a guest can write it
directly: guests reach it only through the hub service, an `sshd` airlock runs
on this host's loopback.

```sh
airlock hub start     # once; it keeps running, like the registry caches
airlock hub status
airlock hub stop
```

Start it before running tasks: without it an agent works but cannot fetch or
push, and `airlock run` says so. Each workspace has its own key, which reaches
its own hub and nothing else, and only for `git fetch` and `git push`: no shell,
no forwarding. Since a push is the only way in, the hub's refusals of
force-pushes and branch deletions are enforced. `airlock rm` revokes a
workspace's key.

The service keeps its own files in `~/.local/state/airlock/hub/`
(`$XDG_STATE_HOME/airlock/hub`): its host key, `sshd_config`, the command each
key is forced to and `authorized_keys`. They live in the state directory, not
beside the workspaces, because airlock rebuilds them: `hub start` rewrites
them from the workspaces, and a lost host key is replaced and handed to each
guest at its next launch. There is nothing there to back up. The hubs
themselves live in the workspaces.

From your own checkout nothing changes: `airlock path <name>` is the hub's path
on this host, and you fetch from it directly. A worktree's `origin` reaches
the hub by its path on the host, and over SSH only inside a guest; but read
[Git on the host](#git-on-the-host) before running git in one yourself.

Two limits for now:

- **No Git LFS through the hub.** LFS content reaches the hub on the host, for
  what tasks start from, so agents see real files. But an agent's *new* LFS
  files reach the hub as pointers only; their content stays in the workspace's
  `work_dir/.repo/lfs/`.
- **Not under sealed egress.** The `shadow` and `enforce` network policies close
  the guest's route to this host, so the hub, like the registry caches, is
  unreachable there.

## Git on the host

Everything in `work_dir/` is the agent's to write, the repository's config and
hooks included, and git runs what those name: a `core.fsmonitor` command at
`git status`, a filter driver at checkout, a hook at any branch update. So
airlock never runs plain git there. Every git command it runs on
`work_dir/.repo` or a worktree overrides the settings known to start a program
and runs inside [bubblewrap](https://github.com/containers/bubblewrap), which
sees only the system directories, `work_dir/`, and the hub read-only: no home
directory, no other workspace, no network.

The installed `airlock` brings its own bubblewrap. Where a distribution allows
user namespaces only to its own copy (Ubuntu's AppArmor policy), point airlock
at it:

```sh
export AIRLOCK_BWRAP=/usr/bin/bwrap
```

If no sandbox can be made, airlock refuses and says so. `AIRLOCK_GIT_SANDBOX=off`
runs git unconfined instead, still with the overrides, and warns every time.

The same caution applies to you. Review an agent's work by fetching the hub
into your own checkout, not by running git, an editor's git integration or a
build inside `work_dir/`. To look at a task's worktree itself, its uncommitted
changes say, use `airlock git`, which runs git there the way airlock does:

```sh
airlock git <name> <task> status
airlock git <name> <task> diff --stat
airlock git <name> <task> -- log --oneline origin/main..
```

It sees the workspace's `work_dir/` and, read-only, its hub, so `fetch origin`
works and a push does not. There is no pager or editor: give a commit message
with `-m`. Paths are relative to the worktree, and git's exit status is
airlock's.

## Registry caches

Every guest pulls its container images from scratch. `airlock registry` runs
pull-through caches on this host, so an image is fetched from the internet once
and from local disk after that:

```sh
airlock registry start              # all upstreams; or name some
airlock registry                    # what is running, and how much each holds
airlock registry stop               # the cached data is kept
airlock registry restart            # after editing the remotes file

systemctl --user status airlock-registry.slice   # every cache, with memory and CPU
systemctl --user status airlock.slice        # all of airlock: the caches, and every VM (airlock-vm.slice)
journalctl --user -t airlock-registry-docker.io   # one cache's log
```

| Upstream | Host | From a guest |
|---|---|---|
| `docker.io` | `127.0.0.1:5101` | `10.0.2.2:5101` |
| `ghcr.io` | `127.0.0.1:5102` | `10.0.2.2:5102` |
| `quay.io` | `127.0.0.1:5103` | `10.0.2.2:5103` |
| `registry.k8s.io` | `127.0.0.1:5104` | `10.0.2.2:5104` |

Each is the Docker registry (`distribution`, from the nixpkgs in `flake.lock`)
in proxy mode, run as a `systemd --user` unit: no root, nothing to install, and
it stops with your user manager — at logout, unless you have enabled lingering.
Proxy mode refuses pushes, so a cache is pull-only and the hub stays the only
way anything leaves a guest. Each runs sandboxed by systemd: the filesystem
read-only, your home hidden behind an empty tmpfs, and only its own cache
directory writable. In a user unit that needs unprivileged user namespaces; a
host without them fails `start` rather than running a cache unsandboxed. Caches listen on loopback only; a guest reaches
host loopback through its network gateway, `10.0.2.2`. The data lives under
`$XDG_CACHE_HOME/airlock/registry` and can be deleted at any time.

A workspace uses the caches when it says so:

```sh
airlock config --workspace <name> cri docker,podman
airlock config --workspace <name> registry on
```

Its guest's container runtimes are then pointed at every cache: containerd and
CRI-O (and so `crictl` and Kubernetes pulls) and Podman for all four upstreams,
Docker for `docker.io`, the only registry `dockerd` can mirror. Each runtime
tries its cache first and falls back to the registry itself, so a cache that is
not running costs nothing but the caching; `airlock run` says when none is.
`registry` is off by default, settable in your defaults like any other key: on
hands the guest the address of services on this host.

This needs a claude-microvm that reads `REGISTRY_MIRRORS`. airlock's pinned
one does; a workspace that pins its own `substrate` to one that does not gets
a setting the guest ignores. Not covered either way: containers that pull images
themselves, and KinD's nodes, which run their own containerd — though the node
images come through the cache.

Reaching host loopback depends on the guest's egress being open, which is the
substrate's default and the only mode airlock launches; under the substrate's
sealed modes (`shadow`, `enforce`) the mirrors are ignored.

### Chaining to a mirror on your LAN

Each cache pulls from its upstream's public endpoint unless
`$XDG_CONFIG_HOME/airlock/registry` names another, one line per upstream:

```
# ~/.config/airlock/registry
docker.io = http://mirror.lan:5000
ghcr.io   = https://mirror.lan:5001
```

Pulls then go guest → this host's cache → the mirror → the registry, so an
image crosses the internet once per LAN and the LAN once per host. Nothing about
a guest changes: it still talks to `10.0.2.2`, and no workspace config is
involved. Upstreams not listed, or listed with nothing after the `=`, keep their
public endpoint. `airlock registry` shows what each cache pulls from, and warns
when one is still running against a remote the file no longer names;
`airlock registry restart` applies the change.

A remote is `http(s)://host[:port]` and nothing more: the cache asks it for
`/v2/…` at its root, so the mirror must serve one upstream there — a plain
`registry` in proxy mode, Zot, or a Nexus Docker proxy on its own port.
Path-prefixed mirrors such as Harbor's proxy-cache projects are refused, as
are credentials. An `https` mirror signed by a private CA needs that CA in
this host's trust store.

A cache must reach its remote to start — `distribution` asks it for `/v2/`
first and exits without an answer — so with the mirror down, `start` fails and
says so. Once running, a cache keeps serving what it holds through a mirror
outage; what it does not hold, guests fetch from the registry directly.

#### Importing from registries.conf

If this host already lists its mirrors for Podman, Buildah, Skopeo or CRI-O,
`import` reads them from there:

```sh
airlock registry import             # what it found, and what it would write
airlock registry import --write     # write it into the remotes file
airlock registry restart
```

It reads them through [registries-conf](https://github.com/devinrsmith/registries-conf),
a small CLI around `go.podman.io/image/v5`, the library those tools share — so
which files are read, in what order, how they merge and which entry applies to
an upstream are that library's answers, not a copy of them. A file those tools
would refuse, import refuses too, with the library's message naming it; an
entry they could not pull through (a mirror location no image reference can be
built on) is reported against its own upstream, and the others are still
imported. It shows which configuration it read. An installed airlock has
registries-conf built in; a source checkout builds the revision in `flake.lock`
on first use.

For each upstream it takes the first mirror a cache can use, and says why it
passed over any others: a mirror with a path, a `namespace-proxy` mirror (it
needs a parameter on every request that a cache cannot send), a `digest-only`
mirror (a cache would serve tags from it too), or one that is airlock's own
cache.
`insecure = true` is read as plain `http`. The tools fail over between mirrors
and a cache cannot, so the rest go unused, and import says how many. `--write`
changes only the upstreams it found a mirror for; the rest of the remotes file
is left as it is.

## Development

```sh
./tests/run-tests.sh          # shell tests against real git repos — no VM, no network
./tests/run-tests.sh status   # just one of them
nix flake check               # those plus shellcheck, in a sandbox
```

The `Makefile` wraps these as `make test` and `make check`, where `make` is
installed — it is not everywhere, including the guest airlock was built in.

Booting a VM stays a manual check; CI has no KVM. The automated tests cover
`run` up to the launch itself — `--dry-run` for the environment the substrate
is handed, and AIRLOCK_LAUNCHER pointed at a stub for the lock, the cleanup and
the exit status — so a change that breaks the boot can still pass them.
