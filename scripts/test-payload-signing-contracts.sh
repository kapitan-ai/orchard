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
if [ "$1" = "-f" ] && [ "$2" = "codesign" ]; then
  command -v codesign
  exit 0
fi
echo "unexpected xcrun invocation: $*" >&2
exit 1
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
  case "$last" in
    *unsigned*) echo "code object is not signed at all" >&2; exit 1 ;;
    *) exit 0 ;;
  esac
fi

if [ "${1:-}" = "--display" ]; then
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
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  printf 'uv %s\n' "$*" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
fi
exit 0
SH

    cat > "$tools/find" <<'SH'
#!/bin/sh
pattern="${ORCHARD_FAKE_FIND_FAIL_PATTERN:-}"
kind="${ORCHARD_FAKE_FIND_FAIL_KIND:-any}"
if [ -n "$pattern" ]; then
  matched=0
  for arg in "$@"; do
    case "$arg" in
      *"$pattern"*) matched=1 ;;
    esac
  done
  if [ "$matched" = "1" ]; then
    fail=0
    case "$kind" in
      any) fail=1 ;;
      print0)
        for arg in "$@"; do
          [ "$arg" = "-print0" ] && fail=1
        done
        ;;
      sidecars)
        for arg in "$@"; do
          case "$arg" in
            '._*'|'.DS_Store') fail=1 ;;
          esac
        done
        ;;
      *) echo "unknown fake find failure kind: $kind" >&2; exit 98 ;;
    esac
    if [ "$fail" = "1" ]; then
      echo "simulated find traversal failure for $pattern" >&2
      exit 96
    fi
  fi
fi
exec /usr/bin/find "$@"
SH

    cat > "$tools/cp" <<'SH'
#!/bin/sh
set -eu
if [ -n "${CP_LOG:-}" ]; then
  printf 'COPYFILE_DISABLE=%s cp %s\n' "${COPYFILE_DISABLE:-}" "$*" >> "$CP_LOG"
fi
if [ "${ORCHARD_REQUIRE_CP_X:-}" = "1" ]; then
  case " $* " in
    *" -X "*) ;;
    *) echo "cp missing -X: $*" >&2; exit 94 ;;
  esac
fi
if [ "${1:-}" = "-X" ]; then
  shift
fi
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
      if [ -n "${ORCHARD_FAKE_SYMLINK_XATTR_PATTERN:-}" ]; then
        ln -s "bin/$bin_name" "$target/xattr-symlink"
      fi
      if [ -n "${ORCHARD_FAKE_EXTERNAL_SYMLINK_TARGET:-}" ]; then
        ln -s "$ORCHARD_FAKE_EXTERNAL_SYMLINK_TARGET" "$target/external-target-symlink"
      fi
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
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  printf 'mix %s\n' "$*" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
fi
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
  homebrew_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib (offset 24)
OUT
    ;;
  *)
    cat <<'OUT'
OUT
    ;;
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

    cat > "$tools/codesign" <<'SH'
#!/bin/sh
set -eu
last=""
for arg in "$@"; do
  last="$arg"
done

case "${1:-}" in
  --verify)
    if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
      printf 'codesign verify %s\n' "$last" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
    fi
    if [ "${CODESIGN_VERIFY_FAIL:-}" = "1" ]; then
      echo "codesign verify fail" >&2
      exit 92
    fi
    exit 0
    ;;
  --display)
    if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
      printf 'codesign display %s\n' "$last" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
    fi
    for arg in "$@"; do
      if [ "$arg" = "--entitlements" ]; then
        if [ "${CODESIGN_FORBIDDEN_ENTITLEMENT:-}" = "1" ]; then
          echo '<key>com.apple.security.cs.disable-library-validation</key>'
        fi
        exit 0
      fi
    done
    echo "Signature size=9000" >&2
    echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
    echo "Timestamp=May 12, 2026" >&2
    echo "Authority=${ORCHARD_PAYLOAD_SIGNING_IDENTITY:-Developer ID Application: Example, Inc. (TEAMID)}" >&2
    exit 0
    ;;
esac

if [ "${CODESIGN_FAIL:-}" = "1" ]; then
  echo "codesign fail" >&2
  exit 91
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
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  printf 'codesign sign %s\n' "$last" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
fi
printf '%s\t%s\t%s\t%s\n' "$last" "$entitlements" "$identity" "$timestamp/$runtime" >> "${CODESIGN_LOG:?}"
SH

    cat > "$tools/xattr" <<'SH'
#!/bin/sh
set -eu
scrub_state="${ORCHARD_FAKE_XATTR_SCRUB_STATE:-}"
if [ -z "$scrub_state" ]; then
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    scrub_state="$ORCHARD_FAKE_TOOL_ORDER_LOG.xattr-scrubbed"
  else
    scrub_state="${TMPDIR:-/tmp}/orchard-fake-xattr-scrubbed"
  fi
fi
symlink_scrub_state="${ORCHARD_FAKE_SYMLINK_XATTR_CLEARED_STATE:-}"
if [ -z "$symlink_scrub_state" ]; then
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    symlink_scrub_state="$ORCHARD_FAKE_TOOL_ORDER_LOG.symlink-xattr-scrubbed"
  else
    symlink_scrub_state="${TMPDIR:-/tmp}/orchard-fake-symlink-xattr-scrubbed"
  fi
fi
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "-s" ] && [ "$#" -eq 3 ]; then
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    printf 'xattr -c -s %s\n' "$3" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  if [ -n "${XATTR_LOG:-}" ]; then
    printf 'xattr -c -s %s\n' "$3" >> "$XATTR_LOG"
  fi
  printf '%s\n' "$3" >> "$symlink_scrub_state"
  exit 0
fi
if [ "${1:-}" = "-s" ] && [ "$#" -eq 2 ]; then
  path="$2"
  dirty_pattern="${ORCHARD_FAKE_SYMLINK_XATTR_PATTERN:-}"
  if [ -n "$dirty_pattern" ]; then
    case "$path" in
      *"$dirty_pattern"*)
        if [ -f "$symlink_scrub_state" ]; then
          while IFS= read -r scrubbed_path; do
            [ "$path" = "$scrubbed_path" ] && exit 0
          done < "$symlink_scrub_state"
        fi
        echo com.apple.quarantine
        ;;
    esac
  fi
  exit 0
fi
if [ "${1:-}" = "-cr" ] && [ "$#" -eq 2 ]; then
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    printf 'xattr -cr %s\n' "$2" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  if [ -n "${XATTR_LOG:-}" ]; then
    printf 'xattr -cr %s\n' "$2" >> "$XATTR_LOG"
  fi
  if [ -n "${ORCHARD_FAKE_EXTERNAL_SYMLINK_TARGET:-}" ] && [ -n "${XATTR_LOG:-}" ]; then
    printf 'external-target-scrubbed %s\n' "$ORCHARD_FAKE_EXTERNAL_SYMLINK_TARGET" >> "$XATTR_LOG"
  fi
  if [ "${XATTR_FAIL:-}" = "1" ]; then
    echo "xattr fail" >&2
    exit 93
  fi
  if [ "${ORCHARD_FAKE_XATTR_DIRTY_UNTIL_SCRUB:-}" = "1" ]; then
    printf '%s\n' "$2" >> "$scrub_state"
  fi
  exit 0
fi
if [ "${1:-}" = "-c" ] && [ "$#" -eq 2 ]; then
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    printf 'xattr -c %s\n' "$2" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  if [ -n "${XATTR_LOG:-}" ]; then
    printf 'xattr -c %s\n' "$2" >> "$XATTR_LOG"
  fi
  if [ "${XATTR_FAIL:-}" = "1" ]; then
    echo "xattr fail" >&2
    exit 93
  fi
  if [ "${ORCHARD_FAKE_XATTR_DIRTY_UNTIL_SCRUB:-}" = "1" ]; then
    printf '%s\n' "$2" >> "$scrub_state"
  fi
  exit 0
fi
if [ "$#" -eq 1 ]; then
  path="$1"
  provenance_pattern="${ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN:-}"
  if [ -n "$provenance_pattern" ]; then
    case "$path" in
      *"$provenance_pattern"*)
        echo com.apple.provenance
        ;;
    esac
  fi
  dirty_pattern="${ORCHARD_FAKE_XATTR_DIRTY_PATTERN:-}"
  if [ -n "$dirty_pattern" ]; then
    case "$path" in
      *"$dirty_pattern"*)
        if [ "${ORCHARD_FAKE_XATTR_DIRTY_UNTIL_SCRUB:-}" = "1" ] && [ -f "$scrub_state" ]; then
          while IFS= read -r scrubbed_root; do
            case "$path" in "$scrubbed_root"|"$scrubbed_root"/*) exit 0 ;; esac
          done < "$scrub_state"
        fi
        echo com.apple.quarantine
        ;;
    esac
  fi
  exit 0
fi
echo "unexpected xattr invocation: $*" >&2
exit 1
SH

    cat > "$tools/pkgbuild" <<'SH'
#!/bin/sh
identifier=""
last=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --identifier) identifier="$2"; shift 2 ;;
    *) last="$1"; shift ;;
  esac
done
case "$identifier" in
  com.orchard.pkg.preflight) is_preflight=1 ;;
  *) is_preflight=0 ;;
esac
if [ "$is_preflight" = "0" ]; then
  echo "pkgbuild invoked" >&2
fi
if [ "${ORCHARD_REQUIRE_COPYFILE_DISABLE:-}" = "1" ] && [ "${COPYFILE_DISABLE:-}" != "1" ]; then
  echo "pkgbuild missing COPYFILE_DISABLE=1" >&2
  exit 95
fi
if [ "${ORCHARD_REQUIRE_COPY_EXTENDED_ATTRIBUTES_DISABLE:-}" = "1" ] && [ "${COPY_EXTENDED_ATTRIBUTES_DISABLE:-}" != "1" ]; then
  echo "pkgbuild missing COPY_EXTENDED_ATTRIBUTES_DISABLE=1" >&2
  exit 95
fi
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  if [ "$is_preflight" = "1" ]; then
    echo "scratch-preflight" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  else
    echo "pkgbuild" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
fi
if [ "$is_preflight" = "1" ] || [ "${ORCHARD_FAKE_PKGBUILD_SUCCESS:-}" = "1" ]; then
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
if [ "${1:-}" = "--expand-full" ]; then
  pkg="$2"
  dest="$3"
  if [ -e "$dest" ]; then
    echo "pkgutil expand destination already exists: $dest" >&2
    exit 97
  fi
  mkdir -p "$dest/Scripts" "$dest/Payload/Library/Application Support/Orchard/share/bin"
  : > "$dest/Scripts/postinstall"
  : > "$dest/Payload/Library/Application Support/Orchard/share/bin/orchardctl"
  case "$pkg" in
    *scratch*.pkg)
      if [ "${ORCHARD_FAKE_SCRATCH_PKGBUILD_DIRTY:-}" = "1" ]; then
        : > "$dest/Scripts/._postinstall"
      fi
      ;;
    *)
      if [ "${ORCHARD_FAKE_EXPANDED_PKG_SIDECAR:-}" = "1" ]; then
        : > "$dest/Scripts/._postinstall"
      fi
      ;;
  esac
  exit 0
fi
echo "unexpected pkgutil invocation: $*" >&2
exit 1
SH

    chmod +x "$tools/git" "$tools/uv" "$tools/find" "$tools/cp" "$tools/mix" "$tools/file" "$tools/otool" "$tools/xcrun" "$tools/codesign" "$tools/xattr" "$tools/pkgbuild" "$tools/pkgutil"
}

write_sign_pkg_fakes() {
    local tools="$1"
    local mode="$2"
    local log="$3"
    mkdir -p "$tools"

    cat > "$tools/productsign" <<SH
#!/bin/sh
last=""
for arg in "\$@"; do
  last="\$arg"
done
echo "productsign invoked" >> "$log"
: > "\$last"
exit 0
SH

    cat > "$tools/pkgutil" <<SH
#!/bin/sh
set -eu
if [ "\$1" != "--expand-full" ]; then
  echo "unexpected pkgutil invocation: \$*" >&2
  exit 1
fi
case "$mode" in
  fail_expand) echo "fake expand failure" >&2; exit 42 ;;
  sleep_expand) if [ -n "\${ORCHARD_FAKE_EXPAND_CHILD_LOG:-}" ]; then (while :; do echo child >> "\$ORCHARD_FAKE_EXPAND_CHILD_LOG"; sleep 1; done) & fi; trap '' TERM; sleep 20 ;;
  child_survives) if [ -n "\${ORCHARD_FAKE_EXPAND_CHILD_LOG:-}" ]; then (trap '' TERM; while :; do echo child >> "\$ORCHARD_FAKE_EXPAND_CHILD_LOG"; sleep 1; done) & fi; trap 'exit 0' TERM; sleep 20 ;;
esac
mkdir -p "\$3/Library/Application Support/Orchard/share/bin"
case "$mode" in
  unsigned) : > "\$3/Library/Application Support/Orchard/share/bin/unsigned" ;;
  ok) : > "\$3/Library/Application Support/Orchard/share/bin/ok" ;;
  fail_expand|sleep_expand) ;;
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
  homebrew_dep)
    cat <<'OUT'
Load command 0
          cmd LC_LOAD_DYLIB
      cmdsize 104
         name /opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib (offset 24)
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
  for arg in "$@"; do
    if [ "$arg" = "--entitlements" ]; then
      if [ "${CODESIGN_FORBIDDEN_ENTITLEMENT:-}" = "1" ]; then
        echo '<key>com.apple.security.cs.disable-library-validation</key>'
      fi
      exit 0
    fi
  done
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
  if [ -n "${XCRUN_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$XCRUN_LOG"
  fi
  printf '{"id":"fake-submission","status":"Accepted"}\n'
  exit 0
fi
if [ "$1" = "stapler" ]; then
  if [ -n "${XCRUN_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$XCRUN_LOG"
  fi
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
forbidden_entitlements="$case_dir/forbidden-entitlements"
mkdir -p "$forbidden_entitlements"
printf '<key>com.apple.security.cs.disable-library-validation</key>\n' > "$forbidden_entitlements/python.entitlements"
assert_fails_with 'Refusing payload signing with com.apple.security.cs.disable-library-validation entitlement' "$case_dir/forbidden-entitlements.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-payload.sh" --entitlements-dir "$forbidden_entitlements" "$root"

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
forbidden_root="$case_dir/forbidden-entitlement/root"
make_root "$forbidden_root"
: > "$forbidden_root/Library/Application Support/Orchard/share/bin/forbidden-entitlement"
assert_fails_with 'forbidden entitlement: com.apple.security.cs.disable-library-validation' "$case_dir/forbidden-entitlement.out" env CODESIGN_FORBIDDEN_ENTITLEMENT=1 PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$forbidden_root"
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
assert_fails_with 'unresolved Mach-O dependency' "$case_dir/executable-path-nonvenv.out" env OTOOL_CASE=executable_path_nonvenv PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity "$IDENTITY" "$root"

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
xattr_log="$case_dir/xattr.log"
ORCHARD_FAKE_METADATA_SIDECAR=1 XATTR_LOG="$xattr_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_sidecar" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/sidecar.out" 2>&1
assert_grep 'Removing macOS metadata sidecar files from staging payload' "$case_dir/sidecar.out"
assert_grep '._orchard_tokenizer' "$case_dir/sidecar.out"
if find "$staging_sidecar" \( -name '._*' -o -name '.DS_Store' \) -print -quit | grep -q .; then
    echo "staging metadata sidecars should be removed before validation" >&2
    find "$staging_sidecar" \( -name '._*' -o -name '.DS_Store' \) >&2
    exit 1
fi
assert_no_grep "xattr -cr $staging_sidecar" "$xattr_log"

staging_provenance_only="$case_dir/staging-provenance-only"
provenance_only_xattr_log="$case_dir/provenance-only-xattr.log"
ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN='native/orchard_tokenizer' XATTR_FAIL=1 XATTR_LOG="$provenance_only_xattr_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_provenance_only" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/provenance-only.out" 2>&1
assert_grep 'STAGING_BASE=' "$case_dir/provenance-only.out"
assert_no_grep 'xattr -c ' "$provenance_only_xattr_log"

staging_mixed_xattr="$case_dir/staging-mixed-xattr"
assert_fails_with 'Failed to scrub extended attributes' "$case_dir/mixed-xattr.out" env ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN='native/orchard_tokenizer' ORCHARD_FAKE_XATTR_DIRTY_PATTERN='native/orchard_tokenizer' XATTR_FAIL=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_mixed_xattr" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir"

staging_symlink_xattr="$case_dir/staging-symlink-xattr"
symlink_xattr_log="$case_dir/symlink-xattr.log"
ORCHARD_FAKE_SYMLINK_XATTR_PATTERN='xattr-symlink' XATTR_LOG="$symlink_xattr_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_symlink_xattr" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/symlink-xattr.out" 2>&1
stage_line_count="$(grep -c '^STAGING_BASE=' "$case_dir/symlink-xattr.out")"
test "$stage_line_count" -eq 1
assert_grep "STAGING_BASE=$staging_symlink_xattr" "$case_dir/symlink-xattr.out"
assert_grep "xattr -c -s $staging_symlink_xattr/Library/Application Support/Orchard/native/orchard_tokenizer/xattr-symlink" "$symlink_xattr_log"
assert_no_grep "xattr -cr $staging_symlink_xattr" "$symlink_xattr_log"
if find "$staging_symlink_xattr" \( -name '._*' -o -name '.DS_Store' \) -print -quit | grep -q .; then
    echo "staging metadata sidecars should be absent after symlink xattr scrub" >&2
    find "$staging_symlink_xattr" \( -name '._*' -o -name '.DS_Store' \) >&2
    exit 1
fi

staging_external_symlink="$case_dir/staging-external-symlink"
external_target="$case_dir/external-target"
external_symlink_log="$case_dir/external-symlink-xattr.log"
printf 'external target\n' > "$external_target"
ORCHARD_FAKE_EXTERNAL_SYMLINK_TARGET="$external_target" ORCHARD_FAKE_SYMLINK_XATTR_PATTERN='external-target-symlink' XATTR_LOG="$external_symlink_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_external_symlink" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/external-symlink.out" 2>&1
staged_external_symlink="$staging_external_symlink/Library/Application Support/Orchard/native/orchard_tokenizer/external-target-symlink"
assert_grep "xattr -c -s $staged_external_symlink" "$external_symlink_log"
assert_no_grep "xattr -cr $staging_external_symlink" "$external_symlink_log"
assert_no_grep "external-target-scrubbed $external_target" "$external_symlink_log"

staging_traversal="$case_dir/staging-traversal"
staging_traversal_order="$case_dir/staging-traversal-order.log"
assert_fails_with 'Failed to traverse macOS metadata sidecars under' "$case_dir/staging-traversal.out" env ORCHARD_FAKE_FIND_FAIL_PATTERN="$staging_traversal" ORCHARD_FAKE_FIND_FAIL_KIND=sidecars CODESIGN_LOG="$case_dir/staging-traversal-codesign.log" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_TOOL_ORDER_LOG="$staging_traversal_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_traversal" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_no_grep 'codesign sign ' "$staging_traversal_order"
assert_no_exact_line 'pkgbuild' "$staging_traversal_order"

source_scripts_order="$case_dir/source-scripts-order.log"
assert_fails_with 'Provenance gate failed for package scripts' "$case_dir/source-scripts.out" env ORCHARD_FAKE_XATTR_DIRTY_PATTERN='packaging/pkg/scripts/postinstall' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_scripts_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-scripts-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'xattr_node_count=' "$case_dir/source-scripts.out"
assert_grep 'packaging/pkg/scripts/postinstall' "$case_dir/source-scripts.out"
assert_no_grep 'uv ' "$source_scripts_order"
assert_no_grep 'mix release' "$source_scripts_order"
assert_no_exact_line 'pkgbuild' "$source_scripts_order"

source_wrappers_order="$case_dir/source-wrappers-order.log"
assert_fails_with 'Provenance gate failed for packaging wrappers' "$case_dir/source-wrappers.out" env ORCHARD_FAKE_XATTR_DIRTY_PATTERN='packaging/pkg/bin/orchardctl' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_wrappers_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-wrappers-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'xattr_node_count=' "$case_dir/source-wrappers.out"
assert_grep 'packaging/pkg/bin/orchardctl' "$case_dir/source-wrappers.out"
assert_no_grep 'uv ' "$source_wrappers_order"
assert_no_grep 'mix release' "$source_wrappers_order"
assert_no_exact_line 'pkgbuild' "$source_wrappers_order"

source_wrappers_provenance_only_order="$case_dir/source-wrappers-provenance-only-order.log"
ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN='packaging/pkg/bin/orchard-controller' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_wrappers_provenance_only_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-wrappers-provenance-only-staging" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/source-wrappers-provenance-only.out" 2>&1
assert_grep 'Provenance inventory: packaging wrappers xattr_node_count=0' "$case_dir/source-wrappers-provenance-only.out"
assert_grep 'STAGING_BASE=' "$case_dir/source-wrappers-provenance-only.out"

source_launchd_order="$case_dir/source-launchd-order.log"
assert_fails_with 'Provenance gate failed for launchd plists' "$case_dir/source-launchd.out" env ORCHARD_FAKE_XATTR_DIRTY_PATTERN='packaging/launchd/com.orchard.controller.plist' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_launchd_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-launchd-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'xattr_node_count=' "$case_dir/source-launchd.out"
assert_grep 'packaging/launchd/com.orchard.controller.plist' "$case_dir/source-launchd.out"
assert_no_grep 'uv ' "$source_launchd_order"
assert_no_grep 'mix release' "$source_launchd_order"
assert_no_exact_line 'pkgbuild' "$source_launchd_order"

source_entitlements_order="$case_dir/source-entitlements-order.log"
assert_fails_with 'Provenance gate failed for payload entitlements' "$case_dir/source-entitlements.out" env ORCHARD_FAKE_XATTR_DIRTY_PATTERN='packaging/pkg/entitlements' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_entitlements_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-entitlements-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'xattr_node_count=' "$case_dir/source-entitlements.out"
assert_grep 'packaging/pkg/entitlements' "$case_dir/source-entitlements.out"
assert_no_grep 'uv ' "$source_entitlements_order"
assert_no_grep 'mix release' "$source_entitlements_order"
assert_no_exact_line 'pkgbuild' "$source_entitlements_order"

source_traversal_order="$case_dir/source-traversal-order.log"
assert_fails_with 'Failed to traverse provenance root' "$case_dir/source-traversal.out" env ORCHARD_FAKE_FIND_FAIL_PATTERN='packaging/pkg/bin' ORCHARD_FAKE_FIND_FAIL_KIND=print0 ORCHARD_FAKE_TOOL_ORDER_LOG="$source_traversal_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-traversal-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'packaging/pkg/bin' "$case_dir/source-traversal.out"
assert_no_grep 'uv ' "$source_traversal_order"
assert_no_grep 'mix release' "$source_traversal_order"
assert_no_exact_line 'pkgbuild' "$source_traversal_order"

scratch_order="$case_dir/scratch-order.log"
assert_fails_with 'Scratch pkgbuild provenance preflight failed' "$case_dir/scratch-preflight.out" env ORCHARD_FAKE_SCRATCH_PKGBUILD_DIRTY=1 ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_TOOL_ORDER_LOG="$scratch_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/scratch-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'payload_sidecar_count=' "$case_dir/scratch-preflight.out"
assert_grep 'Scripts/._postinstall' "$case_dir/scratch-preflight.out"
assert_no_grep 'uv ' "$scratch_order"
assert_no_grep 'mix release' "$scratch_order"
assert_no_exact_line 'pkgbuild' "$scratch_order"

staging_persistent_xattr="$case_dir/staging-persistent-xattr"
persistent_order="$case_dir/persistent-xattr-order.log"
persistent_dirty_path="$staging_persistent_xattr/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'Provenance gate failed for post-scrub staging' "$case_dir/persistent-xattr.out" env ORCHARD_FAKE_XATTR_DIRTY_PATTERN="$persistent_dirty_path" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_TOOL_ORDER_LOG="$persistent_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_persistent_xattr" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'xattr_node_count=' "$case_dir/persistent-xattr.out"
assert_grep "$persistent_dirty_path" "$case_dir/persistent-xattr.out"
assert_no_exact_line 'pkgbuild' "$persistent_order"

staging_signed="$case_dir/staging-signed"
order_log="$case_dir/build-order.log"
signed_dirty_path="$staging_signed/Library/Application Support/Orchard/share/bin/orchardctl"
CODESIGN_LOG="$case_dir/codesign.log" ORCHARD_FAKE_XATTR_DIRTY_PATTERN="$signed_dirty_path" ORCHARD_FAKE_XATTR_DIRTY_UNTIL_SCRUB=1 ORCHARD_FAKE_TOOL_ORDER_LOG="$order_log" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_signed" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir" >"$case_dir/build-signed.out" 2>&1
assert_grep "$staging_signed" "$case_dir/codesign.log"
assert_grep "$IDENTITY" "$case_dir/codesign.log"
first_xattr_line="$(grep -n "xattr -c $signed_dirty_path" "$order_log" | sed -n '1s/:.*//p')"
first_sign_line="$(grep -n 'codesign sign ' "$order_log" | sed -n '1s/:.*//p')"
first_verify_line="$(grep -n 'codesign verify ' "$order_log" | sed -n '1s/:.*//p')"
pkgbuild_line="$(grep -n '^pkgbuild$' "$order_log" | sed -n '1s/:.*//p')"
test "$first_xattr_line" -lt "$first_sign_line"
test "$first_sign_line" -lt "$first_verify_line"
test "$first_verify_line" -lt "$pkgbuild_line"
assert_no_grep "xattr -cr $staging_signed" "$order_log"

staging_verify_fail="$case_dir/staging-verify-fail"
assert_fails_with 'Payload signature verification failed after metadata scrub' "$case_dir/verify-fail.out" env CODESIGN_VERIFY_FAIL=1 CODESIGN_LOG="$case_dir/codesign-verify-fail.log" ORCHARD_FAKE_TOOL_ORDER_LOG="$case_dir/verify-fail-order.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_verify_fail" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_no_grep 'pkgbuild invoked' "$case_dir/verify-fail.out"
assert_no_grep 'pkgbuild' "$case_dir/verify-fail-order.log"

staging_xattr_fail="$case_dir/staging-xattr-fail"
assert_fails_with 'xattr fail' "$case_dir/xattr-fail.out" env XATTR_FAIL=1 ORCHARD_FAKE_XATTR_DIRTY_PATTERN="$staging_xattr_fail/Library/Application Support/Orchard/share/bin/orchardctl" CODESIGN_LOG="$case_dir/codesign-xattr-fail.log" ORCHARD_FAKE_TOOL_ORDER_LOG="$case_dir/xattr-fail-order.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_xattr_fail" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_no_grep 'codesign sign ' "$case_dir/xattr-fail-order.log"
assert_no_grep 'pkgbuild' "$case_dir/xattr-fail-order.log"

staging_stage_signed="$case_dir/staging-stage-signed"
CODESIGN_LOG="$case_dir/codesign-stage.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_stage_signed" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/build-stage-signed.out" 2>&1
assert_grep "STAGING_BASE=$staging_stage_signed" "$case_dir/build-stage-signed.out"
assert_grep "$staging_stage_signed" "$case_dir/codesign-stage.log"
assert_grep "$IDENTITY" "$case_dir/codesign-stage.log"

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

staging_metadata_copy="$case_dir/staging-metadata-copy"
cp_log="$case_dir/cp.log"
ORCHARD_REQUIRE_CP_X=1 CP_LOG="$cp_log" ORCHARD_REQUIRE_COPYFILE_DISABLE=1 ORCHARD_REQUIRE_COPY_EXTENDED_ATTRIBUTES_DISABLE=1 ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_metadata_copy" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir" >"$case_dir/metadata-copy.out" 2>&1
assert_grep 'COPYFILE_DISABLE=1 cp -X -R' "$cp_log"
assert_grep 'COPYFILE_DISABLE=1 cp -X ' "$cp_log"
assert_no_grep 'pkgbuild missing COPYFILE_DISABLE=1' "$case_dir/metadata-copy.out"

staging_pkg_sidecar="$case_dir/staging-pkg-sidecar"
assert_fails_with 'macOS metadata sidecar files detected in PKG payload' "$case_dir/pkg-sidecar.out" env ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_PKGUTIL_SIDECARS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_pkg_sidecar" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'Removed malformed PKG' "$case_dir/pkg-sidecar.out"
if find "$out_dir" -name '*.pkg' -print -quit | grep -q .; then
    echo "malformed PKG should be removed after payload sidecar validation failure" >&2
    find "$out_dir" -name '*.pkg' >&2
    exit 1
fi

staging_expanded_sidecar="$case_dir/staging-expanded-sidecar"
assert_fails_with 'Provenance gate failed for unsigned PKG expanded package' "$case_dir/expanded-sidecar.out" env ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_EXPANDED_PKG_SIDECAR=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_expanded_sidecar" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'Scripts/._postinstall' "$case_dir/expanded-sidecar.out"
assert_grep 'Removed malformed PKG' "$case_dir/expanded-sidecar.out"
if find "$out_dir" -name '*.pkg' -print -quit | grep -q .; then
    echo "malformed PKG should be removed after expanded package sidecar validation failure" >&2
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

tools="$case_dir/tools-closure"
closure_productsign_log="$case_dir/productsign-closure.log"
closure_output_pkg="$case_dir/Orchard-closure-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$closure_productsign_log"
assert_fails_with 'forbidden Mach-O dependency' "$case_dir/closure.out" env OTOOL_CASE=homebrew_dep PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$closure_output_pkg"
test ! -e "$closure_productsign_log"

tools="$case_dir/tools-forbidden-entitlement"
forbidden_productsign_log="$case_dir/productsign-forbidden-entitlement.log"
forbidden_output_pkg="$case_dir/Orchard-forbidden-entitlement-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$forbidden_productsign_log"
assert_fails_with 'forbidden entitlement: com.apple.security.cs.disable-library-validation' "$case_dir/forbidden-entitlement.out" env CODESIGN_FORBIDDEN_ENTITLEMENT=1 PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$forbidden_output_pkg"
test ! -e "$forbidden_productsign_log"

# RED/GREEN: sign-pkg notary auth matrix and bounded expansion diagnostics.
case_dir="$TMP_ROOT/sign-pkg-notary-auth"
mkdir -p "$case_dir"
input_pkg="$case_dir/Orchard.pkg"
: > "$input_pkg"

tools="$case_dir/tools-profile-default"
productsign_log="$case_dir/productsign-profile-default.log"
xcrun_log="$case_dir/xcrun-profile-default.log"
output_pkg="$case_dir/profile-default-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg" >"$case_dir/profile-default.out" 2>&1
assert_grep 'notarytool submit' "$xcrun_log"
assert_grep '--keychain-profile orchard-notary' "$xcrun_log"
assert_grep '--output-format json' "$xcrun_log"
assert_no_grep '--key ' "$xcrun_log"
assert_no_grep '--key-id' "$xcrun_log"
assert_no_grep '--issuer' "$xcrun_log"
assert_grep 'productsign invoked' "$productsign_log"
test -f "$output_pkg"
test -f "$output_pkg.notary.json"
test -f "$output_pkg.sha256"

tools="$case_dir/tools-profile-explicit"
productsign_log="$case_dir/productsign-profile-explicit.log"
xcrun_log="$case_dir/xcrun-profile-explicit.log"
output_pkg="$case_dir/profile-explicit-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" ORCHARD_NOTARY_AUTH=profile ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg" >"$case_dir/profile-explicit.out" 2>&1
assert_grep '--keychain-profile orchard-notary' "$xcrun_log"
assert_no_grep '--key ' "$xcrun_log"
assert_grep 'productsign invoked' "$productsign_log"

tools="$case_dir/tools-api"
productsign_log="$case_dir/productsign-api.log"
xcrun_log="$case_dir/xcrun-api.log"
api_key="$case_dir/AuthKey_TEST.p8"
output_pkg="$case_dir/api-signed.pkg"
: > "$api_key"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=ISSUER123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$output_pkg" >"$case_dir/api.out" 2>&1
assert_grep "--key $api_key" "$xcrun_log"
assert_grep '--key-id KEY123' "$xcrun_log"
assert_grep '--issuer ISSUER123' "$xcrun_log"
assert_grep '--output-format json' "$xcrun_log"
assert_no_grep '--keychain-profile' "$xcrun_log"
assert_grep 'productsign invoked' "$productsign_log"

tools="$case_dir/tools-api-missing"
productsign_log="$case_dir/productsign-api-missing.log"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_KEY_PATH is required' "$case_dir/api-missing-path.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=ISSUER123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-missing-path.pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_KEY_ID is required' "$case_dir/api-missing-id.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_ISSUER_ID=ISSUER123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-missing-id.pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_ISSUER_ID is required' "$case_dir/api-missing-issuer.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-missing-issuer.pkg"
test ! -e "$productsign_log"
assert_fails_with 'Unsupported ORCHARD_NOTARY_AUTH' "$case_dir/auth-unsupported.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=bogus ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/auth-unsupported.pkg"
test ! -e "$productsign_log"
assert_fails_with 'App Store Connect API key does not exist' "$case_dir/api-missing-file.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_PATH="$case_dir/missing.p8" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=ISSUER123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-missing-file.pkg"
test ! -e "$productsign_log"

tools="$case_dir/tools-dry"
productsign_log="$case_dir/productsign-dry.log"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=ISSUER123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/dry.pkg" >"$case_dir/dry.out" 2>&1
assert_grep '--key' "$case_dir/dry.out"
assert_grep '--key-id' "$case_dir/dry.out"
assert_grep '--issuer' "$case_dir/dry.out"
assert_grep '--output-format' "$case_dir/dry.out"
test ! -e "$productsign_log"

tools="$case_dir/tools-expand-fail"
productsign_log="$case_dir/productsign-expand-fail.log"
diag_dir="$case_dir/expand-fail-diagnostics"
write_sign_pkg_fakes "$tools" fail_expand "$productsign_log"
assert_fails_with 'pkgutil --expand-full failed during payload audit' "$case_dir/expand-fail.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/expand-fail.pkg"
test ! -e "$productsign_log"
assert_grep 'status=42' "$diag_dir/expand-full.status"
assert_grep 'fake expand failure' "$diag_dir/expand-full.stderr"

assert_fails_with 'Diagnostics directory already exists' "$case_dir/diag-reuse.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/diag-reuse.pkg"

tools="$case_dir/tools-expand-timeout"
productsign_log="$case_dir/productsign-expand-timeout.log"
diag_dir="$case_dir/expand-timeout-diagnostics"
write_sign_pkg_fakes "$tools" sleep_expand "$productsign_log"
child_log="$case_dir/expand-timeout-child.log"
start_epoch="$(date +%s)"
assert_fails_with 'Timed out expanding PKG for payload audit' "$case_dir/expand-timeout.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_FAKE_EXPAND_CHILD_LOG="$child_log" ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS=1 ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/expand-timeout.pkg"
elapsed=$(( $(date +%s) - start_epoch ))
if [ "$elapsed" -ge 10 ]; then
    echo "expand timeout test took too long: ${elapsed}s" >&2
    exit 1
fi
test ! -e "$productsign_log"
assert_grep 'status=124' "$diag_dir/expand-full.status"
assert_grep 'timeout_after_seconds=1' "$diag_dir/expand-full.timeout"
if [ -f "$child_log" ]; then
    before_count="$(wc -l < "$child_log")"
    sleep 2
    after_count="$(wc -l < "$child_log")"
    if [ "$before_count" != "$after_count" ]; then
        echo "expand timeout left child writer running" >&2
        exit 1
    fi
fi


tools="$case_dir/tools-expand-child-survives"
productsign_log="$case_dir/productsign-expand-child-survives.log"
diag_dir="$case_dir/expand-child-survives-diagnostics"
child_log="$case_dir/expand-child-survives-child.log"
write_sign_pkg_fakes "$tools" child_survives "$productsign_log"
assert_fails_with 'Timed out expanding PKG for payload audit' "$case_dir/expand-child-survives.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_FAKE_EXPAND_CHILD_LOG="$child_log" ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS=1 ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/expand-child-survives.pkg"
test ! -e "$productsign_log"
assert_grep 'status=124' "$diag_dir/expand-full.status"
if [ ! -s "$child_log" ]; then
    echo "child-survival fake did not write child log" >&2
    exit 1
fi
before_count="$(wc -l < "$child_log")"
sleep 2
after_count="$(wc -l < "$child_log")"
if [ "$before_count" != "$after_count" ]; then
    echo "expand timeout left child writer running after leader exited" >&2
    exit 1
fi

# Refuse to run the audit if no process-group-capable launcher is available.
tools="$case_dir/tools-no-setsid"
productsign_log="$case_dir/productsign-no-setsid.log"
diag_dir="$case_dir/no-setsid-diagnostics"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
assert_fails_with 'perl with POSIX::setsid is required' "$case_dir/no-setsid.out" env PATH="$tools:/usr/bin:/bin" ORCHARD_DISABLE_PERL_SETSID_FOR_TEST=1 ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/no-setsid.pkg"
test ! -e "$productsign_log"
assert_grep 'status=125' "$diag_dir/expand-full.status"

printf 'ok\tpayload signing contracts\n'
