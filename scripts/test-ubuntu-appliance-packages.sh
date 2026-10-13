#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-appliance-test.XXXXXX")"
TOOLS="$TMP_ROOT/tools"
OUT_ONE="$TMP_ROOT/out-one"
OUT_TWO="$TMP_ROOT/out-two"
ROOT="$TMP_ROOT/root"
SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD^{commit})"
VERSION="$(tr -d '\n' < "$REPO_ROOT/VERSION")"
DEBIAN_VERSION=${VERSION/-dev/~dev}
LOCK_PID=""

cleanup() {
    if [[ -n "$LOCK_PID" ]]; then
        kill -- "-$LOCK_PID" >/dev/null 2>&1 || true
        wait "$LOCK_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'test-ubuntu-appliance-packages: %s\n' "$1" >&2
    exit 1
}

mkdir -p "$TOOLS"
cat > "$TOOLS/mix" <<'SH'
#!/bin/sh
set -eu
case "$*" in
    'release orchard_controller --overwrite')
        [ "$PWD" = "${ORCHARD_TEST_REPO_ROOT:?}" ] || exit 91
        release="${MIX_BUILD_PATH:?}/rel/orchard_controller"
        mkdir -p "$release/bin" "$release/erts-16.4/bin" "$release/lib/orchard_controller-0.1.0/ebin" "$release/releases"
        cat > "$release/bin/orchard_controller" <<'BIN'
#!/bin/sh
printf 'controller must not run during package tests\n' >&2
exit 99
BIN
        chmod +x "$release/bin/orchard_controller"
        cp /bin/true "$release/erts-16.4/bin/beam.smp"
        ;;
    'release --overwrite')
        [ "$(basename "$PWD")" = "orchard_node_agent" ] || exit 92
        release="${MIX_BUILD_PATH:?}/rel/orchard_node_agent"
        mkdir -p "$release/bin" "$release/erts-16.4/bin" "$release/lib/orchard_node_agent-0.1.0/ebin" "$release/releases"
        cat > "$release/bin/orchard_node_agent" <<'BIN'
#!/bin/sh
printf 'node must not run during package tests\n' >&2
exit 99
BIN
        chmod +x "$release/bin/orchard_node_agent"
        cp /bin/true "$release/erts-16.4/bin/beam.smp"
        ;;
    *) exit 90 ;;
esac
SH
chmod 0755 "$TOOLS/mix"

build_set() {
    local output=$1
    PATH="$TOOLS:$PATH" \
        ORCHARD_TEST_REPO_ROOT="$REPO_ROOT" \
        SOURCE_DATE_EPOCH=0 \
        "$REPO_ROOT/scripts/build-ubuntu-appliance-packages.sh" --allow-dirty "$output" >/dev/null
}

build_set "$OUT_ONE"
build_set "$OUT_TWO"

[[ "$(find "$OUT_ONE" -maxdepth 1 -type f -name '*.deb' | wc -l)" -eq 6 ]] || fail "builder did not emit six coordinated packages"
(cd "$OUT_ONE" && sha256sum --check SHA256SUMS >/dev/null)
diff -u "$OUT_ONE/SHA256SUMS" "$OUT_TWO/SHA256SUMS" >/dev/null || fail "package set is not byte reproducible"

for package in orchard-appliance-tools orchard-controller orchard-postgresql orchard-worker-foundation orchard-node-agent orchard-appliance; do
    deb="$OUT_ONE/${package}_${DEBIAN_VERSION}_amd64.deb"
    [[ -f "$deb" ]] || fail "missing $package package"
    [[ "$(dpkg-deb --field "$deb" X-Orchard-Platform-Profile)" = "ubuntu_24_04_x86_64_single_host" || "$package" = "orchard-node-agent" ]] ||
        fail "$package has the wrong profile"
    dpkg-deb --extract "$deb" "$ROOT"
    mkdir -p "$TMP_ROOT/control/$package"
    dpkg-deb --control "$deb" "$TMP_ROOT/control/$package"
done

[[ ! -e "$TMP_ROOT/tools-payload" ]] || fail "test tools payload path unexpectedly exists"
mkdir "$TMP_ROOT/tools-payload" "$TMP_ROOT/meta-payload"
dpkg-deb --extract "$OUT_ONE/orchard-appliance-tools_${DEBIAN_VERSION}_amd64.deb" "$TMP_ROOT/tools-payload"
dpkg-deb --extract "$OUT_ONE/orchard-appliance_${DEBIAN_VERSION}_amd64.deb" "$TMP_ROOT/meta-payload"
[[ ! -e "$TMP_ROOT/tools-payload/usr/lib/systemd/system/orchard-node-agent.service.d/10-appliance.conf" ]] ||
    fail "appliance tools alter the standalone Node profile"
[[ ! -e "$TMP_ROOT/tools-payload/usr/lib/systemd/system-preset/99-orchard-appliance.preset" ]] ||
    fail "appliance tools alter standalone Node presets"
[[ -f "$TMP_ROOT/meta-payload/usr/lib/systemd/system/orchard-node-agent.service.d/10-appliance.conf" ]] ||
    fail "complete appliance package does not own the Node composition drop-in"
[[ -f "$TMP_ROOT/meta-payload/usr/lib/systemd/system-preset/99-orchard-appliance.preset" ]] ||
    fail "complete appliance package does not own its default-off preset"

META="$OUT_ONE/orchard-appliance_${DEBIAN_VERSION}_amd64.deb"
META_DEPENDS=$(dpkg-deb --field "$META" Depends)
for package in orchard-appliance-tools orchard-controller orchard-postgresql orchard-worker-foundation orchard-node-agent; do
    [[ "$META_DEPENDS" = *"$package (= $DEBIAN_VERSION)"* ]] || fail "meta-package does not exactly pin $package"
done
POSTGRES_DEPENDS=$(dpkg-deb --field "$OUT_ONE/orchard-postgresql_${DEBIAN_VERSION}_amd64.deb" Depends)
[[ "$POSTGRES_DEPENDS" != *'postgresql-16'* ]] || fail "inert package would let Ubuntu initialize PostgreSQL as a dependency side effect"
TOOLS_DEPENDS=$(dpkg-deb --field "$OUT_ONE/orchard-appliance-tools_${DEBIAN_VERSION}_amd64.deb" Depends)
[[ "$TOOLS_DEPENDS" = *'util-linux (>= 2.39)'* && "$TOOLS_DEPENDS" != *'flock'* ]] ||
    fail "appliance tools do not depend on the Ubuntu package that owns flock"

MANIFEST="$ROOT/usr/lib/orchard/appliance/compatibility.json"
jq -e --arg commit "$SOURCE_COMMIT" --arg version "$VERSION" '
  .source_commit == $commit and
  .product_version == $version and
  (.source_tree_clean | type) == "boolean" and
  .activation == "disabled" and
  .providers == [] and
  .support_status == "unqualified" and
  ([.packages[].name] | unique | length) == 6
' "$MANIFEST" >/dev/null || fail "compatibility manifest is invalid"
jq -e '
  .postgresql.major == 16 and
  .postgresql.closure == "postgresql-16-closure.json" and
  .postgresql.install_policy == "lifecycle_owned_no_automatic_cluster" and
  ([.postgresql.packages[].version] | all(length > 0))
' "$ROOT/usr/lib/orchard/appliance/dependencies.json" >/dev/null || fail "PostgreSQL dependency closure is incomplete"
CLOSURE="$ROOT/usr/lib/orchard/appliance/postgresql-16-closure.json"
jq -e '(.packages | length >= 80) and ([.packages[].name] | unique | length) == (.packages | length)' "$CLOSURE" >/dev/null || fail "PostgreSQL transitive closure is incomplete or duplicated"
[[ "$(sha256sum "$CLOSURE" | cut -d ' ' -f 1)" = "$(jq -r '.postgresql_closure_sha256' "$MANIFEST")" ]] || fail "PostgreSQL closure digest is not bound to compatibility metadata"

run_control() {
    local package=$1
    local phase=$2
    local action=${3:-configure}
    env \
        ORCHARD_PACKAGE_ROOT="$ROOT" \
        ORCHARD_SYSTEMD_SIMULATE=1 \
        DPKG_MAINTSCRIPT_PACKAGE="$package" \
        "$TMP_ROOT/control/$package/$phase" "$action"
}

mkdir -p "$ROOT/var/lib/dpkg"
: > "$ROOT/var/lib/dpkg/status"
for package in orchard-appliance-tools orchard-controller orchard-postgresql orchard-worker-foundation orchard-node-agent orchard-appliance; do
    cat >> "$ROOT/var/lib/dpkg/status" <<EOF
Package: $package
Status: install ok installed
Architecture: amd64
Version: $DEBIAN_VERSION
Description: fixture

EOF
done

for package in orchard-appliance-tools orchard-worker-foundation orchard-controller orchard-postgresql orchard-appliance; do
    run_control "$package" postinst
done
ORCHARD_PACKAGE_ROOT="$ROOT" ORCHARD_SYSTEMD_SIMULATE=1 "$TMP_ROOT/control/orchard-node-agent/postinst" configure

for path_mode in \
    etc/orchard/controller:750 \
    etc/orchard/appliance:750 \
    var/lib/orchard/appliance:700 \
    var/lib/orchard/controller:700 \
    var/lib/orchard/models:750 \
    var/lib/orchard/worker:700 \
    var/backups/orchard:700
do
    path=${path_mode%:*}
    mode=${path_mode#*:}
    [[ "$(stat -c %a "$ROOT/$path")" = "$mode" ]] || fail "$path mode is not $mode"
done

[[ ! -e "$ROOT/var/lib/postgresql/16/orchard/PG_VERSION" ]] || fail "package lifecycle initialized PostgreSQL"
[[ ! -e "$ROOT/etc/orchard/appliance/initialized" ]] || fail "package lifecycle initialized the appliance"
[[ ! -e "$ROOT/etc/orchard/node/node-agent.env" ]] || fail "package lifecycle configured or enrolled the Node"
[[ ! -d "$ROOT/opt/orchard/workers" ]] || fail "package lifecycle installed a Worker provider"
[[ ! -d "$ROOT/var/lib/orchard/models" || -z "$(find "$ROOT/var/lib/orchard/models" -mindepth 1 -print -quit)" ]] || fail "package lifecycle installed a model"
[[ ! -d "$ROOT/etc/systemd/system" || -z "$(find "$ROOT/etc/systemd/system" -type l -print -quit)" ]] || fail "package lifecycle enabled a unit"
jq -e --arg version "$DEBIAN_VERSION" '
  .version == $version and .phase == "postinst"
' "$ROOT/var/lib/orchard/appliance/package-receipts/orchard-controller.json" >/dev/null || fail "receipt did not use its embedded exact package version"
jq -e '([.packages[].name] | unique | length) == 6' "$ROOT/var/lib/orchard/appliance/package-receipts/package-set.json" >/dev/null || fail "coordinated package-set receipt does not cover all six packages"
if [[ "$(jq -r '.source_tree_clean' "$MANIFEST")" = "false" ]]; then
    if "$ROOT/usr/lib/orchard/appliance/orchard-appliance-preflight" "$ROOT" >/dev/null 2>&1; then
        fail "preflight accepted package provenance built from a dirty source tree"
    fi
    temporary="$MANIFEST.new"
    jq '.source_tree_clean = true' "$MANIFEST" > "$temporary"
    mv "$temporary" "$MANIFEST"
fi
"$ROOT/usr/lib/orchard/appliance/orchard-appliance-preflight" "$ROOT" >/dev/null || fail "inert compatible package set failed preflight"

sed -i "0,/Version: $DEBIAN_VERSION/s//Version: 9.9.9/" "$ROOT/var/lib/dpkg/status"
if "$ROOT/usr/lib/orchard/appliance/orchard-appliance-preflight" "$ROOT" >/dev/null 2>&1; then
    fail "preflight accepted a mixed unsupported package tuple"
fi
sed -i "0,/Version: 9.9.9/s//Version: $DEBIAN_VERSION/" "$ROOT/var/lib/dpkg/status"

mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -s /usr/lib/systemd/system/orchard-controller.service "$ROOT/etc/systemd/system/multi-user.target.wants/orchard-controller.service"
if "$ROOT/usr/lib/orchard/appliance/orchard-appliance-preflight" "$ROOT" >/dev/null 2>&1; then
    fail "preflight accepted an enabled Orchard unit"
fi
run_control orchard-appliance postinst
[[ ! -e "$ROOT/etc/systemd/system/multi-user.target.wants/orchard-controller.service" ]] || fail "reinstall did not disable a retained enabled unit"

mv "$ROOT/var/lib/orchard" "$ROOT/var/lib/orchard-real"
ln -s "$ROOT/var/lib/orchard-real" "$ROOT/var/lib/orchard"
if "$ROOT/usr/lib/orchard/appliance/orchard-appliance-preflight" "$ROOT" >/dev/null 2>&1; then
    fail "preflight accepted a symlinked role-root parent"
fi
rm "$ROOT/var/lib/orchard"
mv "$ROOT/var/lib/orchard-real" "$ROOT/var/lib/orchard"

SENTINEL="$TMP_ROOT/outside"
mkdir "$SENTINEL"
chmod 0711 "$SENTINEL"
rmdir "$ROOT/var/lib/orchard/controller"
ln -s "$SENTINEL" "$ROOT/var/lib/orchard/controller"
if run_control orchard-controller postinst >/dev/null 2>&1; then
    fail "controller package followed a role-root symlink"
fi
[[ "$(stat -c %a "$SENTINEL")" = "711" ]] || fail "symlink refusal mutated the external target"
rm "$ROOT/var/lib/orchard/controller"
mkdir -m 0700 "$ROOT/var/lib/orchard/controller"

CONTROLLER_RECEIPT="$ROOT/var/lib/orchard/appliance/package-receipts/orchard-controller.json"
mv "$CONTROLLER_RECEIPT" "$CONTROLLER_RECEIPT.safe"
ln -s "$SENTINEL/receipt" "$CONTROLLER_RECEIPT"
printf 'outside\n' > "$SENTINEL/receipt"
if run_control orchard-controller postinst >/dev/null 2>&1; then
    fail "controller package followed a receipt symlink"
fi
[[ "$(cat "$SENTINEL/receipt")" = "outside" ]] || fail "receipt symlink refusal mutated the external target"
rm "$CONTROLLER_RECEIPT"
mv "$CONTROLLER_RECEIPT.safe" "$CONTROLLER_RECEIPT"
ln "$CONTROLLER_RECEIPT" "$TMP_ROOT/receipt-hardlink"
if run_control orchard-controller postinst >/dev/null 2>&1; then
    fail "controller package accepted a hard-linked receipt"
fi
rm "$TMP_ROOT/receipt-hardlink"

setsid flock "$ROOT/var/lib/orchard/appliance/lifecycle.lock" sleep 30 &
LOCK_PID=$!
sleep 0.1
if run_control orchard-controller postinst >/dev/null 2>&1; then
    fail "package lifecycle ignored the exclusive appliance lock"
fi
kill -- "-$LOCK_PID"
wait "$LOCK_PID" >/dev/null 2>&1 || true
LOCK_PID=""
for _ in {1..50}; do
    flock -n "$ROOT/var/lib/orchard/appliance/lifecycle.lock" true 2>/dev/null && break
    sleep 0.05
done
flock -n "$ROOT/var/lib/orchard/appliance/lifecycle.lock" true 2>/dev/null || fail "test lock holder did not release the lifecycle lock"

printf 'retained\n' > "$ROOT/var/lib/orchard/controller/retained"
printf 'retained\n' > "$ROOT/var/lib/orchard/appliance/retained"
ln -s /usr/lib/systemd/system/orchard-controller.service "$ROOT/etc/systemd/system/multi-user.target.wants/orchard-controller.service"
run_control orchard-controller prerm remove
run_control orchard-controller postrm
[[ ! -e "$ROOT/etc/systemd/system/multi-user.target.wants/orchard-controller.service" ]] || fail "ordinary removal did not disable the Controller unit"
grep -Fx 'stop:orchard-controller.service' "$ROOT/run/orchard-appliance/systemd-simulation.log" >/dev/null || fail "ordinary removal did not stop the Controller unit"
[[ -f "$ROOT/var/lib/orchard/controller/retained" ]] || fail "ordinary removal erased Controller state"
[[ -f "$ROOT/var/lib/orchard/appliance/retained" ]] || fail "ordinary removal erased lifecycle state"
jq -e '.generation >= 3 and .phase == "postrm"' "$ROOT/var/lib/orchard/appliance/package-receipts/orchard-controller.json" >/dev/null ||
    fail "package lifecycle receipt is not durable and monotonic"

UNITS="$ROOT/usr/lib/systemd/system"
grep -F 'ConditionPathExists=/etc/orchard/appliance/initialized' "$UNITS/orchard-appliance.target" >/dev/null || fail "appliance target is not initialization-gated"
grep -F 'Requires=orchard-postgresql.service orchard-db-migrate.service orchard-controller.service' "$UNITS/orchard-appliance.target" >/dev/null || fail "target dependency ordering is incomplete"
grep -F 'Slice=orchard-control.slice' "$UNITS/orchard-controller.service" >/dev/null || fail "Controller cgroup boundary is missing"
grep -F 'Slice=orchard-database.slice' "$UNITS/orchard-postgresql.service" >/dev/null || fail "database cgroup boundary is missing"
grep -F 'User=postgres' "$UNITS/orchard-postgresql.service" >/dev/null || fail "PostgreSQL role identity is missing"
grep -F 'KillMode=control-group' "$UNITS/orchard-node-agent.service" >/dev/null || fail "Node process custody boundary regressed"
grep -F 'Slice=orchard.slice' "$UNITS/orchard-node-agent.service.d/10-appliance.conf" >/dev/null || fail "Node appliance cgroup boundary is missing"
grep -Fx 'disable orchard-appliance.target' "$ROOT/usr/lib/systemd/system-preset/99-orchard-appliance.preset" >/dev/null || fail "default-off preset is missing"

mkdir -p "$ROOT/usr/lib/postgresql/16/bin"
printf '#!/bin/sh\nexit 78\n' > "$ROOT/usr/lib/postgresql/16/bin/postgres"
printf '#!/bin/sh\nexit 78\n' > "$ROOT/usr/lib/postgresql/16/bin/pg_ctl"
chmod 0755 "$ROOT/usr/lib/postgresql/16/bin/postgres" "$ROOT/usr/lib/postgresql/16/bin/pg_ctl"
if ! systemd-analyze verify --root="$ROOT" \
    orchard.slice orchard-control.slice orchard-database.slice \
    orchard-postgresql.service orchard-db-migrate.service \
    orchard-controller.service orchard-node-agent.service \
    orchard-appliance.target > /dev/null 2> "$TMP_ROOT/systemd-verify.err"; then
    sed '/Unit sysinit.target not found/d' "$TMP_ROOT/systemd-verify.err" > "$TMP_ROOT/systemd-verify.unexpected"
    [[ ! -s "$TMP_ROOT/systemd-verify.unexpected" ]] || {
        cat "$TMP_ROOT/systemd-verify.unexpected" >&2
        fail "systemd unit verification failed"
    }
fi

[[ ! -e "$ROOT/usr/share/orchard/worker/provider" ]] || fail "Worker foundation contains a provider"
[[ ! -x "$ROOT/usr/share/orchard/worker/README" ]] || fail "Worker foundation unexpectedly contains executable payload"
[[ -x "$ROOT/opt/orchard/controller/releases/orchard_controller/bin/orchard_controller" ]] || fail "Controller role payload is missing"
[[ -x "$ROOT/opt/orchard/node/releases/orchard_node_agent/bin/orchard_node_agent" ]] || fail "Node role payload is missing"

printf 'test-ubuntu-appliance-packages: PASS\n'
