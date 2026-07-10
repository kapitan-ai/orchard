#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY=""
APP=""

usage() {
  printf 'Usage: %s --identity IDENTITY /path/to/Orchard.app\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -* )
      usage >&2
      exit 64
      ;;
    *)
      if [[ -n "$APP" ]]; then
        usage >&2
        exit 64
      fi
      APP="$1"
      shift
      ;;
  esac
done

if [[ -z "$IDENTITY" || ! -d "$APP" ]]; then
  usage >&2
  exit 64
fi
if [[ "$IDENTITY" != "-" && "$IDENTITY" != "Developer ID Application:"* ]]; then
  printf 'sign-app: identity must be ad hoc (-) or Developer ID Application\n' >&2
  exit 64
fi

PAYLOAD="$APP/Contents/Resources/payload"
ENTITLEMENTS="$REPO_ROOT/packaging/pkg/entitlements"
for path in \
  "$APP/Contents/Info.plist" \
  "$APP/Contents/MacOS/Orchard" \
  "$APP/Contents/Helpers/orchard-service" \
  "$PAYLOAD"; do
  if [[ ! -e "$path" ]]; then
    printf 'sign-app: missing app path: %s\n' "$path" >&2
    exit 66
  fi
done

entitlements_for() {
  local path="$1"
  case "$path" in
    */erts-*/bin/beam.smp)
      printf '%s/beam.entitlements' "$ENTITLEMENTS"
      ;;
    */.venv/bin/python*|*/.venv/bin/*)
      if [[ "$path" == */.venv/bin/python* || -x "$path" ]]; then
        printf '%s/python.entitlements' "$ENTITLEMENTS"
      else
        printf '%s/default.entitlements' "$ENTITLEMENTS"
      fi
      ;;
    *)
      printf '%s/default.entitlements' "$ENTITLEMENTS"
      ;;
  esac
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-app-sign.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
MACHO_LIST="$TMP_ROOT/macho-files.txt"
find -P "$APP/Contents" -type f -exec file --mime-type {} + |
  grep -Fv ' (for architecture ' |
  sed -n 's/: *application\/x-mach-binary$//p' |
  LC_ALL=C sort > "$MACHO_LIST"

sign_path() {
  local path="$1"
  local entitlements="$2"
  local args=(codesign --force --options runtime --sign "$IDENTITY")
  if [[ "$IDENTITY" != "-" ]]; then
    args+=(--timestamp)
  fi
  args+=(--entitlements "$entitlements" "$path")
  "${args[@]}"
}

if [[ "$IDENTITY" == "-" ]]; then
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      "$PAYLOAD"/*)
        case "$path" in
          *.so|*.dylib|*.bundle) sign_path "$path" "$(entitlements_for "$path")" ;;
        esac
        ;;
    esac
  done < "$MACHO_LIST"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    case "$path" in
      "$PAYLOAD"/*)
        case "$path" in *.so|*.dylib|*.bundle) continue ;; esac
        sign_path "$path" "$(entitlements_for "$path")"
        ;;
    esac
  done < "$MACHO_LIST"
else
  ORCHARD_PAYLOAD_SIGNING_IDENTITY="$IDENTITY" \
    "$REPO_ROOT/scripts/sign-payload.sh" "$PAYLOAD"
fi

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    "$PAYLOAD"/*|"$APP/Contents/Helpers/orchard-service"|"$APP/Contents/MacOS/Orchard")
      continue
      ;;
    *.so|*.dylib|*.bundle)
      sign_path "$path" "$ENTITLEMENTS/default.entitlements"
      ;;
  esac
done < "$MACHO_LIST"

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "$path" in
    "$PAYLOAD"/*|"$APP/Contents/Helpers/orchard-service"|"$APP/Contents/MacOS/Orchard"|*.so|*.dylib|*.bundle)
      continue
      ;;
  esac
  sign_path "$path" "$ENTITLEMENTS/default.entitlements"
done < "$MACHO_LIST"

sign_path \
  "$APP/Contents/Helpers/orchard-service" \
  "$ENTITLEMENTS/default.entitlements"
sign_path \
  "$APP/Contents/MacOS/Orchard" \
  "$ENTITLEMENTS/default.entitlements"
sign_path "$APP" "$ENTITLEMENTS/default.entitlements"

codesign --verify --strict --verbose=4 "$APP"
