#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="$REPO_ROOT/packaging/linux/node"
OUTPUT_DIR="${1:-$REPO_ROOT/release-artifacts/linux-node}"
PROFILE="${2:-ubuntu_24_04_x86_64_node}"
case "$OUTPUT_DIR" in
    /*) ;;
    *) OUTPUT_DIR="$PWD/$OUTPUT_DIR" ;;
esac
case "$PROFILE" in
    ubuntu_24_04_x86_64_node|ubuntu_26_04_x86_64_node) ;;
    *)
        printf 'build-linux-node-package: unsupported platform profile: %s\n' "$PROFILE" >&2
        exit 64
        ;;
esac
PROFILE_ROOT="$SOURCE_ROOT/profiles/$PROFILE"
DEPENDENCIES="$PROFILE_ROOT/dependencies.json"
PREFLIGHT="$PROFILE_ROOT/preflight"
VERSION="$(tr -d '\n' < "$REPO_ROOT/VERSION")"
DEBIAN_VERSION="${VERSION/-dev/~dev}"
DEBIAN_DEPENDS=$(jq -r '[.packages[] | "\(.name) (\(.version))"] | join(", ")' "$DEPENDENCIES")
ARCH=amd64
case "$PROFILE" in
    ubuntu_24_04_x86_64_node) PACKAGE="orchard-node-agent_${DEBIAN_VERSION}_${ARCH}.deb" ;;
    ubuntu_26_04_x86_64_node) PACKAGE="orchard-node-agent_${DEBIAN_VERSION}_ubuntu26.04_${ARCH}.deb" ;;
esac
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-linux-node-package.XXXXXX")"
PACKAGE_ROOT="$WORK_ROOT/package"
BUILD_PATH=/tmp/orchard-linux-node-package-build
RELEASE_ROOT="$BUILD_PATH/rel/orchard_node_agent"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO_ROOT" log -1 --format=%ct)}"
ERL_COMPILER_OPTIONS=deterministic
export SOURCE_DATE_EPOCH ERL_COMPILER_OPTIONS

cleanup() {
    rm -rf "$WORK_ROOT" "$BUILD_PATH"
}

if ! mkdir -m 0700 "$BUILD_PATH"; then
    printf 'build-linux-node-package: another build or stale build root exists: %s\n' "$BUILD_PATH" >&2
    rm -rf "$WORK_ROOT"
    exit 1
fi
trap cleanup EXIT INT TERM

"$PREFLIGHT" /

cd "$REPO_ROOT/apps/orchard_node_agent"
MIX_ENV=prod MIX_BUILD_PATH="$BUILD_PATH" mix release --overwrite

printf '%s\n' 'ORCHARD_LINUX_DISTRIBUTION_DISABLED' > "$RELEASE_ROOT/releases/COOKIE"

forbidden=$(find "$RELEASE_ROOT" \
    \( -type d -o -type f \) \
    \( -name 'orchard_controller-*' -o -name 'orchard_cli-*' -o -iname '*mlx*' \
       -o -iname '*cuda*' -o -iname '*rocm*' -o -iname '*vllm*' -o -iname '*.dylib' \) \
    -print -quit)
if [[ -n "$forbidden" ]]; then
    printf 'build-linux-node-package: forbidden Node package payload: %s\n' "$forbidden" >&2
    exit 1
fi

allowed_libraries='^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|ld-linux-x86-64\.so\.2|libcrypto\.so\.3|libtinfo\.so\.6|libz\.so\.1|libstdc\+\+\.so\.6|libgcc_s\.so\.1)$'
command -v readelf >/dev/null 2>&1 || {
    printf 'build-linux-node-package: readelf is required to verify runtime dependencies\n' >&2
    exit 1
}
mapfile -d '' release_files < <(find "$RELEASE_ROOT" -type f -print0)
for binary in "${release_files[@]}"; do
    magic=$(od -An -tx1 -N4 "$binary" | tr -d ' \n')
    [[ "$magic" = "7f454c46" ]] || continue
    needed=$(readelf -d "$binary") || {
        printf 'build-linux-node-package: could not inspect ELF dependencies for %s\n' "$binary" >&2
        exit 1
    }
    while read -r library; do
        [[ "$library" =~ $allowed_libraries ]] || {
            printf 'build-linux-node-package: undeclared ELF dependency %s from %s\n' "$library" "$binary" >&2
            exit 1
        }
    done < <(printf '%s\n' "$needed" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
done

mkdir -p \
    "$PACKAGE_ROOT/DEBIAN" \
    "$PACKAGE_ROOT/opt/orchard/node/bin" \
    "$PACKAGE_ROOT/opt/orchard/node/releases" \
    "$PACKAGE_ROOT/opt/orchard/node/share" \
    "$PACKAGE_ROOT/etc/orchard/node" \
    "$PACKAGE_ROOT/var/lib/orchard/node/identity" \
    "$PACKAGE_ROOT/var/lib/orchard/node/models" \
    "$PACKAGE_ROOT/var/log/orchard/node/workers" \
    "$PACKAGE_ROOT/usr/lib/systemd/system"
chmod 0755 "$PACKAGE_ROOT/DEBIAN"

cp -a "$RELEASE_ROOT" "$PACKAGE_ROOT/opt/orchard/node/releases/orchard_node_agent"
install -m 0755 "$SOURCE_ROOT/orchard-node-agent" "$PACKAGE_ROOT/opt/orchard/node/bin/orchard-node-agent"
install -m 0644 "$DEPENDENCIES" "$PACKAGE_ROOT/opt/orchard/node/share/dependencies.json"
printf '%s\n' "$PROFILE" > "$PACKAGE_ROOT/opt/orchard/node/share/platform-profile"
install -m 0644 "$SOURCE_ROOT/orchard-node-agent.service" "$PACKAGE_ROOT/usr/lib/systemd/system/orchard-node-agent.service"
install -m 0755 "$PREFLIGHT" "$PACKAGE_ROOT/opt/orchard/node/bin/preflight"
install -m 0755 "$PREFLIGHT" "$PACKAGE_ROOT/DEBIAN/preinst"
install -m 0755 "$SOURCE_ROOT/postinst" "$PACKAGE_ROOT/DEBIAN/postinst"
install -m 0755 "$SOURCE_ROOT/prerm" "$PACKAGE_ROOT/DEBIAN/prerm"
install -m 0755 "$SOURCE_ROOT/postrm" "$PACKAGE_ROOT/DEBIAN/postrm"

cat > "$PACKAGE_ROOT/DEBIAN/control" <<EOF
Package: orchard-node-agent
Version: $DEBIAN_VERSION
Section: admin
Priority: optional
Architecture: $ARCH
Depends: $DEBIAN_DEPENDS
X-Orchard-Platform-Profile: $PROFILE
Maintainer: Orchard Contributors
Description: Experimental Orchard Node Agent for the selected Ubuntu candidate
 Node-only, provider-neutral package. Installation does not confer scheduling
 authority or a general Linux support claim.
EOF

find "$PACKAGE_ROOT" -type d -exec chmod 0755 {} +
while IFS= read -r -d '' file; do
    if [[ -x "$file" ]]; then
        chmod 0755 "$file"
    else
        chmod 0644 "$file"
    fi
done < <(find "$PACKAGE_ROOT" -type f -print0)
chmod 0755 "$PACKAGE_ROOT/DEBIAN"/{preinst,postinst,prerm,postrm}

find "$PACKAGE_ROOT" -print0 | xargs -0 touch -h -d "@${SOURCE_DATE_EPOCH:-0}"
mkdir -p "$OUTPUT_DIR"
dpkg-deb --root-owner-group --build "$PACKAGE_ROOT" "$OUTPUT_DIR/$PACKAGE"
sha256sum "$OUTPUT_DIR/$PACKAGE" > "$OUTPUT_DIR/$PACKAGE.sha256"
printf '%s\n' "$OUTPUT_DIR/$PACKAGE"
