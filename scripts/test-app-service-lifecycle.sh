#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/orchard-app-lifecycle.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

PAYLOAD="$TMP_ROOT/payload"
TARGET_ROOT="$TMP_ROOT/root"
mkdir -p \
  "$PAYLOAD/releases" \
  "$PAYLOAD/native" \
  "$PAYLOAD/support/openssl/lib" \
  "$PAYLOAD/share/bin" \
  "$PAYLOAD/share/launchd"

printf 'controller\n' > "$PAYLOAD/releases/controller.txt"
printf 'native\n' > "$PAYLOAD/native/worker.txt"
printf '{}\n' > "$PAYLOAD/manifest.json"
printf 'openssl\n' > "$PAYLOAD/support/openssl/lib/libcrypto.3.dylib"

for command in orchard-controller orchard-managed-postgres orchard-node-agent orchardctl; do
  printf '%s\n' "$command" > "$PAYLOAD/share/bin/$command"
done
for label in com.orchard.controller com.orchard.node-agent; do
  printf '%s\n' "$label" > "$PAYLOAD/share/launchd/$label.plist"
done

mkdir -p "$TARGET_ROOT/Library/Application Support/Orchard/support"
printf 'retain-initial-install\n' \
  > "$TARGET_ROOT/Library/Application Support/Orchard/support/operator-initial-note.txt"

ORCHARD_APP_PAYLOAD_ROOT="$PAYLOAD" \
ORCHARD_APP_CONTRACT_PATH="$REPO_ROOT/packaging/service-lifecycle.json" \
swift run --package-path "$REPO_ROOT/packaging/app" orchard-service \
  install --role controller --root "$TARGET_ROOT" > "$TMP_ROOT/install.json"

grep -Fq '"installation_source":"app"' "$TMP_ROOT/install.json"
grep -Fq '"role":"controller"' "$TMP_ROOT/install.json"
test -f "$TARGET_ROOT/Library/LaunchDaemons/com.orchard.controller.plist"
test ! -e "$TARGET_ROOT/Library/LaunchDaemons/com.orchard.node-agent.plist"
test -L "$TARGET_ROOT/usr/local/bin/orchardctl"
grep -Fq 'retain-initial-install' \
  "$TARGET_ROOT/Library/Application Support/Orchard/support/operator-initial-note.txt"

if ORCHARD_APP_PAYLOAD_ROOT="$PAYLOAD" \
  ORCHARD_APP_CONTRACT_PATH="$REPO_ROOT/packaging/service-lifecycle.json" \
  swift run --package-path "$REPO_ROOT/packaging/app" orchard-service \
    install --role invalid --root "$TARGET_ROOT" \
    > "$TMP_ROOT/invalid.out" 2> "$TMP_ROOT/invalid.err"; then
  printf 'test-app-service-lifecycle: invalid role unexpectedly succeeded\n' >&2
  exit 1
else
  status=$?
fi
test "$status" -eq 64
grep -Fq '"code":"invalid_invocation"' "$TMP_ROOT/invalid.err"

mkdir -p "$TARGET_ROOT/Library/Application Support/Orchard/support"
printf 'retain-support\n' \
  > "$TARGET_ROOT/Library/Application Support/Orchard/support/operator-note.txt"
printf 'controller-v2\n' > "$PAYLOAD/releases/controller.txt"
if ORCHARD_APP_PAYLOAD_ROOT="$PAYLOAD" \
  ORCHARD_APP_CONTRACT_PATH="$REPO_ROOT/packaging/service-lifecycle.json" \
  ORCHARD_APP_TEST_FAIL_AFTER=afterPayload \
  swift run --package-path "$REPO_ROOT/packaging/app" orchard-service \
    update --role node-agent --root "$TARGET_ROOT" \
    > "$TMP_ROOT/rollback.out" 2> "$TMP_ROOT/rollback.err"; then
  printf 'test-app-service-lifecycle: injected update unexpectedly succeeded\n' >&2
  exit 1
fi
grep -Fq '"code":"lifecycle_failed"' "$TMP_ROOT/rollback.err"
grep -Fq 'controller' \
  "$TARGET_ROOT/Library/Application Support/Orchard/releases/controller.txt"
grep -Fq 'controller' \
  "$TARGET_ROOT/Library/Application Support/Orchard/support/.install-role"
grep -Fq 'retain-support' \
  "$TARGET_ROOT/Library/Application Support/Orchard/support/operator-note.txt"

mkdir -p "$TARGET_ROOT/Library/Application Support/Orchard/models"
printf 'retain\n' > "$TARGET_ROOT/Library/Application Support/Orchard/models/operator-model"
ORCHARD_APP_PAYLOAD_ROOT="$PAYLOAD" \
ORCHARD_APP_CONTRACT_PATH="$REPO_ROOT/packaging/service-lifecycle.json" \
swift run --package-path "$REPO_ROOT/packaging/app" orchard-service \
  update --role node-agent --root "$TARGET_ROOT" > "$TMP_ROOT/update.json"
grep -Fq '"role":"node-agent"' "$TMP_ROOT/update.json"
test -f "$TARGET_ROOT/Library/LaunchDaemons/com.orchard.node-agent.plist"
test ! -e "$TARGET_ROOT/Library/LaunchDaemons/com.orchard.controller.plist"
grep -Fq 'retain-support' \
  "$TARGET_ROOT/Library/Application Support/Orchard/support/operator-note.txt"

ORCHARD_APP_PAYLOAD_ROOT="$PAYLOAD" \
ORCHARD_APP_CONTRACT_PATH="$REPO_ROOT/packaging/service-lifecycle.json" \
swift run --package-path "$REPO_ROOT/packaging/app" orchard-service \
  uninstall --root "$TARGET_ROOT" > "$TMP_ROOT/uninstall.json"
grep -Fq '"installation_source":"none"' "$TMP_ROOT/uninstall.json"
grep -Fq 'retain' \
  "$TARGET_ROOT/Library/Application Support/Orchard/models/operator-model"
grep -Fq 'retain-support' \
  "$TARGET_ROOT/Library/Application Support/Orchard/support/operator-note.txt"
test ! -e "$TARGET_ROOT/Library/Application Support/Orchard/releases"

printf 'app service lifecycle integration test passed\n'
