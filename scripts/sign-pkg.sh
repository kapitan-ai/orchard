#!/bin/bash
#
# Sign, notarize, and staple an Orchard PKG for distribution.
#
# This script intentionally requires an explicit Developer ID Installer
# identity and notarytool keychain profile. It never falls back to local
# keychain defaults.
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<'EOF'
Usage: scripts/sign-pkg.sh --input <unsigned.pkg> --output <signed.pkg> [options]

Signs, notarizes, staples, and checksums an Orchard PKG.

Required inputs:
  --input <unsigned.pkg>       Unsigned PKG produced by scripts/build-pkg.sh
  --output <signed.pkg>        Destination path for the signed PKG
  --identity <identity>        Developer ID Installer identity
  --notary-profile <profile>   notarytool keychain profile name

Environment alternatives:
  ORCHARD_PKG_SIGNING_IDENTITY     Developer ID Installer identity
  ORCHARD_NOTARYTOOL_PROFILE       notarytool keychain profile name

Options:
  --dry-run                    Print commands without executing them
  --help                       Show this usage and exit

Examples:
  ORCHARD_PKG_SIGNING_IDENTITY='Developer ID Installer: Example, Inc. (TEAMID)' \
  ORCHARD_NOTARYTOOL_PROFILE=orchard-notary \
    scripts/sign-pkg.sh \
      --input artifacts/pkg-builds/2026-04-27/Orchard-0.5.0-20260427-abcdef0.pkg \
      --output artifacts/pkg-builds/2026-04-27/Orchard-0.5.0-20260427-abcdef0-signed.pkg

  scripts/sign-pkg.sh --dry-run \
    --identity 'Developer ID Installer: Example, Inc. (TEAMID)' \
    --notary-profile orchard-notary \
    --input /tmp/Orchard.pkg \
    --output /tmp/Orchard-signed.pkg

Before first use, create the notary profile with:
  xcrun notarytool store-credentials <profile>
EOF
}

IDENTITY="${ORCHARD_PKG_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${ORCHARD_NOTARYTOOL_PROFILE:-}"
INPUT_PKG=""
OUTPUT_PKG=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)
            if [[ $# -lt 2 ]]; then
                log_error "Missing value for --identity"
                usage
                exit 2
            fi
            IDENTITY="$2"
            shift 2
            ;;
        --notary-profile)
            if [[ $# -lt 2 ]]; then
                log_error "Missing value for --notary-profile"
                usage
                exit 2
            fi
            NOTARY_PROFILE="$2"
            shift 2
            ;;
        --input)
            if [[ $# -lt 2 ]]; then
                log_error "Missing value for --input"
                usage
                exit 2
            fi
            INPUT_PKG="$2"
            shift 2
            ;;
        --output)
            if [[ $# -lt 2 ]]; then
                log_error "Missing value for --output"
                usage
                exit 2
            fi
            OUTPUT_PKG="$2"
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
            log_error "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

trap 'log_error "Signing failed at line $LINENO"' ERR

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

IDENTITY="$(trim "$IDENTITY")"
NOTARY_PROFILE="$(trim "$NOTARY_PROFILE")"
INPUT_PKG="$(trim "$INPUT_PKG")"
OUTPUT_PKG="$(trim "$OUTPUT_PKG")"

require_value() {
    local value="$1"
    local label="$2"
    local hint="$3"

    if [[ -z "$value" ]]; then
        log_error "$label is required. $hint"
        usage
        exit 2
    fi
}

require_value "$IDENTITY" "Signing identity" "Set --identity or ORCHARD_PKG_SIGNING_IDENTITY."
require_value "$NOTARY_PROFILE" "notarytool profile" "Set --notary-profile or ORCHARD_NOTARYTOOL_PROFILE."
require_value "$INPUT_PKG" "Input PKG" "Set --input <unsigned.pkg>."
require_value "$OUTPUT_PKG" "Output PKG" "Set --output <signed.pkg>."

PRODUCTSIGN_CMD=(productsign --sign "$IDENTITY" "$INPUT_PKG" "$OUTPUT_PKG")
NOTARY_CMD=(xcrun notarytool submit "$OUTPUT_PKG" --keychain-profile "$NOTARY_PROFILE" --wait)
STAPLER_CMD=(xcrun stapler staple "$OUTPUT_PKG")
CHECKSUM_CMD=(shasum -a 256 "$OUTPUT_PKG")

print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Dry run: no files will be modified and no Apple services will be contacted."
    log_info "Would run:"
    print_command "${PRODUCTSIGN_CMD[@]}"
    print_command "${NOTARY_CMD[@]}"
    print_command "${STAPLER_CMD[@]}"
    print_command "${CHECKSUM_CMD[@]}"
    exit 0
fi

if ! command -v productsign >/dev/null 2>&1; then
    log_error "productsign is required but was not found on PATH. Install Xcode Command Line Tools."
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    log_error "xcrun is required but was not found on PATH. Install Xcode Command Line Tools."
    exit 1
fi

if ! xcrun -f notarytool >/dev/null 2>&1; then
    log_error "xcrun could not locate notarytool. Install current Xcode Command Line Tools or Xcode."
    exit 1
fi

if ! xcrun -f stapler >/dev/null 2>&1; then
    log_error "xcrun could not locate stapler. Install current Xcode Command Line Tools or Xcode."
    exit 1
fi

if [[ ! -f "$INPUT_PKG" ]]; then
    log_error "Input PKG does not exist: $INPUT_PKG"
    exit 1
fi

if [[ -e "$OUTPUT_PKG" || -L "$OUTPUT_PKG" ]]; then
    log_error "Output path already exists: $OUTPUT_PKG"
    log_error "Choose a new --output path or remove the existing file."
    exit 1
fi

if [[ -e "$OUTPUT_PKG.notary.json" || -L "$OUTPUT_PKG.notary.json" ]]; then
    log_error "Notary sidecar already exists: $OUTPUT_PKG.notary.json"
    log_error "Choose a new --output path or remove the existing sidecar."
    exit 1
fi

if [[ -e "$OUTPUT_PKG.sha256" || -L "$OUTPUT_PKG.sha256" ]]; then
    log_error "Checksum sidecar already exists: $OUTPUT_PKG.sha256"
    log_error "Choose a new --output path or remove the existing sidecar."
    exit 1
fi

OUTPUT_DIR="$(dirname "$OUTPUT_PKG")"
if [[ ! -d "$OUTPUT_DIR" ]]; then
    log_info "Creating output directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
fi

WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.orchard-sign.XXXXXX")"
TMP_SIGNED_PKG="$WORK_DIR/$(basename "$OUTPUT_PKG")"
TMP_NOTARY_JSON="$WORK_DIR/notary.json"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PRODUCTSIGN_CMD=(productsign --sign "$IDENTITY" "$INPUT_PKG" "$TMP_SIGNED_PKG")
NOTARY_CMD=(xcrun notarytool submit "$TMP_SIGNED_PKG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
STAPLER_CMD=(xcrun stapler staple "$TMP_SIGNED_PKG")
CHECKSUM_CMD=(shasum -a 256 "$TMP_SIGNED_PKG")

extract_notary_field() {
    local field="$1"
    local json_path="$2"

    /usr/bin/plutil -extract "$field" raw -o - "$json_path" 2>/dev/null || true
}

log_info "Signing PKG with explicit Developer ID Installer identity..."
"${PRODUCTSIGN_CMD[@]}"

log_info "Submitting signed PKG for notarization and waiting for completion..."
set +e
"${NOTARY_CMD[@]}" | tee "$TMP_NOTARY_JSON"
NOTARY_EXIT=${PIPESTATUS[0]}
set -e

NOTARY_SUBMISSION_ID="$(extract_notary_field "id" "$TMP_NOTARY_JSON")"
NOTARY_STATUS="$(extract_notary_field "status" "$TMP_NOTARY_JSON")"

if [[ -z "$NOTARY_SUBMISSION_ID" ]]; then
    log_error "notarytool output did not include a submission ID"
    exit 1
fi

if [[ "$NOTARY_EXIT" -ne 0 ]]; then
    log_error "notarytool exited with status $NOTARY_EXIT. Notary status: ${NOTARY_STATUS:-unknown}"
    exit 1
fi

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
    log_error "Notarization did not finish as Accepted. Status: ${NOTARY_STATUS:-unknown}"
    log_error "See notarytool output above for details."
    exit 1
fi

log_info "Stapling notarization ticket..."
"${STAPLER_CMD[@]}"

mv "$TMP_SIGNED_PKG" "$OUTPUT_PKG"
cp "$TMP_NOTARY_JSON" "$OUTPUT_PKG.notary.json"
SHA256="$(shasum -a 256 "$OUTPUT_PKG" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$OUTPUT_PKG")" > "$OUTPUT_PKG.sha256"

log_info "Signed, notarized, and stapled PKG is ready"
log_info "   Path: $OUTPUT_PKG"
log_info "   SHA-256: $SHA256"
log_info "   Checksum: $OUTPUT_PKG.sha256"
log_info "   Notary submission ID: $NOTARY_SUBMISSION_ID"
log_info "   Notary status: $NOTARY_STATUS"
log_info "   Notary JSON: $OUTPUT_PKG.notary.json"
