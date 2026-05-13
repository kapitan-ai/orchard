#!/bin/bash
# Focused regression tests for Orchard PKG payload signing and verification contracts.
# These tests use fake Apple tooling and do not contact Apple signing or notarization services.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

IDENTITY='Developer ID Application: Example, Inc. (TEAMID)'
WRONG_IDENTITY='Developer ID Application: Wrong, Inc. (TEAMID)'
INSTALLER_IDENTITY='Developer ID Installer: Example, Inc. (TEAMID)'

assert_grep() {
    local pattern="$1"
    local file="$2"
    grep -F "$pattern" "$file" >/dev/null
}

assert_no_grep() {
    local pattern="$1"
    local file="$2"
    if grep -F "$pattern" "$file" >/dev/null; then
        echo "unexpected match for $pattern" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_fails_with() {
    local pattern="$1"
    local out="$2"
    shift 2
    if "$@" >"$out" 2>&1; then
        echo "expected command to fail with: $pattern" >&2
        cat "$out" >&2
        exit 1
    fi
    assert_grep "$pattern" "$out"
}

make_fake_tools() {
    local tools="$1"
    mkdir -p "$tools"

    cat > "$tools/file" <<'SH'
#!/bin/sh
case "$*" in
  *pyvenv.cfg*|*.txt) echo text/plain ;;
  *) echo application/x-mach-binary ;;
esac
SH

    cat > "$tools/xcrun" <<'SH'
#!/bin/sh
if [ "$1" = "-f" ] && [ "$2" = "codesign" ]; then
  command -v codesign
  exit 0
fi
echo "unexpected xcrun invocation: $*" >&2
exit 1
SH

    cat > "$tools/otool" <<'SH'
#!/bin/sh
case "${OTOOL_CASE:-ok}" in
  outbound_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /opt/outside/libbad.dylib (offset 24)
OUT
    ;;
  install_prefix_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /Library/Application Support/Orchard/native/foo/.venv/lib/native.so (offset 24)
OUT
    ;;
  *)
    cat <<'OUT'
OUT
    ;;
esac
SH

    cat > "$tools/codesign" <<'SH'
#!/bin/sh
set -eu
last=""
for arg in "$@"; do
  last="$arg"
done

if [ "${1:-}" = "--verify" ]; then
  case "$last" in
    *unsigned*) echo "code object is not signed at all" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi

if [ "${1:-}" = "--display" ]; then
  case "$last" in
    *adhoc*)
      echo "Signature=adhoc" >&2
      echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
      echo "Timestamp=May 12, 2026" >&2
      echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
      ;;
    *no-runtime*)
      echo "Signature size=9000" >&2
      echo "CodeDirectory v=20500 size=475 flags=0x0(none) hashes=10+7 location=embedded" >&2
      echo "Executable Segment flags=0x1" >&2
      echo "Timestamp=May 12, 2026" >&2
      echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
      ;;
    *runtime-with-executable-segment*)
      echo "Signature size=9000" >&2
      echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
      echo "Executable Segment flags=0x1" >&2
      echo "Timestamp=May 12, 2026" >&2
      echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
      ;;
    *no-timestamp*)
      echo "Signature size=9000" >&2
      echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
      echo "Timestamp=none" >&2
      echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
      ;;
    *wrong-identity*)
      echo "Signature size=9000" >&2
      echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
      echo "Timestamp=May 12, 2026" >&2
      echo "Authority=Developer ID Application: Wrong, Inc. (TEAMID)" >&2
      ;;
    *intermediate-match*)
      echo "Signature size=9000" >&2
      echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
      echo "Timestamp=May 12, 2026" >&2
      echo "Authority=Developer ID Application: Wrong, Inc. (TEAMID)" >&2
      echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
      ;;
    *)
      echo "Signature size=9000" >&2
      echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
      echo "Timestamp=May 12, 2026" >&2
      echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
      ;;
  esac
  exit 0
fi

entitlements=""
identity=""
timestamp=no
runtime=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    --entitlements) entitlements="$2"; shift 2 ;;
    --sign) identity="$2"; shift 2 ;;
    --timestamp) timestamp=yes; shift ;;
    --options)
      if [ "${2:-}" = "runtime" ]; then runtime=yes; fi
      shift 2
      ;;
    *) shift ;;
  esac
done
printf '%s\t%s\t%s\t%s\n' "$last" "$entitlements" "$identity" "$timestamp/$runtime" >> "${CODESIGN_LOG:?}"
exit 0
SH

    chmod +x "$tools/file" "$tools/xcrun" "$tools/otool" "$tools/codesign"
}

make_root() {
    local root="$1"
    mkdir -p "$root/Library/Application Support/Orchard/share/bin"
}

make_valid_venv() {
    local root="$1"
    local venv="$root/Library/Application Support/Orchard/native/foo/.venv"
    mkdir -p "$venv/bin" "$venv/lib"
    cat > "$venv/bin/python" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "$venv/bin/python"
    printf 'include-system-site-packages = false\nversion = 3.13.5\n' > "$venv/pyvenv.cfg"
    echo "$venv"
}

run_with_fakes() {
    local tools="$1"
    shift
    PATH="$tools:/usr/bin:/bin" "$@"
}

write_build_pkg_fakes() {
    local tools="$1"
    mkdir -p "$tools"

    cat > "$tools/git" <<'SH'
#!/bin/sh
case "$1" in
  rev-parse) echo abcdef0 ;;
  diff-index) exit 0 ;;
  *) echo "unexpected git invocation: $*" >&2; exit 1 ;;
esac
SH

    cat > "$tools/uv" <<'SH'
#!/bin/sh
exit 0
SH

    cat > "$tools/cp" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = "-R" ]; then
  src="$2"
  dest="$3"
  base="$(basename "$src")"
  case "$src" in
    */native/orchard_tokenizer|*/native/orchard_worker_mlx)
      target="$dest/$base"
      mkdir -p "$target/bin" "$target/.venv/bin" "$target/.venv/lib"
      if [ "${ORCHARD_FAKE_METADATA_SIDECAR:-}" = "1" ]; then
        : > "$target/._$base"
      fi
      case "$base" in
        orchard_tokenizer) bin_name=orchard-tokenizer ;;
        orchard_worker_mlx) bin_name=orchard-worker-mlx ;;
        *) bin_name=orchard-native ;;
      esac
      cat > "$target/bin/$bin_name" <<'BIN'
#!/bin/sh
exit 0
BIN
      chmod +x "$target/bin/$bin_name"
      cat > "$target/.venv/bin/python" <<'PY'
#!/bin/sh
exit 0
PY
      chmod +x "$target/.venv/bin/python"
      printf 'include-system-site-packages = false\nversion = 3.13.5\n' > "$target/.venv/pyvenv.cfg"
      exit 0
      ;;
  esac
fi
/bin/cp "$@"
SH

    cat > "$tools/mix" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = "run" ]; then
  echo 9.9.9-test
  exit 0
fi
if [ "${1:-}" = "deps.get" ]; then
  exit 0
fi
if [ "${1:-}" = "assets.deploy" ]; then
  exit 0
fi
if [ "${1:-}" = "release" ]; then
  release="$2"
  root="$(pwd)"
  mkdir -p "$root/_build/prod/rel/$release/bin" "$root/_build/prod/rel/$release/erts-16.4/bin"
  cat > "$root/_build/prod/rel/$release/bin/$release" <<'BIN'
#!/bin/sh
exit 0
BIN
  chmod +x "$root/_build/prod/rel/$release/bin/$release"
  : > "$root/_build/prod/rel/$release/erts-16.4/bin/beam.smp"
  exit 0
fi
echo "unexpected mix invocation: $*" >&2
exit 1
SH

    cat > "$tools/file" <<'SH'
#!/bin/sh
case "$*" in
  *pyvenv.cfg*) echo text/plain ;;
  *) echo application/x-mach-binary ;;
esac
SH

    cat > "$tools/otool" <<'SH'
#!/bin/sh
cat <<'OUT'
OUT
SH

    cat > "$tools/xcrun" <<'SH'
#!/bin/sh
if [ "$1" = "-f" ] && [ "$2" = "codesign" ]; then
  command -v codesign
  exit 0
fi
echo "unexpected xcrun invocation: $*" >&2
exit 1
SH

    cat > "$tools/codesign" <<'SH'
#!/bin/sh
set -eu
if [ "${CODESIGN_FAIL:-}" = "1" ]; then
  echo "codesign fail" >&2
  exit 91
fi
last=""
entitlements=""
identity=""
timestamp=no
runtime=no
for arg in "$@"; do
  last="$arg"
done
while [ "$#" -gt 0 ]; do
  case "$1" in
    --entitlements) entitlements="$2"; shift 2 ;;
    --sign) identity="$2"; shift 2 ;;
    --timestamp) timestamp=yes; shift ;;
    --options)
      if [ "${2:-}" = "runtime" ]; then runtime=yes; fi
      shift 2
      ;;
    *) shift ;;
  esac
done
printf '%s\t%s\t%s\t%s\n' "$last" "$entitlements" "$identity" "$timestamp/$runtime" >> "${CODESIGN_LOG:?}"
SH

    cat > "$tools/pkgbuild" <<'SH'
#!/bin/sh
echo "pkgbuild invoked" >&2
if [ "${ORCHARD_FAKE_PKGBUILD_SUCCESS:-}" = "1" ]; then
  last=""
  for arg in "$@"; do
    last="$arg"
  done
  : > "$last"
  exit 0
fi
exit 88
SH

    cat > "$tools/pkgutil" <<'SH'
#!/bin/sh
if [ "${1:-}" = "--payload-files" ]; then
  if [ "${ORCHARD_FAKE_PKGUTIL_SIDECARS:-}" = "1" ]; then
    cat <<'OUT'
./Library/Application Support/Orchard/share/bin/orchardctl
./Library/Application Support/Orchard/share/bin/orchard-controller
./Library/Application Support/Orchard/share/bin/orchard-node-agent
./Library/Application Support/Orchard/share/launchd/com.orchard.controller.plist
./Library/Application Support/Orchard/share/launchd/com.orchard.node-agent.plist
./Library/Application Support/Orchard/releases/orchard_cli/bin/orchard_cli
./Library/Application Support/Orchard/releases/orchard_controller/bin/orchard_controller
./Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent
./Library/Application Support/Orchard/.DS_Store
./Library/Application Support/Orchard/share/bin/._orchardctl
OUT
    exit 0
  fi
  cat <<'OUT'
./Library/Application Support/Orchard/share/bin/orchardctl
./Library/Application Support/Orchard/share/bin/orchard-controller
./Library/Application Support/Orchard/share/bin/orchard-node-agent
./Library/Application Support/Orchard/share/launchd/com.orchard.controller.plist
./Library/Application Support/Orchard/share/launchd/com.orchard.node-agent.plist
./Library/Application Support/Orchard/releases/orchard_cli/bin/orchard_cli
./Library/Application Support/Orchard/releases/orchard_controller/bin/orchard_controller
./Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent
OUT
  exit 0
fi
echo "unexpected pkgutil invocation: $*" >&2
exit 1
SH

    chmod +x "$tools/git" "$tools/uv" "$tools/cp" "$tools/mix" "$tools/file" "$tools/otool" "$tools/xcrun" "$tools/codesign" "$tools/pkgbuild" "$tools/pkgutil"
}

write_sign_pkg_fakes() {
    local tools="$1"
    local mode="$2"
    local log="$3"
    mkdir -p "$tools"

    cat > "$tools/productsign" <<SH
#!/bin/sh
echo "productsign invoked" >> "$log"
exit 0
SH

    cat > "$tools/pkgutil" <<SH
#!/bin/sh
set -eu
if [ "\$1" != "--expand-full" ]; then
  echo "unexpected pkgutil invocation: \$*" >&2
  exit 1
fi
mkdir -p "\$3/Library/Application Support/Orchard/share/bin"
case "$mode" in
  unsigned) : > "\$3/Library/Application Support/Orchard/share/bin/unsigned" ;;
  ok) : > "\$3/Library/Application Support/Orchard/share/bin/ok" ;;
  *) echo "unknown fake pkgutil mode: $mode" >&2; exit 1 ;;
esac
SH

    cat > "$tools/file" <<'SH'
#!/bin/sh
case "$*" in
  *.pkg) echo application/octet-stream ;;
  *) echo application/x-mach-binary ;;
esac
SH

    cat > "$tools/otool" <<'SH'
#!/bin/sh
cat <<'OUT'
OUT
SH

    cat > "$tools/codesign" <<'SH'
#!/bin/sh
set -eu
last=""
for arg in "$@"; do
  last="$arg"
done
if [ "${1:-}" = "--verify" ]; then
  case "$last" in
    *unsigned*) echo "code object is not signed at all" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi
if [ "${1:-}" = "--display" ]; then
  echo "Signature size=9000" >&2
  echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
  echo "Timestamp=May 12, 2026" >&2
  echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
  exit 0
fi
exit 0
SH

    cat > "$tools/xcrun" <<'SH'
#!/bin/sh
if [ "$1" = "-f" ]; then
  case "$2" in
    codesign|notarytool|stapler) command -v "$2" ; exit 0 ;;
  esac
fi
if [ "$1" = "notarytool" ]; then
  printf '{"id":"fake-submission","status":"Accepted"}\n'
  exit 0
fi
if [ "$1" = "stapler" ]; then
  exit 0
fi
echo "unexpected xcrun invocation: $*" >&2
exit 1
SH

    cat > "$tools/notarytool" <<'SH'
#!/bin/sh
exit 0
SH

    cat > "$tools/stapler" <<'SH'
#!/bin/sh
exit 0
SH

    chmod +x "$tools/productsign" "$tools/pkgutil" "$tools/file" "$tools/otool" "$tools/codesign" "$tools/xcrun" "$tools/notarytool" "$tools/stapler"
}

# RED/GREEN: sign-payload refuses implicit or wrong identities.
case_dir="$TMP_ROOT/identity"
tools="$case_dir/tools"
root="$case_dir/root"
mkdir -p "$case_dir"
make_fake_tools "$tools"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'ORCHARD_PAYLOAD_SIGNING_IDENTITY is required' "$case_dir/missing.out" env -i PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/sign-payload.sh" "$root"
assert_fails_with 'Developer ID Application identity' "$case_dir/installer.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$INSTALLER_IDENTITY" "$REPO_ROOT/scripts/sign-payload.sh" "$root"
assert_fails_with 'Developer ID Application identity' "$case_dir/non-app.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY='Apple Development: Example, Inc. (TEAMID)' "$REPO_ROOT/scripts/sign-payload.sh" "$root"

# RED/GREEN: sign-payload discovers Mach-O files, signs libraries before executables, and chooses per-class entitlements.
case_dir="$TMP_ROOT/sign"
tools="$case_dir/tools"
root="$case_dir/root"
mkdir -p "$case_dir"
make_fake_tools "$tools"
make_root "$root"
mkdir -p \
    "$root/Library/Application Support/Orchard/releases/orchard_cli/erts-16.4/bin" \
    "$root/Library/Application Support/Orchard/native/foo/.venv/bin" \
    "$root/Library/Application Support/Orchard/native/foo/.venv/lib"
: > "$root/Library/Application Support/Orchard/releases/orchard_cli/erts-16.4/bin/beam.smp"
: > "$root/Library/Application Support/Orchard/native/foo/.venv/bin/python"
: > "$root/Library/Application Support/Orchard/native/foo/.venv/bin/ruff"
: > "$root/Library/Application Support/Orchard/native/foo/.venv/lib/libnative.so"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
chmod +x "$root/Library/Application Support/Orchard/native/foo/.venv/bin/ruff"
CODESIGN_LOG="$case_dir/codesign.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/sign-payload.sh" "$root" >"$case_dir/sign.out" 2>&1
assert_grep $'libnative.so	' "$case_dir/codesign.log"
first_signed="$(head -1 "$case_dir/codesign.log")"
case "$first_signed" in
  *libnative.so*) ;;
  *) echo "expected library to be signed before executables" >&2; cat "$case_dir/codesign.log" >&2; exit 1 ;;
esac
assert_grep $'beam.smp	' "$case_dir/codesign.log"
assert_grep 'beam.entitlements' "$case_dir/codesign.log"
assert_grep $'.venv/bin/python	' "$case_dir/codesign.log"
assert_grep 'python.entitlements' "$case_dir/codesign.log"
assert_grep $'share/bin/orchardctl	' "$case_dir/codesign.log"
assert_grep 'default.entitlements' "$case_dir/codesign.log"
assert_grep $'	yes/yes' "$case_dir/codesign.log"
assert_fails_with 'manifest output must be outside the staging root' "$case_dir/manifest.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-payload.sh" --manifest-output "$root/manifest.txt" "$root"

# RED/GREEN: verifier rejects signature failure classes and accepts valid signatures.
case_dir="$TMP_ROOT/verify-signatures"
tools="$case_dir/tools"
mkdir -p "$case_dir"
make_fake_tools "$tools"
for name in unsigned no-runtime no-timestamp wrong-identity intermediate-match adhoc; do
    root="$case_dir/$name/root"
    make_root "$root"
    : > "$root/Library/Application Support/Orchard/share/bin/$name"
    case "$name" in
      unsigned) detail='unsigned' ;;
      no-runtime) detail='missing hardened runtime' ;;
      no-timestamp) detail='missing secure timestamp' ;;
      wrong-identity|intermediate-match) detail='wrong identity' ;;
      adhoc) detail='unsigned' ;;
    esac
    assert_fails_with "$detail" "$case_dir/$name.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"
done
root="$case_dir/ok/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/ok"
run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/ok.out" 2>&1
assert_grep $'ok	ok' "$case_dir/ok.out"
assert_no_grep $'	fail	' "$case_dir/ok.out"
root="$case_dir/runtime-with-executable-segment/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/runtime-with-executable-segment"
run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/runtime-with-executable-segment.out" 2>&1
assert_grep $'runtime-with-executable-segment	ok	ok' "$case_dir/runtime-with-executable-segment.out"
assert_no_grep $'	fail	' "$case_dir/runtime-with-executable-segment.out"
assert_fails_with 'Developer ID Application identity' "$case_dir/verify-installer.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$INSTALLER_IDENTITY" "$root"
assert_fails_with 'Developer ID Application identity' "$case_dir/verify-non-app.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity 'Apple Development: Example, Inc. (TEAMID)' "$root"
empty_root="$case_dir/empty/root"
mkdir -p "$empty_root"
assert_fails_with 'no Mach-O files found' "$case_dir/empty.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$empty_root"

# RED/GREEN: payload verification does not execute staged package interpreters.
case_dir="$TMP_ROOT/verify-no-smoke"
tools="$case_dir/tools"
root="$case_dir/root"
mkdir -p "$case_dir"
make_fake_tools "$tools"
make_root "$root"
venv="$(make_valid_venv "$root")"
cat > "$venv/bin/python" <<'SH'
#!/bin/sh
exit 42
SH
chmod +x "$venv/bin/python"
run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/out" 2>&1
assert_grep $'.venv/bin/python	ok	ok' "$case_dir/out"

# RED/GREEN: verifier enforces staged venv closure failures before signing metadata can pass.
case_dir="$TMP_ROOT/verify-venv"
tools="$case_dir/tools"
mkdir -p "$case_dir"
make_fake_tools "$tools"

root="$case_dir/payload-layout/root"
make_root "$root/Payload"
venv="$(make_valid_venv "$root/Payload")"
: > "$venv/lib/native.so"
OTOOL_CASE=install_prefix_dep run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/payload-layout.out" 2>&1
assert_grep $'native.so	ok	ok' "$case_dir/payload-layout.out"

root="$case_dir/outbound/root"
make_root "$root"
venv="$(make_valid_venv "$root")"
mkdir -p "$case_dir/outside"
: > "$case_dir/outside/python"
ln -s "$case_dir/outside/python" "$venv/bin/outbound"
assert_fails_with 'outbound symlink' "$case_dir/outbound.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/dangling/root"
make_root "$root"
venv="$(make_valid_venv "$root")"
ln -s missing-target "$venv/bin/dangling"
assert_fails_with 'dangling symlink' "$case_dir/dangling.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/symlink-python/root"
make_root "$root"
venv="$(make_valid_venv "$root")"
rm "$venv/bin/python"
ln -s /opt/outside/python "$venv/bin/python"
assert_fails_with 'interpreter is symlink' "$case_dir/symlink-python.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/pyvenv/root"
make_root "$root"
venv="$(make_valid_venv "$root")"
printf 'home = /Users/buildhost/.local/share/uv/python\n' > "$venv/pyvenv.cfg"
assert_fails_with 'pyvenv.cfg has build-host path fragment' "$case_dir/pyvenv.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/otool/root"
make_root "$root"
venv="$(make_valid_venv "$root")"
: > "$venv/lib/native.so"
assert_fails_with 'outbound Mach-O dependency' "$case_dir/otool.out" env OTOOL_CASE=outbound_dep PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

# RED/GREEN: build-pkg stage-only preserves staging, prints one machine-readable path, and skips pkgbuild.
case_dir="$TMP_ROOT/build-stage-only"
tools="$case_dir/tools"
out_dir="$case_dir/out"
staging="$case_dir/staging"
mkdir -p "$case_dir"
write_build_pkg_fakes "$tools"
ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/build.out" 2>&1
stage_line_count="$(grep -c '^STAGING_BASE=' "$case_dir/build.out")"
test "$stage_line_count" -eq 1
assert_grep "STAGING_BASE=$staging" "$case_dir/build.out"
test -d "$staging/Library/Application Support/Orchard"
if find "$out_dir" -name '*.pkg' -print -quit | grep -q .; then
    echo "stage-only must not create PKG artifacts" >&2
    find "$out_dir" -name '*.pkg' >&2
    exit 1
fi
assert_fails_with 'Selected staging path already exists' "$case_dir/existing.out" env ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir"

preexisting="$case_dir/preexisting"
mkdir -p "$preexisting"
printf 'keep me\n' > "$preexisting/sentinel"
assert_fails_with 'Selected staging path already exists' "$case_dir/preexisting.out" env ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$preexisting" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
test -f "$preexisting/sentinel"

staging_sidecar="$case_dir/staging-sidecar"
ORCHARD_FAKE_METADATA_SIDECAR=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_sidecar" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/sidecar.out" 2>&1
assert_grep 'Removing macOS metadata sidecar files from staging payload' "$case_dir/sidecar.out"
assert_grep '._orchard_tokenizer' "$case_dir/sidecar.out"
if find "$staging_sidecar" \( -name '._*' -o -name '.DS_Store' \) -print -quit | grep -q .; then
    echo "staging metadata sidecars should be removed before validation" >&2
    find "$staging_sidecar" \( -name '._*' -o -name '.DS_Store' \) >&2
    exit 1
fi

staging_signed="$case_dir/staging-signed"
CODESIGN_LOG="$case_dir/codesign.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_signed" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/build-signed.out" 2>&1
assert_grep "STAGING_BASE=$staging_signed" "$case_dir/build-signed.out"
assert_grep "$staging_signed" "$case_dir/codesign.log"
assert_grep "$IDENTITY" "$case_dir/codesign.log"

staging_fail="$case_dir/staging-fail"
assert_fails_with 'codesign fail' "$case_dir/sign-fail.out" env CODESIGN_FAIL=1 CODESIGN_LOG="$case_dir/codesign-fail.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_fail" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_no_grep 'pkgbuild invoked' "$case_dir/sign-fail.out"

staging_pkgbuild_fail="$case_dir/staging-pkgbuild-fail"
assert_fails_with 'pkgbuild invoked' "$case_dir/pkgbuild-fail.out" env CODESIGN_LOG="$case_dir/codesign-pkgbuild-fail.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_pkgbuild_fail" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
if find "$out_dir" -name '.*.signing-manifest.tmp' -print -quit | grep -q .; then
    echo "temporary payload signing manifest should be removed on pkgbuild failure" >&2
    find "$out_dir" -name '.*.signing-manifest.tmp' >&2
    exit 1
fi

staging_pkg_sidecar="$case_dir/staging-pkg-sidecar"
assert_fails_with 'macOS metadata sidecar files detected in PKG payload' "$case_dir/pkg-sidecar.out" env ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_PKGUTIL_SIDECARS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_pkg_sidecar" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'Removed malformed PKG' "$case_dir/pkg-sidecar.out"
if find "$out_dir" -name '*.pkg' -print -quit | grep -q .; then
    echo "malformed PKG should be removed after payload sidecar validation failure" >&2
    find "$out_dir" -name '*.pkg' >&2
    exit 1
fi

# RED/GREEN: sign-pkg refuses missing, Installer, and unsigned payload identities before productsign.
case_dir="$TMP_ROOT/sign-pkg-audit"
tools="$case_dir/tools"
input_pkg="$case_dir/Orchard.pkg"
output_pkg="$case_dir/Orchard-signed.pkg"
productsign_log="$case_dir/productsign.log"
mkdir -p "$case_dir"
: > "$input_pkg"
write_sign_pkg_fakes "$tools" unsigned "$productsign_log"
assert_fails_with 'Developer ID Installer identity' "$case_dir/application-envelope.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_PAYLOAD_SIGNING_IDENTITY is required' "$case_dir/missing-payload-dry-run.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY= "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_PAYLOAD_SIGNING_IDENTITY is required' "$case_dir/missing-payload.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY= "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"
assert_fails_with 'Developer ID Application identity' "$case_dir/installer-payload.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$INSTALLER_IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"
assert_fails_with 'Refusing to envelope-sign a PKG with unsigned payload Mach-O binaries' "$case_dir/unsigned-payload.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"

printf 'ok\tpayload signing contracts\n'
