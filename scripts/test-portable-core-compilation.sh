#!/usr/bin/env bash

set -euo pipefail

export MIX_ENV=dev

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-portable-compile.XXXXXX")"
TOOLS="$TMP_ROOT/tools"
XCRUN_MARKER="$TMP_ROOT/xcrun-invoked"
BUILD_LOG="$TMP_ROOT/compile.log"
PREP_LOG="$TMP_ROOT/deps.log"
BUILD_PATH="$REPO_ROOT/_build/$MIX_ENV"
HELPERS_BEFORE="$TMP_ROOT/helpers-before.txt"
HELPERS_AFTER="$TMP_ROOT/helpers-after.txt"
HELPERS_DIFF="$TMP_ROOT/helpers.diff"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'portable core compilation test failed: %s\n' "$1" >&2
  exit 1
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1"
  else
    sha256sum "$1"
  fi
}

record_helper_inventory() {
  local destination="$1"
  local file

  : > "$destination"
  [[ -d "$BUILD_PATH" ]] || return 0

  while IFS= read -r file; do
    printf '%s  %s\n' \
      "$(hash_file "$file" | cut -d' ' -f1)" \
      "${file#"$BUILD_PATH/"}" >> "$destination"
  done < <(find "$BUILD_PATH" -type f \
    \( -name 'orchard-secret-tty*' -o -name 'orchard-lifecycle-helper' \) |
    LC_ALL=C sort)
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

record_helper_inventory "$HELPERS_BEFORE"

if ! PATH="$TOOLS:$PATH" \
  mise exec -- mix compile --force --warnings-as-errors >"$BUILD_LOG" 2>&1; then
  cat "$BUILD_LOG" >&2
  if [[ -e "$XCRUN_MARKER" ]]; then
    fail 'Darwin native-helper compilation entered the portable umbrella compile path'
  fi
  fail 'portable umbrella compilation failed'
fi

if [[ -e "$XCRUN_MARKER" ]]; then
  fail 'portable umbrella compilation invoked xcrun'
fi

record_helper_inventory "$HELPERS_AFTER"

if ! diff -u "$HELPERS_BEFORE" "$HELPERS_AFTER" >"$HELPERS_DIFF"; then
  cat "$HELPERS_DIFF" >&2
  fail 'portable umbrella compilation emitted or changed a Darwin native helper'
fi

printf 'portable core compilation test passed\n'
