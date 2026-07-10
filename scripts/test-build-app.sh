#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/orchard-build-app.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

PAYLOAD="$TMP_ROOT/payload"
OUTPUT="$TMP_ROOT/output"
mkdir -p \
  "$PAYLOAD/releases" \
  "$PAYLOAD/native" \
  "$PAYLOAD/support/openssl/lib" \
  "$PAYLOAD/share/bin" \
  "$PAYLOAD/share/launchd"

printf 'controller\n' > "$PAYLOAD/releases/controller.txt"
printf 'native\n' > "$PAYLOAD/native/worker.txt"
ln -s worker.txt "$PAYLOAD/native/worker-link"
printf '{}\n' > "$PAYLOAD/manifest.json"
printf 'openssl\n' > "$PAYLOAD/support/openssl/lib/libcrypto.3.dylib"
for command in orchard-controller orchard-managed-postgres orchard-node-agent orchardctl; do
  printf '%s\n' "$command" > "$PAYLOAD/share/bin/$command"
done
for label in com.orchard.controller com.orchard.node-agent; do
  cp "$REPO_ROOT/packaging/launchd/$label.plist" \
    "$PAYLOAD/share/launchd/$label.plist"
done

"$REPO_ROOT/scripts/build-app.sh" \
  --payload-root "$PAYLOAD" \
  --output "$OUTPUT/Orchard.app" \
  --version 0.1.0 \
  --build test-build

APP="$OUTPUT/Orchard.app"
test -x "$APP/Contents/MacOS/Orchard"
test -x "$APP/Contents/Helpers/orchard-service"
test -f "$APP/Contents/Resources/payload/releases/controller.txt"
test -f "$APP/Contents/Resources/service-lifecycle.json"
test -L "$APP/Contents/Resources/payload/native/worker-link"
jq -e '.symlinks == [{"path":"native/worker-link","target":"worker.txt"}]' \
  "$APP/Contents/Resources/payload/manifest.json" >/dev/null

ln -s /usr/bin/true "$PAYLOAD/native/escaped"
if "$REPO_ROOT/scripts/build-app.sh" \
  --payload-root "$PAYLOAD" \
  --output "$TMP_ROOT/Escaped.app" \
  --version 0.1.0 \
  --build symlink-test > "$TMP_ROOT/symlink.out" 2>&1; then
  printf 'test-build-app: payload symlink unexpectedly accepted\n' >&2
  exit 1
fi
grep -Fq 'payload symlink target must be relative: native/escaped' "$TMP_ROOT/symlink.out"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
test "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" = \
  "com.orchard.app"
file "$APP/Contents/MacOS/Orchard" | grep -Fq 'Mach-O'
file "$APP/Contents/Helpers/orchard-service" | grep -Fq 'Mach-O'

"$APP/Contents/MacOS/Orchard" service status --root "$TMP_ROOT/root" \
  > "$TMP_ROOT/status.json"
grep -Fq '"installation_source":"none"' "$TMP_ROOT/status.json"

printf 'app assembly integration test passed\n'
