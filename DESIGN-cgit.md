# Proposal: browsing hubs on the web with cgit

Status: **settled 2026-10-30, not implemented.** The developer chose the
recommendation for each decision below. One claim is still to verify: that a
guest cannot reach `127.0.0.2` (decision 1). With the implementation this
becomes a decision (D35) in `REQUIREMENTS.md`, and this file goes away.

## What it is

An optional host-side service, `airlock web`, that serves every workspace's hub
read-only through [cgit](https://git.zx2c4.com/cgit/), for looking at what agents
have pushed: branches, logs, commits, diffs between an agent branch and the
default branch, trees. Orchestrated like the hub service (D33) and the registry
caches (D21): a transient `systemd --user` unit in `airlock.slice`, sandboxed,
built from airlock's nixpkgs, started and stopped explicitly.

It is a viewer and nothing more. It keeps no review state (D16): nothing records
what was looked at, and review and publishing stay the developer's own git, from
their own checkout.

## The decisions

### 1. Guests must not reach it — bind `127.0.0.2`, not `127.0.0.1`

The hub service gives each guest its own workspace's hub and nothing else (D33).
A cgit listing every hub, on the loopback a guest can reach (§2, "Guest reaching
host services"), would undo that: any guest could read every workspace's hub,
other projects included.

libslirp maps a guest's `10.0.2.2` to the host's `127.0.0.1` specifically (and
`fec0::2` to `::1`), not to the whole of `127.0.0.0/8`. Linux routes all of
`127/8` to `lo`, so a service bound to **`127.0.0.2`** is reachable from the
host's browser and from an `ssh -L` tunnel, and not from any guest.

- **To verify before relying on it**, the way §2's claim was: a nested guest
  dialling `10.0.2.2:<port>` gets refused while `127.0.0.2:<port>` answers on
  the host. Not checkable from the guest this proposal was written in.
- **Alternatives:** HTTP authentication with a per-host token (more moving parts,
  a secret to keep, and a guest can still probe the parser); a Unix socket
  (browsers cannot dial one, so it needs a proxy anyway).
- **Trade:** any local user on the host can read every hub through it. Bound to
  loopback on a single-user machine, that is the same reach they would need to
  read the data directory. Stated rather than solved.
- Defence in depth: the server refuses any `Host` header but its own
  `127.0.0.2:<port>`, against DNS rebinding from a web page.

### 2. Only the hubs — not `.repo` or the worktrees

The hub is the record of the work (D16, D30). The worktrees are agent-writable,
and anything host-side that reads them is D34's problem: a cgit in `work_dir/`
would be a second, unconfined git implementation running in a repository the
agent controls. Uncommitted or unpushed work is therefore not visible; `airlock
status` still reports it.

Hubs are written only by the host and through `receive-pack` (D33), so their
config is trustworthy. Their *objects* are not: commit messages, paths and
contents are the agent's, and cgit parses and renders them. Hence 3 and 4.

### 3. Sandboxed like the hub and the caches, and read-only

One unit, `airlock-web`, in `airlock-web.slice`:

- `ProtectSystem=strict`, `ProtectHome=tmpfs`, `PrivateTmp`, `NoNewPrivileges`,
  as D21.
- Each hub bound in **read-only and individually** (`BindReadOnlyPaths=`), not
  the workspaces directory: a workspace root also holds `hub_key`, `config` and
  `work_dir/`, none of which cgit needs. So the set of hubs is fixed at start;
  `init` and `rm` restart a running service, as they resync the hub's keys today.
- Only its own config directory besides. No cgit cache (`cache-size=0`), so
  nothing in the unit is writable.
- cgit's dumb-HTTP clone is off (`enable-http-clone=0`): the developer fetches
  the hub by path, and serving git over HTTP is a second channel to nothing.
  Snapshots (tarball downloads) off.

### 4. No rendered README, no highlighting, and a CSP

cgit escapes what it prints, but its `about-filter` (markdown → HTML) and
`source-filter` (syntax highlighting) run further parsers over agent content,
and the first emits HTML the agent wrote. Proposed for v1: neither. Files are
shown as plain text. Every response carries `Content-Security-Policy:
default-src 'self'; script-src 'none'; style-src 'self'`, so an escaping bug in
cgit still runs no script.

Adding highlighting later is a filter and a package; rendering markdown is a
sanitiser too, and is its own decision.

### 5. lighttpd as the server

cgit is a CGI program and needs a server. lighttpd (1.4.85 in airlock's
nixpkgs) does CGI itself (`mod_cgi`), serves cgit's CSS and logo, and sets
headers, in one process and one unit. nginx needs `fcgiwrap` beside it, a
second process and socket; busybox `httpd` and `thttpd` cannot set the headers
in 1 and 4.

**nixpkgs' own cgit wiring, audited 2026-10-30** (nixpkgs `55bfb4d`, the one
in `flake.lock`). The `cgit.nix` beside lighttpd is a NixOS module
(`nixos/modules/services/web-servers/lighttpd/cgit.nix`), not a package. A
second one, `services.cgit` (`nixos/modules/services/networking/cgit.nix`), puts
cgit behind nginx and fcgiwrap. The lighttpd package itself has nothing
cgit-specific in it. Neither module is usable here, and neither is worth
copying wholesale:

- They configure a NixOS system: a root-run `lighttpd.service` running as the
  `lighttpd` system user, enabled at boot. airlock runs on any host with Nix and
  a systemd user manager, unprivileged (D1). A module is not something it can
  evaluate.
- The lighttpd unit has no hardening at all: just `ExecStart`, `ExecReload` and
  `KillSignal`. Decision 3 is ours to write either way.
- What the lighttpd module actually does is about 15 lines of config:
  `mod_cgi`, `mod_alias` and `mod_setenv`; `cgi.assign` and `alias.url`
  pointing at `${cgit}/cgit/cgit.cgi` and its static files; `CGIT_CONFIG` set
  to a generated cgitrc. We take that mapping and add what it lacks: the
  `127.0.0.2` bind, the `Host` check, the CSP, `virtual-root=/`, and a
  `repo.*` section per hub.

So airlock takes only **packages** from nixpkgs, `cgit` and `lighttpd`, built
from `nixpkgs_ref()` as the hub's sshd is, and writes `lighttpd.conf` and
`cgitrc` itself at every start.

Sizes from airlock's nixpkgs: lighttpd's closure is 49 MiB. cgit's is 254 MiB,
most of it for filters decision 4 leaves off: python3 with pygments, markdown
and docutils (highlighting and README rendering), plus groff and lzip/zstd for
man pages and snapshots. Both are substituted from cache.nixos.org, not built. Taken as packaged (decided 2026-10-30): trimming it would mean compiling cgit and its git on every host, and a Nix expression of airlock's own rather than a nixpkgs attribute.
cgit compiles in its own copy of git (2.54 here, against nixpkgs' 2.55), so its
parser of agent objects updates with cgit, not with git. That is one more reason
for decision 3's sandbox.

### 6. Shape

- `airlock web [start | stop | restart | status]`, as `airlock hub`. Named for
  what it does, as `hub` and `registry` are, not for cgit.
- Not started by `run`, `init` or anything else: it is optional, and off unless
  started. No workspace config key, because it concerns the host, not a guest
  (as the registry's remotes file, D21).
- Address `127.0.0.2:5110`; `AIRLOCK_WEB_ADDR`/`AIRLOCK_WEB_PORT` for tests.
- One repository per workspace, at `/<workspace>/`, named for the workspace
  (two workspaces can share a project name). Default branch from the hub's
  `HEAD`; branches sorted by age, so recent agent work comes first.
- `airlock path <name> --web` prints that workspace's URL; `airlock status`
  shows it when the service runs.
- State in `$XDG_STATE_HOME/airlock/web` (rewritten at every start, like the
  hub's); the packages come from `nixpkgs_ref()` like the hub's sshd, with
  `AIRLOCK_CGIT`/`AIRLOCK_LIGHTTPD` naming package roots for tests.
- LFS files show as their pointers: the hub holds the objects but cgit does not
  know LFS.

### 7. Testing

As `test-hub.sh`: stub `systemd-run`/`systemctl` that run the server directly,
then real requests against it — the repo list, a branch, a commit, a diff — and
checks for: the `Host` refusal, the CSP header, a 404 for HTTP clone, and the
unit's properties (read-only binds of the hubs only, no workspace root). The
sandbox itself checked by probing from inside a real unit, per CLAUDE.md, since
`systemctl show` does not prove enforcement. The `127.0.0.2` claim is a manual
check with a nested guest, recorded with its date.
