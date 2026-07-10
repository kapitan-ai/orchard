#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAYLOAD_ROOT=""
OUTPUT=""
VERSION=""
BUILD=""

usage() {
  printf 'Usage: %s --payload-root PATH --output PATH --version VERSION --build BUILD\n' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --payload-root)
      PAYLOAD_ROOT="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:-}"
      shift 2
      ;;
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --build)
      BUILD="${2:-}"
      shift 2
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

for value in PAYLOAD_ROOT OUTPUT VERSION BUILD; do
  if [[ -z "${!value}" ]]; then
    printf 'build-app: missing required %s\n' "$value" >&2
    usage >&2
    exit 64
  fi
done

case "$VERSION:$BUILD" in
  *[!A-Za-z0-9._:-]*)
    printf 'build-app: version and build may contain only letters, numbers, dot, underscore, colon, and hyphen\n' >&2
    exit 64
    ;;
esac

for path in releases native share/bin share/launchd support/openssl; do
  if [[ ! -e "$PAYLOAD_ROOT/$path" ]]; then
    printf 'build-app: missing payload path: %s\n' "$path" >&2
    exit 66
  fi
done

while IFS= read -r -d '' payload_path; do
  if [[ "$payload_path" == *$'\n'* ]]; then
    printf 'build-app: payload paths may not contain newlines\n' >&2
    exit 65
  fi
done < <(find -P "$PAYLOAD_ROOT" -print0)

PAYLOAD_ROOT_CANON="$(cd "$PAYLOAD_ROOT" && pwd -P)"
while IFS= read -r payload_symlink; do
  [[ -n "$payload_symlink" ]] || continue
  link_target="$(readlink "$payload_symlink")"
  if [[ "$link_target" == /* ]]; then
    printf 'build-app: payload symlink target must be relative: %s\n' \
      "${payload_symlink#$PAYLOAD_ROOT/}" >&2
    exit 65
  fi
  resolved_target="$(realpath "$payload_symlink" 2>/dev/null || true)"
  case "$resolved_target" in
    "$PAYLOAD_ROOT_CANON"/*) ;;
    *)
      printf 'build-app: payload symlink escapes payload: %s\n' \
        "${payload_symlink#$PAYLOAD_ROOT/}" >&2
      exit 65
      ;;
  esac
done < <(find -P "$PAYLOAD_ROOT" -type l -print | LC_ALL=C sort)

if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
  printf 'build-app: output already exists: %s\n' "$OUTPUT" >&2
  exit 73
fi

swift build --package-path "$REPO_ROOT/packaging/app" -c release \
  --product Orchard
swift build --package-path "$REPO_ROOT/packaging/app" -c release \
  --product orchard-service
BIN_PATH=$(swift build --package-path "$REPO_ROOT/packaging/app" -c release \
  --show-bin-path)

CONTENTS="$OUTPUT/Contents"
mkdir -p \
  "$CONTENTS/MacOS" \
  "$CONTENTS/Helpers" \
  "$CONTENTS/Resources/payload"

install -m 0755 "$BIN_PATH/Orchard" "$CONTENTS/MacOS/Orchard"
install -m 0755 "$BIN_PATH/orchard-service" "$CONTENTS/Helpers/orchard-service"

sed \
  -e "s/@VERSION@/$VERSION/g" \
  -e "s/@BUILD@/$BUILD/g" \
  "$REPO_ROOT/packaging/app/Info.plist" > "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

for path in releases native share; do
  ditto --norsrc --noextattr \
    "$PAYLOAD_ROOT/$path" \
    "$CONTENTS/Resources/payload/$path"
done
mkdir -p "$CONTENTS/Resources/payload/support"
ditto --norsrc --noextattr \
  "$PAYLOAD_ROOT/support/openssl" \
  "$CONTENTS/Resources/payload/support/openssl"
SYMLINK_RECORDS="$(
  while IFS= read -r -d '' symlink; do
    jq -cn \
      --arg path "${symlink#$CONTENTS/Resources/payload/}" \
      --arg target "$(readlink "$symlink")" \
      '{path:$path,target:$target}'
  done < <(find -P "$CONTENTS/Resources/payload" -type l -print0) |
    jq -s 'sort_by(.path)'
)"
if [[ -f "$PAYLOAD_ROOT/manifest.json" ]]; then
  jq \
    --argjson symlinks "$SYMLINK_RECORDS" \
    '. + {symlinks: $symlinks}' \
    "$PAYLOAD_ROOT/manifest.json" \
    > "$CONTENTS/Resources/payload/manifest.json"
else
  jq -n \
    --arg version "$VERSION" \
    --arg build "$BUILD" \
    --argjson symlinks "$SYMLINK_RECORDS" \
    '{schema_version:1,version:$version,build:$build,payload_roots:["native","releases","share","support/openssl"],symlinks:$symlinks}' \
    > "$CONTENTS/Resources/payload/manifest.json"
fi
install -m 0644 \
  "$REPO_ROOT/packaging/service-lifecycle.json" \
  "$CONTENTS/Resources/service-lifecycle.json"

file "$CONTENTS/MacOS/Orchard" | grep -Fq 'Mach-O'
file "$CONTENTS/Helpers/orchard-service" | grep -Fq 'Mach-O'

printf '%s\n' "$OUTPUT"
