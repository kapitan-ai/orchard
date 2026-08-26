#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-portable-compile.XXXXXX")"
TOOLS="$TMP_ROOT/tools"
XCRUN_MARKER="$TMP_ROOT/xcrun-invoked"
BUILD_LOG="$TMP_ROOT/compile.log"
PREP_LOG="$TMP_ROOT/deps.log"
BUILD_PATH="$REPO_ROOT/_build/dev"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'portable core compilation test failed: %s\n' "$1" >&2
  exit 1
}

mkdir -p "$TOOLS"
cat > "$TOOLS/xcrun" <<SH
#!/bin/sh
: > "$XCRUN_MARKER"
printf 'portable compilation invoked Darwin tooling: %s\n' "\$*" >&2
exit 97
SH
chmod 0755 "$TOOLS/xcrun"

cd "$REPO_ROOT"
if ! mise exec -- mix deps.compile >"$PREP_LOG" 2>&1; then
  cat "$PREP_LOG" >&2
  fail 'dependency compilation failed before the portable boundary test'
fi

mise exec -- mix clean

if ! PATH="$TOOLS:$PATH" \
  mise exec -- mix compile --warnings-as-errors >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  if [[ -e "$XCRUN_MARKER" ]]; then
    fail 'Darwin native-helper compilation entered the portable umbrella compile path'
  fi
  fail 'portable umbrella compilation failed'
fi

if [[ -e "$XCRUN_MARKER" ]]; then
  fail 'portable umbrella compilation invoked xcrun'
fi

if find "$BUILD_PATH" -type f \
  \( -name 'orchard-secret-tty*' -o -name 'orchard-lifecycle-helper' \) \
  -print -quit | grep -q .; then
  fail 'portable umbrella compilation emitted a Darwin native helper'
fi

printf 'portable core compilation test passed\n'
