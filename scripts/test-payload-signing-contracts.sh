#!/bin/bash
# Focused regression tests for Orchard payload signing, verification, and Mach-O closure contracts.
# Covers scripts/sign-payload.sh, scripts/verify-payload-signing.sh, and
# scripts/remediate-otp-openssl-closure.sh, all invoked by scripts/build-payload.sh and scripts/sign-app.sh.
# These tests use fake Apple tooling and do not contact Apple signing or notarization services.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

IDENTITY='Developer ID Application: Example, Inc. (TEAMID)'
INSTALLER_IDENTITY='Developer ID Installer: Example, Inc. (TEAMID)'

unset ORCHARD_BUILD_KEYCHAIN ORCHARD_KEYCHAIN_PASSWORD ORCHARD_BUILD_KEYCHAIN_PREPARED ORCHARD_BUILD_KEYCHAIN_DRY_RUN

assert_grep() {
    local pattern="$1"
    local file="$2"
    grep -F -- "$pattern" "$file" >/dev/null
}

assert_no_grep() {
    local pattern="$1"
    local file="$2"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    if grep -F -- "$pattern" "$file" >/dev/null; then
        echo "unexpected match for $pattern" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_no_exact_line() {
    local pattern="$1"
    local file="$2"
    if grep -Fx "$pattern" "$file" >/dev/null; then
        echo "unexpected exact line: $pattern" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_file_empty() {
    local file="$1"
    if [[ -s "$file" ]]; then
        echo "expected empty file: $file" >&2
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
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'file\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
case "$*" in
  *pyvenv.cfg*|*.txt) echo text/plain ;;
  *universal-native.so)
    printf 'application/x-mach-binary\n'
    printf '%s (for architecture x86_64):\tapplication/x-mach-binary\n' "$*"
    printf '%s (for architecture arm64):\tapplication/x-mach-binary\n' "$*"
    ;;
  *) echo application/x-mach-binary ;;
esac
SH

    cat > "$tools/xcrun" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'xcrun\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ "$1" = "-f" ] && [ "$2" = "codesign" ]; then
  command -v codesign
  exit 0
fi
echo "unexpected xcrun invocation: $*" >&2
exit 1
SH

    cat > "$tools/security" <<'SH'
#!/bin/sh
if [ -n "${SECURITY_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$SECURITY_LOG"
fi
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  printf 'security %s\n' "${1:-}" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
fi
case "${1:-}" in
  unlock-keychain) exit "${SECURITY_UNLOCK_EXIT:-0}" ;;
  set-key-partition-list) exit "${SECURITY_PARTITION_EXIT:-0}" ;;
  *) echo "unexpected security invocation: $*" >&2; exit 99 ;;
esac
SH

    cat > "$tools/otool" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'otool\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -n "${OTOOL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$OTOOL_LOG"
fi
target=""
for arg in "$@"; do
  target="$arg"
done
case "$target" in
  *libcrypto*.dylib|*libssl*.dylib) exit 0 ;;
esac
case "${OTOOL_CASE:-ok}" in
  outbound_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /opt/outside/libbad.dylib (offset 24)
OUT
    ;;
  homebrew_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib (offset 24)
OUT
    ;;
  cellar_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /opt/homebrew/Cellar/openssl@3/3.3.0/lib/libssl.3.dylib (offset 24)
OUT
    ;;
  buildhost_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /Users/buildhost/orchard/tmp/libcrypto.3.dylib (offset 24)
OUT
    ;;
  buildhost_cellar_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /Users/buildhost/Cellar/openssl@3/3.3.0/lib/libcrypto.3.dylib (offset 24)
OUT
    ;;
  install_prefix_escape_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /Library/Application Support/Orchard/../Outside/libbad.dylib (offset 24)
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
  in_payload_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /Library/Application Support/Orchard/share/lib/libcrypto.3.dylib (offset 24)
OUT
    ;;
  rpath_payload)
    cat <<'OUT'
Load command 0
          cmd LC_RPATH
      cmdsize 48
         path @loader_path/../lib (offset 12)
Load command 1
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @rpath/libcrypto.3.dylib (offset 24)
OUT
    ;;
  executable_path_venv)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @executable_path/python (offset 24)
OUT
    ;;
  executable_path_nonvenv)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @executable_path/libhelper.dylib (offset 24)
OUT
    ;;
  loader_path_escape)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @loader_path/../../../outside/libbad.dylib (offset 24)
OUT
    ;;
  rpath_unresolved)
    cat <<'OUT'
Load command 0
          cmd LC_RPATH
      cmdsize 48
         path @loader_path/../missing (offset 12)
Load command 1
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @rpath/libmissing.dylib (offset 24)
OUT
    ;;
  rpath_libjaccl_unresolved)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @rpath/libjaccl.dylib (offset 24)
OUT
    ;;
  rpath_staging_absolute)
    cat <<OUT
Load command 0
          cmd LC_RPATH
      cmdsize 48
         path ${OTOOL_STAGING_RPATH:?} (offset 12)
Load command 1
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @rpath/libcrypto.3.dylib (offset 24)
OUT
    ;;
  universal_cross_slice_rpath)
    cat <<'OUT'
/unused (for architecture x86_64):
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @rpath/libcrypto.3.dylib (offset 24)
/unused (for architecture arm64):
Load command 0
          cmd LC_RPATH
      cmdsize 48
         path @loader_path/../lib (offset 12)
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
  if [ -n "${CODESIGN_LOG:-}" ]; then
    printf 'argv\t%s\n' "$*" >> "$CODESIGN_LOG"
  fi
  if [ "${CODESIGN_VERIFY_FAIL:-}" = "1" ]; then
    if [ "${CODESIGN_ECHO_ARGS_ON_FAIL:-}" = "1" ]; then
      echo "codesign verify failed with args: $*" >&2
    else
      echo "codesign verify fail" >&2
    fi
    exit 92
  fi
  case "$last" in
    *unsigned*) echo "code object is not signed at all" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi

if [ "${1:-}" = "--display" ]; then
  if [ -n "${CODESIGN_LOG:-}" ]; then
    printf 'argv\t%s\n' "$*" >> "$CODESIGN_LOG"
  fi
  if [ "${CODESIGN_DISPLAY_FAIL:-}" = "1" ]; then
    if [ "${CODESIGN_ECHO_ARGS_ON_FAIL:-}" = "1" ]; then
      echo "codesign display failed with args: $*" >&2
    else
      echo "codesign display fail" >&2
    fi
    exit 93
  fi
  for arg in "$@"; do
    if [ "$arg" = "--entitlements" ]; then
      if [ "${CODESIGN_FORBIDDEN_ENTITLEMENT:-}" = "1" ]; then
        echo '<key>com.apple.security.cs.disable-library-validation</key>'
      fi
      exit 0
    fi
  done
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
original_args="$*"
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
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  printf 'codesign sign %s\n' "$last" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
fi
if [ "${CODESIGN_FAIL:-}" = "1" ]; then
  if [ "${CODESIGN_ECHO_ARGS_ON_FAIL:-}" = "1" ]; then
    echo "codesign sign failed with args: $original_args" >&2
  else
    echo "codesign fail" >&2
  fi
  exit 91
fi
printf '%s\t%s\t%s\t%s\n' "$last" "$entitlements" "$identity" "$timestamp/$runtime" >> "${CODESIGN_LOG:?}"
printf 'argv\t%s\n' "$original_args" >> "${CODESIGN_LOG:?}"
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'codesign\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
exit 0
SH

    cat > "$tools/shasum" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'shasum\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
exec /usr/bin/shasum "$@"
SH

    chmod +x "$tools/file" "$tools/xcrun" "$tools/security" "$tools/otool" "$tools/codesign" "$tools/shasum"
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


# RED/GREEN: sign-payload refuses implicit or wrong identities.
case_dir="$TMP_ROOT/identity"
tools="$case_dir/tools"
root="$case_dir/root"
mkdir -p "$case_dir"
make_fake_tools "$tools"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'ORCHARD_PAYLOAD_SIGNING_IDENTITY is required' "$case_dir/missing.out" env -i PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/sign-payload.sh" "$root"
assert_fails_with 'Developer ID Application identity' "$case_dir/installer.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$INSTALLER_IDENTITY" "$REPO_ROOT/scripts/sign-payload.sh" "$root"
assert_fails_with 'Developer ID Application identity' "$case_dir/non-app.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY='Apple Development: Example, Inc. (TEAMID)' "$REPO_ROOT/scripts/sign-payload.sh" "$root"
forbidden_entitlements="$case_dir/forbidden-entitlements"
mkdir -p "$forbidden_entitlements"
printf '<key>com.apple.security.cs.disable-library-validation</key>\n' > "$forbidden_entitlements/python.entitlements"
assert_fails_with 'Refusing payload signing with com.apple.security.cs.disable-library-validation entitlement' "$case_dir/forbidden-entitlements.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-payload.sh" --entitlements-dir "$forbidden_entitlements" "$root"

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
: > "$root/Library/Application Support/Orchard/native/foo/.venv/lib/universal-native.so"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
chmod +x "$root/Library/Application Support/Orchard/native/foo/.venv/bin/ruff"
CODESIGN_LOG="$case_dir/codesign.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/sign-payload.sh" "$root" >"$case_dir/sign.out" 2>&1
assert_grep $'libnative.so	' "$case_dir/codesign.log"
assert_grep $'universal-native.so	' "$case_dir/codesign.log"
first_signed="$(head -1 "$case_dir/codesign.log")"
case "$first_signed" in
  *.venv/lib/*.so*) ;;
  *) echo "expected library to be signed before executables" >&2; cat "$case_dir/codesign.log" >&2; exit 1 ;;
esac
assert_grep $'beam.smp	' "$case_dir/codesign.log"
assert_grep 'beam.entitlements' "$case_dir/codesign.log"
assert_grep $'.venv/bin/python	' "$case_dir/codesign.log"
assert_grep 'python.entitlements' "$case_dir/codesign.log"
assert_grep $'share/bin/orchardctl	' "$case_dir/codesign.log"
assert_grep 'default.entitlements' "$case_dir/codesign.log"
assert_grep $'	yes/yes' "$case_dir/codesign.log"
assert_fails_with 'manifest output must be outside the staging root' "$case_dir/manifest.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-payload.sh" --manifest-output "$root/manifest.txt" "$root"

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
forbidden_root="$case_dir/forbidden-entitlement/root"
make_root "$forbidden_root"
: > "$forbidden_root/Library/Application Support/Orchard/share/bin/forbidden-entitlement"
assert_fails_with 'forbidden entitlement: com.apple.security.cs.disable-library-validation' "$case_dir/forbidden-entitlement.out" env CODESIGN_FORBIDDEN_ENTITLEMENT=1 PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$forbidden_root"
empty_root="$case_dir/empty/root"
mkdir -p "$empty_root"
assert_fails_with 'no Mach-O files found' "$case_dir/empty.out" run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$empty_root"

# RED/GREEN: optional build keychain is forwarded to payload signing and verification.
case_dir="$TMP_ROOT/payload-keychain"
tools="$case_dir/tools"
mkdir -p "$case_dir"
make_fake_tools "$tools"
payload_tools="$tools"
kc_dir="$case_dir/Keychains"
mkdir -p "$kc_dir"
build_keychain="$kc_dir/orchard-build.keychain-db"
: > "$build_keychain"
build_keychain_base="$(basename "$build_keychain")"
build_keychain_resolved="$(cd "$kc_dir" && pwd -P)/$build_keychain_base"
missing_keychain="$kc_dir/missing-build.keychain-db"
missing_keychain_base="$(basename "$missing_keychain")"
fixture_password='fixture-build-keychain-password'

# KC1: with no ORCHARD_BUILD_KEYCHAIN, codesign argv stays byte-compatible and has no --keychain.
root="$case_dir/kc1-sign/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
CODESIGN_LOG="$case_dir/kc1-sign-codesign.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/sign-payload.sh" "$root" >"$case_dir/kc1-sign.out" 2>&1
assert_no_grep '--keychain' "$case_dir/kc1-sign-codesign.log"

root="$case_dir/kc1-verify/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
CODESIGN_LOG="$case_dir/kc1-verify-codesign.log" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/kc1-verify.out" 2>&1
assert_no_grep '--keychain' "$case_dir/kc1-verify-codesign.log"

# KC2: sign-payload passes the explicit keychain at the canonical codesign position.
root="$case_dir/kc2-sign/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
CODESIGN_LOG="$case_dir/kc2-sign-codesign.log" ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/sign-payload.sh" "$root" >"$case_dir/kc2-sign.out" 2>&1
assert_grep "--timestamp --keychain $build_keychain_resolved --sign" "$case_dir/kc2-sign-codesign.log"

# Dry-run prints the same shape with a basename placeholder and never the absolute keychain path.
SECURITY_LOG="$case_dir/kc2-dry-security.log"
: > "$SECURITY_LOG"
ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" SECURITY_LOG="$SECURITY_LOG" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/sign-payload.sh" --dry-run "$root" >"$case_dir/kc2-dry.out" 2>&1
assert_grep "--timestamp --keychain \\<build-keychain:$build_keychain_base\\> --sign" "$case_dir/kc2-dry.out"
assert_no_grep "$build_keychain_resolved" "$case_dir/kc2-dry.out"
assert_no_grep "$build_keychain" "$case_dir/kc2-dry.out"
assert_no_grep "$fixture_password" "$case_dir/kc2-dry.out"
if [[ -s "$SECURITY_LOG" ]]; then
    echo "dry-run must not invoke security" >&2
    cat "$SECURITY_LOG" >&2
    exit 1
fi

# KC3: verify-payload-signing passes the explicit keychain before each verified path.
root="$case_dir/kc3-verify/root"
make_root "$root"
verify_target="$root/Library/Application Support/Orchard/share/bin/orchardctl"
: > "$verify_target"
CODESIGN_LOG="$case_dir/kc3-verify-codesign.log" ORCHARD_BUILD_KEYCHAIN="$build_keychain" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/kc3-verify.out" 2>&1
assert_grep "--verify --strict --verbose=4 --keychain $build_keychain_resolved $verify_target" "$case_dir/kc3-verify-codesign.log"
assert_grep "--display --verbose=4 --keychain $build_keychain_resolved $verify_target" "$case_dir/kc3-verify-codesign.log"
assert_grep "--display --entitlements :- --keychain $build_keychain_resolved $verify_target" "$case_dir/kc3-verify-codesign.log"

# KC4: missing keychain fails before codesign and reports only the basename.
root="$case_dir/kc4-missing/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
CODESIGN_LOG="$case_dir/kc4-codesign.log"
: > "$CODESIGN_LOG"
assert_fails_with "$missing_keychain_base" "$case_dir/kc4.out" env ORCHARD_BUILD_KEYCHAIN="$missing_keychain" CODESIGN_LOG="$CODESIGN_LOG" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/sign-payload.sh" "$root"
assert_no_grep "$missing_keychain" "$case_dir/kc4.out"
if [[ -s "$CODESIGN_LOG" ]]; then
    echo "codesign must not run when build keychain validation fails" >&2
    cat "$CODESIGN_LOG" >&2
    exit 1
fi

# KC4a: invalid signer/verifier inputs fail before keychain preparation side effects.
SECURITY_LOG="$case_dir/kc4a-security.log"
: > "$SECURITY_LOG"
assert_fails_with 'staging root does not exist' "$case_dir/kc4a-missing-root.out" env ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" SECURITY_LOG="$SECURITY_LOG" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/sign-payload.sh" "$case_dir/does-not-exist"
assert_file_empty "$SECURITY_LOG"
root="$case_dir/kc4a-missing-entitlements/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'entitlements directory does not exist' "$case_dir/kc4a-missing-entitlements.out" env ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" SECURITY_LOG="$SECURITY_LOG" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/sign-payload.sh" --entitlements-dir "$case_dir/missing-entitlements" "$root"
assert_file_empty "$SECURITY_LOG"
assert_fails_with 'root does not exist' "$case_dir/kc4a-verify-missing-root.out" env ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" SECURITY_LOG="$SECURITY_LOG" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$case_dir/verify-does-not-exist"
assert_file_empty "$SECURITY_LOG"

# KC4b: verifier keychain fingerprint failures stop before security and codesign.
shasum_fail_tools="$case_dir/kc4b-tools"
make_fake_tools "$shasum_fail_tools"
cat > "$shasum_fail_tools/shasum" <<'SH'
#!/bin/sh
exit 42
SH
chmod +x "$shasum_fail_tools/shasum"
root="$case_dir/kc4b-verify/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
SECURITY_LOG="$case_dir/kc4b-security.log"
CODESIGN_LOG="$case_dir/kc4b-codesign.log"
: > "$SECURITY_LOG"
: > "$CODESIGN_LOG"
assert_fails_with 'shasum failed while fingerprinting build keychain exit=42' "$case_dir/kc4b.out" env ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" SECURITY_LOG="$SECURITY_LOG" CODESIGN_LOG="$CODESIGN_LOG" PATH="$shasum_fail_tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"
assert_file_empty "$SECURITY_LOG"
assert_file_empty "$CODESIGN_LOG"

# KC5: password-bearing preparation unlocks and partition-lists before the first codesign.
root="$case_dir/kc5-sign/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
SECURITY_LOG="$case_dir/kc5-security.raw.log"
order_log="$case_dir/kc5-order.log"
env_presence_log="$case_dir/kc5-env-presence.log"
: > "$SECURITY_LOG"
: > "$env_presence_log"
CODESIGN_LOG="$case_dir/kc5-codesign.log" SECURITY_LOG="$SECURITY_LOG" ORCHARD_FAKE_ENV_PRESENCE_LOG="$env_presence_log" ORCHARD_FAKE_TOOL_ORDER_LOG="$order_log" ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/sign-payload.sh" "$root" >"$case_dir/kc5.out" 2>&1
test "$(grep -c '^unlock-keychain ' "$SECURITY_LOG" || true)" -eq 1
test "$(grep -c '^set-key-partition-list ' "$SECURITY_LOG" || true)" -eq 1
assert_grep "unlock-keychain -p $fixture_password $build_keychain_resolved" "$SECURITY_LOG"
assert_grep "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $fixture_password $build_keychain_resolved" "$SECURITY_LOG"
first_security_line="$(grep -n '^security unlock-keychain$' "$order_log" | sed -n '1s/:.*//p')"
first_codesign_line="$(grep -n '^codesign sign ' "$order_log" | sed -n '1s/:.*//p')"
test "$first_security_line" -lt "$first_codesign_line"
assert_grep $'file\tORCHARD_KEYCHAIN_PASSWORD_present=' "$env_presence_log"
assert_grep $'xcrun\tORCHARD_KEYCHAIN_PASSWORD_present=' "$env_presence_log"
assert_grep $'codesign\tORCHARD_KEYCHAIN_PASSWORD_present=' "$env_presence_log"
assert_no_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=x' "$env_presence_log"
sed -e "s|$fixture_password|<redacted-password-token>|g" -e "s|$build_keychain_resolved|$build_keychain_base|g" "$SECURITY_LOG" > "$case_dir/kc5-security.sanitized.log"

# KC6: operator-prepared keychain still forwards --keychain without security calls.
root="$case_dir/kc6-sign/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
SECURITY_LOG="$case_dir/kc6-security.log"
: > "$SECURITY_LOG"
CODESIGN_LOG="$case_dir/kc6-codesign.log" SECURITY_LOG="$SECURITY_LOG" ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    run_with_fakes "$tools" "$REPO_ROOT/scripts/sign-payload.sh" "$root" >"$case_dir/kc6.out" 2>&1
assert_grep "--timestamp --keychain $build_keychain_resolved --sign" "$case_dir/kc6-codesign.log"
if [[ -s "$SECURITY_LOG" ]]; then
    echo "operator-prepared keychain must not invoke security" >&2
    cat "$SECURITY_LOG" >&2
    exit 1
fi


# KC8: direct bash -x signing and verification do not reveal keychain path or password.
root="$case_dir/kc8-sign-xtrace/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
SECURITY_LOG="$case_dir/kc8-sign-security.raw.log"
CODESIGN_LOG="$case_dir/kc8-sign-codesign.log"
: > "$SECURITY_LOG"
env ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" SECURITY_LOG="$SECURITY_LOG" CODESIGN_LOG="$CODESIGN_LOG" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" PATH="$payload_tools:/usr/bin:/bin" \
    bash -x "$REPO_ROOT/scripts/sign-payload.sh" "$root" >"$case_dir/kc8-sign-xtrace.out" 2>&1
assert_no_grep "$fixture_password" "$case_dir/kc8-sign-xtrace.out"
assert_no_grep "$build_keychain_resolved" "$case_dir/kc8-sign-xtrace.out"
assert_no_grep "$build_keychain" "$case_dir/kc8-sign-xtrace.out"

root="$case_dir/kc8-verify-xtrace/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
SECURITY_LOG="$case_dir/kc8-verify-security.raw.log"
CODESIGN_LOG="$case_dir/kc8-verify-codesign.log"
: > "$SECURITY_LOG"
env ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" SECURITY_LOG="$SECURITY_LOG" CODESIGN_LOG="$CODESIGN_LOG" PATH="$payload_tools:/usr/bin:/bin" \
    bash -x "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/kc8-verify-xtrace.out" 2>&1
assert_no_grep "$fixture_password" "$case_dir/kc8-verify-xtrace.out"
assert_no_grep "$build_keychain_resolved" "$case_dir/kc8-verify-xtrace.out"
assert_no_grep "$build_keychain" "$case_dir/kc8-verify-xtrace.out"

# KC9: codesign diagnostics redact the explicit keychain path before user-facing output.
root="$case_dir/kc9-sign-fail/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with '<build-keychain:' "$case_dir/kc9-sign-fail.out" env ORCHARD_BUILD_KEYCHAIN="$build_keychain" CODESIGN_FAIL=1 CODESIGN_ECHO_ARGS_ON_FAIL=1 CODESIGN_LOG="$case_dir/kc9-sign-codesign.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" PATH="$payload_tools:/usr/bin:/bin" "$REPO_ROOT/scripts/sign-payload.sh" "$root"
assert_no_grep "$build_keychain_resolved" "$case_dir/kc9-sign-fail.out"
assert_no_grep "$build_keychain" "$case_dir/kc9-sign-fail.out"

root="$case_dir/kc9-verify-fail/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with '<build-keychain:' "$case_dir/kc9-verify-fail.out" env ORCHARD_BUILD_KEYCHAIN="$build_keychain" CODESIGN_VERIFY_FAIL=1 CODESIGN_ECHO_ARGS_ON_FAIL=1 CODESIGN_LOG="$case_dir/kc9-verify-codesign.log" PATH="$payload_tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"
assert_no_grep "$build_keychain_resolved" "$case_dir/kc9-verify-fail.out"
assert_no_grep "$build_keychain" "$case_dir/kc9-verify-fail.out"

cat "$case_dir/kc2-sign.out" "$case_dir/kc2-dry.out" "$case_dir/kc3-verify.out" "$case_dir/kc4.out" "$case_dir/kc5.out" "$case_dir/kc5-security.sanitized.log" "$case_dir/kc6.out" "$case_dir/kc8-sign-xtrace.out" "$case_dir/kc8-verify-xtrace.out" "$case_dir/kc9-sign-fail.out" "$case_dir/kc9-verify-fail.out" > "$case_dir/durable-keychain-scan.log"
assert_no_grep "$fixture_password" "$case_dir/durable-keychain-scan.log"
assert_no_grep "$build_keychain_resolved" "$case_dir/durable-keychain-scan.log"
assert_no_grep "$build_keychain" "$case_dir/durable-keychain-scan.log"

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

root="$case_dir/executable-path/root"
make_root "$root"
venv="$(make_valid_venv "$root")"
: > "$venv/lib/native.so"
OTOOL_CASE=executable_path_venv run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/executable-path.out" 2>&1
assert_grep $'native.so	ok	ok' "$case_dir/executable-path.out"
assert_no_grep $'	fail	' "$case_dir/executable-path.out"

# RED/GREEN: verifier enforces whole-payload Mach-O closure beyond Python venvs.
case_dir="$TMP_ROOT/verify-whole-payload-closure"
tools="$case_dir/tools"
mkdir -p "$case_dir"
make_fake_tools "$tools"

root="$case_dir/homebrew/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'forbidden Mach-O dependency' "$case_dir/homebrew.out" env OTOOL_CASE=homebrew_dep PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/cellar/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'forbidden Mach-O dependency' "$case_dir/cellar.out" env OTOOL_CASE=cellar_dep PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/buildhost/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'forbidden Mach-O dependency' "$case_dir/buildhost.out" env OTOOL_CASE=buildhost_dep PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/install-prefix-escape/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'outbound Mach-O dependency' "$case_dir/install-prefix-escape.out" env OTOOL_CASE=install_prefix_escape_dep PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/executable-path-nonvenv/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
: > "$root/Library/Application Support/Orchard/share/bin/libhelper.dylib"
assert_fails_with 'unresolved Mach-O dependency' "$case_dir/executable-path-nonvenv.out" env -i OTOOL_CASE=executable_path_nonvenv PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/loader-path-escape/root"
make_root "$root"
mkdir -p "$root/Library/Application Support/outside"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
: > "$root/Library/Application Support/outside/libbad.dylib"
assert_fails_with 'outbound Mach-O dependency' "$case_dir/loader-path-escape.out" env OTOOL_CASE=loader_path_escape PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/loader-path-escape-expanded/root"
make_root "$root/Payload"
mkdir -p "$root/Payload/Library/Application Support/outside"
: > "$root/Payload/Library/Application Support/Orchard/share/bin/orchardctl"
: > "$root/Payload/Library/Application Support/outside/libbad.dylib"
assert_fails_with 'outbound Mach-O dependency' "$case_dir/loader-path-escape-expanded.out" env OTOOL_CASE=loader_path_escape PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/rpath-unresolved/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'unresolved @rpath dependency' "$case_dir/rpath-unresolved.out" env OTOOL_CASE=rpath_unresolved PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/rpath-libjaccl-unresolved/root"
make_root "$root"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'unresolved @rpath dependency' "$case_dir/rpath-libjaccl-unresolved.out" env OTOOL_CASE=rpath_libjaccl_unresolved PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"
assert_grep '@rpath/libjaccl.dylib' "$case_dir/rpath-libjaccl-unresolved.out"

root="$case_dir/rpath-payload/root"
make_root "$root"
mkdir -p "$root/Library/Application Support/Orchard/share/lib"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
: > "$root/Library/Application Support/Orchard/share/lib/libcrypto.3.dylib"
OTOOL_CASE=rpath_payload run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/rpath-payload.out" 2>&1
assert_grep $'share/bin/orchardctl	ok	ok' "$case_dir/rpath-payload.out"
assert_no_grep $'	fail	' "$case_dir/rpath-payload.out"

root="$case_dir/universal-cross-slice/root"
make_root "$root"
mkdir -p "$root/Library/Application Support/Orchard/share/lib"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
: > "$root/Library/Application Support/Orchard/share/lib/libcrypto.3.dylib"
assert_fails_with 'unresolved @rpath dependency' "$case_dir/universal-cross-slice.out" env OTOOL_CASE=universal_cross_slice_rpath OTOOL_LOG="$case_dir/universal-otool.log" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"
assert_grep '-arch all -l' "$case_dir/universal-otool.log"

root="$case_dir/rpath-staging-absolute/root"
make_root "$root"
mkdir -p "$root/Library/Application Support/Orchard/support/openssl/lib"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
: > "$root/Library/Application Support/Orchard/support/openssl/lib/libcrypto.3.dylib"
assert_fails_with 'LC_RPATH' "$case_dir/rpath-staging-absolute.out" env OTOOL_CASE=rpath_staging_absolute OTOOL_STAGING_RPATH="$root/Library/Application Support/Orchard/support/openssl/lib" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

root="$case_dir/install-prefix-payload/root"
make_root "$root"
mkdir -p "$root/Library/Application Support/Orchard/share/lib"
: > "$root/Library/Application Support/Orchard/share/bin/orchardctl"
: > "$root/Library/Application Support/Orchard/share/lib/libcrypto.3.dylib"
OTOOL_CASE=in_payload_dep run_with_fakes "$tools" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root" >"$case_dir/install-prefix-payload.out" 2>&1
assert_grep $'share/bin/orchardctl	ok	ok' "$case_dir/install-prefix-payload.out"
assert_no_grep $'	fail	' "$case_dir/install-prefix-payload.out"

# RED/GREEN: OTP OpenSSL remediation bundles dylibs and rewrites load commands to payload-relative refs.
case_dir="$TMP_ROOT/remediate-otp-openssl"
tools="$case_dir/tools"
root="$case_dir/root/Library/Application Support/Orchard"
fake_cellar="$case_dir/fake/Cellar/openssl@3/3.3.0/lib"
install_name_log="$case_dir/install-name-tool.log"
provenance="$case_dir/openssl-provenance.txt"
mkdir -p "$tools" "$root/releases/orchard_controller/lib/crypto-5.5.3/priv/lib" "$fake_cellar"
: > "$root/releases/orchard_controller/lib/crypto-5.5.3/priv/lib/crypto.so"
printf 'fake libcrypto\n' > "$fake_cellar/libcrypto.3.dylib"
cat > "$tools/file" <<'SH'
#!/bin/sh
echo application/x-mach-binary
SH
cat > "$tools/otool" <<'SH'
#!/bin/sh
if [ -n "${OTOOL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$OTOOL_LOG"
fi
target=""
for arg in "$@"; do
  target="$arg"
done
case "$target" in
  *libcrypto*.dylib)
    cat <<OUT
Load command 0
          cmd LC_ID_DYLIB
      cmdsize 104
         name ${ORCHARD_FAKE_CELLAR_LIBCRYPTO:-/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib} (offset 24)
OUT
    exit 0
    ;;
esac
case "${OTOOL_CASE:-ok}" in
  rpath_homebrew_openssl)
    cat <<OUT
Load command 0
          cmd LC_RPATH
      cmdsize 48
         path ${ORCHARD_FAKE_CELLAR_DIR:?} (offset 12)
Load command 1
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @rpath/libcrypto.3.dylib (offset 24)
OUT
    ;;
  rpath_homebrew_load_first)
    cat <<OUT
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 96
         name @rpath/libcrypto.3.dylib (offset 24)
Load command 1
          cmd LC_RPATH
      cmdsize 48
         path ${ORCHARD_FAKE_CELLAR_DIR:?} (offset 12)
OUT
    ;;
  absolute_homebrew_with_rpath)
    cat <<OUT
Load command 0
          cmd LC_RPATH
      cmdsize 48
         path ${ORCHARD_FAKE_CELLAR_DIR:?} (offset 12)
Load command 1
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name ${ORCHARD_FAKE_CELLAR_LIBCRYPTO:?} (offset 24)
OUT
    ;;
  buildhost_cellar_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /Users/buildhost/Cellar/openssl@3/3.3.0/lib/libcrypto.3.dylib (offset 24)
OUT
    ;;
  *)
    if [ -n "${ORCHARD_FAKE_CELLAR_LIBCRYPTO:-}" ]; then
      cat <<OUT
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name ${ORCHARD_FAKE_CELLAR_LIBCRYPTO} (offset 24)
OUT
    fi
    ;;
esac
SH
cat > "$tools/install_name_tool" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "${INSTALL_NAME_TOOL_LOG:?}"
if [ "${1:-}" = "-change" ]; then
  last=""
  for arg in "$@"; do
    last="$arg"
  done
  case "$last" in
    *support/openssl/lib/libcrypto.3.dylib)
      echo "unexpected self-ID rewrite with -change: $*" >&2
      exit 1
      ;;
  esac
fi
exit 0
SH
chmod +x "$tools/file" "$tools/otool" "$tools/install_name_tool"
ORCHARD_ALLOW_TEST_HOMEBREW_PREFIX=1 ORCHARD_TEST_HOMEBREW_PREFIX="$case_dir/fake" ORCHARD_FAKE_CELLAR_LIBCRYPTO="$fake_cellar/libcrypto.3.dylib" INSTALL_NAME_TOOL_LOG="$install_name_log" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/remediate-otp-openssl-closure.sh" --provenance-output "$provenance" "$case_dir/root/Library/Application Support/Orchard" >"$case_dir/remediate.out" 2>&1
test -f "$root/support/openssl/lib/libcrypto.3.dylib"
assert_grep "bundled 1 OpenSSL dylib" "$case_dir/remediate.out"
assert_grep "-change $fake_cellar/libcrypto.3.dylib @loader_path/" "$install_name_log"
assert_grep "support/openssl/lib/libcrypto.3.dylib" "$install_name_log"
assert_grep "source=$fake_cellar/libcrypto.3.dylib" "$provenance"
assert_grep "bundled=support/openssl/lib/libcrypto.3.dylib" "$provenance"

rpath_root="$case_dir/rpath-root/Library/Application Support/Orchard"
rpath_log="$case_dir/rpath-install-name-tool.log"
mkdir -p "$rpath_root/releases/orchard_controller/lib/crypto-5.5.3/priv/lib"
: > "$rpath_root/releases/orchard_controller/lib/crypto-5.5.3/priv/lib/crypto.so"
ORCHARD_ALLOW_TEST_HOMEBREW_PREFIX=1 ORCHARD_TEST_HOMEBREW_PREFIX="$case_dir/fake" ORCHARD_FAKE_CELLAR_DIR="$fake_cellar" ORCHARD_FAKE_CELLAR_LIBCRYPTO="$fake_cellar/libcrypto.3.dylib" INSTALL_NAME_TOOL_LOG="$rpath_log" OTOOL_CASE=rpath_homebrew_openssl OTOOL_LOG="$case_dir/remediate-otool.log" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/remediate-otp-openssl-closure.sh" --provenance-output "$case_dir/rpath-provenance.txt" "$rpath_root" >"$case_dir/rpath-remediate.out" 2>&1
assert_grep '-arch all -l' "$case_dir/remediate-otool.log"
assert_grep "-change @rpath/libcrypto.3.dylib @loader_path/" "$rpath_log"
assert_grep "-delete_rpath $fake_cellar" "$rpath_log"
assert_grep "source=$fake_cellar/libcrypto.3.dylib" "$case_dir/rpath-provenance.txt"

rpath_load_first_log="$case_dir/rpath-load-first-install-name-tool.log"
ORCHARD_ALLOW_TEST_HOMEBREW_PREFIX=1 ORCHARD_TEST_HOMEBREW_PREFIX="$case_dir/fake" ORCHARD_FAKE_CELLAR_DIR="$fake_cellar" ORCHARD_FAKE_CELLAR_LIBCRYPTO="$fake_cellar/libcrypto.3.dylib" INSTALL_NAME_TOOL_LOG="$rpath_load_first_log" OTOOL_CASE=rpath_homebrew_load_first PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/remediate-otp-openssl-closure.sh" --provenance-output "$case_dir/rpath-load-first-provenance.txt" "$rpath_root" >"$case_dir/rpath-load-first-remediate.out" 2>&1
assert_grep "-change @rpath/libcrypto.3.dylib @loader_path/" "$rpath_load_first_log"
assert_grep "-delete_rpath $fake_cellar" "$rpath_load_first_log"

absolute_rpath_log="$case_dir/absolute-rpath-install-name-tool.log"
ORCHARD_ALLOW_TEST_HOMEBREW_PREFIX=1 ORCHARD_TEST_HOMEBREW_PREFIX="$case_dir/fake" ORCHARD_FAKE_CELLAR_DIR="$fake_cellar" ORCHARD_FAKE_CELLAR_LIBCRYPTO="$fake_cellar/libcrypto.3.dylib" INSTALL_NAME_TOOL_LOG="$absolute_rpath_log" OTOOL_CASE=absolute_homebrew_with_rpath PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/remediate-otp-openssl-closure.sh" --provenance-output "$case_dir/absolute-rpath-provenance.txt" "$rpath_root" >"$case_dir/absolute-rpath-remediate.out" 2>&1
assert_grep "-change $fake_cellar/libcrypto.3.dylib @loader_path/" "$absolute_rpath_log"
assert_grep "-delete_rpath $fake_cellar" "$absolute_rpath_log"

assert_fails_with 'must be outside the staging root' "$case_dir/provenance-in-staging.out" env ORCHARD_ALLOW_TEST_HOMEBREW_PREFIX=1 ORCHARD_TEST_HOMEBREW_PREFIX="$case_dir/fake" ORCHARD_FAKE_CELLAR_LIBCRYPTO="$fake_cellar/libcrypto.3.dylib" INSTALL_NAME_TOOL_LOG="$install_name_log" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/remediate-otp-openssl-closure.sh" --provenance-output "$root/provenance.txt" "$case_dir/root/Library/Application Support/Orchard"

buildhost_cellar_root="$case_dir/buildhost-cellar/Library/Application Support/Orchard"
mkdir -p "$buildhost_cellar_root/releases/orchard_controller/lib/crypto-5.5.3/priv/lib"
: > "$buildhost_cellar_root/releases/orchard_controller/lib/crypto-5.5.3/priv/lib/crypto.so"
OTOOL_CASE=buildhost_cellar_dep PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/remediate-otp-openssl-closure.sh" --provenance-output "$case_dir/buildhost-cellar-provenance.txt" "$buildhost_cellar_root" >"$case_dir/buildhost-cellar-remediate.out" 2>&1
assert_grep 'no Homebrew OpenSSL load commands found' "$case_dir/buildhost-cellar-remediate.out"
assert_no_grep 'source=/Users/buildhost/Cellar' "$case_dir/buildhost-cellar-provenance.txt"

stale_provenance="$case_dir/stale-provenance.txt"
printf 'source=/stale/libcrypto.3.dylib\n' > "$stale_provenance"
PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/remediate-otp-openssl-closure.sh" --provenance-output "$stale_provenance" "$case_dir/root/Library/Application Support/Orchard" >"$case_dir/noop-provenance.out" 2>&1
assert_grep 'result=no_homebrew_openssl_load_commands_found' "$stale_provenance"
assert_no_grep 'source=/stale/libcrypto.3.dylib' "$stale_provenance"

printf 'ok\tpayload signing contracts\n'
