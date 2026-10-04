#!/usr/bin/env bash
# Explicit source-development helper only; no installation or distribution.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$REPO_ROOT/.local/linux-node-root-guardian"
INCLUDE_TEST_HELPER=false
CC="${CC:-cc}"

usage() {
  printf 'Usage: %s [--output DIR] [--include-test-helper]\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage >&2; exit 64; }
      OUTPUT="$2"
      shift 2
      ;;
    --include-test-helper) INCLUDE_TEST_HELPER=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

if [[ "$(uname -s)" != Linux ]]; then
  printf 'build-linux-node-root-guardian: Linux host required\n' >&2
  exit 69
fi
command -v "$CC" >/dev/null 2>&1 || { printf 'C compiler unavailable\n' >&2; exit 69; }
if [[ -L "$OUTPUT" || ( -e "$OUTPUT" && ! -d "$OUTPUT" ) ]]; then
  printf 'build-linux-node-root-guardian: output directory refused\n' >&2
  exit 73
fi
mkdir -p "$OUTPUT"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-root-guardian-build.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

compile() {
  local name="$1"
  shift
  "$CC" -std=c11 -Wall -Wextra -Werror -pedantic -O2 "$@" \
    "$REPO_ROOT/packaging/native_helpers/orchard_node_root_guardian.c" -o "$BUILD_ROOT/$name"
  # Refuse output symlinks rather than following an existing destination.
  [[ ! -L "$OUTPUT/$name" && ! -d "$OUTPUT/$name" ]] || exit 73
  install -m 0755 "$BUILD_ROOT/$name" "$OUTPUT/$name"
}

compile orchard-node-root-guardian
if [[ "$INCLUDE_TEST_HELPER" == true ]]; then
  compile orchard-node-root-guardian-test -DORCHARD_NODE_ROOT_GUARDIAN_TEST
else
  rm -f "$OUTPUT/orchard-node-root-guardian-test"
fi
printf '%s\n' "$OUTPUT"
