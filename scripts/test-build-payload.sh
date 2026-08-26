#!/bin/bash
# Behavioral regression test for scripts/build-payload.sh.
# It runs the real payload build against a fake git/uv/mix toolchain, then
# asserts the emitted PAYLOAD_ROOT handoff and the resulting staging tree.
# No Apple signing, notarization, or network access is involved.

set -euo pipefail

# Keep the run hermetic: a developer shell may export real signing credentials,
# and this test must never reach Apple tooling or a real keychain.
unset ORCHARD_PAYLOAD_SIGNING_IDENTITY
unset ORCHARD_BUILD_KEYCHAIN
unset ORCHARD_KEYCHAIN_PASSWORD
unset ORCHARD_BUILD_CHANNEL

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-build-payload.XXXXXX")"
cleanup() {
    rm -rf \
        "$TMP_ROOT" \
        "$REPO_ROOT/native/orchard_tokenizer/.venv-pkg" \
        "$REPO_ROOT/native/orchard_worker_mlx/.venv-pkg" \
        "$REPO_ROOT/_build/prod/rel/orchard_controller" \
        "$REPO_ROOT/_build/prod/rel/orchard_node_agent" \
        "$REPO_ROOT/_build/prod/rel/orchard_cli" \
        "$REPO_ROOT/_build/prod/lib/orchard_cli/priv/orchard-secret-tty-test"
}
trap cleanup EXIT INT TERM

FAKE_SHA=abcdef0123456789abcdef0123456789abcdef01
SHORT_SHA="${FAKE_SHA:0:7}"
FAKE_VERSION=9.9.9-test

TOOLS="$TMP_ROOT/tools"
OUT_DIR="$TMP_ROOT/out"
PKG_TOOL_LOG="$TMP_ROOT/pkg-tools.log"
mkdir -p "$TOOLS"
: > "$PKG_TOOL_LOG"

fail() {
    printf 'test-build-payload: %s\n' "$1" >&2
    exit 1
}

cat > "$TOOLS/git" <<SH
#!/bin/sh
case "\$1" in
  rev-parse) echo $FAKE_SHA ;;
  status) : ;;
  *) echo "unexpected git invocation: \$*" >&2; exit 1 ;;
esac
SH

cat > "$TOOLS/uv" <<'SH'
#!/bin/sh
set -eu
base="$(basename "$(pwd)")"
case "$base" in
  orchard_tokenizer) bin_name=orchard-tokenizer; pkg_name=orchard_tokenizer; require_extra_mlx=0 ;;
  orchard_worker_mlx) bin_name=orchard-worker-mlx; pkg_name=orchard_worker_mlx; require_extra_mlx=1 ;;
  *) exit 0 ;;
esac
if [ "${UV_PROJECT_ENVIRONMENT:-}" != ".venv-pkg" ]; then
  echo "uv must build the packaging venv with UV_PROJECT_ENVIRONMENT=.venv-pkg" >&2
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

cat > "$TOOLS/mix" <<SH
#!/bin/sh
set -eu
if [ "\${1:-}" = "run" ]; then
  echo $FAKE_VERSION
  exit 0
fi
case "\${1:-}" in
  deps.get|assets.setup|assets.deploy) exit 0 ;;
esac
if [ "\${1:-}" = "release" ]; then
  release="\$2"
  root="\$(pwd)"
  mkdir -p "\$root/_build/prod/rel/\$release/bin" "\$root/_build/prod/rel/\$release/erts-16.4/bin"
  cat > "\$root/_build/prod/rel/\$release/bin/\$release" <<'BIN'
#!/bin/sh
exit 0
BIN
  chmod +x "\$root/_build/prod/rel/\$release/bin/\$release"
  : > "\$root/_build/prod/rel/\$release/erts-16.4/bin/beam.smp"
  if { [ "\$release" = "orchard_cli" ] || [ "\$release" = "orchard_controller" ]; } &&
    [ -d "\$root/_build/prod/lib/orchard_cli/priv" ]; then
    app_root="\$root/_build/prod/rel/\$release/lib/orchard_cli-$FAKE_VERSION"
    mkdir -p "\$app_root"
    cp -R "\$root/_build/prod/lib/orchard_cli/priv" "\$app_root/priv"
  fi
  exit 0
fi
echo "unexpected mix invocation: \$*" >&2
exit 1
SH

# The staged tree holds shell stubs rather than real Mach-O binaries, so the
# closure verifier needs Mach-O classification and load commands stubbed out.
cat > "$TOOLS/file" <<'SH'
#!/bin/sh
case "$*" in
  *pyvenv.cfg*|*.py|*.plist|*.txt|*.json) echo text/plain ;;
  *) echo application/x-mach-binary ;;
esac
SH

cat > "$TOOLS/otool" <<'SH'
#!/bin/sh
target=""
for arg in "$@"; do
  target="$arg"
done
case "$target" in
  *libcrypto*.dylib|*libssl*.dylib) exit 0 ;;
esac
exit 0
SH

chmod +x "$TOOLS/file" "$TOOLS/otool"

# Native packaging must never reach for PKG tooling. These record any attempt.
for pkg_tool in pkgbuild productbuild productsign pkgutil installer; do
    cat > "$TOOLS/$pkg_tool" <<SH
#!/bin/sh
printf '%s %s\n' "$pkg_tool" "\$*" >> "$PKG_TOOL_LOG"
exit 1
SH
    chmod +x "$TOOLS/$pkg_tool"
done

chmod +x "$TOOLS/git" "$TOOLS/uv" "$TOOLS/mix"

mkdir -p "$REPO_ROOT/_build/prod/lib/orchard_cli/priv"
: > "$REPO_ROOT/_build/prod/lib/orchard_cli/priv/orchard-secret-tty-test"

BUILD_OUT="$TMP_ROOT/build.out"
if ! PATH="$TOOLS:$PATH" "$REPO_ROOT/scripts/build-payload.sh" "$OUT_DIR" \
    >"$BUILD_OUT" 2>&1; then
    cat "$BUILD_OUT" >&2
    fail 'payload build failed'
fi

payload_root_lines="$(grep -c '^PAYLOAD_ROOT=' "$BUILD_OUT" || true)"
if [[ "$payload_root_lines" -ne 1 ]]; then
    cat "$BUILD_OUT" >&2
    fail "expected exactly one PAYLOAD_ROOT line, saw $payload_root_lines"
fi

PAYLOAD_ROOT="$(grep '^PAYLOAD_ROOT=' "$BUILD_OUT" | sed 's/^PAYLOAD_ROOT=//')"
EXPECTED_STAGING_BASE="$OUT_DIR/Orchard-$FAKE_VERSION-$(date +%Y%m%d)-$SHORT_SHA"
EXPECTED_PAYLOAD_ROOT="$EXPECTED_STAGING_BASE/Library/Application Support/Orchard"

if [[ "$PAYLOAD_ROOT" != "$EXPECTED_PAYLOAD_ROOT" ]]; then
    fail "PAYLOAD_ROOT mismatch: printed '$PAYLOAD_ROOT', expected '$EXPECTED_PAYLOAD_ROOT'"
fi

# The printed path is the handoff contract with scripts/build-app.sh, so it must
# name a real staged tree rather than a value the build merely intended.
test -d "$PAYLOAD_ROOT" || fail 'PAYLOAD_ROOT does not name a directory'

for staged in \
    "share/bin/orchardctl" \
    "share/bin/orchard-controller" \
    "share/bin/orchard-node-agent" \
    "share/bin/orchard-managed-postgres" \
    "share/launchd/com.orchard.controller.plist" \
    "share/launchd/com.orchard.node-agent.plist" \
    "releases/orchard_cli/bin/orchard_cli" \
    "releases/orchard_controller/bin/orchard_controller" \
    "releases/orchard_node_agent/bin/orchard_node_agent" \
    "native/orchard_tokenizer/.venv/bin/orchard-tokenizer" \
    "native/orchard_worker_mlx/.venv/bin/orchard-worker-mlx"; do
    test -e "$PAYLOAD_ROOT/$staged" || fail "missing staged payload path: $staged"
done

for staged_command in orchardctl orchard-controller orchard-node-agent orchard-managed-postgres; do
    test -x "$PAYLOAD_ROOT/share/bin/$staged_command" ||
        fail "staged command is not executable: $staged_command"
    cmp -s "$REPO_ROOT/packaging/payload/bin/$staged_command" \
        "$PAYLOAD_ROOT/share/bin/$staged_command" ||
        fail "staged command differs from packaging/payload/bin/$staged_command"
done

for helper in orchard-secret-tty orchard-lifecycle-helper; do
    helper_path="$(find "$PAYLOAD_ROOT/releases/orchard_cli/lib" \
        -path "*/priv/$helper" -type f -print -quit 2>/dev/null || true)"
    test -n "$helper_path" || fail "missing staged macOS native helper: $helper"
    test -x "$helper_path" || fail "staged macOS native helper is not executable: $helper"
done

if find "$PAYLOAD_ROOT" -name 'orchard-secret-tty-test' -print -quit | grep -q .; then
    fail 'payload staged the test-only terminal helper'
fi

# Darwin helper sources build into binaries outside the payload; neither the
# helper sources nor any make recipe may reach the staged tree.
for helper_source in orchard_secret_tty.c orchard_lifecycle_helper.c; do
    if find "$PAYLOAD_ROOT" -name "$helper_source" -print -quit | grep -q .; then
        fail "payload staged a Darwin native helper source: $helper_source"
    fi
done

# Scoped to the staged releases so the sweep cannot trip over C sources that
# legitimately ship inside the staged Python environments under native/.
# Residual harness limitation: release trees here come from the fake mix stub,
# so this sweep guards the contract rather than exercising a real release.
# scripts/test-payload-orchardctl-console-pty.sh stages a genuine release.
staged_source="$(find "$PAYLOAD_ROOT/releases" -type f \
    \( -name '*.c' -o -name 'Makefile' \) -print -quit 2>/dev/null || true)"
if [[ -n "$staged_source" ]]; then
    fail "staged release tree contains native build inputs: $staged_source"
fi

# Managed Postgres has no LaunchDaemon until Managed Database Mode ships.
if [[ -e "$PAYLOAD_ROOT/share/launchd/com.orchard.postgres.plist" ]]; then
    fail 'managed Postgres LaunchDaemon must not be staged'
fi

# Packaging venvs are renamed into place; no build-only .venv-pkg may survive.
if find "$EXPECTED_STAGING_BASE" -name '.venv-pkg' -print -quit | grep -q .; then
    fail 'staged payload retains a build-only .venv-pkg directory'
fi

# Native helper sources must not ship alongside the built venvs.
for source_dir in \
    "native/orchard_tokenizer/src" \
    "native/orchard_tokenizer/tests" \
    "native/orchard_worker_mlx/src" \
    "native/orchard_worker_mlx/tests" \
    "native/orchard_worker_mlx/proto"; do
    if [[ -e "$PAYLOAD_ROOT/$source_dir" ]]; then
        fail "native helper source staged into payload: $source_dir"
    fi
done

if find "$OUT_DIR" -name '*.pkg' -print -quit | grep -q .; then
    fail 'payload build produced a PKG artifact'
fi

if [[ -s "$PKG_TOOL_LOG" ]]; then
    cat "$PKG_TOOL_LOG" >&2
    fail 'payload build invoked PKG tooling'
fi

# Re-running into an occupied staging path must fail closed rather than merge
# into or overwrite a previously validated payload.
RERUN_OUT="$TMP_ROOT/rerun.out"
if PATH="$TOOLS:$PATH" "$REPO_ROOT/scripts/build-payload.sh" "$OUT_DIR" \
    >"$RERUN_OUT" 2>&1; then
    fail 'payload build overwrote an existing staging path'
fi
grep -Fq 'Selected staging path already exists' "$RERUN_OUT" ||
    fail 'occupied staging path did not report the expected refusal'
test -e "$PAYLOAD_ROOT/share/bin/orchardctl" ||
    fail 'refused rerun damaged the existing staged payload'

# A dirty source tree without --allow-dirty must not produce a payload.
DIRTY_OUT_DIR="$TMP_ROOT/dirty-out"
DIRTY_OUT="$TMP_ROOT/dirty.out"
cat > "$TOOLS/git" <<SH
#!/bin/sh
case "\$1" in
  rev-parse) echo $FAKE_SHA ;;
  status) printf ' M fake-source\n' ;;
  *) echo "unexpected git invocation: \$*" >&2; exit 1 ;;
esac
SH
chmod +x "$TOOLS/git"
if PATH="$TOOLS:$PATH" "$REPO_ROOT/scripts/build-payload.sh" "$DIRTY_OUT_DIR" \
    >"$DIRTY_OUT" 2>&1; then
    fail 'dirty build inputs produced a payload without --allow-dirty'
fi
grep -Fq 'Uncommitted or untracked build inputs detected' "$DIRTY_OUT" ||
    fail 'dirty build inputs did not report the expected refusal'
if grep -q '^PAYLOAD_ROOT=' "$DIRTY_OUT"; then
    fail 'refused dirty build still printed PAYLOAD_ROOT'
fi

printf 'payload build integration test passed\n'
