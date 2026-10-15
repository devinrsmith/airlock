# airlock

Isolated, virtualized coding-agent workspaces. An agent runs in a microVM whose
only channel to your machine is a bare git repository — it never sees your
working tree, your credentials, or your processes.

**Status: early, but in use. Every command is implemented, and `run` boots real
guests.**

[REQUIREMENTS.md](REQUIREMENTS.md) is the design: 20 decisions, the threat model,
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
<data-dir>/<workspace>/        workspace root — never mounted into the guest
├── work_dir/                  → mounted at /work
│   ├── CLAUDE.md              emitted; tells the agent where to work
│   ├── <project>.git/         the hub — the agent pushes here
│   └── <project>/             the agent's clone
├── agent_home/                → mounted at /home/agent
└── config                     what this workspace is allowed to do
```

Two directories are mounted; the root is not. Everything airlock relies on for
its own integrity lives beside them, out of the agent's reach.

## Usage

```sh
airlock init <name> --from-local /path/to/checkout
airlock init <name> --from-remote https://github.com/acme/widget

airlock run <name>                # launch the agent's VM
airlock run <name> --dry-run      # show the launch environment without booting
airlock status                    # every workspace: running, and what the agent pushed
airlock status <name>             # one workspace in detail
airlock fetch <name>              # refresh the hub from its upstreams
airlock doctor <name> [--fix]     # verify invariants, repair safe drift
airlock rm <name>                 # tear it down, with confirmation
airlock path <name>               # where the hub is, for `git remote add`
airlock registry start            # pull-through image caches for guests
```

Then, in your own checkout:

```sh
git remote add hub "$(airlock path <name>)"
git fetch hub
```

`airlock path` exists so the layout stays airlock's business and not yours. It
prints one bare line and nothing else, and takes `--clone`, `--root`,
`--agent-home` or `--config` when you want a different part of the workspace.
`airlock status <name>` prints the `git remote add` line ready to copy.

Work the agent pushes arrives on `agent/*` branches in the hub. You review it
with your own git, against your own remotes, and publish it yourself: no forge
credential ever exists inside the VM.

```sh
git fetch hub
git log  origin/main..hub/agent/fix-parser
git diff origin/main...hub/agent/fix-parser
```

airlock keeps no record of what you have read. Your checkout's `hub/*`
remote-tracking refs are that record, and `git fetch` reports a branch the
agent rewrote as a `(forced update)`. `airlock status` lists the hub branches
carrying commits its default branch does not have.

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
the clone's git config, the flavor decided which context file was emitted.
`config` edits text only and says so; `airlock doctor <name> --fix` reconciles.

## Authenticating the agent

Each workspace has its own agent home, so an interactive login is per workspace:
log in once inside one VM and a *different* workspace will ask again. The way to
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

The key still reaches disk inside the workspace: the substrate writes it to
`agent_home/.microvm-env` (mode 0600) at each launch. The difference from a
stored login is that it is re-derived from your environment every time rather
than being a long-lived token the workspace owns — delete the workspace and
there is nothing left to revoke.

airlock deliberately does not copy your `~/.claude/.credentials.json` into new
workspaces. It could, but a long-lived token copied into every workspace is
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
`cri_storage_mb`, `store_size_mb`. A command-line flag still wins over any of
them.

## The substrate

The microVM itself is [claude-microvm](https://github.com/systemstart/claude-microvm),
a flake input pinned in `flake.lock`. airlock never builds it: `run` shells out
to `nix run <ref>#<flavor>` at launch, so all airlock needs from the lock is the
revision. Bump it deliberately:

```sh
nix flake update claude-microvm
```

An installed airlock has that reference baked into its wrapper, so it launches
the microVM its build was locked against. A source checkout reads the same
revision out of `flake.lock`, so the two cannot drift apart. A workspace can pin
itself to something else with `substrate = <flake ref>` in its config;
`airlock status` marks such a workspace with `*`, and `airlock status <name>`
names the ref it launches.

For a running VM, both report what it was *launched* with, which `run` records
in the workspace's lock: change the config under a running VM and `status`
marks it `!`, and `airlock status <name>` names the keys that changed. They
take effect on the next `run`.

## Registry caches

Every guest pulls its container images from scratch. `airlock registry` runs
pull-through caches on this host, so an image is fetched from the internet once
and from local disk after that:

```sh
airlock registry start              # all upstreams; or name some
airlock registry                    # what is running, and how much each holds
airlock registry stop               # the cached data is kept

systemctl --user status airlock.slice        # every cache, with memory and CPU
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

Guests are not configured to use the caches yet. Until they are, name the
cache in the image reference, and tell the runtime it speaks plain HTTP (each
has its own insecure-registry option):

```sh
podman pull --tls-verify=false 10.0.2.2:5101/library/alpine:3.20
```

Reaching host loopback depends on the guest's egress being open, which is the
substrate's default and the only mode airlock launches; a guest under the
substrate's sealed modes (`shadow`, `enforce`) could not reach a cache.

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
