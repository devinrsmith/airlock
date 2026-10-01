# airlock

Isolated, virtualized coding-agent workspaces. An agent runs in a microVM whose
only channel to your machine is a bare git repository — it never sees your
working tree, your credentials, or your processes.

**Status: early. Every command is implemented. `run` has never booted a real
guest — see [Development](#development).**

[REQUIREMENTS.md](REQUIREMENTS.md) is the design: 18 decisions, the threat model,
and the hazards worth knowing before trusting any of this.

## What a workspace is

```
<data-dir>/<workspace>/        workspace root — never mounted into the guest
├── work_dir/                  → mounted at /work
│   ├── CLAUDE.md              emitted; tells the agent where to work
│   ├── <project>.git/         the hub — the agent pushes here
│   └── <project>/             the agent's clone
├── agent_home/                → mounted at /home/agent
├── config                     what this workspace is allowed to do
└── watermarks/                review state — the guest cannot reach it
```

Two directories are mounted; the root is not. Everything airlock relies on for
its own integrity lives beside them, out of the agent's reach.

## Usage

```sh
airlock init <name> --from-local /path/to/checkout
airlock init <name> --from-remote https://github.com/acme/widget

airlock run <name>                # launch the agent's VM
airlock run <name> --dry-run      # show the launch environment without booting
airlock status                    # every workspace: running, and what is waiting
airlock status <name>             # one workspace in detail
airlock fetch <name>              # refresh the hub from its upstreams
airlock review <name>             # read what the agent pushed, accepting as you go
airlock review <name> --accept    # pre-approve: accept everything shown, no prompts
airlock doctor <name> [--fix]     # verify invariants, repair safe drift
airlock rm <name>                 # tear it down, with confirmation
```

Then, in your own checkout:

```sh
git remote add hub <data-dir>/<workspace>/work_dir/<project>.git
git fetch hub
```

Work the agent pushes arrives on `agent/*` branches in the hub. You review it
and publish it yourself: no forge credential ever exists inside the VM.

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
`store_size_mb`. A command-line flag still wins over any of them.

## The vendored substrate

The microVM itself is [claude-microvm](https://github.com/systemstart/claude-microvm),
vendored as a git submodule under `substrate/`. Its version is pinned by a commit
in this repository, so it moves when someone deliberately moves it.

```sh
git clone --recurse-submodules <this repo>     # or: git submodule update --init
```

**Nix flakes leave submodules out** unless the reference asks for them, so an
install needs `?submodules=1`:

```sh
nix profile install 'git+https://.../airlock?submodules=1'
```

A build without it still works for everything except `run`, which says so rather
than quietly reaching for github. A workspace can also pin itself to a different
substrate with `substrate = <flake ref>` in its config.

## Development

```sh
make test         # shell tests against real git repos — no VM, no network
make shellcheck
make check        # nix flake check: both of the above, in a sandbox
```

Booting a VM is a manual smoke test; CI has no KVM. `run` is covered up to the
launch itself — `--dry-run` for the environment the substrate is handed, and
AIRLOCK_LAUNCHER pointed at a stub for the lock, the cleanup and the exit
status — but no guest has been booted through it yet.
