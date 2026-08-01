#!/bin/bash
# Focused regression tests for Orchard PKG payload signing and verification contracts.
# These tests use fake Apple tooling and do not contact Apple signing or notarization services.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_ROOT" "$REPO_ROOT/native/orchard_tokenizer/.venv-pkg" "$REPO_ROOT/native/orchard_worker_mlx/.venv-pkg"
}
trap cleanup EXIT

IDENTITY='Developer ID Application: Example, Inc. (TEAMID)'
WRONG_IDENTITY='Developer ID Application: Wrong, Inc. (TEAMID)'
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

write_build_pkg_fakes() {
    local tools="$1"
    mkdir -p "$tools"

    cat > "$tools/git" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'git\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
case "$1" in
  rev-parse) echo abcdef0 ;;
  diff-index) exit 0 ;;
  *) echo "unexpected git invocation: $*" >&2; exit 1 ;;
esac
SH

    cat > "$tools/uv" <<'SH'
#!/bin/sh
set -eu
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'uv\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  printf 'uv %s\n' "$*" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
fi
base="$(basename "$(pwd)")"
case "$base" in
  orchard_tokenizer) bin_name=orchard-tokenizer; pkg_name=orchard_tokenizer; require_extra_mlx=0 ;;
  orchard_worker_mlx) bin_name=orchard-worker-mlx; pkg_name=orchard_worker_mlx; require_extra_mlx=1 ;;
  *) exit 0 ;;
esac
if [ "${UV_PROJECT_ENVIRONMENT:-}" != ".venv-pkg" ]; then
  echo "uv must build packaging venv with UV_PROJECT_ENVIRONMENT=.venv-pkg" >&2
  exit 90
fi
saw_sync=0
saw_locked=0
saw_no_editable=0
saw_extra_mlx=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    sync) saw_sync=1 ;;
    --locked) saw_locked=1 ;;
    --no-editable) saw_no_editable=1 ;;
    --extra)
      shift
      [ "${1:-}" = "mlx" ] && saw_extra_mlx=1
      ;;
  esac
  shift
done
if [ "$saw_sync" != "1" ] || [ "$saw_locked" != "1" ] || [ "$saw_no_editable" != "1" ]; then
  echo "uv sync must use --locked --no-editable for packaging venvs" >&2
  exit 91
fi
if [ "$require_extra_mlx" = "1" ] && [ "$saw_extra_mlx" != "1" ]; then
  echo "orchard_worker_mlx packaging sync must include --extra mlx" >&2
  exit 92
fi
venv=".venv-pkg"
mkdir -p "$venv/bin" "$venv/lib/python3.13/site-packages/$pkg_name"
cat > "$venv/bin/python" <<'PY'
#!/bin/sh
exit 0
PY
cat > "$venv/bin/$bin_name" <<'BIN'
#!/bin/sh
if [ "${1:-}" = "--request-json" ]; then
  printf '%s\n' '{"ok":true,"result":{"compatible":true}}'
fi
exit 0
BIN
chmod +x "$venv/bin/python" "$venv/bin/$bin_name"
printf 'include-system-site-packages = false\nversion = 3.13.5\n' > "$venv/pyvenv.cfg"
: > "$venv/lib/python3.13/site-packages/$pkg_name/__init__.py"
: > "$venv/lib/python3.13/site-packages/$pkg_name/cli.py"
exit 0
SH

    cat > "$tools/find" <<'SH'
#!/bin/sh
pattern="${ORCHARD_FAKE_FIND_FAIL_PATTERN:-}"
kind="${ORCHARD_FAKE_FIND_FAIL_KIND:-any}"
sidecar_root="${ORCHARD_FAKE_FIND_SIDECAR_ROOT:-}"
sidecar_path="${ORCHARD_FAKE_FIND_SIDECAR_PATH:-}"
if [ -n "$sidecar_root" ] && [ -n "$sidecar_path" ]; then
  root_matched=0
  sidecar_query=0
  for arg in "$@"; do
    case "$arg" in
      *"$sidecar_root"*) root_matched=1 ;;
      '._*'|'.DS_Store') sidecar_query=1 ;;
    esac
  done
  if [ "$root_matched" = "1" ] && [ "$sidecar_query" = "1" ]; then
    printf '%s\n' "$sidecar_path"
    exit 0
  fi
fi
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
      mkdir -p "$target/bin" "$target/.venv-pkg/bin" "$target/.venv-pkg/lib/python3.13/site-packages"
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
      case "$base" in
        orchard_tokenizer) pkg_name=orchard_tokenizer ;;
        orchard_worker_mlx) pkg_name=orchard_worker_mlx ;;
        *) pkg_name=orchard_native ;;
      esac
      mkdir -p "$target/.venv-pkg/lib/python3.13/site-packages/$pkg_name"
      cat > "$target/.venv-pkg/bin/python" <<'PY'
#!/bin/sh
exit 0
PY
      cat > "$target/.venv-pkg/bin/$bin_name" <<'BIN'
#!/bin/sh
if [ "${1:-}" = "--request-json" ]; then
  printf '%s\n' '{"ok":true,"result":{"compatible":true}}'
fi
exit 0
BIN
      chmod +x "$target/.venv-pkg/bin/python" "$target/.venv-pkg/bin/$bin_name"
      printf 'include-system-site-packages = false\nversion = 3.13.5\n' > "$target/.venv-pkg/pyvenv.cfg"
      : > "$target/.venv-pkg/lib/python3.13/site-packages/$pkg_name/__init__.py"
      : > "$target/.venv-pkg/lib/python3.13/site-packages/$pkg_name/cli.py"
      exit 0
      ;;
  esac
fi
/bin/cp "$@"
SH

    cat > "$tools/mix" <<'SH'
#!/bin/sh
set -eu
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'mix\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
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
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'file\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
case "$*" in
  *pyvenv.cfg*) echo text/plain ;;
  *) echo application/x-mach-binary ;;
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

    cat > "$tools/codesign" <<'SH'
#!/bin/sh
set -eu
last=""
for arg in "$@"; do
  last="$arg"
done

case "${1:-}" in
  --verify)
    if [ -n "${CODESIGN_LOG:-}" ]; then
      printf 'argv\t%s\n' "$*" >> "$CODESIGN_LOG"
    fi
    if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
      printf 'codesign verify %s\n' "$last" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
    fi
    if [ "${CODESIGN_VERIFY_FAIL:-}" = "1" ]; then
      if [ "${CODESIGN_ECHO_ARGS_ON_FAIL:-}" = "1" ]; then
        echo "codesign verify failed with args: $*" >&2
      else
        echo "codesign verify fail" >&2
      fi
      exit 92
    fi
    exit 0
    ;;
  --display)
    if [ -n "${CODESIGN_LOG:-}" ]; then
      printf 'argv\t%s\n' "$*" >> "$CODESIGN_LOG"
    fi
    if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
      printf 'codesign display %s\n' "$last" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
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
    echo "Signature size=9000" >&2
    echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
    echo "Timestamp=May 12, 2026" >&2
    echo "Authority=${ORCHARD_PAYLOAD_SIGNING_IDENTITY:-Developer ID Application: Example, Inc. (TEAMID)}" >&2
    exit 0
    ;;
esac

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
SH

    cat > "$tools/chmod" <<'SH'
#!/bin/sh
set -eu
/bin/chmod "$@"
pattern="${ORCHARD_FAKE_XATTR_PRE_PKGBUILD_PATTERN:-}"
if [ -n "$pattern" ] && [ "$#" -ge 2 ]; then
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    printf 'pre-pkgbuild-xattr-marker-check %s\n' "$*" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  last=""
  for arg in "$@"; do
    last="$arg"
  done
  case "$last" in
    *"$pattern"*)
      state="${ORCHARD_FAKE_XATTR_PRE_PKGBUILD_STATE:-${TMPDIR:-/tmp}/orchard-fake-pre-pkgbuild-xattr}"
      : > "$state"
      ;;
  esac
fi
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
path_attr_was_scrubbed() {
  target="$1"
  attr="$2"
  state_file="$3"
  [ -f "$state_file" ] || return 1
  while IFS="	" read -r scrubbed_path scrubbed_attr; do
    [ "$target" = "$scrubbed_path" ] && [ "$attr" = "$scrubbed_attr" ] && return 0
  done < "$state_file"
  return 1
}
if [ "${1:-}" = "-d" ] && [ "${2:-}" = "-s" ] && [ "$#" -eq 4 ]; then
  attr="$3"
  path="$4"
  if [ "$attr" = "com.apple.provenance" ]; then
    echo "must not delete immutable provenance" >&2
    exit 90
  fi
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    printf 'xattr -d -s %s %s\n' "$attr" "$path" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  if [ -n "${XATTR_LOG:-}" ]; then
    printf 'xattr -d -s %s %s\n' "$attr" "$path" >> "$XATTR_LOG"
  fi
  if [ "${XATTR_FAIL:-}" = "1" ]; then
    echo "xattr fail" >&2
    exit 93
  fi
  printf '%s\t%s\n' "$path" "$attr" >> "$symlink_scrub_state"
  exit 0
fi
if [ "${1:-}" = "-d" ] && [ "$#" -eq 3 ]; then
  attr="$2"
  path="$3"
  if [ "$attr" = "com.apple.provenance" ]; then
    echo "must not delete immutable provenance" >&2
    exit 90
  fi
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    printf 'xattr -d %s %s\n' "$attr" "$path" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  if [ -n "${XATTR_LOG:-}" ]; then
    printf 'xattr -d %s %s\n' "$attr" "$path" >> "$XATTR_LOG"
  fi
  if [ "${XATTR_FAIL:-}" = "1" ]; then
    echo "xattr fail" >&2
    exit 93
  fi
  printf '%s\t%s\n' "$path" "$attr" >> "$scrub_state"
  exit 0
fi
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "-s" ] && [ "$#" -eq 3 ]; then
  echo "unexpected whole-node symlink xattr clear: $*" >&2
  exit 89
fi
if [ "${1:-}" = "-cr" ] && [ "$#" -eq 2 ]; then
  echo "unexpected recursive xattr clear: $*" >&2
  exit 89
fi
if [ "${1:-}" = "-c" ] && [ "$#" -eq 2 ]; then
  echo "unexpected whole-node xattr clear: $*" >&2
  exit 89
fi
if [ "${1:-}" = "-s" ] && [ "$#" -eq 2 ]; then
  path="$2"
  dirty_pattern="${ORCHARD_FAKE_SYMLINK_XATTR_PATTERN:-}"
  if [ -n "$dirty_pattern" ]; then
    case "$path" in
      *"$dirty_pattern"*)
        path_attr_was_scrubbed "$path" com.apple.quarantine "$symlink_scrub_state" || echo com.apple.quarantine
        ;;
    esac
  fi
  exit 0
fi
if [ "$#" -eq 1 ]; then
  path="$1"
  # ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN models persistent immutable provenance.
  provenance_pattern="${ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN:-}"
  if [ -n "$provenance_pattern" ]; then
    case "$path" in
      *"$provenance_pattern"*)
        echo com.apple.provenance
        ;;
    esac
  fi
  provenance_until_scrub_pattern="${ORCHARD_FAKE_XATTR_PROVENANCE_UNTIL_SCRUB:-}"
  if [ -n "$provenance_until_scrub_pattern" ]; then
    case "$path" in
      *"$provenance_until_scrub_pattern"*)
        echo com.apple.provenance
        ;;
    esac
  fi
  pre_pkgbuild_pattern="${ORCHARD_FAKE_XATTR_PRE_PKGBUILD_PATTERN:-}"
  pre_pkgbuild_state="${ORCHARD_FAKE_XATTR_PRE_PKGBUILD_STATE:-${TMPDIR:-/tmp}/orchard-fake-pre-pkgbuild-xattr}"
  if [ -n "$pre_pkgbuild_pattern" ] && [ -f "$pre_pkgbuild_state" ]; then
    case "$path" in
      *"$pre_pkgbuild_pattern"*)
        echo com.apple.quarantine
        ;;
    esac
  fi
  dirty_pattern="${ORCHARD_FAKE_XATTR_DIRTY_PATTERN:-}"
  if [ -n "$dirty_pattern" ]; then
    case "$path" in
      *"$dirty_pattern"*)
        if [ "${ORCHARD_FAKE_XATTR_DIRTY_UNTIL_SCRUB:-}" = "1" ]; then
          path_attr_was_scrubbed "$path" com.apple.quarantine "$scrub_state" && exit 0
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
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'pkgbuild\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
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
set -eu
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'pkgutil\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi

emit_clean_payload_files() {
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
}

is_repaired_pkg() {
  [ -f "$1" ] && grep -Fqx 'ORCHARD_REPAIRED=1' "$1"
}

write_package_info() {
  pkg="$1"
  dest="$2"
  if [ -f "$pkg" ] && grep -q '<pkg-info' "$pkg"; then
    sed -n '/<pkg-info/,$p' "$pkg" > "$dest/PackageInfo"
    return 0
  fi
  files=8
  kbytes=0
  if [ "${ORCHARD_FAKE_PKGUTIL_SIDECARS:-}" = "1" ] && ! is_repaired_pkg "$pkg"; then
    files=10
  fi
  if [ "${ORCHARD_FAKE_PACKAGEINFO_STALE_COUNT:-}" = "1" ]; then
    files=999
  fi
  if [ "${ORCHARD_FAKE_PACKAGEINFO_STALE_KBYTES:-}" = "1" ]; then
    kbytes=999
  fi
  cat > "$dest/PackageInfo" <<OUT
<pkg-info identifier="com.orchard.pkg" version="9.9.9-test" install-location="/">
  <payload numberOfFiles="$files" installKBytes="$kbytes"/>
</pkg-info>
OUT
}

write_bom_marker() {
  pkg="$1"
  dest="$2"
  if is_repaired_pkg "$pkg"; then
    printf 'clean\n' > "$dest/Bom"
  elif [ "${ORCHARD_FAKE_PKGUTIL_SIDECARS:-}" = "1" ]; then
    printf 'with_sidecars\n' > "$dest/Bom"
  else
    printf 'clean\n' > "$dest/Bom"
  fi
}

if [ "${1:-}" = "--payload-files" ]; then
  pkg="$2"
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    echo "pkgutil --payload-files" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  if [ "${ORCHARD_FAKE_PKGUTIL_SIDECARS:-}" = "1" ] && ! is_repaired_pkg "$pkg"; then
    emit_clean_payload_files
    cat <<'OUT'
./Library/Application Support/Orchard/.DS_Store
./Library/Application Support/Orchard/share/bin/._orchardctl
OUT
    exit 0
  fi
  emit_clean_payload_files
  exit 0
fi
if [ "${1:-}" = "--expand" ]; then
  pkg="$2"
  dest="$3"
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    echo "pkgutil --expand" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  if [ -e "$dest" ]; then
    echo "pkgutil expand destination already exists: $dest" >&2
    exit 97
  fi
  mkdir -p "$dest/Scripts"
  write_bom_marker "$pkg" "$dest"
  : > "$dest/Payload"
  write_package_info "$pkg" "$dest"
  : > "$dest/Scripts/postinstall"
  exit 0
fi
if [ "${1:-}" = "--flatten" ]; then
  src="$2"
  dest="$3"
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    echo "pkgutil --flatten" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  test -f "$src/Bom"
  test -f "$src/Payload"
  test -f "$src/PackageInfo"
  {
    echo 'ORCHARD_REPAIRED=1'
    cat "$src/PackageInfo"
  } > "$dest"
  exit 0
fi
if [ "${1:-}" = "--expand-full" ]; then
  pkg="$2"
  dest="$3"
  if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
    echo "pkgutil --expand-full" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
  fi
  if [ -e "$dest" ]; then
    echo "pkgutil expand destination already exists: $dest" >&2
    exit 97
  fi
  mkdir -p \
    "$dest/Scripts" \
    "$dest/Payload/Library/Application Support/Orchard/share/bin" \
    "$dest/Payload/Library/Application Support/Orchard/share/launchd" \
    "$dest/Payload/Library/Application Support/Orchard/releases/orchard_cli/bin" \
    "$dest/Payload/Library/Application Support/Orchard/releases/orchard_controller/bin" \
    "$dest/Payload/Library/Application Support/Orchard/releases/orchard_node_agent/bin"
  : > "$dest/Scripts/postinstall"
  : > "$dest/Payload/Library/Application Support/Orchard/share/bin/orchardctl"
  : > "$dest/Payload/Library/Application Support/Orchard/share/bin/orchard-controller"
  : > "$dest/Payload/Library/Application Support/Orchard/share/bin/orchard-node-agent"
  : > "$dest/Payload/Library/Application Support/Orchard/share/launchd/com.orchard.controller.plist"
  : > "$dest/Payload/Library/Application Support/Orchard/share/launchd/com.orchard.node-agent.plist"
  : > "$dest/Payload/Library/Application Support/Orchard/releases/orchard_cli/bin/orchard_cli"
  : > "$dest/Payload/Library/Application Support/Orchard/releases/orchard_controller/bin/orchard_controller"
  : > "$dest/Payload/Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent"
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

    cat > "$tools/lsbom" <<'SH'
#!/bin/sh
set -eu
bom="$1"
owner="0/0"
if [ "${ORCHARD_FAKE_LSBOM_OWNER:-}" = "builduser" ]; then
  owner="501/20"
fi
emit_clean_bom() {
  printf '.\t40755\t0/0\n'
  printf './Library\t40755\t0/0\n'
  printf './Library/Application Support\t40755\t0/0\n'
  printf './Library/Application Support/Orchard\t40755\t%s\n' "$owner"
  printf './Library/Application Support/Orchard/share/bin/orchardctl\t100755\t%s\t0\t0\n' "$owner"
  printf './Library/Application Support/Orchard/share/bin/orchard-controller\t100755\t%s\t0\t0\n' "$owner"
  printf './Library/Application Support/Orchard/share/bin/orchard-node-agent\t100755\t%s\t0\t0\n' "$owner"
  printf './Library/Application Support/Orchard/share/launchd/com.orchard.controller.plist\t100644\t%s\t0\t0\n' "$owner"
  printf './Library/Application Support/Orchard/share/launchd/com.orchard.node-agent.plist\t100644\t%s\t0\t0\n' "$owner"
  printf './Library/Application Support/Orchard/releases/orchard_cli/bin/orchard_cli\t100755\t%s\t0\t0\n' "$owner"
  printf './Library/Application Support/Orchard/releases/orchard_controller/bin/orchard_controller\t100755\t%s\t0\t0\n' "$owner"
  printf './Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent\t100755\t%s\t0\t0\n' "$owner"
}
if grep -Fqx 'with_sidecars' "$bom" 2>/dev/null; then
  emit_clean_bom
  printf './Library/Application Support/Orchard/.DS_Store\t100644\t%s\t0\t0\n' "$owner"
  printf './Library/Application Support/Orchard/share/bin/._orchardctl\t100644\t%s\t0\t0\n' "$owner"
  exit 0
fi
if grep -Fqx 'clean' "$bom" 2>/dev/null; then
  emit_clean_bom
  exit 0
fi
cat "$bom"
SH

    cat > "$tools/mkbom" <<'SH'
#!/bin/sh
set -eu
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  printf 'mkbom %s\n' "$*" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
fi
if [ "${1:-}" != "-i" ]; then
  echo "mkbom must preserve metadata with -i filelist" >&2
  exit 85
fi
cp "$2" "$3"
SH

    cat > "$tools/cpio" <<'SH'
#!/bin/sh
set -eu
echo "repair must not regenerate Payload with cpio from staging" >&2
exit 86
SH

    cat > "$tools/tar" <<'SH'
#!/bin/sh
set -eu
mode=""
for arg in "$@"; do
  case "$arg" in
    -cf) mode=create ;;
    -xf) mode=extract ;;
  esac
done
case "$mode" in
  create)
    base="$(basename "$(pwd)")"
    case "$base" in
      orchard_tokenizer|orchard_worker_mlx)
        if [ "${COPYFILE_DISABLE:-}" != "1" ] || [ "${COPY_EXTENDED_ATTRIBUTES_DISABLE:-}" != "1" ]; then
          echo "native helper tar create must suppress macOS copyfile metadata" >&2
          exit 94
        fi
        saw_venv_exclude=0
        for arg in "$@"; do
          [ "$arg" = "--exclude" ] && continue
          [ "$arg" = "./.venv" ] && saw_venv_exclude=1
          [ "$arg" = "--exclude=./.venv" ] && saw_venv_exclude=1
        done
        if [ "$saw_venv_exclude" != "1" ]; then
          echo "native helper tar create must exclude source .venv" >&2
          exit 95
        fi
        if [ ! -x ".venv-pkg/bin/python" ]; then
          echo "fake native tar requires .venv-pkg from uv packaging sync" >&2
          exit 93
        fi
        printf 'ORCHARD_FAKE_NATIVE_HELPER=%s\n' "$base"
        exit 0
        ;;
    esac
    exec /usr/bin/tar "$@"
    ;;
  extract)
    if [ "${COPYFILE_DISABLE:-}" != "1" ] || [ "${COPY_EXTENDED_ATTRIBUTES_DISABLE:-}" != "1" ]; then
      echo "native helper tar extract must suppress macOS copyfile metadata" >&2
      exit 96
    fi
    marker=""
    IFS= read -r marker || true
    case "$marker" in
      ORCHARD_FAKE_NATIVE_HELPER=*) base="${marker#ORCHARD_FAKE_NATIVE_HELPER=}" ;;
      *) exec /usr/bin/tar "$@" ;;
    esac
    case "$base" in
      orchard_tokenizer) bin_name=orchard-tokenizer; pkg_name=orchard_tokenizer ;;
      orchard_worker_mlx) bin_name=orchard-worker-mlx; pkg_name=orchard_worker_mlx ;;
      *) exec /usr/bin/tar "$@" ;;
    esac
    mkdir -p "bin" ".venv-pkg/bin" ".venv-pkg/lib/python3.13/site-packages/$pkg_name"
    if [ "${ORCHARD_FAKE_METADATA_SIDECAR:-}" = "1" ]; then
      : > "._$base"
    fi
    cat > "bin/$bin_name" <<'BIN'
#!/bin/sh
exit 0
BIN
    chmod +x "bin/$bin_name"
    if [ -n "${ORCHARD_FAKE_SYMLINK_XATTR_PATTERN:-}" ]; then
      ln -s "bin/$bin_name" "xattr-symlink"
    fi
    if [ -n "${ORCHARD_FAKE_EXTERNAL_SYMLINK_TARGET:-}" ]; then
      ln -s "$ORCHARD_FAKE_EXTERNAL_SYMLINK_TARGET" "external-target-symlink"
    fi
    cat > ".venv-pkg/bin/python" <<'PY'
#!/bin/sh
exit 0
PY
    cat > ".venv-pkg/bin/$bin_name" <<'BIN'
#!/bin/sh
if [ "${1:-}" = "--request-json" ]; then
  printf '%s\n' '{"ok":true,"result":{"compatible":true}}'
fi
exit 0
BIN
    chmod +x ".venv-pkg/bin/python" ".venv-pkg/bin/$bin_name"
    printf 'include-system-site-packages = false\nversion = 3.13.5\n' > ".venv-pkg/pyvenv.cfg"
    : > ".venv-pkg/lib/python3.13/site-packages/$pkg_name/__init__.py"
    : > ".venv-pkg/lib/python3.13/site-packages/$pkg_name/cli.py"
    exit 0
    ;;
esac
exec /usr/bin/tar "$@"
SH

    cat > "$tools/gzip" <<'SH'
#!/bin/sh
set -eu
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'gzip\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -n "${ORCHARD_FAKE_TOOL_ORDER_LOG:-}" ]; then
  printf 'gzip %s\n' "$*" >> "$ORCHARD_FAKE_TOOL_ORDER_LOG"
fi
if [ "${1:-}" = "-dc" ]; then
  if [ "${ORCHARD_FAKE_PAYLOAD_FORMAT:-newc}" = "odc" ]; then
    perl -e '
      use strict; use warnings;
      my ($uid, $gid) = $ENV{ORCHARD_FAKE_PAYLOAD_OWNER} && $ENV{ORCHARD_FAKE_PAYLOAD_OWNER} eq "builduser" ? (501, 20) : (0, 0);
      sub rec {
        my ($name, $data) = @_;
        $data //= "";
        my $namesize = length($name) + 1;
        my $filesize = length($data);
        printf "070707%06o%06o%06o%06o%06o%06o%06o%011o%06o%011o", 0, 1, 0100644, $uid, $gid, 1, 0, 0, $namesize, $filesize;
        print $name, "\0", $data;
      }
      my @entries = (
        "./Library/Application Support/Orchard/share/bin/orchardctl",
        "./Library/Application Support/Orchard/share/bin/orchard-controller",
        "./Library/Application Support/Orchard/share/bin/orchard-node-agent",
        "./Library/Application Support/Orchard/share/launchd/com.orchard.controller.plist",
        "./Library/Application Support/Orchard/share/launchd/com.orchard.node-agent.plist",
        "./Library/Application Support/Orchard/releases/orchard_cli/bin/orchard_cli",
        "./Library/Application Support/Orchard/releases/orchard_controller/bin/orchard_controller",
        "./Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent"
      );
      rec($_, "payload-data") for @entries;
      if ($ENV{ORCHARD_FAKE_PKGUTIL_SIDECARS}) {
        rec("./Library/Application Support/Orchard/.DS_Store", "sidecar");
        rec("./Library/Application Support/Orchard/share/bin/._orchardctl", "sidecar");
      }
      rec("TRAILER!!!", "");
    '
    exit 0
  fi
  perl -e '
    use strict; use warnings;
    my ($uid, $gid) = $ENV{ORCHARD_FAKE_PAYLOAD_OWNER} && $ENV{ORCHARD_FAKE_PAYLOAD_OWNER} eq "builduser" ? (501, 20) : (0, 0);
    sub rec {
      my ($name) = @_;
      my $namesize = length($name) + 1;
      my $mode = ($name eq "TRAILER!!!" || $name =~ m{/$}) ? 0040755 : 0100644;
      my @fields = (1, $mode, $uid, $gid, 1, 0, 0, 0, 0, 0, 0, $namesize, 0);
      print "070701", join("", map { sprintf("%08X", $_) } @fields);
      print $name, "\0";
      print "\0" x ((4 - ((110 + $namesize) % 4)) % 4);
    }
    my @entries = (
      "./Library/Application Support/Orchard/share/bin/orchardctl",
      "./Library/Application Support/Orchard/share/bin/orchard-controller",
      "./Library/Application Support/Orchard/share/bin/orchard-node-agent",
      "./Library/Application Support/Orchard/share/launchd/com.orchard.controller.plist",
      "./Library/Application Support/Orchard/share/launchd/com.orchard.node-agent.plist",
      "./Library/Application Support/Orchard/releases/orchard_cli/bin/orchard_cli",
      "./Library/Application Support/Orchard/releases/orchard_controller/bin/orchard_controller",
      "./Library/Application Support/Orchard/releases/orchard_node_agent/bin/orchard_node_agent"
    );
    if ($ENV{ORCHARD_FAKE_PKGUTIL_SIDECARS}) {
      push @entries, "./Library/Application Support/Orchard/.DS_Store", "./Library/Application Support/Orchard/share/bin/._orchardctl";
    }
    rec($_) for @entries;
    rec("TRAILER!!!");
  '
  exit 0
fi
last=""
for arg in "$@"; do
  last="$arg"
done
if [ -n "$last" ] && [ -f "$last" ]; then
  cat "$last"
else
  cat
fi
SH

    cat > "$tools/shasum" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'shasum\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
exec /usr/bin/shasum "$@"
SH

    chmod +x "$tools/git" "$tools/uv" "$tools/find" "$tools/cp" "$tools/mix" "$tools/file" "$tools/otool" "$tools/xcrun" "$tools/security" "$tools/codesign" "$tools/chmod" "$tools/xattr" "$tools/pkgbuild" "$tools/pkgutil" "$tools/lsbom" "$tools/mkbom" "$tools/cpio" "$tools/tar" "$tools/gzip" "$tools/shasum"
}

write_sign_pkg_fakes() {
    local tools="$1"
    local mode="$2"
    local log="$3"
    mkdir -p "$tools"

    cat > "$tools/orchard-fake-env-guard" <<'SH'
#!/bin/sh
set -eu
tool_name="${1:-unknown}"
for name in ORCHARD_NOTARY_API_KEY_PATH ORCHARD_NOTARY_API_KEY_ID ORCHARD_NOTARY_API_KEY_TYPE ORCHARD_NOTARY_API_ISSUER_ID; do
  eval "present=\${$name+x}"
  if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
    printf '%s\t%s_present=%s\n' "$tool_name" "$name" "$present" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
  fi
  if [ -n "$present" ]; then
    echo "$tool_name inherited $name" >&2
    exit 97
  fi
done
SH

    cat > "$tools/productsign" <<SH
#!/bin/sh
exec </dev/null
original_args="\$*"
unexpected_productsign() {
  echo "unexpected productsign invocation: \$original_args" >&2
  exit 99
}
if [ -n "\${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'productsign\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "\${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "\$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "\${0%/*}/orchard-fake-env-guard" ]; then
  "\${0%/*}/orchard-fake-env-guard" productsign
fi
if [ -n "\${ORCHARD_KEYCHAIN_PASSWORD+x}" ]; then
  echo "productsign inherited ORCHARD_KEYCHAIN_PASSWORD" >&2
  exit 97
fi
kind=real
last=""
saw_keychain=0
for arg in "\$@"; do
  case "\$arg" in
    orchard-flag-probe-invalid-identity|/dev/null) kind=probe ;;
    --keychain) saw_keychain=1 ;;
  esac
  last="\$arg"
done
case "\$kind" in
  probe)
    if [ "\$#" -ne 6 ] || [ "\${1:-}" != "--sign" ] || [ "\${3:-}" != "--keychain" ] || [ "\${5:-}" != "/dev/null" ] || [ -z "\${6:-}" ]; then
      unexpected_productsign
    fi
    ;;
  real)
    case "\$#" in
      4)
        if [ "\${1:-}" != "--sign" ] || [ -z "\${4:-}" ]; then
          unexpected_productsign
        fi
        ;;
      6)
        if [ "\${1:-}" != "--sign" ] || [ "\${3:-}" != "--keychain" ] || [ -z "\${6:-}" ]; then
          unexpected_productsign
        fi
        ;;
      *) unexpected_productsign ;;
    esac
    ;;
esac
if [ "\$kind" = "probe" ]; then
  printf 'probe\t%s\n' "\$*" >> "$log"
  case "\${PRODUCTSIGN_PROBE_BUCKET:-reject}" in
    accept|validation|keychain-validation) echo "productsign: invalid signing identity" >&2; exit 1 ;;
    reject|unknown) echo "productsign: unknown option --keychain" >&2; exit 64 ;;
    illegal) echo "productsign: illegal option -- keychain" >&2; exit 64 ;;
    empty) exit 0 ;;
    *) echo "productsign: unexpected probe response" >&2; exit 1 ;;
  esac
fi
if [ "\$saw_keychain" = "1" ] && [ "\${ORCHARD_FAKE_PRODUCTSIGN_ALLOW_KEYCHAIN:-}" != "1" ]; then
  echo "productsign must not receive --keychain" >&2
  exit 98
fi
echo "productsign invoked" >> "$log"
printf 'real\t%s\n' "\$*" >> "$log"
printf 'argv\t%s\n' "\$*" >> "$log"
if [ "\$last" = "-" ] || [ -p "\$last" ]; then
  echo "unsafe productsign output target: \$last" >&2
  exit 99
fi
: > "\$last"
exit 0
SH

    cat > "$tools/pkgutil" <<SH
#!/bin/sh
set -eu
if [ -n "\${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'pkgutil\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "\${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "\$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "\${0%/*}/orchard-fake-env-guard" ]; then
  "\${0%/*}/orchard-fake-env-guard" pkgutil
fi
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
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'file\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" file
fi
case "$*" in
  *.pkg) echo application/octet-stream ;;
  *) echo application/x-mach-binary ;;
esac
SH

    cat > "$tools/otool" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'otool\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" otool
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
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'codesign\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" codesign
fi
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

    cat > "$tools/security" <<'SH'
#!/bin/sh
if [ -n "${SECURITY_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$SECURITY_LOG"
fi
case "${1:-}" in
  unlock-keychain) exit "${SECURITY_UNLOCK_EXIT:-0}" ;;
  set-key-partition-list) exit "${SECURITY_PARTITION_EXIT:-0}" ;;
  list-keychains)
    if [ "$#" -ne 1 ]; then
      echo "forbidden persistent keychain mutation: $*" >&2
      exit 99
    fi
    case "${ORCHARD_FAKE_SECURITY_SEARCH_LIST_MODE:-quoted}" in
      quoted) printf '    "%s"\n' "${ORCHARD_FAKE_SECURITY_SEARCH_LIST:-}" ;;
      unquoted) printf '%s\n' "${ORCHARD_FAKE_SECURITY_SEARCH_LIST:-}" ;;
      empty) exit 0 ;;
      fail) echo "security list-keychains failed" >&2; exit 42 ;;
      *) echo "unknown search list mode" >&2; exit 99 ;;
    esac
    ;;
  default-keychain) echo "forbidden persistent keychain mutation: $*" >&2; exit 99 ;;
  *) echo "unexpected security invocation: $*" >&2; exit 99 ;;
esac
SH

    cat > "$tools/xcrun" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'xcrun\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" xcrun
fi
if [ "$1" = "-f" ]; then
  case "$2" in
    codesign|notarytool|stapler) command -v "$2" ; exit 0 ;;
  esac
fi
if [ "$1" = "notarytool" ]; then
  if [ -n "${ORCHARD_KEYCHAIN_PASSWORD+x}" ]; then
    echo "xcrun notarytool inherited ORCHARD_KEYCHAIN_PASSWORD" >&2
    exit 97
  fi
  for arg in "$@"; do
    if [ "$arg" = "--keychain" ]; then
      echo "xcrun notarytool must not receive --keychain" >&2
      exit 98
    fi
  done
  if [ -n "${XCRUN_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$XCRUN_LOG"
  fi
  notary_key=""
  notary_key_id=""
  notary_issuer=""
  notary_next=""
  for arg in "$@"; do
    if [ -n "$notary_next" ]; then
      case "$notary_next" in
        key) notary_key="$arg" ;;
        key-id) notary_key_id="$arg" ;;
        issuer) notary_issuer="$arg" ;;
      esac
      notary_next=""
      continue
    fi
    case "$arg" in
      --key) notary_next=key ;;
      --key-id) notary_next=key-id ;;
      --issuer) notary_next=issuer ;;
    esac
  done
  if [ "${ORCHARD_FAKE_NOTARY_ECHO_AUTH:-}" = "1" ]; then
    printf 'notarytool stderr key=%s key-id=%s issuer=%s\n' "$notary_key" "$notary_key_id" "$notary_issuer" >&2
    printf '{"id":"fake-submission-%s","status":"Accepted","key":"%s","keyId":"%s","issuer":"%s"}\n' "$notary_key_id" "$notary_key" "$notary_key_id" "$notary_issuer"
  else
    printf '{"id":"fake-submission","status":"Accepted"}\n'
  fi
  exit 0
fi
if [ "$1" = "stapler" ]; then
  if [ -n "${ORCHARD_KEYCHAIN_PASSWORD+x}" ]; then
    echo "xcrun stapler inherited ORCHARD_KEYCHAIN_PASSWORD" >&2
    exit 97
  fi
  for arg in "$@"; do
    if [ "$arg" = "--keychain" ]; then
      echo "xcrun stapler must not receive --keychain" >&2
      exit 98
    fi
  done
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
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'stapler\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" stapler
fi
exit 0
SH

    cat > "$tools/shasum" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'shasum\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" shasum
fi
if [ -n "${ORCHARD_KEYCHAIN_PASSWORD+x}" ]; then
  echo "shasum inherited ORCHARD_KEYCHAIN_PASSWORD" >&2
  exit 97
fi
exec /usr/bin/shasum "$@"
SH

    chmod +x "$tools/orchard-fake-env-guard" "$tools/productsign" "$tools/pkgutil" "$tools/file" "$tools/otool" "$tools/codesign" "$tools/security" "$tools/xcrun" "$tools/notarytool" "$tools/stapler" "$tools/shasum"
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

# KC7: build-pkg forwards keychain env to payload signing and verification without xtrace leaks.
tools="$case_dir/build-tools"
write_build_pkg_fakes "$tools"
staging="$case_dir/staging-signed"
out_dir="$case_dir/out"
SECURITY_LOG="$case_dir/build-security.raw.log"
order_log="$case_dir/build-order.log"
build_codesign_log="$case_dir/build-codesign.log"
build_env_presence_log="$case_dir/build-env-presence-password.log"
: > "$SECURITY_LOG"
: > "$build_env_presence_log"
env ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" SECURITY_LOG="$SECURITY_LOG" CODESIGN_LOG="$build_codesign_log" ORCHARD_FAKE_ENV_PRESENCE_LOG="$build_env_presence_log" ORCHARD_FAKE_TOOL_ORDER_LOG="$order_log" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging" PATH="$tools:/usr/bin:/bin" \
    bash -x "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir" >"$case_dir/build-xtrace.out" 2>&1
test "$(grep -c '^unlock-keychain ' "$SECURITY_LOG" || true)" -eq 2
test "$(grep -c '^set-key-partition-list ' "$SECURITY_LOG" || true)" -eq 2
assert_grep "--timestamp --keychain $build_keychain_resolved --sign" "$build_codesign_log"
assert_grep "--verify --strict --verbose=4 --keychain $build_keychain_resolved" "$build_codesign_log"
assert_no_grep "$fixture_password" "$case_dir/build-xtrace.out"
assert_no_grep "$build_keychain_resolved" "$case_dir/build-xtrace.out"
assert_no_grep "$build_keychain" "$case_dir/build-xtrace.out"
for tool_name in git uv mix pkgbuild pkgutil file xcrun codesign shasum; do
    assert_grep "${tool_name}"$'\tORCHARD_KEYCHAIN_PASSWORD_present=' "$build_env_presence_log"
done
assert_no_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=x' "$build_env_presence_log"
sed -e "s|$fixture_password|<redacted-password-token>|g" -e "s|$build_keychain_resolved|$build_keychain_base|g" "$SECURITY_LOG" > "$case_dir/build-security.sanitized.log"

# KC7a: build-pkg fails early when Perl cannot execute.
perl_fail_tools="$case_dir/build-perl-fail-tools"
write_build_pkg_fakes "$perl_fail_tools"
cat > "$perl_fail_tools/perl" <<'SH'
#!/bin/sh
exit 86
SH
chmod +x "$perl_fail_tools/perl"
staging="$case_dir/staging-perl-fail"
out_dir="$case_dir/out-perl-fail"
order_log="$case_dir/build-perl-fail-order.log"
: > "$order_log"
assert_fails_with 'perl failed a basic execution check' "$case_dir/build-perl-fail.out" env ORCHARD_FAKE_TOOL_ORDER_LOG="$order_log" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging" PATH="$perl_fail_tools:/usr/bin:/bin" bash "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_no_grep 'uv ' "$order_log"
assert_no_grep 'mix deps.' "$order_log"
assert_no_grep 'mix compile' "$order_log"
assert_no_grep 'mix release' "$order_log"
assert_no_grep 'pkgbuild ' "$order_log"

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

# KC10: build-pkg preserves env presence semantics when password is unset.
staging="$case_dir/staging-operator-prepared"
out_dir="$case_dir/out-operator-prepared"
SECURITY_LOG="$case_dir/build-operator-security.raw.log"
env_presence_log="$case_dir/build-env-presence.log"
operator_codesign_log="$case_dir/build-operator-codesign.log"
: > "$SECURITY_LOG"
: > "$env_presence_log"
env -u ORCHARD_KEYCHAIN_PASSWORD ORCHARD_BUILD_KEYCHAIN="$build_keychain" SECURITY_LOG="$SECURITY_LOG" CODESIGN_LOG="$operator_codesign_log" ORCHARD_FAKE_ENV_PRESENCE_LOG="$env_presence_log" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging" PATH="$tools:/usr/bin:/bin" \
    bash -x "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir" >"$case_dir/build-operator-xtrace.out" 2>&1
assert_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=' "$env_presence_log"
assert_no_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=x' "$env_presence_log"
assert_no_grep "$build_keychain_resolved" "$case_dir/build-operator-xtrace.out"
assert_no_grep "$build_keychain" "$case_dir/build-operator-xtrace.out"

# KC11: build-pkg treats set-but-empty password as absent while still forwarding a configured keychain.
staging="$case_dir/staging-empty-password"
out_dir="$case_dir/out-empty-password"
SECURITY_LOG="$case_dir/build-empty-password-security.raw.log"
empty_env_presence_log="$case_dir/build-empty-password-env-presence.log"
empty_codesign_log="$case_dir/build-empty-password-codesign.log"
: > "$SECURITY_LOG"
: > "$empty_env_presence_log"
env ORCHARD_BUILD_KEYCHAIN="$build_keychain" ORCHARD_KEYCHAIN_PASSWORD= SECURITY_LOG="$SECURITY_LOG" CODESIGN_LOG="$empty_codesign_log" ORCHARD_FAKE_ENV_PRESENCE_LOG="$empty_env_presence_log" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging" PATH="$tools:/usr/bin:/bin" \
    bash -x "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir" >"$case_dir/build-empty-password-xtrace.out" 2>&1
assert_file_empty "$SECURITY_LOG"
assert_grep "--timestamp --keychain $build_keychain_resolved --sign" "$empty_codesign_log"
assert_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=' "$empty_env_presence_log"
assert_no_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=x' "$empty_env_presence_log"
assert_no_grep "$build_keychain_resolved" "$case_dir/build-empty-password-xtrace.out"
assert_no_grep "$build_keychain" "$case_dir/build-empty-password-xtrace.out"

# KC12: build-pkg discards an accidental password when no build keychain is configured.
staging="$case_dir/staging-password-without-keychain"
out_dir="$case_dir/out-password-without-keychain"
SECURITY_LOG="$case_dir/build-no-keychain-security.raw.log"
no_keychain_env_presence_log="$case_dir/build-no-keychain-env-presence.log"
no_keychain_codesign_log="$case_dir/build-no-keychain-codesign.log"
: > "$SECURITY_LOG"
: > "$no_keychain_env_presence_log"
env ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" SECURITY_LOG="$SECURITY_LOG" CODESIGN_LOG="$no_keychain_codesign_log" ORCHARD_FAKE_ENV_PRESENCE_LOG="$no_keychain_env_presence_log" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging" PATH="$tools:/usr/bin:/bin" \
    bash -x "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir" >"$case_dir/build-no-keychain-xtrace.out" 2>&1
assert_file_empty "$SECURITY_LOG"
assert_no_grep '--keychain' "$no_keychain_codesign_log"
assert_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=' "$no_keychain_env_presence_log"
assert_no_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=x' "$no_keychain_env_presence_log"
assert_no_grep "$fixture_password" "$case_dir/build-no-keychain-xtrace.out"

cat "$case_dir/kc2-sign.out" "$case_dir/kc2-dry.out" "$case_dir/kc3-verify.out" "$case_dir/kc4.out" "$case_dir/kc5.out" "$case_dir/kc5-security.sanitized.log" "$case_dir/kc6.out" "$case_dir/build-xtrace.out" "$case_dir/build-security.sanitized.log" "$case_dir/kc8-sign-xtrace.out" "$case_dir/kc8-verify-xtrace.out" "$case_dir/kc9-sign-fail.out" "$case_dir/kc9-verify-fail.out" "$case_dir/build-operator-xtrace.out" "$case_dir/build-empty-password-xtrace.out" "$case_dir/build-no-keychain-xtrace.out" > "$case_dir/durable-keychain-scan.log"
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

# RED/GREEN: build-pkg stage-only preserves staging, prints one machine-readable path, and skips pkgbuild.
case_dir="$TMP_ROOT/build-stage-only"
tools="$case_dir/tools"
out_dir="$case_dir/out"
build_date="$(date +%Y%m%d)"
staging="$case_dir/staging"
mkdir -p "$case_dir"
write_build_pkg_fakes "$tools"
ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/build.out" 2>&1
stage_line_count="$(grep -c '^STAGING_BASE=' "$case_dir/build.out")"
test "$stage_line_count" -eq 1
assert_grep "STAGING_BASE=$staging" "$case_dir/build.out"
test -d "$staging/Library/Application Support/Orchard"
test -d "$staging/Library/Application Support/Orchard/native/orchard_tokenizer/.venv"
test -d "$staging/Library/Application Support/Orchard/native/orchard_worker_mlx/.venv"
test ! -e "$staging/Library/Application Support/Orchard/native/orchard_tokenizer/.venv-pkg"
test ! -e "$staging/Library/Application Support/Orchard/native/orchard_worker_mlx/.venv-pkg"
test ! -e "$REPO_ROOT/native/orchard_tokenizer/.venv-pkg"
test ! -e "$REPO_ROOT/native/orchard_worker_mlx/.venv-pkg"
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
ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN='native/orchard_tokenizer' XATTR_LOG="$provenance_only_xattr_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_provenance_only" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/provenance-only.out" 2>&1
assert_grep 'STAGING_BASE=' "$case_dir/provenance-only.out"
assert_no_grep 'com.apple.provenance' "$provenance_only_xattr_log"
assert_grep 'Provenance inventory: post-scrub staging xattr_node_count=0 payload_sidecar_count=0' "$case_dir/provenance-only.out"

staging_mixed_xattr="$case_dir/staging-mixed-xattr"
mixed_xattr_log="$case_dir/mixed-xattr.log"
ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN='native/orchard_tokenizer' ORCHARD_FAKE_XATTR_DIRTY_PATTERN='native/orchard_tokenizer' ORCHARD_FAKE_XATTR_DIRTY_UNTIL_SCRUB=1 XATTR_LOG="$mixed_xattr_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_mixed_xattr" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/mixed-xattr.out" 2>&1
assert_grep 'STAGING_BASE=' "$case_dir/mixed-xattr.out"
assert_grep "xattr -d com.apple.quarantine $staging_mixed_xattr/Library/Application Support/Orchard/native/orchard_tokenizer" "$mixed_xattr_log"
assert_no_grep 'xattr -d com.apple.provenance' "$mixed_xattr_log"
assert_grep 'Provenance inventory: post-scrub staging xattr_node_count=0 payload_sidecar_count=0' "$case_dir/mixed-xattr.out"

staging_mixed_xattr_fail="$case_dir/staging-mixed-xattr-fail"
assert_fails_with 'xattr fail' "$case_dir/mixed-xattr-fail.out" env ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN='native/orchard_tokenizer' ORCHARD_FAKE_XATTR_DIRTY_PATTERN='native/orchard_tokenizer' XATTR_FAIL=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_mixed_xattr_fail" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir"

staging_symlink_xattr="$case_dir/staging-symlink-xattr"
symlink_xattr_log="$case_dir/symlink-xattr.log"
ORCHARD_FAKE_SYMLINK_XATTR_PATTERN='xattr-symlink' XATTR_LOG="$symlink_xattr_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_symlink_xattr" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/symlink-xattr.out" 2>&1
stage_line_count="$(grep -c '^STAGING_BASE=' "$case_dir/symlink-xattr.out")"
test "$stage_line_count" -eq 1
assert_grep "STAGING_BASE=$staging_symlink_xattr" "$case_dir/symlink-xattr.out"
assert_grep "xattr -d -s com.apple.quarantine $staging_symlink_xattr/Library/Application Support/Orchard/native/orchard_tokenizer/xattr-symlink" "$symlink_xattr_log"
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
assert_grep "xattr -d -s com.apple.quarantine $staged_external_symlink" "$external_symlink_log"
assert_no_grep "xattr -cr $staging_external_symlink" "$external_symlink_log"
assert_no_grep "external-target-scrubbed $external_target" "$external_symlink_log"

staging_traversal="$case_dir/staging-traversal"
staging_traversal_order="$case_dir/staging-traversal-order.log"
assert_fails_with 'Failed to traverse macOS metadata sidecars under' "$case_dir/staging-traversal.out" env ORCHARD_FAKE_FIND_FAIL_PATTERN="$staging_traversal" ORCHARD_FAKE_FIND_FAIL_KIND=sidecars CODESIGN_LOG="$case_dir/staging-traversal-codesign.log" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_TOOL_ORDER_LOG="$staging_traversal_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_traversal" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_no_grep 'codesign sign ' "$staging_traversal_order"
assert_no_exact_line 'pkgbuild' "$staging_traversal_order"

source_scripts_order="$case_dir/source-scripts-order.log"
assert_fails_with 'Source metadata gate failed for package scripts' "$case_dir/source-scripts.out" env ORCHARD_FAKE_FIND_SIDECAR_ROOT='packaging/pkg/scripts' ORCHARD_FAKE_FIND_SIDECAR_PATH='packaging/pkg/scripts/._postinstall' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_scripts_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-scripts-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'payload_sidecar_count=1' "$case_dir/source-scripts.out"
assert_grep 'packaging/pkg/scripts/._postinstall' "$case_dir/source-scripts.out"
assert_no_grep 'uv ' "$source_scripts_order"
assert_no_grep 'mix release' "$source_scripts_order"
assert_no_exact_line 'pkgbuild' "$source_scripts_order"

source_wrappers_order="$case_dir/source-wrappers-order.log"
assert_fails_with 'Source metadata gate failed for packaging wrappers' "$case_dir/source-wrappers.out" env ORCHARD_FAKE_FIND_SIDECAR_ROOT='packaging/pkg/bin' ORCHARD_FAKE_FIND_SIDECAR_PATH='packaging/pkg/bin/._orchardctl' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_wrappers_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-wrappers-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'payload_sidecar_count=1' "$case_dir/source-wrappers.out"
assert_grep 'packaging/pkg/bin/._orchardctl' "$case_dir/source-wrappers.out"
assert_no_grep 'uv ' "$source_wrappers_order"
assert_no_grep 'mix release' "$source_wrappers_order"
assert_no_exact_line 'pkgbuild' "$source_wrappers_order"

source_wrappers_provenance_only_order="$case_dir/source-wrappers-provenance-only-order.log"
ORCHARD_FAKE_XATTR_PROVENANCE_PATTERN='packaging/pkg/bin/orchard-controller' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_wrappers_provenance_only_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-wrappers-provenance-only-staging" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --stage-only --allow-dirty "$out_dir" >"$case_dir/source-wrappers-provenance-only.out" 2>&1
assert_grep 'Source metadata inventory: packaging wrappers payload_sidecar_count=0' "$case_dir/source-wrappers-provenance-only.out"
assert_grep 'STAGING_BASE=' "$case_dir/source-wrappers-provenance-only.out"
assert_no_exact_line 'pkgbuild' "$source_wrappers_provenance_only_order"

source_launchd_order="$case_dir/source-launchd-order.log"
assert_fails_with 'Source metadata gate failed for launchd plists' "$case_dir/source-launchd.out" env ORCHARD_FAKE_FIND_SIDECAR_ROOT='packaging/launchd' ORCHARD_FAKE_FIND_SIDECAR_PATH='packaging/launchd/._com.orchard.controller.plist' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_launchd_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-launchd-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'payload_sidecar_count=1' "$case_dir/source-launchd.out"
assert_grep 'packaging/launchd/._com.orchard.controller.plist' "$case_dir/source-launchd.out"
assert_no_grep 'uv ' "$source_launchd_order"
assert_no_grep 'mix release' "$source_launchd_order"
assert_no_exact_line 'pkgbuild' "$source_launchd_order"

source_entitlements_order="$case_dir/source-entitlements-order.log"
assert_fails_with 'Source metadata gate failed for payload entitlements' "$case_dir/source-entitlements.out" env ORCHARD_FAKE_FIND_SIDECAR_ROOT='packaging/pkg/entitlements' ORCHARD_FAKE_FIND_SIDECAR_PATH='packaging/pkg/entitlements/._python.entitlements' ORCHARD_FAKE_TOOL_ORDER_LOG="$source_entitlements_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-entitlements-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'payload_sidecar_count=1' "$case_dir/source-entitlements.out"
assert_grep 'packaging/pkg/entitlements/._python.entitlements' "$case_dir/source-entitlements.out"
assert_no_grep 'uv ' "$source_entitlements_order"
assert_no_grep 'mix release' "$source_entitlements_order"
assert_no_exact_line 'pkgbuild' "$source_entitlements_order"

source_traversal_order="$case_dir/source-traversal-order.log"
assert_fails_with 'Failed to traverse macOS metadata sidecars under' "$case_dir/source-traversal.out" env ORCHARD_FAKE_FIND_FAIL_PATTERN='packaging/pkg/bin' ORCHARD_FAKE_FIND_FAIL_KIND=sidecars ORCHARD_FAKE_TOOL_ORDER_LOG="$source_traversal_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$case_dir/source-traversal-staging" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'Source metadata gate failed for packaging wrappers' "$case_dir/source-traversal.out"
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
first_xattr_line="$(grep -n "xattr -d com.apple.quarantine $signed_dirty_path" "$order_log" | sed -n '1s/:.*//p')"
first_sign_line="$(grep -n 'codesign sign ' "$order_log" | sed -n '1s/:.*//p')"
first_verify_line="$(grep -n 'codesign verify ' "$order_log" | sed -n '1s/:.*//p')"
pkgbuild_line="$(grep -n '^pkgbuild$' "$order_log" | sed -n '1s/:.*//p')"
payload_files_line="$(grep -n '^pkgutil --payload-files$' "$order_log" | sed -n '1s/:.*//p')"
metadata_expand_line="$(grep -n '^pkgutil --expand$' "$order_log" | sed -n '1s/:.*//p')"
final_expand_full_line="$(grep -n '^pkgutil --expand-full$' "$order_log" | tail -1 | sed 's/:.*//')"
test "$first_xattr_line" -lt "$first_sign_line"
test "$first_sign_line" -lt "$first_verify_line"
test "$first_verify_line" -lt "$pkgbuild_line"
test "$pkgbuild_line" -lt "$payload_files_line"
test "$payload_files_line" -lt "$metadata_expand_line"
test "$metadata_expand_line" -lt "$final_expand_full_line"
assert_no_grep "xattr -cr $staging_signed" "$order_log"
assert_no_grep 'xattr -d com.apple.provenance' "$order_log"
assert_no_grep 'mkbom ' "$order_log"
assert_no_grep 'cpio ' "$order_log"
if ! find "$out_dir" -name '*.pkg.signing-manifest.txt' -print -quit | grep -q .; then
    echo "signed non-stage build should publish payload signing manifest" >&2
    cat "$case_dir/build-signed.out" >&2
    exit 1
fi

staging_verify_fail="$case_dir/staging-verify-fail"
stale_verify_pkg="$out_dir/Orchard-9.9.9-test-${build_date}-abcdef0.pkg"
printf 'stale pkg\n' > "$stale_verify_pkg"
printf 'stale checksum\n' > "$stale_verify_pkg.sha256"
printf 'stale manifest\n' > "$stale_verify_pkg.signing-manifest.txt"
assert_fails_with 'Payload signature verification failed after metadata scrub' "$case_dir/verify-fail.out" env CODESIGN_VERIFY_FAIL=1 CODESIGN_LOG="$case_dir/codesign-verify-fail.log" ORCHARD_FAKE_TOOL_ORDER_LOG="$case_dir/verify-fail-order.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_verify_fail" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_no_grep 'pkgbuild invoked' "$case_dir/verify-fail.out"
assert_no_grep 'pkgbuild' "$case_dir/verify-fail-order.log"
test ! -e "$stale_verify_pkg"
test ! -e "$stale_verify_pkg.sha256"
test ! -e "$stale_verify_pkg.signing-manifest.txt"

staging_pre_pkgbuild_xattr="$case_dir/staging-pre-pkgbuild-xattr"
pre_pkgbuild_order="$case_dir/pre-pkgbuild-order.log"
pre_pkgbuild_dirty_path="$staging_pre_pkgbuild_xattr/Library/Application Support/Orchard/share/bin/orchardctl"
assert_fails_with 'Provenance gate failed for pre-pkgbuild' "$case_dir/pre-pkgbuild-xattr.out" env ORCHARD_FAKE_XATTR_PRE_PKGBUILD_PATTERN="$pre_pkgbuild_dirty_path" ORCHARD_FAKE_XATTR_PRE_PKGBUILD_STATE="$case_dir/pre-pkgbuild-xattr-state" ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_TOOL_ORDER_LOG="$pre_pkgbuild_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_pre_pkgbuild_xattr" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'xattr_node_count=' "$case_dir/pre-pkgbuild-xattr.out"
assert_grep "$pre_pkgbuild_dirty_path" "$case_dir/pre-pkgbuild-xattr.out"
assert_grep 'pre-pkgbuild-xattr-marker-check' "$pre_pkgbuild_order"
assert_no_exact_line 'pkgbuild' "$pre_pkgbuild_order"

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
stale_pkgbuild_pkg="$out_dir/Orchard-9.9.9-test-${build_date}-abcdef0.pkg"
printf 'stale pkg\n' > "$stale_pkgbuild_pkg"
printf 'stale checksum\n' > "$stale_pkgbuild_pkg.sha256"
printf 'stale manifest\n' > "$stale_pkgbuild_pkg.signing-manifest.txt"
assert_fails_with 'pkgbuild invoked' "$case_dir/pkgbuild-fail.out" env CODESIGN_LOG="$case_dir/codesign-pkgbuild-fail.log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" ORCHARD_PKG_STAGING_BASE="$staging_pkgbuild_fail" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
test ! -e "$stale_pkgbuild_pkg"
test ! -e "$stale_pkgbuild_pkg.sha256"
test ! -e "$stale_pkgbuild_pkg.signing-manifest.txt"
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
pkg_sidecar_out="$case_dir/pkg-sidecar-out"
pkg_sidecar_order="$case_dir/pkg-sidecar-order.log"
ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_PKGUTIL_SIDECARS=1 ORCHARD_FAKE_PAYLOAD_FORMAT=odc ORCHARD_FAKE_TOOL_ORDER_LOG="$pkg_sidecar_order" ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_pkg_sidecar" PATH="$tools:/usr/bin:/bin" \
    "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$pkg_sidecar_out" >"$case_dir/pkg-sidecar.out" 2>&1
assert_grep 'Repairing PKG by filtering 2 macOS metadata sidecar payload entries' "$case_dir/pkg-sidecar.out"
assert_grep 'PKG metadata invariants validated for unsigned PKG' "$case_dir/pkg-sidecar.out"
assert_grep 'mkbom -i ' "$pkg_sidecar_order"
assert_grep 'gzip -dc ' "$pkg_sidecar_order"
assert_no_grep 'cpio ' "$pkg_sidecar_order"
if ! find "$pkg_sidecar_out" -name '*.pkg.sha256' -print -quit | grep -q .; then
    echo "repaired sidecar PKG should publish checksum" >&2
    cat "$case_dir/pkg-sidecar.out" >&2
    exit 1
fi

staging_pkg_builduser_owner="$case_dir/staging-pkg-builduser-owner"
pkg_builduser_owner_out="$case_dir/pkg-builduser-owner-out"
stale_builduser_pkg="$pkg_builduser_owner_out/Orchard-9.9.9-test-${build_date}-abcdef0.pkg"
mkdir -p "$pkg_builduser_owner_out"
printf 'stale pkg\n' > "$stale_builduser_pkg"
printf 'stale checksum\n' > "$stale_builduser_pkg.sha256"
printf 'stale manifest\n' > "$stale_builduser_pkg.signing-manifest.txt"
assert_fails_with 'PKG Bom ownership invariant failed' "$case_dir/pkg-builduser-owner.out" env ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_LSBOM_OWNER=builduser ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_pkg_builduser_owner" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$pkg_builduser_owner_out"
assert_grep 'Removed malformed PKG outputs' "$case_dir/pkg-builduser-owner.out"
test ! -e "$stale_builduser_pkg"
test ! -e "$stale_builduser_pkg.sha256"
test ! -e "$stale_builduser_pkg.signing-manifest.txt"
if find "$pkg_builduser_owner_out" -name '*.pkg.sha256' -print -quit | grep -q .; then
    echo "PKG with build-user Bom ownership must not publish checksum" >&2
    find "$pkg_builduser_owner_out" -name '*.pkg.sha256' >&2
    exit 1
fi

staging_pkg_payload_builduser_owner="$case_dir/staging-pkg-payload-builduser-owner"
pkg_payload_builduser_owner_out="$case_dir/pkg-payload-builduser-owner-out"
assert_fails_with 'PKG Payload ownership invariant failed' "$case_dir/pkg-payload-builduser-owner.out" env ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_PAYLOAD_OWNER=builduser ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_pkg_payload_builduser_owner" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$pkg_payload_builduser_owner_out"
assert_grep 'Removed malformed PKG outputs' "$case_dir/pkg-payload-builduser-owner.out"
if find "$pkg_payload_builduser_owner_out" -name '*.pkg.sha256' -print -quit | grep -q .; then
    echo "PKG with build-user Payload archive ownership must not publish checksum" >&2
    find "$pkg_payload_builduser_owner_out" -name '*.pkg.sha256' >&2
    exit 1
fi

staging_pkg_stale_count="$case_dir/staging-pkg-stale-count"
pkg_stale_count_out="$case_dir/pkg-stale-count-out"
assert_fails_with 'PackageInfo payload numberOfFiles is stale' "$case_dir/pkg-stale-count.out" env ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_PACKAGEINFO_STALE_COUNT=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_pkg_stale_count" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$pkg_stale_count_out"
assert_grep 'Removed malformed PKG outputs' "$case_dir/pkg-stale-count.out"
if find "$pkg_stale_count_out" -name '*.pkg.sha256' -print -quit | grep -q .; then
    echo "PKG with stale PackageInfo numberOfFiles must not publish checksum" >&2
    find "$pkg_stale_count_out" -name '*.pkg.sha256' >&2
    exit 1
fi

staging_pkg_stale_kbytes="$case_dir/staging-pkg-stale-kbytes"
pkg_stale_kbytes_out="$case_dir/pkg-stale-kbytes-out"
assert_fails_with 'PackageInfo payload installKBytes is stale' "$case_dir/pkg-stale-kbytes.out" env ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_PACKAGEINFO_STALE_KBYTES=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_pkg_stale_kbytes" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$pkg_stale_kbytes_out"
assert_grep 'Removed malformed PKG outputs' "$case_dir/pkg-stale-kbytes.out"
if find "$pkg_stale_kbytes_out" -name '*.pkg.sha256' -print -quit | grep -q .; then
    echo "PKG with stale PackageInfo installKBytes must not publish checksum" >&2
    find "$pkg_stale_kbytes_out" -name '*.pkg.sha256' >&2
    exit 1
fi

staging_expanded_sidecar="$case_dir/staging-expanded-sidecar"
assert_fails_with 'Provenance gate failed for unsigned PKG expanded package' "$case_dir/expanded-sidecar.out" env ORCHARD_FAKE_PKGBUILD_SUCCESS=1 ORCHARD_FAKE_EXPANDED_PKG_SIDECAR=1 ORCHARD_PAYLOAD_SIGNING_IDENTITY= ORCHARD_PKG_STAGING_BASE="$staging_expanded_sidecar" PATH="$tools:/usr/bin:/bin" "$REPO_ROOT/scripts/build-pkg.sh" --allow-dirty "$out_dir"
assert_grep 'Scripts/._postinstall' "$case_dir/expanded-sidecar.out"
assert_grep 'Removed malformed PKG outputs' "$case_dir/expanded-sidecar.out"
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
assert_fails_with 'Developer ID Installer identity' "$case_dir/application-envelope.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_PAYLOAD_SIGNING_IDENTITY is required' "$case_dir/missing-payload-dry-run.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY= "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_PAYLOAD_SIGNING_IDENTITY is required' "$case_dir/missing-payload.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY= "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"
assert_fails_with 'Developer ID Application identity' "$case_dir/installer-payload.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$INSTALLER_IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"
assert_fails_with 'Refusing to envelope-sign a PKG with unsigned payload Mach-O binaries' "$case_dir/unsigned-payload.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg"
test ! -e "$productsign_log"

tools="$case_dir/tools-closure"
closure_productsign_log="$case_dir/productsign-closure.log"
closure_output_pkg="$case_dir/Orchard-closure-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$closure_productsign_log"
assert_fails_with 'forbidden Mach-O dependency' "$case_dir/closure.out" env -i OTOOL_CASE=homebrew_dep PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$closure_output_pkg"
test ! -e "$closure_productsign_log"

tools="$case_dir/tools-forbidden-entitlement"
forbidden_productsign_log="$case_dir/productsign-forbidden-entitlement.log"
forbidden_output_pkg="$case_dir/Orchard-forbidden-entitlement-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$forbidden_productsign_log"
assert_fails_with 'forbidden entitlement: com.apple.security.cs.disable-library-validation' "$case_dir/forbidden-entitlement.out" env -i CODESIGN_FORBIDDEN_ENTITLEMENT=1 PATH="$tools:/usr/bin:/bin" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$forbidden_output_pkg"
test ! -e "$forbidden_productsign_log"

# RED/GREEN: sign-pkg notary auth matrix and bounded expansion diagnostics.
# For the focused, always-runnable dry-run API-key Team/Individual contract,
# run scripts/test-sign-pkg-notary-auth.sh.
case_dir="$TMP_ROOT/sign-pkg-notary-auth"
mkdir -p "$case_dir"
input_pkg="$case_dir/Orchard.pkg"
: > "$input_pkg"

tools="$case_dir/tools-profile-default"
productsign_log="$case_dir/productsign-profile-default.log"
xcrun_log="$case_dir/xcrun-profile-default.log"
output_pkg="$case_dir/profile-default-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
env -i PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
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

for productsign_strategy in accept reject; do
    tools="$case_dir/tools-profile-keychain-$productsign_strategy"
    productsign_log="$case_dir/productsign-profile-keychain-$productsign_strategy.log"
    xcrun_log="$case_dir/xcrun-profile-keychain-$productsign_strategy.log"
    sign_pkg_env_presence_log="$case_dir/sign-pkg-keychain-$productsign_strategy-env-presence.log"
    sign_pkg_security_log="$case_dir/sign-pkg-keychain-$productsign_strategy-security.raw.log"
    sign_pkg_keychain_dir="$case_dir/Keychains-$productsign_strategy"
    mkdir -p "$sign_pkg_keychain_dir"
    sign_pkg_keychain="$sign_pkg_keychain_dir/orchard-build.keychain-db"
    : > "$sign_pkg_keychain"
    sign_pkg_keychain_resolved="$(cd "$sign_pkg_keychain_dir" && pwd -P)/orchard-build.keychain-db"
    output_pkg="$case_dir/profile-keychain-$productsign_strategy-signed.pkg"
    : > "$sign_pkg_env_presence_log"
    : > "$sign_pkg_security_log"
    write_sign_pkg_fakes "$tools" ok "$productsign_log"
    env -i PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" SECURITY_LOG="$sign_pkg_security_log" ORCHARD_FAKE_ENV_PRESENCE_LOG="$sign_pkg_env_presence_log" ORCHARD_FAKE_PRODUCTSIGN_ALLOW_KEYCHAIN=1 ORCHARD_FAKE_SECURITY_SEARCH_LIST="$sign_pkg_keychain_resolved" PRODUCTSIGN_PROBE_BUCKET="$productsign_strategy" ORCHARD_BUILD_KEYCHAIN="$sign_pkg_keychain" ORCHARD_KEYCHAIN_PASSWORD="$fixture_password" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
        "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg" >"$case_dir/profile-keychain-$productsign_strategy.out" 2>&1
    test "$(grep -c '^unlock-keychain ' "$sign_pkg_security_log" || true)" -eq 2
    test "$(grep -c '^set-key-partition-list ' "$sign_pkg_security_log" || true)" -eq 2
    assert_no_grep 'list-keychains -' "$sign_pkg_security_log"
    assert_no_grep 'default-keychain' "$sign_pkg_security_log"
    for tool_name in pkgutil file otool codesign xcrun productsign shasum; do
        assert_grep "${tool_name}"$'\tORCHARD_KEYCHAIN_PASSWORD_present=' "$sign_pkg_env_presence_log"
    done
    assert_no_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=x' "$sign_pkg_env_presence_log"
    assert_no_grep 'ORCHARD_NOTARY_API_KEY_PATH_present=x' "$sign_pkg_env_presence_log"
    assert_no_grep 'ORCHARD_NOTARY_API_KEY_ID_present=x' "$sign_pkg_env_presence_log"
    assert_no_grep 'ORCHARD_NOTARY_API_KEY_TYPE_present=x' "$sign_pkg_env_presence_log"
    assert_no_grep 'ORCHARD_NOTARY_API_ISSUER_ID_present=x' "$sign_pkg_env_presence_log"
    assert_grep 'productsign invoked' "$productsign_log"
    if [[ "$productsign_strategy" == "accept" ]]; then
        assert_no_grep 'list-keychains' "$sign_pkg_security_log"
        assert_grep $'real\t'"--sign $INSTALLER_IDENTITY --keychain $sign_pkg_keychain_resolved" "$productsign_log"
    else
        test "$(grep -c '^list-keychains$' "$sign_pkg_security_log" || true)" -eq 1
        if grep -F $'real\t' "$productsign_log" | grep -F ' --keychain ' >/dev/null; then
            echo "Strategy D real productsign argv must omit --keychain" >&2
            cat "$productsign_log" >&2
            exit 1
        fi
    fi
    assert_grep '--keychain-profile orchard-notary' "$xcrun_log"
    assert_no_grep ' --keychain ' "$xcrun_log"
    test -f "$output_pkg"
    test -f "$output_pkg.notary.json"
    test -f "$output_pkg.sha256"
done

tools="$case_dir/tools-profile-explicit"
productsign_log="$case_dir/productsign-profile-explicit.log"
xcrun_log="$case_dir/xcrun-profile-explicit.log"
output_pkg="$case_dir/profile-explicit-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
env -i PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" ORCHARD_NOTARY_AUTH=profile ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$output_pkg" >"$case_dir/profile-explicit.out" 2>&1
assert_grep '--keychain-profile orchard-notary' "$xcrun_log"
assert_no_grep '--key ' "$xcrun_log"
assert_grep 'productsign invoked' "$productsign_log"

tools="$case_dir/tools-api"
productsign_log="$case_dir/productsign-api.log"
xcrun_log="$case_dir/xcrun-api.log"
api_key="$case_dir/AuthKey_TEST.p8"
api_key_id='KEY123'
issuer_id='12345678-1234-1234-1234-123456789abc'
output_pkg="$case_dir/api-signed.pkg"
api_env_presence_log="$case_dir/api-env-presence.log"
api_diag_dir="$case_dir/api-diagnostics"
: > "$api_key"
: > "$api_env_presence_log"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
env -i PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" ORCHARD_FAKE_ENV_PRESENCE_LOG="$api_env_presence_log" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$api_diag_dir" ORCHARD_FAKE_NOTARY_ECHO_AUTH=1 ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=team ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID="$api_key_id" ORCHARD_NOTARY_API_ISSUER_ID="$issuer_id" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$output_pkg" >"$case_dir/api.out" 2>&1
assert_grep "--key $api_key" "$xcrun_log"
assert_grep "--key-id $api_key_id" "$xcrun_log"
assert_grep "--issuer $issuer_id" "$xcrun_log"
assert_grep '--output-format json' "$xcrun_log"
assert_no_grep '--keychain-profile' "$xcrun_log"
assert_grep 'productsign invoked' "$productsign_log"
assert_grep '<notary-api-key>' "$case_dir/api.out"
assert_grep '<notary-api-key-id>' "$case_dir/api.out"
assert_grep '<notary-issuer-id>' "$case_dir/api.out"
assert_grep '<notary-api-key>' "$output_pkg.notary.json"
assert_grep '<notary-api-key-id>' "$output_pkg.notary.json"
assert_grep '<notary-issuer-id>' "$output_pkg.notary.json"
assert_grep 'fake-submission' "$output_pkg.notary.json"
assert_grep 'Accepted' "$output_pkg.notary.json"
cat "$case_dir/api.out" "$output_pkg.notary.json" "$output_pkg.sha256" "$api_diag_dir"/* > "$case_dir/api-product-durable-combined.log"
assert_no_grep "$api_key" "$case_dir/api-product-durable-combined.log"
assert_no_grep "$api_key_id" "$case_dir/api-product-durable-combined.log"
assert_no_grep "$issuer_id" "$case_dir/api-product-durable-combined.log"
assert_no_grep 'ORCHARD_NOTARY_API_KEY_PATH_present=x' "$api_env_presence_log"
assert_no_grep 'ORCHARD_NOTARY_API_KEY_ID_present=x' "$api_env_presence_log"
assert_no_grep 'ORCHARD_NOTARY_API_KEY_TYPE_present=x' "$api_env_presence_log"
assert_no_grep 'ORCHARD_NOTARY_API_ISSUER_ID_present=x' "$api_env_presence_log"

tools="$case_dir/tools-api-xtrace"
productsign_log="$case_dir/productsign-api-xtrace.log"
xcrun_log="$case_dir/xcrun-api-xtrace.log"
output_pkg="$case_dir/api-xtrace-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
env -i PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=team ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=12345678-1234-1234-1234-123456789abc ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    bash -x "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$output_pkg" >"$case_dir/api-xtrace.out" 2>&1
assert_grep "--key $api_key" "$xcrun_log"
assert_grep '--key-id KEY123' "$xcrun_log"
assert_grep '--issuer 12345678-1234-1234-1234-123456789abc' "$xcrun_log"
assert_no_grep "$api_key" "$case_dir/api-xtrace.out"
assert_no_grep 'KEY123' "$case_dir/api-xtrace.out"
assert_no_grep '12345678-1234-1234-1234-123456789abc' "$case_dir/api-xtrace.out"

tools="$case_dir/tools-api-individual"
productsign_log="$case_dir/productsign-api-individual.log"
xcrun_log="$case_dir/xcrun-api-individual.log"
output_pkg="$case_dir/api-individual-signed.pkg"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
env -i PATH="$tools:/usr/bin:/bin" XCRUN_LOG="$xcrun_log" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=individual ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=stale-non-uuid ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$output_pkg" >"$case_dir/api-individual.out" 2>&1
assert_grep "--key $api_key" "$xcrun_log"
assert_grep '--key-id KEY123' "$xcrun_log"
assert_no_grep '--issuer' "$xcrun_log"
assert_grep '--output-format json' "$xcrun_log"
assert_no_grep '--keychain-profile' "$xcrun_log"
assert_grep 'productsign invoked' "$productsign_log"

tools="$case_dir/tools-api-missing"
productsign_log="$case_dir/productsign-api-missing.log"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_KEY_PATH is required' "$case_dir/api-missing-path.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=ISSUER123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-missing-path.pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_KEY_ID is required' "$case_dir/api-missing-id.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_ISSUER_ID=ISSUER123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-missing-id.pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_ISSUER_ID must be a UUID' "$case_dir/api-invalid-issuer.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=auto ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=not-a-uuid ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-invalid-issuer.pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_ISSUER_ID must be a UUID' "$case_dir/api-auto-nonhex-issuer.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=auto ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-auto-nonhex-issuer.pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_ISSUER_ID must be a UUID' "$case_dir/api-team-nonhex-issuer.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=team ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-team-nonhex-issuer.pkg"
test ! -e "$productsign_log"
assert_fails_with 'ORCHARD_NOTARY_API_ISSUER_ID is required' "$case_dir/api-team-missing-issuer.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=team ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-team-missing-issuer.pkg"
test ! -e "$productsign_log"
assert_fails_with 'Unsupported ORCHARD_NOTARY_API_KEY_TYPE' "$case_dir/api-unsupported-key-type.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=enterprise ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-unsupported-key-type.pkg"
test ! -e "$productsign_log"
assert_fails_with 'Unsupported ORCHARD_NOTARY_AUTH' "$case_dir/auth-unsupported.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=bogus ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/auth-unsupported.pkg"
test ! -e "$productsign_log"
missing_api_key="$case_dir/missing.p8"
assert_fails_with 'App Store Connect API key does not exist: <notary-api-key>' "$case_dir/api-missing-file.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=individual ORCHARD_NOTARY_API_KEY_PATH="$missing_api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/api-missing-file.pkg"
assert_no_grep "$missing_api_key" "$case_dir/api-missing-file.out"
test ! -e "$productsign_log"

tools="$case_dir/tools-dry"
productsign_log="$case_dir/productsign-dry.log"
write_sign_pkg_fakes "$tools" ok "$productsign_log"
env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=12345678-1234-1234-1234-123456789abc ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/dry.pkg" >"$case_dir/dry.out" 2>&1
assert_grep '--key' "$case_dir/dry.out"
assert_grep '\<notary-api-key\>' "$case_dir/dry.out"
assert_grep '--key-id' "$case_dir/dry.out"
assert_grep '\<notary-api-key-id\>' "$case_dir/dry.out"
assert_grep '--issuer' "$case_dir/dry.out"
assert_grep '\<notary-issuer-id\>' "$case_dir/dry.out"
assert_grep '--output-format' "$case_dir/dry.out"
assert_no_grep "$api_key" "$case_dir/dry.out"
assert_no_grep 'KEY123' "$case_dir/dry.out"
assert_no_grep '12345678-1234-1234-1234-123456789abc' "$case_dir/dry.out"
test ! -e "$productsign_log"

env -i PATH="$tools:/usr/bin:/bin" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=individual ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID=KEY123 ORCHARD_NOTARY_API_ISSUER_ID=stale-non-uuid ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run --identity "$INSTALLER_IDENTITY" --input "$input_pkg" --output "$case_dir/dry-individual.pkg" >"$case_dir/dry-individual.out" 2>&1
assert_grep '--key' "$case_dir/dry-individual.out"
assert_grep '\<notary-api-key\>' "$case_dir/dry-individual.out"
assert_grep '--key-id' "$case_dir/dry-individual.out"
assert_grep '\<notary-api-key-id\>' "$case_dir/dry-individual.out"
assert_no_grep '--issuer' "$case_dir/dry-individual.out"
assert_grep '--output-format' "$case_dir/dry-individual.out"
assert_no_grep "$api_key" "$case_dir/dry-individual.out"
assert_no_grep 'KEY123' "$case_dir/dry-individual.out"
assert_no_grep 'stale-non-uuid' "$case_dir/dry-individual.out"
test ! -e "$productsign_log"

tools="$case_dir/tools-expand-fail"
productsign_log="$case_dir/productsign-expand-fail.log"
diag_dir="$case_dir/expand-fail-diagnostics"
write_sign_pkg_fakes "$tools" fail_expand "$productsign_log"
assert_fails_with 'pkgutil --expand-full failed during payload audit' "$case_dir/expand-fail.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/expand-fail.pkg"
test ! -e "$productsign_log"
assert_grep 'status=42' "$diag_dir/expand-full.status"
assert_grep 'fake expand failure' "$diag_dir/expand-full.stderr"

assert_fails_with 'Diagnostics directory already exists' "$case_dir/diag-reuse.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/diag-reuse.pkg"

tools="$case_dir/tools-expand-timeout"
productsign_log="$case_dir/productsign-expand-timeout.log"
diag_dir="$case_dir/expand-timeout-diagnostics"
write_sign_pkg_fakes "$tools" sleep_expand "$productsign_log"
child_log="$case_dir/expand-timeout-child.log"
start_epoch="$(date +%s)"
assert_fails_with 'Timed out expanding PKG for payload audit' "$case_dir/expand-timeout.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_FAKE_EXPAND_CHILD_LOG="$child_log" ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS=1 ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/expand-timeout.pkg"
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
assert_fails_with 'Timed out expanding PKG for payload audit' "$case_dir/expand-child-survives.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_FAKE_EXPAND_CHILD_LOG="$child_log" ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS=1 ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/expand-child-survives.pkg"
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
assert_fails_with 'perl with POSIX::setsid is required' "$case_dir/no-setsid.out" env -i PATH="$tools:/usr/bin:/bin" ORCHARD_DISABLE_PERL_SETSID_FOR_TEST=1 ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" "$REPO_ROOT/scripts/sign-pkg.sh" --identity "$INSTALLER_IDENTITY" --notary-profile orchard-notary --input "$input_pkg" --output "$case_dir/no-setsid.pkg"
test ! -e "$productsign_log"
assert_grep 'status=125' "$diag_dir/expand-full.status"

printf 'ok\tpayload signing contracts\n'
