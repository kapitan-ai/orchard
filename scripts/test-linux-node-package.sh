#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-linux-node-test.XXXXXX")"
TOOLS="$TMP_ROOT/tools"
PREFLIGHT_TOOLS="$TMP_ROOT/preflight-tools"
OUT="$TMP_ROOT/out"
PROFILES_ROOT="$REPO_ROOT/packaging/linux/node/profiles"

case "$(. /etc/os-release && printf '%s' "$ID:$VERSION_ID")" in
    ubuntu:24.04)
        PROFILE=ubuntu_24_04_x86_64_node
        REJECTED_HOST_PROFILE=ubuntu_26_04_x86_64_node
        PROFILE_VERSION=24.04
        COREUTILS_DEPENDENCY='coreutils (>= 9.4)'
        COREUTILS_PREFIX=""
        ;;
    ubuntu:26.04)
        PROFILE=ubuntu_26_04_x86_64_node
        REJECTED_HOST_PROFILE=ubuntu_24_04_x86_64_node
        PROFILE_VERSION=26.04
        COREUTILS_DEPENDENCY='gnu-coreutils (>= 9.7)'
        COREUTILS_PREFIX=gnu
        ;;
    *)
        printf 'test-linux-node-package: an enumerated Ubuntu candidate host is required\n' >&2
        exit 69
        ;;
esac

cleanup() {
    if [[ -n "${FIRST_PID:-}" ]]; then
        kill "$FIRST_PID" >/dev/null 2>&1 || true
        wait "$FIRST_PID" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
    printf 'test-linux-node-package: %s\n' "$1" >&2
    exit 1
}

prepare_preflight_root() {
    local root=$1
    local version=$2
    mkdir -p "$root/etc" "$root/proc/1" "$root/proc/sys/kernel" "$root/sys/fs/cgroup"
    printf 'ID=ubuntu\nVERSION_ID="%s"\n' "$version" > "$root/etc/os-release"
    printf 'systemd\n' > "$root/proc/1/comm"
    printf 'fixture-kernel\n' > "$root/proc/sys/kernel/osrelease"
}

run_preflight() {
    local profile=$1
    local root=$2
    shift 2
    env PATH="$PREFLIGHT_TOOLS:$PATH" ORCHARD_TEST_PREFLIGHT_PROFILE="$profile" "$@" "$PROFILES_ROOT/$profile/preflight" "$root"
}

mkdir -p "$TOOLS" "$PREFLIGHT_TOOLS"
cat > "$TOOLS/mix" <<'SH'
#!/bin/sh
set -eu
[ "${1:-}" = "release" ] && [ "${2:-}" = "--overwrite" ] || exit 90
[ "$(basename "$PWD")" = "orchard_node_agent" ] || exit 91
release="${MIX_BUILD_PATH:?}/rel/orchard_node_agent"
mkdir -p "$release/bin" "$release/erts-16.4/bin" "$release/lib/orchard_node_agent-0.1.0/ebin" "$release/releases"
cat > "$release/bin/orchard_node_agent" <<'BIN'
#!/bin/sh
printf 'started:%s:%s:%s\n' "$ORCHARD_SUPPORT_ROOT" "$ORCHARD_NODE_IDENTITY_ROOT" "$ORCHARD_MODELS_ROOT"
printf 'distribution:%s:%s:%s:%s\n' "${RELEASE_DISTRIBUTION:-}" "${RELEASE_NODE:-unset}" "${RELEASE_COOKIE:-unset}" "${ERL_EPMD_PORT:-unset}"
printf 'coreutils-prefix:%s\n' "${ORCHARD_LINUX_COREUTILS_PREFIX:-}"
if [ "${ORCHARD_TEST_SLEEP:-0}" -gt 0 ]; then
    exec sleep "$ORCHARD_TEST_SLEEP"
fi
BIN
chmod +x "$release/bin/orchard_node_agent"
cp /bin/true "$release/erts-16.4/bin/beam.smp"
if [ "${ORCHARD_TEST_FAKE_CONTAMINATED:-0}" = "1" ]; then
    mkdir -p "$release/lib/orchard_controller-0.1.0/ebin"
fi
SH
chmod +x "$TOOLS/mix"
cat > "$TOOLS/readelf" <<'SH'
#!/bin/sh
if [ "${ORCHARD_TEST_READELF_FAIL:-0}" = "1" ]; then
    exit 1
fi
if [ "${ORCHARD_TEST_READELF_UNDECLARED:-0}" = "1" ]; then
    printf ' 0x0000000000000001 (NEEDED) Shared library: [libundeclared.so.1]\n'
    exit 0
fi
exec /usr/bin/readelf "$@"
SH
chmod +x "$TOOLS/readelf"

cat > "$PREFLIGHT_TOOLS/uname" <<'SH'
#!/bin/sh
case "${1:-}" in
    -m) printf 'x86_64\n' ;;
    -r)
        if [ -n "${ORCHARD_TEST_KERNEL_RELEASE:-}" ]; then
            printf '%s\n' "$ORCHARD_TEST_KERNEL_RELEASE"
        elif [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ]; then
            printf '7.0.0-30-generic\n'
        else
            printf '6.8.0-139-generic\n'
        fi
        ;;
    *) exit 2 ;;
esac
SH
cat > "$PREFLIGHT_TOOLS/ldd" <<'SH'
#!/bin/sh
if [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ]; then
    printf 'ldd (Ubuntu GLIBC 2.43-2ubuntu2.3) 2.43\n'
else
    printf 'ldd (Ubuntu GLIBC 2.39) 2.39\n'
fi
SH
cat > "$PREFLIGHT_TOOLS/systemctl" <<'SH'
#!/bin/sh
if [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ]; then
    printf 'systemd 259 (259.5)\n'
else
    printf 'systemd 255 (255.4)\n'
fi
SH
cat > "$PREFLIGHT_TOOLS/systemd-detect-virt" <<'SH'
#!/bin/sh
exit 1
SH
cat > "$PREFLIGHT_TOOLS/dpkg-query" <<'SH'
#!/bin/sh
package=""
for argument in "$@"; do package=$argument; done
[ "$package" != "${ORCHARD_TEST_MISSING_PACKAGE:-}" ] || exit 1
case "$package" in
    libc6) [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ] && printf '2.43-2ubuntu2.3' || printf '2.39' ;;
    systemd) [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ] && printf '259.5-0ubuntu3.4' || printf '255' ;;
    util-linux) [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ] && printf '2.41.3' || printf '2.39' ;;
    gnu-coreutils) printf '9.7-3ubuntu2' ;;
    coreutils) printf '9.4' ;;
    adduser) [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ] && printf '3.153ubuntu1' || printf '3.137ubuntu1' ;;
    libssl3t64) [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ] && printf '3.5.5' || printf '3.0.13' ;;
    libtinfo6) [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ] && printf '6.6' || printf '6.4' ;;
    zlib1g) [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ] && printf '1:1.3.dfsg+really1.3.1' || printf '1:1.3.dfsg' ;;
    libstdc++6|libgcc-s1) [ "$ORCHARD_TEST_PREFLIGHT_PROFILE" = "ubuntu_26_04_x86_64_node" ] && printf '16' || printf '14' ;;
    *) exit 1 ;;
esac
SH
cat > "$PREFLIGHT_TOOLS/coreutils-fixture" <<'SH'
#!/bin/sh
case "${1:-}" in
    --version)
        case "$(basename "$0")" in
            timeout)
                [ "${ORCHARD_TEST_POISON_UNPREFIXED:-0}" = "0" ] || {
                    printf 'timeout (uutils) 0.0.0\n'
                    exit 0
                }
                ;;
            gnutimeout)
                [ "${ORCHARD_TEST_POISON_GNU_TIMEOUT:-0}" = "0" ] || {
                    printf 'timeout (uutils) 0.0.0\n'
                    exit 0
                }
                ;;
        esac
        printf '%s (GNU coreutils) 9.7\n' "$(basename "$0")"
        ;;
    -fc) printf 'cgroup2fs\n' ;;
    *) exit 2 ;;
esac
SH
chmod +x "$PREFLIGHT_TOOLS"/*
for command in stat timeout gnustat gnutimeout; do
    ln -s coreutils-fixture "$PREFLIGHT_TOOLS/$command"
done
for command in basename cat dpkg flock grep sed; do
    ln -s "$(command -v "$command")" "$PREFLIGHT_TOOLS/$command"
done

for candidate in ubuntu_24_04_x86_64_node ubuntu_26_04_x86_64_node; do
    manifest="$PROFILES_ROOT/$candidate/dependencies.json"
    preflight="$PROFILES_ROOT/$candidate/preflight"
    jq -e --arg candidate "$candidate" '.profile == $candidate and .architecture == "amd64"' "$manifest" >/dev/null || fail "$candidate manifest identity is invalid"
    [[ -x "$preflight" ]] || fail "$candidate preflight is not executable"
done
jq -e '.commands.stat.executable == "stat" and .commands.timeout.executable == "timeout"' "$PROFILES_ROOT/ubuntu_24_04_x86_64_node/dependencies.json" >/dev/null || fail "24.04 GNU command provenance is invalid"
jq -e '.commands.stat.executable == "gnustat" and .commands.timeout.executable == "gnutimeout" and ([.packages[].name] | index("gnu-coreutils"))' "$PROFILES_ROOT/ubuntu_26_04_x86_64_node/dependencies.json" >/dev/null || fail "26.04 GNU command provenance is invalid"

for candidate in ubuntu_24_04_x86_64_node ubuntu_26_04_x86_64_node; do
    version=${candidate#ubuntu_}
    version=${version%_x86_64_node}
    version=${version//_/.}
    case "$candidate" in
        ubuntu_24_04_x86_64_node) rejected_profile=ubuntu_26_04_x86_64_node ;;
        ubuntu_26_04_x86_64_node) rejected_profile=ubuntu_24_04_x86_64_node ;;
    esac
    fixture_root="$TMP_ROOT/preflight-$candidate"
    prepare_preflight_root "$fixture_root" "$version"
    run_preflight "$candidate" "$fixture_root" >/dev/null
    if run_preflight "$rejected_profile" "$fixture_root" >/dev/null 2>&1; then
        fail "$rejected_profile preflight accepted the $candidate fixture"
    fi
done
printf 'ID=ubuntu\nVERSION_ID="25.10"\n' > "$TMP_ROOT/preflight-$PROFILE/etc/os-release"
if run_preflight "$PROFILE" "$TMP_ROOT/preflight-$PROFILE" >/dev/null 2>&1; then
    fail "$PROFILE preflight accepted an unenumerated Ubuntu release"
fi
printf 'ID=ubuntu\nID=ubuntu\nVERSION_ID="%s"\n' "$PROFILE_VERSION" > "$TMP_ROOT/preflight-$PROFILE/etc/os-release"
if run_preflight "$PROFILE" "$TMP_ROOT/preflight-$PROFILE" >/dev/null 2>&1; then
    fail "$PROFILE preflight accepted malformed duplicate host identity"
fi
printf 'ID=ubuntu\nVERSION_ID="%s\n' "$PROFILE_VERSION" > "$TMP_ROOT/preflight-$PROFILE/etc/os-release"
if run_preflight "$PROFILE" "$TMP_ROOT/preflight-$PROFILE" >/dev/null 2>&1; then
    fail "$PROFILE preflight accepted an unmatched identity quote"
fi
prepare_preflight_root "$TMP_ROOT/preflight-$PROFILE" "$PROFILE_VERSION"
for candidate in ubuntu_24_04_x86_64_node ubuntu_26_04_x86_64_node; do
    case "$candidate" in
        ubuntu_24_04_x86_64_node)
            fixture_version=24.04
            old_kernel=6.7.0-1-generic
            guardian_package=coreutils
            poison=ORCHARD_TEST_POISON_UNPREFIXED=1
            ;;
        ubuntu_26_04_x86_64_node)
            fixture_version=26.04
            old_kernel=6.8.0-1-generic
            guardian_package=gnu-coreutils
            poison=ORCHARD_TEST_POISON_GNU_TIMEOUT=1
            ;;
    esac
    candidate_root="$TMP_ROOT/preflight-$candidate"
    prepare_preflight_root "$candidate_root" "$fixture_version"
    if run_preflight "$candidate" "$candidate_root" ORCHARD_TEST_KERNEL_RELEASE="$old_kernel" >/dev/null 2>&1; then
        fail "$candidate preflight accepted an out-of-profile kernel"
    fi
    if run_preflight "$candidate" "$candidate_root" "$poison" >/dev/null 2>&1; then
        fail "$candidate preflight inferred GNU semantics from a command name"
    fi
    if run_preflight "$candidate" "$candidate_root" ORCHARD_TEST_MISSING_PACKAGE="$guardian_package" >/dev/null 2>&1; then
        fail "$candidate preflight accepted an incomplete dependency closure"
    fi
done

for rejected_kernel in 7.0.0-1010-aws 7.0.0-custom 6.8.0-1-generic; do
    if run_preflight ubuntu_26_04_x86_64_node "$TMP_ROOT/preflight-ubuntu_26_04_x86_64_node" ORCHARD_TEST_KERNEL_RELEASE="$rejected_kernel" >/dev/null 2>&1; then
        fail "26.04 preflight accepted unqualified kernel $rejected_kernel"
    fi
done
run_preflight ubuntu_26_04_x86_64_node "$TMP_ROOT/preflight-ubuntu_26_04_x86_64_node" ORCHARD_TEST_POISON_UNPREFIXED=1 >/dev/null || fail "26.04 preflight fell back to poisoned unprefixed commands"
rm "$PREFLIGHT_TOOLS/gnutimeout"
if env PATH="$PREFLIGHT_TOOLS" ORCHARD_TEST_PREFLIGHT_PROFILE=ubuntu_26_04_x86_64_node "$PROFILES_ROOT/ubuntu_26_04_x86_64_node/preflight" "$TMP_ROOT/preflight-ubuntu_26_04_x86_64_node" >/dev/null 2>&1; then
    fail "26.04 preflight accepted a missing GNU-prefixed command"
fi
ln -s coreutils-fixture "$PREFLIGHT_TOOLS/gnutimeout"

for malformed_version in '26x04' '26"04'; do
    printf 'ID=ubuntu\nVERSION_ID="%s"\n' "$malformed_version" > "$TMP_ROOT/preflight-ubuntu_26_04_x86_64_node/etc/os-release"
    if run_preflight ubuntu_26_04_x86_64_node "$TMP_ROOT/preflight-ubuntu_26_04_x86_64_node" >/dev/null 2>&1; then
        fail "26.04 preflight accepted malformed release identity $malformed_version"
    fi
done
prepare_preflight_root "$TMP_ROOT/preflight-ubuntu_26_04_x86_64_node" 26.04

set +e
"$REPO_ROOT/scripts/build-linux-node-package.sh" "$TMP_ROOT/unsupported" ubuntu_latest_x86_64_node > "$TMP_ROOT/unsupported.out" 2>&1
status=$?
set -e
[[ "$status" -eq 64 ]] || fail "builder did not reject an unsupported profile before mutation"
grep -F 'unsupported platform profile' "$TMP_ROOT/unsupported.out" >/dev/null || fail "unsupported profile failure was not explained"

set +e
PATH="$TOOLS:$PATH" "$REPO_ROOT/scripts/build-linux-node-package.sh" "$TMP_ROOT/cross-profile" "$REJECTED_HOST_PROFILE" > "$TMP_ROOT/cross-profile.out" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "builder accepted a profile that did not match its build host"
grep -F 'requires exact VERSION_ID=' "$TMP_ROOT/cross-profile.out" >/dev/null || fail "cross-profile build failure was not explained"

PATH="$TOOLS:$PATH" SOURCE_DATE_EPOCH=0 "$REPO_ROOT/scripts/build-linux-node-package.sh" "$OUT" "$PROFILE" > "$TMP_ROOT/build.out"
DEB=$(tail -n 1 "$TMP_ROOT/build.out")
[[ -f "$DEB" ]] || fail "builder did not emit a Debian package"
sha256sum --check "$DEB.sha256" >/dev/null
FIRST_SHA=$(sha256sum "$DEB" | cut -d ' ' -f 1)
rm -rf "$OUT"
PATH="$TOOLS:$PATH" SOURCE_DATE_EPOCH=0 "$REPO_ROOT/scripts/build-linux-node-package.sh" "$OUT" "$PROFILE" > "$TMP_ROOT/rebuild.out"
DEB=$(tail -n 1 "$TMP_ROOT/rebuild.out")
[[ "$(sha256sum "$DEB" | cut -d ' ' -f 1)" = "$FIRST_SHA" ]] || fail "package build is not reproducible"

dpkg-deb --info "$DEB" > "$TMP_ROOT/info"
grep -F 'Architecture: amd64' "$TMP_ROOT/info" >/dev/null || fail "package architecture is not amd64"
grep -F "X-Orchard-Platform-Profile: $PROFILE" "$TMP_ROOT/info" >/dev/null || fail "package profile identity is missing"
grep -F "$COREUTILS_DEPENDENCY" "$TMP_ROOT/info" >/dev/null || fail "inventory command guardian is missing"

ROOT="$TMP_ROOT/root"
dpkg-deb --extract "$DEB" "$ROOT"
dpkg-deb --control "$DEB" "$TMP_ROOT/control"
[[ -x "$ROOT/opt/orchard/node/releases/orchard_node_agent/bin/orchard_node_agent" ]] || fail "Node release is missing"
[[ -e "$ROOT/opt/orchard/node/releases/orchard_node_agent/erts-16.4/bin/beam.smp" ]] || fail "bundled ERTS is missing"
[[ "$(stat -c %a "$ROOT/opt/orchard/node/releases/orchard_node_agent/lib")" = "755" ]] || fail "release directories are not traversable by orchard-node"
[[ "$(stat -c %a "$ROOT/opt/orchard/node/releases/orchard_node_agent/lib/orchard_node_agent-0.1.0/ebin")" = "755" ]] || fail "release application directories are not traversable by orchard-node"
[[ ! -e "$ROOT/opt/orchard/node/releases/orchard_controller" ]] || fail "Controller leaked into Node package"
[[ ! -e "$ROOT/opt/orchard/node/native" ]] || fail "provider payload leaked into Node package"
jq -e --arg profile "$PROFILE" '.profile == $profile and (.excluded | index("CUDA"))' "$ROOT/opt/orchard/node/share/dependencies.json" >/dev/null
[[ "$(cat "$ROOT/opt/orchard/node/share/platform-profile")" = "$PROFILE" ]] || fail "runtime profile marker is invalid"

ORCHARD_PACKAGE_ROOT="$ROOT" ORCHARD_SYSTEMD_SIMULATE=1 "$TMP_ROOT/control/postinst" configure
[[ "$(stat -c %a "$ROOT/var/lib/orchard/node/identity")" = "700" ]] || fail "identity root mode is not 0700"
[[ "$(stat -c %u "$ROOT/var/lib/orchard/node")" = "$(id -u)" ]] || fail "structural state root has the wrong owner"
[[ "$(stat -c %u "$ROOT/var/lib/orchard/node/identity")" = "$(id -u)" ]] || fail "identity leaf has the wrong service owner"
grep -Fx 'daemon-reload' "$ROOT/run/orchard-node/systemd-simulation.log" >/dev/null || fail "install did not simulate daemon reload"

SENTINEL="$TMP_ROOT/outside-sentinel"
mkdir "$SENTINEL"
chmod 711 "$SENTINEL"
rmdir "$ROOT/var/lib/orchard/node/models"
ln -s "$SENTINEL" "$ROOT/var/lib/orchard/node/models"
if ORCHARD_PACKAGE_ROOT="$ROOT" ORCHARD_SYSTEMD_SIMULATE=1 "$TMP_ROOT/control/postinst" configure >/dev/null 2>&1; then
    fail "postinst followed a service-controlled directory symlink"
fi
[[ "$(stat -c %a "$SENTINEL")" = "711" ]] || fail "postinst mutated a symlink target"
rm "$ROOT/var/lib/orchard/node/models"
ORCHARD_PACKAGE_ROOT="$ROOT" ORCHARD_SYSTEMD_SIMULATE=1 "$TMP_ROOT/control/postinst" configure

mkdir -p "$ROOT/etc/orchard/node" "$ROOT/var/lib/orchard/node/identity" "$ROOT/var/log/orchard/node" "$ROOT/run/orchard-node"
printf '%s\n' 'ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam' > "$ROOT/etc/orchard/node/node-agent.env"
chmod 640 "$ROOT/etc/orchard/node/node-agent.env"
chmod 700 "$ROOT/var/lib/orchard/node/identity"

WRAPPER="$ROOT/opt/orchard/node/bin/orchard-node-agent"
ORCHARD_LINUX_RELOCATED_TEST=1 ORCHARD_LINUX_ROOT="$ROOT" ORCHARD_TEST_SLEEP=20 RELEASE_DISTRIBUTION=name RELEASE_NODE=unsafe@127.0.0.1 RELEASE_COOKIE=unsafe ERL_EPMD_PORT=4369 ERL_FLAGS='-sname unsafe' RELEASE_VM_ARGS=unsafe "$WRAPPER" start > "$TMP_ROOT/first.out" 2>&1 &
FIRST_PID=$!
for _ in {1..50}; do
    grep -q '^started:' "$TMP_ROOT/first.out" && break
    sleep 0.05
done
grep -F "started:$ROOT/var/lib/orchard/node:$ROOT/var/lib/orchard/node/identity:$ROOT/var/lib/orchard/node/models" "$TMP_ROOT/first.out" >/dev/null || fail "wrapper did not set fixed relocated paths"
grep -Fx 'distribution:none:unset:unset:unset' "$TMP_ROOT/first.out" >/dev/null || fail "wrapper did not disable unqualified BEAM Distribution"
grep -Fx "coreutils-prefix:$COREUTILS_PREFIX" "$TMP_ROOT/first.out" >/dev/null || fail "wrapper did not select the profile command provenance"

set +e
ORCHARD_LINUX_RELOCATED_TEST=1 ORCHARD_LINUX_ROOT="$ROOT" "$WRAPPER" start > "$TMP_ROOT/second.out" 2>&1
status=$?
set -e
[[ "$status" -eq 75 ]] || fail "duplicate identity-root owner exited $status instead of 75"
grep -F 'identity root is already owned' "$TMP_ROOT/second.out" >/dev/null || fail "duplicate ownership was not explained"

kill "$FIRST_PID"
wait "$FIRST_PID" >/dev/null 2>&1 || true
FIRST_PID=""
ORCHARD_LINUX_RELOCATED_TEST=1 ORCHARD_LINUX_ROOT="$ROOT" "$WRAPPER" start > "$TMP_ROOT/restart.out"
grep -q '^started:' "$TMP_ROOT/restart.out" || fail "stale lock file blocked restart"

set +e
PATH="$TOOLS:$PATH" ORCHARD_TEST_FAKE_CONTAMINATED=1 "$REPO_ROOT/scripts/build-linux-node-package.sh" "$TMP_ROOT/contaminated" "$PROFILE" > "$TMP_ROOT/contaminated.out" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "builder accepted Controller code in the Node release"
grep -F 'forbidden Node package payload' "$TMP_ROOT/contaminated.out" >/dev/null || fail "forbidden payload failure was not explained"

for mode in ORCHARD_TEST_READELF_FAIL ORCHARD_TEST_READELF_UNDECLARED; do
    set +e
    PATH="$TOOLS:$PATH" env "$mode=1" "$REPO_ROOT/scripts/build-linux-node-package.sh" "$TMP_ROOT/readelf-rejected" "$PROFILE" > "$TMP_ROOT/readelf-rejected.out" 2>&1
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "builder accepted an unverified ELF dependency closure"
done

printf 'ID=ubuntu\nVERSION_ID="%s"\n' "$PROFILE_VERSION" > "$ROOT/etc/os-release"
prepare_preflight_root "$ROOT" "$PROFILE_VERSION"
env PATH="$PREFLIGHT_TOOLS:$PATH" ORCHARD_TEST_PREFLIGHT_PROFILE="$PROFILE" "$ROOT/opt/orchard/node/bin/preflight" "$ROOT" >/dev/null
printf 'ID=debian\nVERSION_ID="12"\n' > "$ROOT/etc/os-release"
if env PATH="$PREFLIGHT_TOOLS:$PATH" ORCHARD_TEST_PREFLIGHT_PROFILE="$PROFILE" "$ROOT/opt/orchard/node/bin/preflight" "$ROOT" >/dev/null 2>&1; then
    fail "preflight accepted an unsupported distribution"
fi

printf 'identity\n' > "$ROOT/var/lib/orchard/node/identity/node-id"
printf 'config\n' > "$ROOT/etc/orchard/node/retained.conf"
printf 'log\n' > "$ROOT/var/log/orchard/node/retained.log"
ORCHARD_PACKAGE_ROOT="$ROOT" ORCHARD_SYSTEMD_SIMULATE=1 "$TMP_ROOT/control/prerm" remove
ORCHARD_PACKAGE_ROOT="$ROOT" ORCHARD_SYSTEMD_SIMULATE=1 "$TMP_ROOT/control/postrm" remove
[[ -f "$ROOT/var/lib/orchard/node/identity/node-id" ]] || fail "default removal erased identity"
[[ -f "$ROOT/etc/orchard/node/retained.conf" ]] || fail "default removal erased configuration"
[[ -f "$ROOT/var/log/orchard/node/retained.log" ]] || fail "default removal erased logs"
[[ ! -e "$ROOT/run/orchard-node" ]] || fail "default removal retained runtime-only files"

if ! systemd-analyze verify --root="$ROOT" orchard-node-agent.service > /dev/null 2> "$TMP_ROOT/systemd-verify.err"; then
    sed '/Unit sysinit.target not found/d' "$TMP_ROOT/systemd-verify.err" > "$TMP_ROOT/systemd-verify.unexpected"
    [[ ! -s "$TMP_ROOT/systemd-verify.unexpected" ]] || {
        cat "$TMP_ROOT/systemd-verify.unexpected" >&2
        fail "systemd unit verification failed"
    }
fi
UNIT="$ROOT/usr/lib/systemd/system/orchard-node-agent.service"
grep -F 'KillMode=control-group' "$UNIT" >/dev/null || fail "unit does not retain process-group custody"
grep -F 'ConditionPathExists=/etc/orchard/node/node-agent.env' "$UNIT" >/dev/null || fail "unit is not default-off before configuration"

printf 'test-linux-node-package: PASS\n'
