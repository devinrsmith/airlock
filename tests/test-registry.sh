# shellcheck shell=bash
# `airlock registry` — pull-through caches run as systemd user units.
#
# Nothing here starts a real registry or talks to systemd: `systemctl`,
# `systemd-run` and `nix` are stubs on PATH that record what they were asked
# and keep "running" units as files. What is under test is airlock's side —
# which units it asks for, with what config, and what it reports — not
# systemd's or the registry's.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
export AIRLOCK_CONFIG="$TMP/airlock-config"
export AIRLOCK_REGISTRY_HOME="$TMP/registry"
export AIRLOCK_REGISTRY_CONFIG="$TMP/registry-remotes"
export AIRLOCK_REGISTRY_PKG="github:NixOS/nixpkgs/0000000000000000000000000000000000000000#distribution"
export AIRLOCK_REGISTRY_SETTLE=0

AIRLOCK="$REPO_ROOT/bin/airlock"
OUT="$TMP/out"
UNITS="$TMP/units"
CALLS="$TMP/calls"
mkdir -p "$TMP/bin" "$UNITS" "$TMP/pkg/bin"

# The "registry" the stub nix hands back. Never executed: systemd-run is a stub.
printf '#!%s\nexit 0\n' "$BASH" > "$TMP/pkg/bin/registry"
chmod +x "$TMP/pkg/bin/registry"

# A unit is "active" while $UNITS/<unit> exists. STUB_DIES names a unit that
# systemd-run accepts but that is gone by the time anyone looks — a registry
# that exited at once, on a taken port say. STUB_NO_MANAGER makes every
# systemctl --user call fail, as with no user manager.
cat > "$TMP/bin/systemctl" <<EOF
#!$BASH
echo "systemctl \$*" >> "$CALLS"
[ -z "\${STUB_NO_MANAGER:-}" ] || exit 1
[ "\$1" = "--user" ] || exit 1
case "\$2" in
  show-environment) exit 0 ;;
  is-active) if [ -e "$UNITS/\$3" ]; then echo active; else echo inactive; exit 3; fi ;;
  stop)      rm -f "$UNITS/\$3" ;;
  *)         exit 1 ;;
esac
EOF
cat > "$TMP/bin/systemd-run" <<EOF
#!$BASH
echo "systemd-run \$*" >> "$CALLS"
unit=""
for a in "\$@"; do case "\$a" in --unit=*) unit="\${a#--unit=}" ;; esac; done
[ -n "\$unit" ] || exit 1
[ "\$unit" = "\${STUB_DIES:-}" ] || printf '%s\n' "\$*" > "$UNITS/\$unit"
EOF
cat > "$TMP/bin/nix" <<EOF
#!$BASH
echo "nix \$*" >> "$CALLS"
echo "$TMP/pkg"
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"

run() { local rc=0; : > "$CALLS"; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }
count() { grep -c -- "$1" "$CALLS" || true; }

# --- status before anything runs ------------------------------------------

case_begin "status lists every upstream, none running, nothing cached"
assert_ok "status succeeds" run registry
for u in docker.io ghcr.io quay.io registry.k8s.io; do
  assert_contains "$OUT" "$u" "lists $u"
done
assert_eq "4" "$(grep -c ' inactive ' "$OUT")" "all four inactive"
assert_contains "$OUT" "5101" "shows docker.io's port"
assert_contains "$OUT" "10.0.2.2" "says how a guest reaches it"
assert_eq "0" "$(count '^nix ')" "status never asks nix for the registry"

# --- start ------------------------------------------------------------------

case_begin "start brings every upstream up as its own user unit"
assert_ok "start succeeds" run registry start
for u in docker.io ghcr.io quay.io registry.k8s.io; do
  assert_file "$UNITS/airlock-registry-$u"
  assert_contains "$UNITS/airlock-registry-$u" "--user" "$u runs as a user unit"
  assert_contains "$UNITS/airlock-registry-$u" "$TMP/pkg/bin/registry serve $AIRLOCK_REGISTRY_HOME/$u/config.yml" "$u serves its own config"
  assert_contains "$UNITS/airlock-registry-$u" "--description=airlock registry: $u (pull-through cache of https://" "$u says what it is"
  assert_contains "$UNITS/airlock-registry-$u" "Documentation=https://github.com/devinrsmith/airlock#registry-caches" "$u says where it is documented"
  assert_contains "$UNITS/airlock-registry-$u" "SyslogIdentifier=airlock-registry-$u " "$u logs under its own name"
  assert_contains "$UNITS/airlock-registry-$u" "--slice=airlock-registry " "$u is in the caches' slice, inside airlock.slice"
  assert_contains "$UNITS/airlock-registry-$u" "NoNewPrivileges=yes" "$u cannot gain privileges"
  assert_contains "$UNITS/airlock-registry-$u" "Environment=OTEL_TRACES_EXPORTER=none" "$u exports no traces"
  assert_contains "$UNITS/airlock-registry-$u" "ProtectSystem=strict" "$u sees the system read-only"
  assert_contains "$UNITS/airlock-registry-$u" "ProtectHome=tmpfs" "$u cannot read home"
  assert_contains "$UNITS/airlock-registry-$u" "PrivateTmp=yes" "$u has its own /tmp"
  assert_contains "$UNITS/airlock-registry-$u" "BindPaths=$AIRLOCK_REGISTRY_HOME/$u " "$u gets exactly its own directory back"
  assert_dir "$AIRLOCK_REGISTRY_HOME/$u/data"
done
assert_eq "1" "$(count '^nix build')" "the registry is resolved once, not per upstream"
assert_contains "$CALLS" "nix build --no-link --print-out-paths $AIRLOCK_REGISTRY_PKG" "from the pinned reference"
assert_contains "$OUT" "docker.io: started" "says what started"
assert_contains "$OUT" "10.0.2.2:5101" "and where a guest finds it"

case_begin "each instance proxies its own upstream, on loopback only"
C="$AIRLOCK_REGISTRY_HOME/docker.io/config.yml"
assert_contains "$C" "addr: 127.0.0.1:5101" "loopback, its own port"
assert_contains "$C" "remoteurl: https://registry-1.docker.io" "docker.io's real endpoint"
assert_contains "$C" "rootdirectory: '$AIRLOCK_REGISTRY_HOME/docker.io/data'" "its own data directory"
assert_contains "$AIRLOCK_REGISTRY_HOME/ghcr.io/config.yml" "remoteurl: https://ghcr.io" "ghcr.io proxies ghcr.io"
assert_contains "$AIRLOCK_REGISTRY_HOME/registry.k8s.io/config.yml" "addr: 127.0.0.1:5104" "ports do not collide"
if grep -q '0\.0\.0\.0\|^ *addr: :' "$AIRLOCK_REGISTRY_HOME"/*/config.yml; then
  _fail "an instance listens beyond loopback"
else _pass; fi

case_begin "status reports what is running"
assert_ok "status succeeds" run registry status
assert_eq "4" "$(grep -c ' active ' "$OUT")" "all four active"

case_begin "a second start is a no-op that does not wait on nix"
assert_ok "start again succeeds" run registry start
assert_eq "0" "$(count '^systemd-run')" "no unit started twice"
assert_eq "0" "$(count '^nix ')" "nix not consulted when nothing needs starting"
assert_contains "$OUT" "docker.io: already running" "says so"

# --- stop ---------------------------------------------------------------------

case_begin "stop one, by name; its cache stays"
echo blob > "$AIRLOCK_REGISTRY_HOME/quay.io/data/blob"
assert_ok "stop quay.io succeeds" run registry stop quay.io
assert_absent "$UNITS/airlock-registry-quay.io"
assert_file "$UNITS/airlock-registry-docker.io"
assert_file "$AIRLOCK_REGISTRY_HOME/quay.io/data/blob"
assert_contains "$OUT" "quay.io: stopped" "says so"

case_begin "stopping something not running says so"
assert_ok "stop quay.io again succeeds" run registry stop quay.io
assert_contains "$OUT" "quay.io: not running" "says so"
assert_eq "0" "$(count 'systemctl --user stop')" "asks systemd to stop nothing"

case_begin "start one, by name"
assert_ok "start quay.io succeeds" run registry start quay.io
assert_file "$UNITS/airlock-registry-quay.io"
assert_eq "1" "$(count '^systemd-run')" "only that one started"

case_begin "stop with no names stops everything"
assert_ok "stop succeeds" run registry stop
assert_eq "0" "$(find "$UNITS" -type f | wc -l | tr -d ' ')" "nothing left running"
assert_eq "4" "$(count 'systemctl --user stop')" "one stop per running unit"

# --- refusals ---------------------------------------------------------------

case_begin "an unknown upstream starts nothing, not even the known ones"
assert_fails "start with an unknown name fails" run registry start docker.io nope.example
assert_contains "$OUT" "unknown upstream: nope.example" "names it"
assert_eq "0" "$(count '^systemd-run')" "nothing started"

case_begin "a cache that does not stay up fails the start and says where to look"
STUB_DIES=airlock-registry-ghcr.io assert_fails "start fails" run registry start
assert_contains "$OUT" "ghcr.io: did not stay up" "names the one that died"
assert_contains "$OUT" "journalctl --user -u airlock-registry-ghcr.io" "points at its log"
assert_file "$UNITS/airlock-registry-docker.io"
assert_contains "$OUT" "docker.io: started" "the others still start"
run registry stop >/dev/null 2>&1

case_begin "no systemd user manager is an error, not a silent no-op"
STUB_NO_MANAGER=1 assert_fails "start fails" run registry start
assert_contains "$OUT" "no systemd user manager" "says why"
assert_eq "0" "$(count '^systemd-run')" "nothing started"

case_begin "unknown subcommands and stray arguments are refused"
assert_fails "unknown subcommand" run registry reload
assert_fails "status takes no names" run registry status docker.io

# --- where it lives ---------------------------------------------------------

case_begin "the cache lives under the XDG cache dir, where status cannot mistake it for a workspace"
git init --quiet -b main "$TMP/src"
( cd "$TMP/src" || exit 1
  git -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m one ) >/dev/null 2>&1
GIT_CONFIG_GLOBAL=/dev/null "$AIRLOCK" init demo --from-local "$TMP/src" >/dev/null 2>&1
( unset AIRLOCK_REGISTRY_HOME
  export XDG_CACHE_HOME="$TMP/xdg-cache"
  "$AIRLOCK" registry start docker.io >/dev/null 2>&1
  "$AIRLOCK" registry stop >/dev/null 2>&1 )
assert_file "$TMP/xdg-cache/airlock/registry/docker.io/config.yml"
"$AIRLOCK" status > "$OUT" 2>&1
assert_eq "0" "$(grep -c broken "$OUT")" "status sees no broken workspace"

case_begin "a quote in the cache path is escaped in the YAML"
AIRLOCK_REGISTRY_HOME="$TMP/it's" assert_ok "start succeeds" run registry start docker.io
assert_contains "$TMP/it's/docker.io/config.yml" "rootdirectory: '$TMP/it''s/docker.io/data'" "doubled quote"
run registry stop >/dev/null 2>&1

# --- which registry ----------------------------------------------------------

case_begin "an installed build runs the distribution from its baked-in nixpkgs"
AIRLOCK_REGISTRY_PKG="" AIRLOCK_NIXPKGS="github:NixOS/nixpkgs/3333333333333333333333333333333333333333" \
  assert_ok "start succeeds" run registry start docker.io
assert_contains "$CALLS" "github:NixOS/nixpkgs/3333333333333333333333333333333333333333#distribution" \
  "the same nixpkgs the substrate is launched on"
run registry stop >/dev/null 2>&1

case_begin "a source checkout runs the distribution from the nixpkgs in flake.lock"
cat > "$TMP/flake.lock" <<'EOF'
{
  "nodes": {
    "nixpkgs-lib": {
      "locked": { "rev": "1111111111111111111111111111111111111111", "type": "github" }
    },
    "nixpkgs": {
      "locked": {
        "owner": "NixOS",
        "repo": "nixpkgs",
        "rev": "2222222222222222222222222222222222222222",
        "type": "github"
      }
    },
    "root": {
      "inputs": {
        "nixpkgs": "nixpkgs"
      }
    }
  },
  "root": "root",
  "version": 7
}
EOF
AIRLOCK_REGISTRY_PKG="" AIRLOCK_NIXPKGS="" AIRLOCK_FLAKE_LOCK="$TMP/flake.lock" assert_ok "start succeeds" run registry start docker.io
assert_contains "$CALLS" "github:NixOS/nixpkgs/2222222222222222222222222222222222222222#distribution" "the locked nixpkgs, not a similarly named node"
run registry stop >/dev/null 2>&1

case_begin "a lock without nixpkgs is an error, not a guess"
printf '{ "nodes": { "root": {} } }\n' > "$TMP/empty.lock"
AIRLOCK_REGISTRY_PKG="" AIRLOCK_NIXPKGS="" AIRLOCK_FLAKE_LOCK="$TMP/empty.lock" assert_fails "start fails" run registry start docker.io
assert_contains "$OUT" "cannot tell which registry to run" "says why"
assert_eq "0" "$(count '^systemd-run')" "nothing started"

# --- remotes ---------------------------------------------------------------

REMOTES="$AIRLOCK_REGISTRY_CONFIG"
DCONF="$AIRLOCK_REGISTRY_HOME/docker.io/config.yml"

case_begin "with no remotes file, every cache pulls from its upstream, and status says so"
rm -f "$REMOTES"
assert_ok "status succeeds" run registry status
assert_contains "$OUT" "https://registry-1.docker.io" "docker.io's public endpoint"
assert_contains "$OUT" "https://quay.io" "quay.io's"
assert_contains "$OUT" "remotes:    $REMOTES (absent" "names the file it would read"

case_begin "a remote in the file is what the cache pulls from; the others keep theirs"
cat > "$REMOTES" <<'EOR'
# a LAN mirror
docker.io = http://mirror.lan:5000/
quay.io   =
EOR
assert_ok "start succeeds" run registry start docker.io quay.io
assert_contains "$DCONF" "remoteurl: http://mirror.lan:5000" "the mirror"
if grep -q 'remoteurl: http://mirror.lan:5000/' "$DCONF"; then _fail "trailing slash kept"; else _pass; fi
assert_contains "$AIRLOCK_REGISTRY_HOME/quay.io/config.yml" "remoteurl: https://quay.io" "empty means the table's own"
assert_contains "$UNITS/airlock-registry-docker.io" "pull-through cache of http://mirror.lan:5000)" "the unit says what it pulls from"
assert_contains "$OUT" "docker.io: pulling from http://mirror.lan:5000" "start says so"
if grep -q "quay.io: pulling from" "$OUT"; then _fail "a default remote announced"; else _pass; fi
assert_contains "$DCONF" "addr: 127.0.0.1:5101" "still loopback, still its own port"

case_begin "status shows each running cache's remote and names the file"
assert_ok "status succeeds" run registry status
assert_contains "$OUT" "http://mirror.lan:5000" "the mirror"
assert_contains "$OUT" "remotes:    $REMOTES" "the file"
if grep -q "absent" "$OUT"; then _fail "file reported absent"; else _pass; fi

case_begin "the guest's side is unchanged by a remote"
mkdir -p "$TMP/plan" && cd "$TMP/plan" || exit 1
"$AIRLOCK" config --workspace demo cri docker >/dev/null 2>&1
"$AIRLOCK" config --workspace demo registry on >/dev/null 2>&1
AIRLOCK_SUBSTRATE="github:x/y/0" AIRLOCK_NIXPKGS="github:x/z/0" "$AIRLOCK" run demo --dry-run > "$OUT" 2>&1
assert_contains "$OUT" "REGISTRY_MIRRORS=docker.io=http://10.0.2.2:5101," "guests still use this host's cache"
if grep -q "mirror.lan" "$OUT"; then _fail "the LAN mirror leaked into the plan"; else _pass; fi
cd "$TMP" || exit 1

case_begin "a running cache the file has moved on from is reported, and restart applies it"
printf 'docker.io = https://other.lan\n' > "$REMOTES"
assert_ok "status succeeds" run registry status
assert_contains "$OUT" "docker.io: running against http://mirror.lan:5000, but the remotes file now says https://other.lan" "status warns"
assert_contains "$OUT" "airlock registry restart docker.io" "and says what to do"
if grep -q "^docker\.io .* http://mirror\.lan:5000$" "$OUT"; then _pass; else _fail "the row shows what the cache is running against"; fi
assert_ok "start succeeds" run registry start docker.io
assert_contains "$OUT" "docker.io: already running" "start does not replace it"
assert_contains "$OUT" "now says https://other.lan" "but warns"
assert_ok "restart succeeds" run registry restart docker.io
assert_contains "$DCONF" "remoteurl: https://other.lan" "restart picks up the file"
assert_eq "1" "$(count 'systemctl --user stop airlock-registry-docker.io')" "by stopping it"
assert_eq "1" "$(count '^systemd-run')" "and starting only it"
assert_ok "status succeeds" run registry status
if grep -q "running against" "$OUT"; then _fail "still reported stale"; else _pass; fi

case_begin "restart with no names restarts every cache and starts the rest"
assert_ok "restart succeeds" run registry restart
assert_eq "4" "$(find "$UNITS" -type f | wc -l | tr -d ' ')" "all four running"
if grep -q "not running" "$OUT"; then _fail "noise about stopped caches"; else _pass; fi
run registry stop >/dev/null 2>&1

case_begin "the remotes file is refused, whole, when any line is wrong"
for bad in \
  'nope.example = http://mirror.lan' \
  'docker.io = mirror.lan:5000' \
  'docker.io = ftp://mirror.lan' \
  'docker.io = http://mirror.lan:5000/v2/dockerhub-proxy' \
  'docker.io = http://user:pass@mirror.lan' \
  "docker.io = http://mirror.lan'" \
  'docker.io = http://mirror.lan: 5000' \
  'docker.io'; do
  printf 'ghcr.io = http://good.lan\n%s\n' "$bad" > "$REMOTES"
  assert_fails "start refuses: $bad" run registry start
  assert_contains "$OUT" "$REMOTES" "names the file for: $bad"
  assert_eq "0" "$(count '^systemd-run')" "starts nothing for: $bad"
done
assert_fails "status refuses too" run registry status

case_begin "a bad remotes file does not take down a running cache on restart"
rm -f "$REMOTES"
run registry start docker.io >/dev/null 2>&1
printf 'docker.io = not a url\n' > "$REMOTES"
assert_fails "restart fails" run registry restart docker.io
assert_file "$UNITS/airlock-registry-docker.io"
assert_eq "0" "$(count 'systemctl --user stop')" "nothing stopped"
assert_fails "restart of an unknown name fails" run registry restart nope.example
assert_eq "0" "$(count 'systemctl --user stop')" "nothing stopped for that either"
assert_ok "stop still works with a bad file" run registry stop
rm -f "$REMOTES"

case_begin "the remotes file lives under the XDG config dir"
( unset AIRLOCK_REGISTRY_CONFIG
  export XDG_CONFIG_HOME="$TMP/xdg-config"
  mkdir -p "$XDG_CONFIG_HOME/airlock"
  printf 'ghcr.io = http://10.1.2.3:5002\n' > "$XDG_CONFIG_HOME/airlock/registry"
  "$AIRLOCK" registry start ghcr.io >/dev/null 2>&1
  "$AIRLOCK" registry status > "$OUT" 2>&1
  "$AIRLOCK" registry stop >/dev/null 2>&1 )
assert_contains "$AIRLOCK_REGISTRY_HOME/ghcr.io/config.yml" "remoteurl: http://10.1.2.3:5002" "an address works as well as a name"
assert_contains "$OUT" "remotes:    $TMP/xdg-config/airlock/registry" "status names it"
