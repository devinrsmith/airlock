# airlock

Isolated, virtualized coding-agent workspaces. An agent runs in a microVM whose
only channel to your machine is a bare git repository — it never sees your
working tree, your credentials, or your processes.

**Status: early. `init` works; everything else is unimplemented.**

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
```

Then, in your own checkout:

```sh
git remote add hub <data-dir>/<workspace>/work_dir/<project>.git
git fetch hub
```

Work the agent pushes arrives on `agent/*` branches in the hub. You review it
and publish it yourself: no forge credential ever exists inside the VM.

## Development

```sh
make test         # shell tests against real git repos — no VM, no network
make shellcheck
make check        # nix flake check: both of the above, in a sandbox
```

Booting a VM is a manual smoke test; CI has no KVM.
