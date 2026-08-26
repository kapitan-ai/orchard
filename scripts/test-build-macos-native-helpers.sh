#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-macos-helpers.XXXXXX")"
OUTPUT="$TMP_ROOT/output"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'macOS native-helper build test failed: %s\n' "$1" >&2
  exit 1
}

"$REPO_ROOT/scripts/build-macos-native-helpers.sh" \
  --output "$OUTPUT" \
  --include-test-helper >/dev/null

for helper in orchard-secret-tty orchard-secret-tty-test orchard-lifecycle-helper; do
  if [[ ! -x "$OUTPUT/$helper" ]]; then
    fail "missing executable helper: $helper"
  fi
  if ! file "$OUTPUT/$helper" | grep -Fq 'Mach-O'; then
    fail "helper is not a Mach-O executable: $helper"
  fi
done

"$REPO_ROOT/scripts/build-macos-native-helpers.sh" --output "$OUTPUT" >/dev/null
if [[ -e "$OUTPUT/orchard-secret-tty-test" ]]; then
  fail 'production-only rebuild retained the test helper'
fi

if find "$OUTPUT" -type f \( -name '*.c' -o -name 'Makefile' \) -print -quit | grep -q .; then
  fail 'native-helper build output contains source files'
fi

printf 'macOS native-helper build test passed\n'
