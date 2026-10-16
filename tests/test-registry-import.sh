# shellcheck shell=bash
# `airlock registry import` — reading the host's registries.conf the way
# go.podman.io/image/v5 does, and proposing remotes from it.
#
# These need registries-conf (AIRLOCK_REGISTRIES_CONF, else on PATH) and jq,
# and skip without them rather than build either. Every path the library would
# search is redirected into the temp dir: AIRLOCK_CONTAINERS_ROOT (its --root)
# for /etc and /usr/share, XDG_CONFIG_HOME for the user's. The file rules are
# the library's own now, so the cases below on which files and which entry
# check that import asks it the right questions, not the rules themselves.

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cd "$TMP" || exit 1

export AIRLOCK_DATA_HOME="$TMP/data"
export AIRLOCK_CONFIG="$TMP/airlock-config"
export AIRLOCK_REGISTRY_HOME="$TMP/registry"
export AIRLOCK_REGISTRY_CONFIG="$TMP/remotes"
export AIRLOCK_CONTAINERS_ROOT="$TMP/root"
export XDG_CONFIG_HOME="$TMP/xdg"
export XDG_CACHE_HOME="$TMP/cache"
unset CONTAINERS_REGISTRIES_CONF CONTAINERS_REGISTRIES_CONF_OVERRIDE

AIRLOCK="$REPO_ROOT/bin/airlock"
OUT="$TMP/out"
ETC="$TMP/root/etc/containers"
SHARE="$TMP/root/usr/share/containers"
USER_C="$TMP/xdg/containers"
UID_NOW="$(id -u)"
if [ "$UID_NOW" -gt 0 ]; then KIND=rootless; else KIND=rootful; fi

run() { local rc=0; "$AIRLOCK" "$@" > "$OUT" 2>&1 || rc=$?; return $rc; }
reset() { rm -rf -- "$TMP/root" "$TMP/xdg" "$AIRLOCK_REGISTRY_CONFIG"; mkdir -p "$ETC" "$SHARE" "$USER_C"; }
# conf <file> <prefix> <mirror>... — one [[registry]] for <prefix>, its
# location the prefix itself, with plain mirrors in order.
conf() {
  local file="$1" prefix="$2" m
  shift 2
  mkdir -p "$(dirname "$file")"
  printf '[[registry]]\nprefix = "%s"\nlocation = "%s"\n' "$prefix" "$prefix" >> "$file"
  for m in "$@"; do printf '[[registry.mirror]]\nlocation = "%s"\n' "$m" >> "$file"; done
}
# The remote import proposes for an upstream: its row's first value.
proposed() { awk -v u="$1" '$1 == u { print $2; exit }' "$OUT"; }
not_contains() { # file needle label
  if grep -qF -- "$2" "$1"; then _fail "$3: '$2' found in $1"; else _pass; fi
}

[ -n "${AIRLOCK_REGISTRIES_CONF:-}" ] || AIRLOCK_REGISTRIES_CONF="$(command -v registries-conf || true)"
export AIRLOCK_REGISTRIES_CONF
if [ -z "$AIRLOCK_REGISTRIES_CONF" ] || ! command -v jq >/dev/null 2>&1; then
  case_begin "registry import"
  skip "needs registries-conf and jq"
  return 0   # sourced by run-tests.sh
fi

# --- which files --------------------------------------------------------------

case_begin "no registries.conf anywhere: nothing to import, nothing written"
reset
assert_ok "import succeeds" run registry import
assert_contains "$OUT" "nothing: no registries.conf" "says so"
assert_absent "$AIRLOCK_REGISTRY_CONFIG"

case_begin "one main file: the user's hides /etc's, which hides /usr/share's"
reset
conf "$SHARE/registries.conf" docker.io share.lan
conf "$ETC/registries.conf" docker.io etc.lan
assert_ok "import succeeds" run registry import
assert_eq "https://etc.lan" "$(proposed docker.io)" "/etc over /usr/share"
not_contains "$OUT" "$SHARE/registries.conf" "/usr/share's main file is not read"
conf "$USER_C/registries.conf" docker.io user.lan
assert_ok "import succeeds" run registry import
assert_eq "https://user.lan" "$(proposed docker.io)" "the user's over /etc"
if grep -qxF "  $ETC/registries.conf" "$OUT"; then _fail "/etc's main file is read"; else _pass; fi

case_begin "a drop-in replaces the main file's entry whole, mirrors and all"
reset
conf "$ETC/registries.conf" docker.io main-first.lan
conf "$ETC/registries.conf.d/10-lan.conf" docker.io dropin.lan
assert_ok "import succeeds" run registry import
assert_eq "https://dropin.lan" "$(proposed docker.io)" "the drop-in's"
not_contains "$OUT" "main-first.lan" "the main file's mirrors are gone, not appended"

case_begin "within one file, the first entry for a prefix wins"
reset
conf "$ETC/registries.conf" ghcr.io first.lan
conf "$ETC/registries.conf" ghcr.io second.lan
assert_ok "import succeeds" run registry import
assert_eq "https://first.lan" "$(proposed ghcr.io)" "the first"

case_begin "drop-ins: a name hides the same name lower down; all are read in name order"
reset
conf "$SHARE/registries.conf.d/50-same.conf" quay.io share-same.lan
conf "$ETC/registries.conf.d/50-same.conf" quay.io etc-same.lan
conf "$USER_C/registries.conf.d/40-docker.conf" docker.io user-40.lan
conf "$SHARE/registries.conf.d/60-docker.conf" docker.io share-60.lan
conf "$ETC/registries.conf.d/.hidden.conf" registry.k8s.io hidden.lan
conf "$ETC/registries.conf.d/70-ignored.toml" ghcr.io not-conf.lan
assert_ok "import succeeds" run registry import
assert_eq "https://etc-same.lan" "$(proposed quay.io)" "/etc's 50-same.conf hides /usr/share's"
assert_eq "https://share-60.lan" "$(proposed docker.io)" "60 is read after 40, whichever directory"
assert_eq "https://hidden.lan" "$(proposed registry.k8s.io)" "a dotfile drop-in is read"
not_contains "$OUT" "not-conf.lan" "only *.conf"

case_begin "the $KIND drop-in directories are read, the per-uid one above the shared one"
reset
if [ "$KIND" = rootless ]; then
  conf "$ETC/registries.rootless.conf.d/$UID_NOW/50-x.conf" docker.io per-uid.lan
  conf "$ETC/registries.rootless.conf.d/50-x.conf" docker.io rootless.lan
  conf "$ETC/registries.rootful.conf.d/10-y.conf" ghcr.io rootful.lan
  assert_ok "import succeeds" run registry import
  assert_eq "https://per-uid.lan" "$(proposed docker.io)" "per-uid over shared rootless"
  not_contains "$OUT" "rootful.lan" "the rootful directory is not read"
else
  conf "$ETC/registries.rootful.conf.d/50-x.conf" docker.io rootful.lan
  conf "$ETC/registries.rootless.conf.d/10-y.conf" ghcr.io rootless.lan
  assert_ok "import succeeds" run registry import
  assert_eq "https://rootful.lan" "$(proposed docker.io)" "the rootful directory"
  not_contains "$OUT" "rootless.lan" "the rootless directory is not read"
fi

case_begin "CONTAINERS_REGISTRIES_CONF is the only main file and turns drop-ins off"
reset
conf "$ETC/registries.conf" docker.io etc.lan
conf "$ETC/registries.conf.d/10-lan.conf" ghcr.io dropin.lan
conf "$TMP/elsewhere.conf" docker.io env.lan
CONTAINERS_REGISTRIES_CONF="$TMP/elsewhere.conf" assert_ok "import succeeds" run registry import
assert_eq "https://env.lan" "$(proposed docker.io)" "the named file"
not_contains "$OUT" "dropin.lan" "no drop-ins"
CONTAINERS_REGISTRIES_CONF="$TMP/missing.conf" assert_fails "a missing one is an error" run registry import
assert_contains "$OUT" "$TMP/missing.conf" "says which"

case_begin "CONTAINERS_REGISTRIES_CONF_OVERRIDE is read last of all"
reset
conf "$ETC/registries.conf.d/99-last.conf" docker.io dropin.lan
conf "$TMP/override.conf" docker.io override.lan
CONTAINERS_REGISTRIES_CONF_OVERRIDE="$TMP/override.conf" assert_ok "import succeeds" run registry import
assert_eq "https://override.lan" "$(proposed docker.io)" "over every drop-in"
rm -f "$TMP/override.conf"
CONTAINERS_REGISTRIES_CONF_OVERRIDE="$TMP/override.conf" assert_fails "a missing one is an error" run registry import

# --- which entry ---------------------------------------------------------------

case_begin "the longest matching prefix wins; a wildcard is used when nothing exact is"
reset
printf '[[registry]]\nprefix = "*.k8s.io"\n[[registry.mirror]]\nlocation = "wild.lan"\n' > "$ETC/registries.conf"
assert_ok "import succeeds" run registry import
assert_eq "https://wild.lan" "$(proposed registry.k8s.io)" "the wildcard"
assert_contains "$OUT" "matched by prefix *.k8s.io" "says it was a wildcard"
conf "$ETC/registries.conf" registry.k8s.io exact.lan
assert_ok "import succeeds" run registry import
assert_eq "https://exact.lan" "$(proposed registry.k8s.io)" "exact over wildcard"

case_begin "a prefix defaults to the location; a narrower prefix is reported, not imported"
reset
printf '[[registry]]\nlocation = "quay.io"\n[[registry.mirror]]\nlocation = "quay.lan"\n' > "$ETC/registries.conf"
conf "$ETC/registries.conf" docker.io hub.lan
printf '[[registry]]\nprefix = "docker.io/library/busybox"\nlocation = "bb.lan/busybox"\n' >> "$ETC/registries.conf"
assert_ok "import succeeds" run registry import
assert_eq "https://quay.lan" "$(proposed quay.io)" "prefix from location"
assert_eq "https://hub.lan" "$(proposed docker.io)" "the registry-wide entry"
assert_contains "$OUT" "docker.io/library/busybox sends those images elsewhere" "the narrower one is named"

case_begin "a location other than the registry's own is a candidate, after the mirrors"
reset
printf '[[registry]]\nprefix = "ghcr.io"\nlocation = "ghcr.lan:5000"\n' > "$ETC/registries.conf"
assert_ok "import succeeds" run registry import
assert_eq "https://ghcr.lan:5000" "$(proposed ghcr.io)" "the rewritten location"
assert_contains "$OUT" "from its location" "says it was the location"

case_begin "a blocked registry imports nothing"
reset
printf '[[registry]]\nlocation = "quay.io"\nblocked = true\n[[registry.mirror]]\nlocation = "quay.lan"\n' > "$ETC/registries.conf"
assert_ok "import succeeds" run registry import
assert_contains "$OUT" "blocked: nothing to import" "says so"
assert_eq "" "$(grep -F '= https://quay.lan' "$OUT")" "not proposed"

# --- which mirror -----------------------------------------------------------------

case_begin "mirrors a cache cannot use are skipped, with reasons; the first usable one is taken"
reset
cat > "$ETC/registries.conf" <<'EOF'
[[registry]]
prefix = "docker.io"
location = "docker.io"
[[registry.mirror]]
location = "harbor.lan/dockerhub-proxy"
[[registry.mirror]]
location = "digests.lan"
pull-from-mirror = "digest-only"
[[registry.mirror]]
location = "127.0.0.1:5101"
insecure = true
[[registry.mirror]]
location = "10.0.2.2:5102"
[[registry.mirror]]
location = "registry-1.docker.io"
[[registry.mirror]]
location = "big.lan:123456"
[[registry.mirror]]
location = "tags.lan:5000"
insecure = true
pull-from-mirror = "tag-only"
[[registry.mirror]]
location = "spare.lan"
EOF
assert_ok "import succeeds" run registry import
assert_eq "http://tags.lan:5000" "$(proposed docker.io)" "tag-only is usable, insecure is http"
assert_contains "$OUT" "skipped harbor.lan/dockerhub-proxy: has a path" "path"
assert_contains "$OUT" "skipped digests.lan: pull-from-mirror = digest-only" "digest-only mirror"
assert_contains "$OUT" "skipped 127.0.0.1:5101: that is airlock's own cache" "own cache on loopback"
assert_contains "$OUT" "skipped 10.0.2.2:5102: that is airlock's own cache" "own cache from a guest"
assert_contains "$OUT" "skipped registry-1.docker.io: that is docker.io's own endpoint" "the public endpoint"
assert_contains "$OUT" "skipped big.lan:123456: not a host[:port]" "a port the remotes file cannot name"
assert_contains "$OUT" "insecure = true, read as plain http" "says how insecure was read"
assert_contains "$OUT" "1 more after it not used" "no failover"

case_begin "a namespace-proxy mirror is skipped"
reset
printf '[[registry]]\nprefix = "docker.io"\nlocation = "docker.io"\n[[registry.mirror]]\nlocation = "proxy.lan"\nnamespace-proxy = "docker.io"\n[[registry.mirror]]\nlocation = "plain.lan"\n' > "$ETC/registries.conf"
assert_ok "import succeeds" run registry import
assert_eq "https://plain.lan" "$(proposed docker.io)" "the next mirror"
assert_contains "$OUT" "skipped proxy.lan: namespace-proxy" "says why"

case_begin "an entry the tools themselves cannot pull through is reported for its upstream alone"
reset
printf '[[registry]]\nprefix = "docker.io"\nlocation = "docker.io"\n[[registry.mirror]]\nlocation = "[fd00::1]:5000"\n' > "$ETC/registries.conf"
conf "$ETC/registries.conf" ghcr.io ghcr.lan
assert_ok "import succeeds" run registry import
assert_contains "$OUT" "docker.io        not importable: the tools themselves fail on its entry" "says so"
assert_contains "$OUT" "invalid reference format" "with the library's reason"
assert_eq "https://ghcr.lan" "$(proposed ghcr.io)" "the other upstreams are still imported"

case_begin "mirror-by-digest-only on the registry rules out all its mirrors, but not a location"
reset
printf '[[registry]]\nprefix = "ghcr.io"\nlocation = "ghcr.lan"\nmirror-by-digest-only = true\n[[registry.mirror]]\nlocation = "m.lan"\n' > "$ETC/registries.conf"
assert_ok "import succeeds" run registry import
assert_eq "https://ghcr.lan" "$(proposed ghcr.io)" "the location"
assert_contains "$OUT" "mirror-by-digest-only" "says why the mirror was not"
not_contains "$OUT" "= https://m.lan" "the mirror is not proposed"

# --- what the library would refuse ---------------------------------------------------

case_begin "a file the tools would refuse is refused, by name, and nothing is written"
bad() { # label file-content needle
  reset
  conf "$ETC/registries.conf" docker.io fine.lan
  mkdir -p "$ETC/registries.conf.d"
  printf '%b' "$2" > "$ETC/registries.conf.d/50-bad.conf"
  assert_fails "refused: $1" run registry import --write
  assert_contains "$OUT" "$ETC/registries.conf.d/50-bad.conf" "names the file: $1"
  assert_contains "$OUT" "$3" "says why: $1"
  assert_absent "$AIRLOCK_REGISTRY_CONFIG"
}
bad "malformed TOML" 'x = [\n' "toml:"
bad "v1 format" '[registries.search]\nregistries = ["docker.io"]\n' "must be in v2 format"
bad "scheme in a location" '[[registry]]\nlocation = "https://quay.io"\n' "URI schemes are not supported"
bad "no location or prefix" '[[registry]]\ninsecure = true\n' "both location and prefix are unset"
bad "pull-from-mirror on a registry" '[[registry]]\nlocation = "quay.io"\npull-from-mirror = "all"\n' "must not be set for a non-mirror registry"
bad "unknown pull-from-mirror" '[[registry]]\nlocation = "quay.io"\n[[registry.mirror]]\nlocation = "m.lan"\npull-from-mirror = "sometimes"\n' "unsupported pull-from-mirror value"
bad "conflicting insecure" '[[registry]]\nprefix = "a.io"\nlocation = "quay.io"\n[[registry]]\nprefix = "b.io"\nlocation = "quay.io"\ninsecure = true\n' "defined multiple times"
bad "malformed wildcard" '[[registry]]\nprefix = "*.example.com/x"\n' "Wildcarded prefix"
bad "an entry the import would not even use" '[[registry]]\nprefix = "unrelated.example"\nlocation = "u.example"\n[[registry.mirror]]\nlocation = ""\n' "mirror location is unset"
bad "a duplicate the first-wins rule drops" '[[registry]]\nprefix = "quay.io"\nlocation = "quay.io"\n[[registry]]\nprefix = "quay.io"\nlocation = "quay.io"\n[[registry.mirror]]\nlocation = ""\n' "mirror location is unset"

# --- writing -----------------------------------------------------------------------------

case_begin "without --write nothing is written; with it, the file is created"
reset
conf "$ETC/registries.conf" docker.io hub.lan:5000
assert_ok "import succeeds" run registry import
assert_absent "$AIRLOCK_REGISTRY_CONFIG"
assert_contains "$OUT" "docker.io        = https://hub.lan:5000  (was https://registry-1.docker.io)" "shows the change"
assert_contains "$OUT" "nothing written" "says so"
assert_ok "import --write succeeds" run registry import --write
assert_contains "$AIRLOCK_REGISTRY_CONFIG" "docker.io = https://hub.lan:5000" "written"
assert_contains "$OUT" "airlock registry restart" "says how it takes effect"
assert_ok "the result is a valid remotes file" run registry import

case_begin "--write changes only what it imports, keeping the rest of the file"
cat > "$AIRLOCK_REGISTRY_CONFIG" <<'EOF'
# mine
ghcr.io   = http://hand.lan:5002
docker.io = http://old.lan
EOF
assert_ok "import --write succeeds" run registry import --write
assert_contains "$AIRLOCK_REGISTRY_CONFIG" "# mine" "comment kept"
assert_contains "$AIRLOCK_REGISTRY_CONFIG" "ghcr.io   = http://hand.lan:5002" "an upstream it had nothing for is untouched"
assert_contains "$AIRLOCK_REGISTRY_CONFIG" "docker.io = https://hub.lan:5000" "the imported one replaced"
not_contains "$AIRLOCK_REGISTRY_CONFIG" "old.lan" "the old value is gone"
assert_ok "import again succeeds" run registry import
assert_contains "$OUT" "(unchanged)" "a second import changes nothing"

case_begin "an invalid remotes file is not edited"
printf 'docker.io = not a url\n' > "$AIRLOCK_REGISTRY_CONFIG"
assert_fails "import refuses" run registry import --write
assert_contains "$AIRLOCK_REGISTRY_CONFIG" "not a url" "left as it was"
assert_fails "stray arguments are refused" run registry import docker.io
