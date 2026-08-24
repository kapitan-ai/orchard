#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-app-signing.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

PAYLOAD="$TMP_ROOT/payload"
APP="$TMP_ROOT/Orchard.app"
MANIFEST="$TMP_ROOT/signing-manifest.json"
WRONG_ENTITLEMENTS_APP="$TMP_ROOT/WrongEntitlements.app"
EXTRA_CODE_APP="$TMP_ROOT/ExtraCode.app"
mkdir -p \
  "$PAYLOAD/releases" \
  "$PAYLOAD/native" \
  "$PAYLOAD/support/openssl/lib" \
  "$PAYLOAD/share/bin" \
  "$PAYLOAD/share/launchd"

printf 'controller\n' > "$PAYLOAD/releases/controller.txt"
cp /usr/bin/true "$PAYLOAD/native/nested-helper"
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
  --output "$APP" \
  --version 0.1.0 \
  --build signing-test >/dev/null

if codesign --verify --strict "$APP" >/dev/null 2>&1; then
  printf 'test-app-signing: unsigned app unexpectedly verified\n' >&2
  exit 1
fi

"$REPO_ROOT/scripts/sign-app.sh" --identity - "$APP"
"$REPO_ROOT/scripts/verify-app-signing.sh" \
  --ad-hoc \
  --manifest-output "$MANIFEST" \
  "$APP"

codesign --verify --strict --verbose=4 "$APP"
jq -e '.schema_version == 1' "$MANIFEST" >/dev/null
jq -e '.entries | map(.path) | index("Contents/Resources/payload/native/nested-helper") != null' \
  "$MANIFEST" >/dev/null
jq -e '.entries | map(.path) | index("Contents/Helpers/orchard-service") != null' \
  "$MANIFEST" >/dev/null
jq -e '.entries | map(.path) | index("Contents/MacOS/Orchard") != null' \
  "$MANIFEST" >/dev/null
jq -e '.entries[-1].path == "."' "$MANIFEST" >/dev/null
jq -e '.entries | all(.flags | contains("runtime"))' "$MANIFEST" >/dev/null
jq -e '.entries | all(.entitlement_class != null and .entitlement_digest != null)' \
  "$MANIFEST" >/dev/null

ditto --norsrc --noextattr "$APP" "$WRONG_ENTITLEMENTS_APP"
codesign --force --options runtime --sign - \
  --entitlements "$REPO_ROOT/packaging/payload/entitlements/beam.entitlements" \
  "$WRONG_ENTITLEMENTS_APP/Contents/Resources/payload/native/nested-helper"
codesign --force --options runtime --sign - \
  --entitlements "$REPO_ROOT/packaging/payload/entitlements/default.entitlements" \
  "$WRONG_ENTITLEMENTS_APP"
if "$REPO_ROOT/scripts/verify-app-signing.sh" --ad-hoc \
  "$WRONG_ENTITLEMENTS_APP" > "$TMP_ROOT/wrong-entitlements.out" 2>&1; then
  printf 'test-app-signing: wrong nested entitlements unexpectedly verified\n' >&2
  exit 1
fi
grep -Fq 'entitlements mismatch' "$TMP_ROOT/wrong-entitlements.out"

ditto --norsrc --noextattr "$APP" "$EXTRA_CODE_APP"
mkdir -p "$EXTRA_CODE_APP/Contents/Resources/extra"
cp /usr/bin/false "$EXTRA_CODE_APP/Contents/Resources/extra/unsigned-helper"
if "$REPO_ROOT/scripts/verify-app-signing.sh" --ad-hoc \
  "$EXTRA_CODE_APP" > "$TMP_ROOT/extra-code.out" 2>&1; then
  printf 'test-app-signing: unsigned extra Mach-O unexpectedly verified\n' >&2
  exit 1
fi

printf 'app signing integration test passed\n'
