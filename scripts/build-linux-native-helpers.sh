#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ROOT="$REPO_ROOT/packaging/native_helpers"
OUTPUT=""
INCLUDE_TEST_HELPER=false
CC="${CC:-cc}"

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
  printf 'build-linux-native-helpers: --output is required\n' >&2
  exit 64
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'build-linux-native-helpers: Linux host required\n' >&2
  exit 69
fi
if ! command -v "$CC" >/dev/null 2>&1; then
  printf 'build-linux-native-helpers: C compiler not found: %s\n' "$CC" >&2
  exit 69
fi
if [[ -L "$OUTPUT" || ( -e "$OUTPUT" && ! -d "$OUTPUT" ) ]]; then
  printf 'build-linux-native-helpers: output must be a real directory: %s\n' "$OUTPUT" >&2
  exit 73
fi

mkdir -p "$OUTPUT"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-linux-helper-build.XXXXXX")"
cleanup() {
  rm -rf "$BUILD_ROOT"
}
trap cleanup EXIT INT TERM

compile_helper() {
  local target="$1"
  shift

  "$CC" -std=c11 -Wall -Wextra -Werror -pedantic -O2 \
    "$@" "$SOURCE_ROOT/orchard_transport_publish.c" -o "$BUILD_ROOT/$target"
  install -m 0755 "$BUILD_ROOT/$target" "$OUTPUT/$target"
}

compile_helper orchard-transport-publish

if [[ "$INCLUDE_TEST_HELPER" == "true" ]]; then
  compile_helper orchard-transport-publish-test -DORCHARD_TRANSPORT_PUBLISH_TEST
else
  rm -f "$OUTPUT/orchard-transport-publish-test"
fi

printf '%s\n' "$OUTPUT"
