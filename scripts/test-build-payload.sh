#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$($REPO_ROOT/scripts/build-payload.sh --help)"

grep -Fq 'Usage: scripts/build-payload.sh [--allow-dirty] [--clean] [output_dir]' <<<"$OUTPUT"
grep -Fq 'PAYLOAD_ROOT=' <<<"$OUTPUT"
if grep -Eiq 'pkgbuild|stage-only|\.pkg' <<<"$OUTPUT"; then
  printf 'test-build-payload: help exposes removed PKG behavior\n' >&2
  exit 1
fi

for wrapper in orchard-controller orchard-managed-postgres orchard-node-agent orchardctl; do
  test -x "$REPO_ROOT/packaging/payload/bin/$wrapper"
done
for entitlements in beam default python; do
  test -f "$REPO_ROOT/packaging/payload/entitlements/$entitlements.entitlements"
done

for removed in \
  "$REPO_ROOT/packaging/pkg" \
  "$REPO_ROOT/scripts/build-pkg.sh" \
  "$REPO_ROOT/scripts/sign-pkg.sh" \
  "$REPO_ROOT/scripts/test-sign-pkg-keychain.sh" \
  "$REPO_ROOT/scripts/test-sign-pkg-notary-auth.sh"; do
  if [[ -e "$removed" || -L "$removed" ]]; then
    printf 'test-build-payload: removed PKG path remains: %s\n' "$removed" >&2
    exit 1
  fi
done

printf 'build payload surface test passed\n'
