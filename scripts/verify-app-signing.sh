#!/bin/bash
set -euo pipefail

MODE=""
IDENTITY=""
MANIFEST_OUTPUT=""
APP=""
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  printf 'Usage: %s (--ad-hoc | --identity IDENTITY) [--manifest-output PATH] /path/to/Orchard.app\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ad-hoc)
      MODE="ad-hoc"
      shift
      ;;
    --identity)
      MODE="developer-id"
      IDENTITY="${2:-}"
      shift 2
      ;;
    --manifest-output)
      MANIFEST_OUTPUT="${2:-}"
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

if [[ -z "$MODE" || ! -d "$APP" ]]; then
  usage >&2
  exit 64
fi
if [[ "$MODE" == "developer-id" && "$IDENTITY" != "Developer ID Application:"* ]]; then
  printf 'verify-app-signing: Developer ID Application identity is required\n' >&2
  exit 64
fi
if [[ -n "$MANIFEST_OUTPUT" && -e "$MANIFEST_OUTPUT" ]]; then
  printf 'verify-app-signing: manifest already exists: %s\n' "$MANIFEST_OUTPUT" >&2
  exit 73
fi

PAYLOAD="$APP/Contents/Resources/payload"
ENTITLEMENTS="$REPO_ROOT/packaging/payload/entitlements"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-app-verify.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
ENTRIES="$TMP_ROOT/entries.jsonl"
MACHO_LIST="$TMP_ROOT/macho-files.txt"
: > "$ENTRIES"
find -P "$APP/Contents" -type f -exec file --mime-type {} + |
  grep -Fv ' (for architecture ' |
  sed -n 's/: *application\/x-mach-binary$//p' |
  LC_ALL=C sort > "$MACHO_LIST"

PAYLOAD_CANON="$(cd "$PAYLOAD" && pwd -P)"
if ! mise exec -- "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" --no-smoke "$PAYLOAD_CANON" \
  > "$TMP_ROOT/closure.out" 2>&1; then
  printf 'verify-app-signing: payload dependency closure failed\n' >&2
  sed -n '1,40p' "$TMP_ROOT/closure.out" >&2
  exit 1
fi

PAYLOAD_SYMLINKS="$(jq -cS '(.symlinks // []) | sort_by(.path)' "$PAYLOAD/manifest.json")"
ACTUAL_SYMLINKS="$TMP_ROOT/actual-symlinks.jsonl"
: > "$ACTUAL_SYMLINKS"
while IFS= read -r -d '' symlink; do
  case "$symlink" in
    "$PAYLOAD"/*)
      jq -cn \
        --arg path "${symlink#"$PAYLOAD"/}" \
        --arg target "$(readlink "$symlink")" \
        '{path:$path,target:$target}' >> "$ACTUAL_SYMLINKS"
      ;;
    *)
      printf 'verify-app-signing: unexpected app symlink: %s\n' "${symlink#"$APP"/}" >&2
      exit 1
      ;;
  esac
done < <(find -P "$APP/Contents" -type l -print0)
ACTUAL_SYMLINKS_JSON="$(jq -sc 'sort_by(.path)' "$ACTUAL_SYMLINKS")"
if [[ "$(jq -cS . <<< "$ACTUAL_SYMLINKS_JSON")" != "$PAYLOAD_SYMLINKS" ]]; then
  printf 'verify-app-signing: payload symlink manifest mismatch\n' >&2
  exit 1
fi

entitlements_class_for() {
  local path="$1"
  case "$path" in
    */Contents/Resources/payload/*/erts-*/bin/beam.smp)
      printf 'beam'
      ;;
    */Contents/Resources/payload/*/.venv/bin/python*|*/Contents/Resources/payload/*/.venv/bin/*)
      if [[ "$path" == */.venv/bin/python* || -x "$path" ]]; then
        printf 'python'
      else
        printf 'default'
      fi
      ;;
    *)
      printf 'default'
      ;;
  esac
}

canonical_entitlements() {
  local source="$1"
  if [[ ! -s "$source" ]]; then
    printf '{}\n'
    return
  fi
  plutil -convert json -o - "$source" | jq -cS .
}

record_path() {
  local path="$1"
  local relative="$2"
  local expected_class="$3"
  local details flags cdhash team identity sha actual_entitlements
  local actual_canonical expected_canonical entitlements_sha

  codesign --verify --strict --verbose=4 "$path"
  details="$(codesign -dvvv "$path" 2>&1)"
  flags="$(printf '%s\n' "$details" | sed -n 's/.*flags=[^(]*(\([^)]*\)).*/\1/p' | head -1)"
  if [[ "$flags" != *runtime* ]]; then
    printf 'verify-app-signing: hardened runtime missing: %s\n' "$relative" >&2
    exit 1
  fi
  cdhash="$(printf '%s\n' "$details" | sed -n 's/^CDHash=//p' | head -1)"
  team="$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  identity="$(printf '%s\n' "$details" | sed -n 's/^Authority=//p' | head -1)"

  if [[ "$MODE" == "ad-hoc" ]]; then
    if ! printf '%s\n' "$details" | grep -Fq 'Signature=adhoc'; then
      printf 'verify-app-signing: expected ad hoc signature: %s\n' "$relative" >&2
      exit 1
    fi
    identity="ad-hoc"
    team=""
  elif [[ "$identity" != "$IDENTITY" ]]; then
    printf 'verify-app-signing: identity mismatch for %s\n' "$relative" >&2
    exit 1
  elif ! printf '%s\n' "$details" | grep -Eq '^Timestamp=.+$' || \
    printf '%s\n' "$details" | grep -Eq '^Timestamp=(none|-)$'; then
    printf 'verify-app-signing: secure timestamp missing: %s\n' "$relative" >&2
    exit 1
  fi

  actual_entitlements="$(mktemp "$TMP_ROOT/entitlements.XXXXXX")"
  if ! codesign -d --entitlements :- "$path" > "$actual_entitlements" 2>/dev/null; then
    printf 'verify-app-signing: cannot read entitlements: %s\n' "$relative" >&2
    exit 1
  fi
  if ! actual_canonical="$(canonical_entitlements "$actual_entitlements")"; then
    printf 'verify-app-signing: invalid embedded entitlements: %s\n' "$relative" >&2
    exit 1
  fi
  if ! expected_canonical="$(canonical_entitlements "$ENTITLEMENTS/$expected_class.entitlements")"; then
    printf 'verify-app-signing: invalid expected entitlements class: %s\n' "$expected_class" >&2
    exit 1
  fi
  if [[ "$actual_canonical" != "$expected_canonical" ]]; then
    printf 'verify-app-signing: entitlements mismatch for %s (expected %s)\n' \
      "$relative" "$expected_class" >&2
    exit 1
  fi
  entitlements_sha="$(printf '%s' "$actual_canonical" | shasum -a 256 | awk '{print $1}')"
  if [[ -f "$path" ]]; then
    sha="$(shasum -a 256 "$path" | awk '{print $1}')"
  else
    sha="$(shasum -a 256 "$path/Contents/_CodeSignature/CodeResources" | awk '{print $1}')"
  fi

  jq -cn \
    --arg path "$relative" \
    --arg sha256 "$sha" \
    --arg cdhash "$cdhash" \
    --arg team_id "$team" \
    --arg flags "$flags" \
    --arg entitlement_class "$expected_class" \
    --arg entitlement_digest "$entitlements_sha" \
    --arg identity "$identity" \
    '{path:$path,sha256:$sha256,cdhash:$cdhash,team_id:$team_id,flags:$flags,entitlement_class:$entitlement_class,entitlement_digest:$entitlement_digest,identity:$identity}' \
    >> "$ENTRIES"
}

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  record_path "$path" "${path#"$APP"/}" "$(entitlements_class_for "$path")"
done < "$MACHO_LIST"

record_path "$APP" "." "default"

if [[ -n "$MANIFEST_OUTPUT" ]]; then
  mkdir -p "$(dirname "$MANIFEST_OUTPUT")"
  jq -s --argjson payload_symlinks "$PAYLOAD_SYMLINKS" \
    '{schema_version:1,payload_symlinks:$payload_symlinks,entries:.}' \
    "$ENTRIES" > "$MANIFEST_OUTPUT"
fi
