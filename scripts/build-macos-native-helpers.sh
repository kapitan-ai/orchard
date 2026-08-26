#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="$REPO_ROOT/packaging/macos/native_helpers"
OUTPUT=""
INCLUDE_TEST_HELPER=false

usage() {
  printf 'Usage: %s --output PATH [--include-test-helper]\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --include-test-helper)
      INCLUDE_TEST_HELPER=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  printf 'build-macos-native-helpers: --output is required\n' >&2
  exit 64
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'build-macos-native-helpers: Darwin host required\n' >&2
  exit 69
fi
if ! xcrun -f clang >/dev/null 2>&1; then
  printf 'build-macos-native-helpers: xcrun could not locate clang\n' >&2
  exit 69
fi
if [[ -L "$OUTPUT" || ( -e "$OUTPUT" && ! -d "$OUTPUT" ) ]]; then
  printf 'build-macos-native-helpers: output must be a real directory: %s\n' "$OUTPUT" >&2
  exit 73
fi

mkdir -p "$OUTPUT"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-macos-helper-build.XXXXXX")"
cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT INT TERM

compile_helper() {
  local source="$1"
  local target="$2"
  shift 2

  xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic -O2 \
    "$@" "$SOURCE_ROOT/$source" -o "$BUILD_ROOT/$target"
  install -m 0755 "$BUILD_ROOT/$target" "$OUTPUT/$target"
}

compile_helper orchard_secret_tty.c orchard-secret-tty
compile_helper orchard_lifecycle_helper.c orchard-lifecycle-helper

if [[ "$INCLUDE_TEST_HELPER" == "true" ]]; then
  compile_helper orchard_secret_tty.c orchard-secret-tty-test \
    -DORCHARD_SECRET_TTY_TEST
else
  rm -f "$OUTPUT/orchard-secret-tty-test"
fi

printf '%s\n' "$OUTPUT"
