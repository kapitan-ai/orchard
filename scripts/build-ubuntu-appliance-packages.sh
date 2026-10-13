#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="$REPO_ROOT/packaging/linux/appliance"
OUTPUT_DIR="$REPO_ROOT/release-artifacts/ubuntu-appliance"
ALLOW_DIRTY=false

usage() {
    cat <<'EOF'
Usage: scripts/build-ubuntu-appliance-packages.sh [--allow-dirty] [output_dir]

Build the inert coordinated package set for ubuntu_24_04_x86_64_single_host.
The output is not installed, published, or activated.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-dirty)
            ALLOW_DIRTY=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            printf 'build-ubuntu-appliance-packages: unknown option %s\n' "$1" >&2
            exit 64
            ;;
        *)
            OUTPUT_DIR=$1
            shift
            [[ $# -eq 0 ]] || {
                printf 'build-ubuntu-appliance-packages: only one output directory is accepted\n' >&2
                exit 64
            }
            ;;
    esac
done

case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$PWD/$OUTPUT_DIR" ;;
esac

for command in dpkg-deb flock jq sha256sum readelf; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'build-ubuntu-appliance-packages: required command is missing: %s\n' "$command" >&2
        exit 69
    }
done

VERSION="$(tr -d '\n' < "$REPO_ROOT/VERSION")"
DEBIAN_VERSION=${VERSION/-dev/~dev}
ARCH=amd64
PROFILE=ubuntu_24_04_x86_64_single_host
SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD^{commit})"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" log -1 --format=%ct)}"
ERL_COMPILER_OPTIONS=deterministic
export SOURCE_DATE_EPOCH ERL_COMPILER_OPTIONS

SOURCE_TREE_CLEAN=true
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
    SOURCE_TREE_CLEAN=false
    if [[ "$ALLOW_DIRTY" != true ]]; then
        printf 'build-ubuntu-appliance-packages: refusing dirty source; commit first or use --allow-dirty for non-publishable development evidence\n' >&2
        exit 1
    fi
fi

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-appliance-package.XXXXXX")"
BUILD_PATH="$WORK_ROOT/build"
PACKAGE_ROOTS="$WORK_ROOT/packages"
CONTROLLER_RELEASE="$BUILD_PATH/rel/orchard_controller"
NODE_OUTPUT="$WORK_ROOT/node-output"

cleanup() {
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT INT TERM

mkdir -p "$BUILD_PATH" "$PACKAGE_ROOTS" "$NODE_OUTPUT"

(
    cd "$REPO_ROOT"
    MIX_ENV=prod MIX_BUILD_PATH="$BUILD_PATH" mix release orchard_controller --overwrite
)
[[ -x "$CONTROLLER_RELEASE/bin/orchard_controller" ]] || {
    printf 'build-ubuntu-appliance-packages: Controller release is incomplete\n' >&2
    exit 1
}
printf '%s\n' 'ORCHARD_LINUX_DISTRIBUTION_DISABLED' > "$CONTROLLER_RELEASE/releases/COOKIE"

SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    flock "${TMPDIR:-/tmp}/orchard-appliance-node-package.lock" \
    "$REPO_ROOT/scripts/build-linux-node-package.sh" "$NODE_OUTPUT" ubuntu_24_04_x86_64_node >/dev/null
NODE_PACKAGE=$(find "$NODE_OUTPUT" -maxdepth 1 -type f -name 'orchard-node-agent_*.deb' -print -quit)
[[ -n "$NODE_PACKAGE" ]] || {
    printf 'build-ubuntu-appliance-packages: Node package was not produced\n' >&2
    exit 1
}
NODE_VERSION=$(dpkg-deb --field "$NODE_PACKAGE" Version)
[[ "$NODE_VERSION" = "$DEBIAN_VERSION" ]] || {
    printf 'build-ubuntu-appliance-packages: Node package version %s does not match %s\n' "$NODE_VERSION" "$DEBIAN_VERSION" >&2
    exit 1
}

POSTGRESQL_CLOSURE_SHA256=$(sha256sum "$SOURCE_ROOT/postgresql-16-closure.json" | cut -d ' ' -f 1)
DEPENDENCY_LOCK_SHA256=$(
    cat \
        "$SOURCE_ROOT/dependencies.json" \
        "$SOURCE_ROOT/postgresql-16-closure.json" \
        "$REPO_ROOT/packaging/linux/node/profiles/ubuntu_24_04_x86_64_node/dependencies.json" |
        sha256sum | cut -d ' ' -f 1
)

COMPATIBILITY="$WORK_ROOT/compatibility.json"
jq -n \
    --arg profile "$PROFILE" \
    --arg version "$VERSION" \
    --arg debian_version "$DEBIAN_VERSION" \
    --arg source_commit "$SOURCE_COMMIT" \
    --arg dependency_lock_sha256 "$DEPENDENCY_LOCK_SHA256" \
    --arg postgresql_closure_sha256 "$POSTGRESQL_CLOSURE_SHA256" \
    --argjson clean "$SOURCE_TREE_CLEAN" \
    '{
      schema_version: 1,
      profile: $profile,
      architecture: "amd64",
      product_version: $version,
      source_commit: $source_commit,
      source_tree_clean: $clean,
      dependency_lock_sha256: $dependency_lock_sha256,
      postgresql_closure_sha256: $postgresql_closure_sha256,
      activation: "disabled",
      schema_contract: $version,
      runtime_endpoint_contract: "cluster.v1/beam-peer-grant-v1",
      worker_runtime_contract: "orchard.worker.v1",
      packages: [
        {name: "orchard-appliance-tools", version: $debian_version},
        {name: "orchard-controller", version: $debian_version},
        {name: "orchard-postgresql", version: $debian_version},
        {name: "orchard-worker-foundation", version: $debian_version},
        {name: "orchard-node-agent", version: $debian_version},
        {name: "orchard-appliance", version: $debian_version}
      ],
      providers: [],
      support_status: "unqualified"
    }' > "$COMPATIBILITY"

new_package() {
    local package=$1
    local root="$PACKAGE_ROOTS/$package"
    mkdir -p "$root/DEBIAN"
    chmod 0755 "$root/DEBIAN"
    printf '%s\n' "$root"
}

install_maintainers() {
    local root=$1
    local phase
    for phase in postinst prerm postrm; do
        {
            printf '#!/bin/sh\nset -eu\nORCHARD_MAINTAINER_PHASE=%s\nORCHARD_MAINTSCRIPT_VERSION=%s\nexport ORCHARD_MAINTAINER_PHASE ORCHARD_MAINTSCRIPT_VERSION\n' "$phase" "$DEBIAN_VERSION"
            cat "$SOURCE_ROOT/maintainer"
        } > "$root/DEBIAN/$phase"
        chmod 0755 "$root/DEBIAN/$phase"
    done
}

write_control() {
    local root=$1
    local package=$2
    local depends=$3
    local description=$4
    cat > "$root/DEBIAN/control" <<EOF
Package: $package
Version: $DEBIAN_VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Depends: $depends
X-Orchard-Platform-Profile: $PROFILE
X-Orchard-Activation: disabled
Maintainer: Orchard Contributors
Description: $description
 Inert, unqualified foundation for the exact Ubuntu 24.04 single-host profile.
 Installation does not initialize authority, activate services, or confer support.
EOF
}

TOOLS_ROOT=$(new_package orchard-appliance-tools)
mkdir -p \
    "$TOOLS_ROOT/usr/lib/orchard/appliance" \
    "$TOOLS_ROOT/usr/lib/systemd/system" \
    "$TOOLS_ROOT/etc/orchard/appliance"
chmod 0750 "$TOOLS_ROOT/etc/orchard/appliance"
install -m 0755 "$SOURCE_ROOT/orchard-appliance-preflight" "$TOOLS_ROOT/usr/lib/orchard/appliance/orchard-appliance-preflight"
install -m 0755 "$SOURCE_ROOT/orchard-db-migrate" "$TOOLS_ROOT/usr/lib/orchard/appliance/orchard-db-migrate"
install -m 0644 "$COMPATIBILITY" "$TOOLS_ROOT/usr/lib/orchard/appliance/compatibility.json"
install -m 0644 "$SOURCE_ROOT/dependencies.json" "$TOOLS_ROOT/usr/lib/orchard/appliance/dependencies.json"
install -m 0644 "$SOURCE_ROOT/postgresql-16-closure.json" "$TOOLS_ROOT/usr/lib/orchard/appliance/postgresql-16-closure.json"
install -m 0644 "$COMPATIBILITY" "$TOOLS_ROOT/etc/orchard/appliance/compatibility.json"
install -m 0644 "$SOURCE_ROOT/orchard-appliance.target" "$TOOLS_ROOT/usr/lib/systemd/system/orchard-appliance.target"
install -m 0644 "$SOURCE_ROOT/orchard.slice" "$TOOLS_ROOT/usr/lib/systemd/system/orchard.slice"
install -m 0644 "$SOURCE_ROOT/orchard-control.slice" "$TOOLS_ROOT/usr/lib/systemd/system/orchard-control.slice"
install -m 0644 "$SOURCE_ROOT/orchard-database.slice" "$TOOLS_ROOT/usr/lib/systemd/system/orchard-database.slice"
install_maintainers "$TOOLS_ROOT"
write_control "$TOOLS_ROOT" orchard-appliance-tools 'util-linux (>= 2.39), jq (>= 1.7), coreutils (>= 9.4)' 'Orchard appliance lifecycle and compatibility tools'

CONTROLLER_ROOT=$(new_package orchard-controller)
mkdir -p \
    "$CONTROLLER_ROOT/opt/orchard/controller/bin" \
    "$CONTROLLER_ROOT/opt/orchard/controller/releases" \
    "$CONTROLLER_ROOT/usr/lib/systemd/system"
cp -a "$CONTROLLER_RELEASE" "$CONTROLLER_ROOT/opt/orchard/controller/releases/orchard_controller"
install -m 0755 "$SOURCE_ROOT/orchard-controller" "$CONTROLLER_ROOT/opt/orchard/controller/bin/orchard-controller"
install -m 0644 "$SOURCE_ROOT/orchard-controller.service" "$CONTROLLER_ROOT/usr/lib/systemd/system/orchard-controller.service"
install_maintainers "$CONTROLLER_ROOT"
write_control "$CONTROLLER_ROOT" orchard-controller "orchard-appliance-tools (= $DEBIAN_VERSION)" 'Portable Orchard Controller role payload'

POSTGRES_ROOT=$(new_package orchard-postgresql)
mkdir -p "$POSTGRES_ROOT/usr/lib/systemd/system" "$POSTGRES_ROOT/usr/share/orchard/postgresql"
install -m 0644 "$SOURCE_ROOT/orchard-postgresql.service" "$POSTGRES_ROOT/usr/lib/systemd/system/orchard-postgresql.service"
install -m 0644 "$SOURCE_ROOT/orchard-db-migrate.service" "$POSTGRES_ROOT/usr/lib/systemd/system/orchard-db-migrate.service"
install -m 0644 "$SOURCE_ROOT/dependencies.json" "$POSTGRES_ROOT/usr/share/orchard/postgresql/dependencies.json"
install -m 0644 "$SOURCE_ROOT/postgresql-16-closure.json" "$POSTGRES_ROOT/usr/share/orchard/postgresql/postgresql-16-closure.json"
install_maintainers "$POSTGRES_ROOT"
write_control "$POSTGRES_ROOT" orchard-postgresql "orchard-appliance-tools (= $DEBIAN_VERSION)" 'Default-off PostgreSQL 16 integration metadata and units'

WORKER_ROOT=$(new_package orchard-worker-foundation)
mkdir -p "$WORKER_ROOT/usr/share/orchard/worker"
printf '%s\n' 'No Worker provider is included or activated by this package.' > "$WORKER_ROOT/usr/share/orchard/worker/README"
install_maintainers "$WORKER_ROOT"
write_control "$WORKER_ROOT" orchard-worker-foundation "orchard-appliance-tools (= $DEBIAN_VERSION)" 'Provider-free Orchard Worker identity and custody roots'

META_ROOT=$(new_package orchard-appliance)
mkdir -p \
    "$META_ROOT/usr/share/orchard/appliance" \
    "$META_ROOT/usr/lib/systemd/system/orchard-node-agent.service.d" \
    "$META_ROOT/usr/lib/systemd/system-preset"
install -m 0644 "$COMPATIBILITY" "$META_ROOT/usr/share/orchard/appliance/compatibility.json"
install -m 0644 "$SOURCE_ROOT/orchard-node-agent.service.d.conf" "$META_ROOT/usr/lib/systemd/system/orchard-node-agent.service.d/10-appliance.conf"
install -m 0644 "$SOURCE_ROOT/99-orchard-appliance.preset" "$META_ROOT/usr/lib/systemd/system-preset/99-orchard-appliance.preset"
install_maintainers "$META_ROOT"
write_control "$META_ROOT" orchard-appliance "orchard-appliance-tools (= $DEBIAN_VERSION), orchard-controller (= $DEBIAN_VERSION), orchard-postgresql (= $DEBIAN_VERSION), orchard-worker-foundation (= $DEBIAN_VERSION), orchard-node-agent (= $DEBIAN_VERSION)" 'Compatibility-locking Ubuntu single-host Orchard meta-package'

mkdir -p "$OUTPUT_DIR"
rm -f "$OUTPUT_DIR"/*.deb "$OUTPUT_DIR"/*.deb.sha256 "$OUTPUT_DIR/SHA256SUMS"
for package in orchard-appliance-tools orchard-controller orchard-postgresql orchard-worker-foundation orchard-appliance; do
    root="$PACKAGE_ROOTS/$package"
    find "$root" -print0 | xargs -0 touch -h -d "@$SOURCE_DATE_EPOCH"
    output="$OUTPUT_DIR/${package}_${DEBIAN_VERSION}_${ARCH}.deb"
    dpkg-deb --root-owner-group --build "$root" "$output" >/dev/null
done
install -m 0644 "$NODE_PACKAGE" "$OUTPUT_DIR/orchard-node-agent_${DEBIAN_VERSION}_${ARCH}.deb"

(
    cd "$OUTPUT_DIR"
    sha256sum ./*.deb | LC_ALL=C sort -k2 > SHA256SUMS
    while read -r digest file; do
        printf '%s  %s\n' "$digest" "${file#./}" > "${file#./}.sha256"
    done < SHA256SUMS
)

printf 'APPLIANCE_PACKAGES=%s\n' "$OUTPUT_DIR"
