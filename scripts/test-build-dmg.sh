#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-build-dmg.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

PAYLOAD="$TMP_ROOT/payload"
APP="$TMP_ROOT/Orchard.app"
FAKE_AMORE="$TMP_ROOT/amore"
DMG="$TMP_ROOT/Orchard.dmg"
RELEASE_NOTES="$TMP_ROOT/release notes.md"
REAL_AMORE="${ORCHARD_TEST_REAL_AMORE:-0}"
REAL_HDIUTIL="$(command -v hdiutil)"
REAL_SHASUM="$(command -v shasum)"
HDITOOL_DIR="$TMP_ROOT/tools"
mkdir -p "$HDITOOL_DIR"
cat > "$HDITOOL_DIR/hdiutil" <<'HDITOOL'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "detach" ]]; then
  case "${2:-}" in
    /dev/*) ;;
    *)
      printf 'test-build-dmg: detach must use a device entry\n' >&2
      exit 91
      ;;
  esac
fi
exec "$ORCHARD_TEST_REAL_HDIUTIL" "$@"
HDITOOL
chmod +x "$HDITOOL_DIR/hdiutil"
cat > "$HDITOOL_DIR/shasum" <<'SHATOOL'
#!/bin/bash
set -euo pipefail
last_argument="${!#:-}"
if [[ "${ORCHARD_TEST_FAIL_SHA:-0}" == "1" && "$last_argument" == *.dmg ]]; then
  exit 97
fi
exec "$ORCHARD_TEST_REAL_SHASUM" "$@"
SHATOOL
chmod +x "$HDITOOL_DIR/shasum"
mkdir -p \
  "$PAYLOAD/releases" \
  "$PAYLOAD/native" \
  "$PAYLOAD/support/openssl/lib" \
  "$PAYLOAD/share/bin" \
  "$PAYLOAD/share/launchd"

printf 'controller\n' > "$PAYLOAD/releases/controller.txt"
cp /usr/bin/true "$PAYLOAD/native/nested-helper"
ln -s nested-helper "$PAYLOAD/native/nested-helper-link"
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
  --build dmg-test >/dev/null
"$REPO_ROOT/scripts/sign-app.sh" --identity - "$APP" >/dev/null
printf 'Orchard release notes\n' > "$RELEASE_NOTES"

if [[ "$REAL_AMORE" == "1" ]]; then
  FAKE_AMORE="$(command -v amore)"
else
  cat > "$FAKE_AMORE" <<'FAKE'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "create-dmg" && "${2:-}" == "--help" ]]; then
  printf '%s\n' 'create-dmg APP --output PATH --skip-notarization --no-watermark'
  exit 0
fi
if [[ "${1:-}" == "release" && "${2:-}" == "--help" ]]; then
  printf '%s\n' 'release DMG --draft --release-notes TEXT --format json'
  exit 0
fi
if [[ "${1:-}" != "create-dmg" ]]; then
  exit 64
fi
shift
APP="$1"
shift
OUTPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --skip-notarization|--no-watermark)
      shift
      ;;
    *)
      exit 64
      ;;
  esac
done
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/fake-amore.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGE/Orchard.app"
if [[ "${FAKE_AMORE_MUTATE_NESTED:-0}" == "1" ]]; then
  cp /usr/bin/false \
    "$STAGE/Orchard.app/Contents/Resources/payload/native/nested-helper"
  codesign --force --options runtime --sign - \
    "$STAGE/Orchard.app/Contents/Resources/payload/native/nested-helper"
  codesign --force --options runtime --sign - "$STAGE/Orchard.app"
fi
if [[ "${FAKE_AMORE_RETARGET_SYMLINK:-0}" == "1" ]]; then
  rm "$STAGE/Orchard.app/Contents/Resources/payload/native/nested-helper-link"
  ln -s ../releases/controller.txt \
    "$STAGE/Orchard.app/Contents/Resources/payload/native/nested-helper-link"
  codesign --force --options runtime --sign - "$STAGE/Orchard.app"
fi
hdiutil create \
  -volname Orchard \
  -srcfolder "$STAGE" \
  -format UDZO \
  -ov \
  "$OUTPUT" >/dev/null
FAKE
  chmod +x "$FAKE_AMORE"
fi

PATH="$HDITOOL_DIR:$PATH" \
ORCHARD_TEST_REAL_HDIUTIL="$REAL_HDIUTIL" \
ORCHARD_TEST_REAL_SHASUM="$REAL_SHASUM" \
ORCHARD_AMORE_BIN="$FAKE_AMORE" \
  "$REPO_ROOT/scripts/build-dmg.sh" \
  --ad-hoc \
  --release-notes-file "$RELEASE_NOTES" \
  --input "$APP" \
  --output "$DMG"

test -f "$DMG"
test -f "$DMG.before-signing-manifest.json"
test -f "$DMG.after-signing-manifest.json"
test -f "$DMG.release-notes.md"
grep -Fq 'Orchard release notes' "$DMG.release-notes.md"
test -f "$DMG.sha256"
hdiutil imageinfo "$DMG" >/dev/null

if [[ "$REAL_AMORE" != "1" ]]; then
  if ORCHARD_AMORE_BIN="$FAKE_AMORE" FAKE_AMORE_MUTATE_NESTED=1 \
    "$REPO_ROOT/scripts/build-dmg.sh" \
    --ad-hoc \
    --release-notes-file "$RELEASE_NOTES" \
    --input "$APP" \
    --output "$TMP_ROOT/Mutated.dmg" \
    > "$TMP_ROOT/mutated.out" 2>&1; then
    printf 'test-build-dmg: nested mutation unexpectedly passed\n' >&2
    exit 1
  fi
  grep -Fq 'nested signature or entitlement mutation' "$TMP_ROOT/mutated.out"

  if ORCHARD_AMORE_BIN="$FAKE_AMORE" FAKE_AMORE_RETARGET_SYMLINK=1 \
    "$REPO_ROOT/scripts/build-dmg.sh" \
    --ad-hoc \
    --release-notes-file "$RELEASE_NOTES" \
    --input "$APP" \
    --output "$TMP_ROOT/Retargeted.dmg" \
    > "$TMP_ROOT/retargeted.out" 2>&1; then
    printf 'test-build-dmg: symlink retarget unexpectedly passed\n' >&2
    exit 1
  fi
  grep -Fq 'nested signature or entitlement mutation' "$TMP_ROOT/retargeted.out"

  printf 'Release notes\n' > "$TMP_ROOT/release-notes.txt"
  ORCHARD_AMORE_BIN="$FAKE_AMORE" \
    "$REPO_ROOT/scripts/build-dmg.sh" \
    --identity 'Developer ID Application: Example (TEAMID)' \
    --notary-profile orchard-notary \
    --publish-draft \
    --release-notes-file "$TMP_ROOT/release-notes.txt" \
    --dry-run \
    --input "$APP" \
    --output "$TMP_ROOT/Release.dmg" \
    > "$TMP_ROOT/release-plan.txt"
  grep -Fq 'amore create-dmg <app-copy> --output <dmg> --codesign-identity <developer-id-application> --keychain-profile <notary-profile>' \
    "$TMP_ROOT/release-plan.txt"
  grep -Fq 'amore release <verified-dmg> --draft --release-notes <release-notes> --format json' \
    "$TMP_ROOT/release-plan.txt"
  test ! -e "$TMP_ROOT/Release.dmg"

  AMORE_WITH_SPACES="$TMP_ROOT/amore tool"
  cp "$FAKE_AMORE" "$AMORE_WITH_SPACES"
  ORCHARD_AMORE_BIN="$AMORE_WITH_SPACES" \
    "$REPO_ROOT/scripts/build-dmg.sh" \
    --ad-hoc \
    --release-notes-file "$RELEASE_NOTES" \
    --input "$APP" \
    --output "$TMP_ROOT/Quoted.dmg" >/dev/null
  test -f "$TMP_ROOT/Quoted.dmg"

  if PATH="$HDITOOL_DIR:$PATH" \
    ORCHARD_TEST_REAL_HDIUTIL="$REAL_HDIUTIL" \
    ORCHARD_TEST_REAL_SHASUM="$REAL_SHASUM" \
    ORCHARD_TEST_FAIL_SHA=1 \
    ORCHARD_AMORE_BIN="$FAKE_AMORE" \
    "$REPO_ROOT/scripts/build-dmg.sh" \
    --ad-hoc \
    --release-notes-file "$RELEASE_NOTES" \
    --input "$APP" \
    --output "$TMP_ROOT/FailedAfterVerify.dmg" \
    > "$TMP_ROOT/failed-after-verify.out" 2>&1; then
    printf 'test-build-dmg: post-verification failure unexpectedly passed\n' >&2
    exit 1
  fi
  test -f "$TMP_ROOT/FailedAfterVerify.dmg"
  test -f "$TMP_ROOT/FailedAfterVerify.dmg.before-signing-manifest.json"
  test -f "$TMP_ROOT/FailedAfterVerify.dmg.after-signing-manifest.json"
fi

printf 'DMG handoff integration test passed\n'
