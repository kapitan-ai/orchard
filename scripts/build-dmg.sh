#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY_MODE=""
IDENTITY=""
NOTARY_PROFILE=""
INPUT=""
OUTPUT=""
PUBLISH_DRAFT=false
RELEASE_NOTES_FILE=""
DRY_RUN=false
AMORE_BIN="${ORCHARD_AMORE_BIN:-amore}"
TMP_ROOT=""
MOUNT_POINT=""
ATTACHED_DEVICE=""
MOUNTED=false
SUCCEEDED=false
ARTIFACT_VERIFIED=false

usage() {
  printf 'Usage: %s (--ad-hoc | --identity IDENTITY --notary-profile PROFILE) --input APP --output DMG [--publish-draft --release-notes-file PATH] [--dry-run]\n' "$0"
}

detach_image() {
  local device="${ATTACHED_DEVICE:-}"
  [[ -n "$device" ]] || return 1
  local attempt
  for attempt in 1 2 3; do
    if hdiutil detach "$device" >/dev/null 2>&1; then
      MOUNTED=false
      return 0
    fi
    sleep "$attempt"
  done
  if hdiutil detach -force "$device" >/dev/null 2>&1; then
    MOUNTED=false
    return 0
  fi
  return 1
}

cleanup() {
  local detach_failed=false
  if [[ "$MOUNTED" == "true" ]]; then
    if ! detach_image; then
      detach_failed=true
      printf 'build-dmg: failed to detach %s; preserving %s and %s for recovery\n' \
        "${ATTACHED_DEVICE:-unknown-device}" "$TMP_ROOT" "${OUTPUT:-unknown-output}" >&2
      TMP_ROOT=""
    fi
  fi
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT"
  fi
  if [[ "$SUCCEEDED" != "true" && "$ARTIFACT_VERIFIED" != "true" && \
    "$detach_failed" != "true" && -n "$OUTPUT" ]]; then
    rm -f \
      "$OUTPUT" \
      "$OUTPUT.sha256" \
      "$OUTPUT.before-signing-manifest.json" \
      "$OUTPUT.after-signing-manifest.json" \
      "$OUTPUT.release-notes.md" \
      "$OUTPUT.amore-release.json"
  fi
}
trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ad-hoc)
      VERIFY_MODE="ad-hoc"
      shift
      ;;
    --identity)
      VERIFY_MODE="developer-id"
      IDENTITY="${2:-}"
      shift 2
      ;;
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --input)
      INPUT="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --publish-draft)
      PUBLISH_DRAFT=true
      shift
      ;;
    --release-notes-file)
      RELEASE_NOTES_FILE="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
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

if [[ -z "$VERIFY_MODE" || ! -d "$INPUT" || -z "$OUTPUT" ]]; then
  usage >&2
  exit 64
fi
if [[ "$VERIFY_MODE" == "developer-id" && "$IDENTITY" != "Developer ID Application:"* ]]; then
  printf 'build-dmg: Developer ID Application identity is required\n' >&2
  exit 64
fi
if [[ "$VERIFY_MODE" == "developer-id" && -z "$NOTARY_PROFILE" ]]; then
  printf 'build-dmg: --notary-profile is required for Developer ID notarization\n' >&2
  exit 64
fi
if [[ -n "$RELEASE_NOTES_FILE" && ! -f "$RELEASE_NOTES_FILE" ]]; then
  printf 'build-dmg: release notes file does not exist: %s\n' "$RELEASE_NOTES_FILE" >&2
  exit 66
fi
if [[ "$VERIFY_MODE" == "developer-id" && ! -f "$RELEASE_NOTES_FILE" ]]; then
  printf 'build-dmg: --release-notes-file is required for a release distribution set\n' >&2
  exit 64
fi
if [[ "$PUBLISH_DRAFT" == "true" ]]; then
  if [[ "$VERIFY_MODE" != "developer-id" ]]; then
    printf 'build-dmg: draft publication requires Developer ID notarization\n' >&2
    exit 64
  fi
  if [[ ! -f "$RELEASE_NOTES_FILE" ]]; then
    printf 'build-dmg: --release-notes-file is required for draft publication\n' >&2
    exit 64
  fi
fi
for path in \
  "$OUTPUT" \
  "$OUTPUT.sha256" \
  "$OUTPUT.before-signing-manifest.json" \
  "$OUTPUT.after-signing-manifest.json" \
  "$OUTPUT.release-notes.md" \
  "$OUTPUT.amore-release.json"; do
  if [[ -e "$path" || -L "$path" ]]; then
    printf 'build-dmg: output already exists: %s\n' "$path" >&2
    exit 73
  fi
done
if ! command -v "$AMORE_BIN" >/dev/null 2>&1 && [[ ! -x "$AMORE_BIN" ]]; then
  printf 'build-dmg: Amore CLI not found: %s\n' "$AMORE_BIN" >&2
  exit 69
fi

AMORE_HELP="$("$AMORE_BIN" create-dmg --help 2>&1)"
for capability in create-dmg --output --skip-notarization; do
  if ! grep -Fq -- "$capability" <<< "$AMORE_HELP"; then
    printf 'build-dmg: Amore CLI lacks required capability: %s\n' "$capability" >&2
    exit 69
  fi
done
if [[ "$PUBLISH_DRAFT" == "true" ]]; then
  RELEASE_HELP="$("$AMORE_BIN" release --help 2>&1)"
  for capability in release --draft --release-notes --format; do
    if ! grep -Fq -- "$capability" <<< "$RELEASE_HELP"; then
      printf 'build-dmg: Amore CLI lacks required publication capability: %s\n' "$capability" >&2
      exit 69
    fi
  done
fi

if [[ "$DRY_RUN" == "true" ]]; then
  if [[ "$VERIFY_MODE" == "ad-hoc" ]]; then
    printf 'amore create-dmg <app-copy> --output <dmg> --skip-notarization\n'
  else
    printf 'amore create-dmg <app-copy> --output <dmg> --codesign-identity <developer-id-application> --keychain-profile <notary-profile>\n'
  fi
  if [[ "$PUBLISH_DRAFT" == "true" ]]; then
    printf 'amore release <verified-dmg> --draft --release-notes <release-notes> --format json\n'
  fi
  SUCCEEDED=true
  exit 0
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-dmg-build.XXXXXX")"
APP_COPY="$TMP_ROOT/Orchard.app"
MOUNT_POINT="$TMP_ROOT/mount"
ATTACH_PLIST="$TMP_ROOT/attach.plist"
mkdir -p "$MOUNT_POINT" "$(dirname "$OUTPUT")"
ditto --norsrc --noextattr "$INPUT" "$APP_COPY"

VERIFY_ARGS=()
if [[ "$VERIFY_MODE" == "ad-hoc" ]]; then
  VERIFY_ARGS+=(--ad-hoc)
else
  VERIFY_ARGS+=(--identity "$IDENTITY")
fi

"$REPO_ROOT/scripts/verify-app-signing.sh" \
  "${VERIFY_ARGS[@]}" \
  --manifest-output "$OUTPUT.before-signing-manifest.json" \
  "$INPUT"

AMORE_CREATE_ARGS=(create-dmg "$APP_COPY" --output "$OUTPUT")
if [[ "$VERIFY_MODE" == "ad-hoc" ]]; then
  AMORE_CREATE_ARGS+=(--skip-notarization)
else
  AMORE_CREATE_ARGS+=(
    --codesign-identity "$IDENTITY"
    --keychain-profile "$NOTARY_PROFILE"
  )
fi
"$AMORE_BIN" "${AMORE_CREATE_ARGS[@]}"

hdiutil imageinfo "$OUTPUT" >/dev/null
hdiutil attach \
  -readonly \
  -nobrowse \
  -plist \
  -mountpoint "$MOUNT_POINT" \
  "$OUTPUT" > "$ATTACH_PLIST"
MOUNTED=true
ATTACHED_DEVICE="$(
  plutil -convert json -o - "$ATTACH_PLIST" |
    jq -er '[."system-entities"[] | select(has("mount-point"))][0]."dev-entry"'
)" || {
  printf 'build-dmg: could not determine attached DMG device\n' >&2
  exit 1
}

MOUNTED_APP="$MOUNT_POINT/Orchard.app"
if [[ ! -d "$MOUNTED_APP" ]]; then
  printf 'build-dmg: mounted DMG does not contain Orchard.app\n' >&2
  exit 1
fi
if ! "$REPO_ROOT/scripts/verify-app-signing.sh" \
  "${VERIFY_ARGS[@]}" \
  --manifest-output "$OUTPUT.after-signing-manifest.json" \
  "$MOUNTED_APP"; then
  printf 'build-dmg: nested signature or entitlement mutation detected\n' >&2
  exit 1
fi

jq -S '[.entries[] | select(.path != ".")]' \
  "$OUTPUT.before-signing-manifest.json" > "$TMP_ROOT/before-nested.json"
jq -S '[.entries[] | select(.path != ".")]' \
  "$OUTPUT.after-signing-manifest.json" > "$TMP_ROOT/after-nested.json"
if ! cmp -s "$TMP_ROOT/before-nested.json" "$TMP_ROOT/after-nested.json"; then
  printf 'build-dmg: nested signature or entitlement mutation detected\n' >&2
  exit 1
fi
if [[ "$(jq -cS '.payload_symlinks' "$OUTPUT.before-signing-manifest.json")" != \
  "$(jq -cS '.payload_symlinks' "$OUTPUT.after-signing-manifest.json")" ]]; then
  printf 'build-dmg: nested signature or entitlement mutation detected\n' >&2
  exit 1
fi

if ! detach_image; then
  printf 'build-dmg: failed to detach mounted DMG device: %s\n' "$ATTACHED_DEVICE" >&2
  exit 1
fi
if [[ "$VERIFY_MODE" == "developer-id" ]]; then
  xcrun stapler validate "$OUTPUT"
fi
ARTIFACT_VERIFIED=true
DMG_SHA256="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
printf '%s  %s\n' "$DMG_SHA256" "$(basename "$OUTPUT")" > "$OUTPUT.sha256"
if [[ -f "$RELEASE_NOTES_FILE" ]]; then
  cp "$RELEASE_NOTES_FILE" "$OUTPUT.release-notes.md"
fi
if [[ "$PUBLISH_DRAFT" == "true" ]]; then
  RELEASE_NOTES="$(<"$RELEASE_NOTES_FILE")"
  "$AMORE_BIN" release "$OUTPUT" \
    --draft \
    --release-notes "$RELEASE_NOTES" \
    --format json \
    > "$OUTPUT.amore-release.json"
fi
SUCCEEDED=true
printf '%s\n' "$OUTPUT"
