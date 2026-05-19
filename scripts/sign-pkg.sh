#!/bin/bash
#
# Sign, notarize, and staple an Orchard PKG for distribution.
#
# This script intentionally requires an explicit Developer ID Installer
# identity and explicit notarization credentials. It never falls back to
# local keychain defaults.
#

set -euo pipefail

PAYLOAD_AUDIT_BUILD_KEYCHAIN=""
PAYLOAD_AUDIT_BUILD_KEYCHAIN_CONFIGURED=false
PAYLOAD_AUDIT_KEYCHAIN_PASSWORD=""
PAYLOAD_AUDIT_KEYCHAIN_PASSWORD_CONFIGURED=false
_payload_audit_keychain_restore_xtrace=0
case "$-" in
    *x*)
        _payload_audit_keychain_restore_xtrace=1
        set +x
        ;;
esac
if [[ -n "${ORCHARD_BUILD_KEYCHAIN:-}" ]]; then
    PAYLOAD_AUDIT_BUILD_KEYCHAIN="$ORCHARD_BUILD_KEYCHAIN"
    PAYLOAD_AUDIT_BUILD_KEYCHAIN_CONFIGURED=true
    if [[ -n "${ORCHARD_KEYCHAIN_PASSWORD:-}" ]]; then
        PAYLOAD_AUDIT_KEYCHAIN_PASSWORD="$ORCHARD_KEYCHAIN_PASSWORD"
        PAYLOAD_AUDIT_KEYCHAIN_PASSWORD_CONFIGURED=true
    fi
fi
unset ORCHARD_KEYCHAIN_PASSWORD
unset ORCHARD_BUILD_KEYCHAIN
if [[ "$_payload_audit_keychain_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _payload_audit_keychain_restore_xtrace

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

Notarization auth:
  --notary-profile <profile>   notarytool keychain profile name (default mode)

Environment alternatives:
  ORCHARD_PKG_SIGNING_IDENTITY         Developer ID Installer identity
  ORCHARD_PAYLOAD_SIGNING_IDENTITY     Developer ID Application identity used for payload audit
  ORCHARD_NOTARY_AUTH                  profile (default) or api-key
  ORCHARD_NOTARYTOOL_PROFILE           notarytool keychain profile name for profile auth
  ORCHARD_NOTARY_API_KEY_PATH          App Store Connect API key .p8 path for api-key auth
  ORCHARD_NOTARY_API_KEY_ID            App Store Connect API key ID for api-key auth
  ORCHARD_NOTARY_API_KEY_TYPE          auto (default), team, or individual
  ORCHARD_NOTARY_API_ISSUER_ID         App Store Connect issuer UUID for Team API Keys; omitted for Individual API Keys
  ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS    Timeout for pkgutil --expand-full audit (default: 600)
  ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR      Durable diagnostics dir for package audit metadata (success or failure)

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

Before first profile-auth use, create the notary profile with:
  xcrun notarytool store-credentials <profile>

For API-key auth, set ORCHARD_NOTARY_AUTH=api-key, ORCHARD_NOTARY_API_KEY_PATH, and ORCHARD_NOTARY_API_KEY_ID. Set ORCHARD_NOTARY_API_KEY_TYPE=team with ORCHARD_NOTARY_API_ISSUER_ID for Team API Keys. Set ORCHARD_NOTARY_API_KEY_TYPE=individual to omit --issuer, even if a stale issuer env var is present. The default ORCHARD_NOTARY_API_KEY_TYPE=auto omits absent issuer, includes valid issuer UUID, and rejects malformed non-empty issuer values.

Validate API-key argument construction with:
  bash scripts/test-sign-pkg-notary-auth.sh
EOF
}

IDENTITY="${ORCHARD_PKG_SIGNING_IDENTITY:-}"
NOTARY_AUTH="${ORCHARD_NOTARY_AUTH:-profile}"
NOTARY_PROFILE="${ORCHARD_NOTARYTOOL_PROFILE:-}"
NOTARY_API_KEY_PATH="${ORCHARD_NOTARY_API_KEY_PATH:-}"
NOTARY_API_KEY_ID="${ORCHARD_NOTARY_API_KEY_ID:-}"
NOTARY_API_KEY_TYPE="${ORCHARD_NOTARY_API_KEY_TYPE:-auto}"
NOTARY_API_ISSUER_ID="${ORCHARD_NOTARY_API_ISSUER_ID:-}"
PAYLOAD_SIGNING_IDENTITY="${ORCHARD_PAYLOAD_SIGNING_IDENTITY:-}"
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
NOTARY_AUTH="$(trim "$NOTARY_AUTH")"
NOTARY_PROFILE="$(trim "$NOTARY_PROFILE")"
NOTARY_API_KEY_PATH="$(trim "$NOTARY_API_KEY_PATH")"
NOTARY_API_KEY_ID="$(trim "$NOTARY_API_KEY_ID")"
NOTARY_API_KEY_TYPE="$(trim "$NOTARY_API_KEY_TYPE")"
NOTARY_API_ISSUER_ID="$(trim "$NOTARY_API_ISSUER_ID")"
PAYLOAD_SIGNING_IDENTITY="$(trim "$PAYLOAD_SIGNING_IDENTITY")"
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

is_uuid() {
    local value="$1"
    [[ "$value" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

require_value "$IDENTITY" "Signing identity" "Set --identity or ORCHARD_PKG_SIGNING_IDENTITY."
require_value "$INPUT_PKG" "Input PKG" "Set --input <unsigned.pkg>."
require_value "$OUTPUT_PKG" "Output PKG" "Set --output <signed.pkg>."
require_value "$PAYLOAD_SIGNING_IDENTITY" "ORCHARD_PAYLOAD_SIGNING_IDENTITY" "Set it to the Developer ID Application identity used by scripts/build-pkg.sh."

case "$NOTARY_AUTH" in
    profile)
        require_value "$NOTARY_PROFILE" "notarytool profile" "Set --notary-profile or ORCHARD_NOTARYTOOL_PROFILE."
        NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
        ;;
    api-key)
        require_value "$NOTARY_API_KEY_PATH" "ORCHARD_NOTARY_API_KEY_PATH" "Set it to the App Store Connect API key .p8 path."
        require_value "$NOTARY_API_KEY_ID" "ORCHARD_NOTARY_API_KEY_ID" "Set it to the App Store Connect API key ID."
        NOTARY_AUTH_ARGS=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID")
        case "$NOTARY_API_KEY_TYPE" in
            individual)
                ;;
            team)
                require_value "$NOTARY_API_ISSUER_ID" "ORCHARD_NOTARY_API_ISSUER_ID" "Set it to the App Store Connect issuer UUID for Team API Keys."
                if is_uuid "$NOTARY_API_ISSUER_ID"; then
                    NOTARY_AUTH_ARGS+=(--issuer "$NOTARY_API_ISSUER_ID")
                else
                    log_error "ORCHARD_NOTARY_API_ISSUER_ID must be a UUID for Team API Keys."
                    exit 2
                fi
                ;;
            auto)
                if [[ -n "$NOTARY_API_ISSUER_ID" ]]; then
                    if is_uuid "$NOTARY_API_ISSUER_ID"; then
                        NOTARY_AUTH_ARGS+=(--issuer "$NOTARY_API_ISSUER_ID")
                    else
                        log_error "ORCHARD_NOTARY_API_ISSUER_ID must be a UUID for Team API Keys; set ORCHARD_NOTARY_API_KEY_TYPE=individual to omit --issuer for Individual API Keys."
                        exit 2
                    fi
                fi
                ;;
            *)
                log_error "Unsupported ORCHARD_NOTARY_API_KEY_TYPE: $NOTARY_API_KEY_TYPE"
                log_error "Use 'auto', 'team', or 'individual'."
                exit 2
                ;;
        esac
        ;;
    *)
        log_error "Unsupported ORCHARD_NOTARY_AUTH: $NOTARY_AUTH"
        log_error "Use 'profile' or 'api-key'."
        exit 2
        ;;
esac

case "$IDENTITY" in
    "Developer ID Installer:"*) ;;
    *)
        log_error "PKG signing requires a Developer ID Installer identity."
        exit 2
        ;;
esac

case "$PAYLOAD_SIGNING_IDENTITY" in
    "Developer ID Application:"*) ;;
    *)
        log_error "Payload audit requires a Developer ID Application identity in ORCHARD_PAYLOAD_SIGNING_IDENTITY."
        exit 2
        ;;
esac

PRODUCTSIGN_CMD=(productsign --sign "$IDENTITY" "$INPUT_PKG" "$OUTPUT_PKG")
NOTARY_CMD=(xcrun notarytool submit "$OUTPUT_PKG" "${NOTARY_AUTH_ARGS[@]}" --wait --output-format json)
STAPLER_CMD=(xcrun stapler staple "$OUTPUT_PKG")
CHECKSUM_CMD=(shasum -a 256 "$OUTPUT_PKG")

print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

run_payload_audit_verifier() {
    local restore_xtrace=0
    local status=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    set +e
    (
        if [[ "$PAYLOAD_AUDIT_BUILD_KEYCHAIN_CONFIGURED" == "true" ]]; then
            export ORCHARD_BUILD_KEYCHAIN="$PAYLOAD_AUDIT_BUILD_KEYCHAIN"
            if [[ "$PAYLOAD_AUDIT_KEYCHAIN_PASSWORD_CONFIGURED" == "true" ]]; then
                export ORCHARD_KEYCHAIN_PASSWORD="$PAYLOAD_AUDIT_KEYCHAIN_PASSWORD"
            fi
        fi
        "$REPO_ROOT/scripts/verify-payload-signing.sh" "$@"
    )
    status=$?
    set -e

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$status"
}

validate_positive_integer() {
    local value="$1"
    local label="$2"

    case "$value" in
        ''|*[!0-9]*)
            log_error "$label must be a positive integer: $value"
            exit 2
            ;;
        0)
            log_error "$label must be greater than zero"
            exit 2
            ;;
    esac
}

print_tail_if_present() {
    local label="$1"
    local path="$2"

    if [[ -s "$path" ]]; then
        log_error "$label tail:"
        tail -20 "$path" >&2 || true
    fi
}


RESERVED_DIAGNOSTICS_DIR=""

reserve_diagnostics_dir() {
    local configured="${ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR:-}"
    local reserved=""

    if [[ -n "$configured" ]]; then
        if [[ -e "$configured" || -L "$configured" ]]; then
            log_error "Diagnostics directory already exists: $configured"
            log_error "Choose a fresh ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR path."
            exit 1
        fi
        local old_umask
        old_umask="$(umask)"
        umask 077
        mkdir "$configured"
        umask "$old_umask"
        reserved="$configured"
    else
        local old_umask
        old_umask="$(umask)"
        umask 077
        reserved="$(mktemp -d "$OUTPUT_PKG.expand-diagnostics.XXXXXX")"
        umask "$old_umask"
    fi

    RESERVED_DIAGNOSTICS_DIR="$reserved"
}

expand_pkg_for_audit() {
    local input_pkg="$1"
    local expanded_pkg="$2"
    local diagnostics_dir="$3"
    local timeout_seconds="$4"
    local stdout_path="$diagnostics_dir/expand-full.stdout"
    local stderr_path="$diagnostics_dir/expand-full.stderr"
    local status_path="$diagnostics_dir/expand-full.status"
    local meta_path="$diagnostics_dir/expand-full.meta"
    local timeout_marker="$diagnostics_dir/expand-full.timeout"
    local expand_pid=""
    local expand_status=0
    local timed_out=false
    local deadline=0

    : > "$stdout_path"
    : > "$stderr_path"
    rm -f "$status_path" "$meta_path" "$timeout_marker"

    {
        printf 'input=%s\n' "$input_pkg"
        if [[ -f "$input_pkg" ]]; then
            printf 'input_size_bytes=%s\n' "$(stat -f '%z' "$input_pkg" 2>/dev/null || stat -c '%s' "$input_pkg" 2>/dev/null || printf unknown)"
            printf 'input_sha256=%s\n' "$(shasum -a 256 "$input_pkg" | awk '{print $1}')"
        fi
        printf 'expanded_dir=%s\n' "$expanded_pkg"
        printf 'timeout_seconds=%s\n' "$timeout_seconds"
    } > "$meta_path"

    if [[ "${ORCHARD_DISABLE_PERL_SETSID_FOR_TEST:-}" == "1" ]] || ! command -v perl >/dev/null 2>&1 || ! perl -MPOSIX=setsid -e 'exit 0' >/dev/null 2>&1; then
        log_error "perl with POSIX::setsid is required for bounded pkgutil process-group cleanup"
        log_error "Expansion diagnostics: $diagnostics_dir"
        printf 'status=125
' > "$status_path"
        return 125
    fi

    perl -MPOSIX=setsid -e 'setsid() or die "setsid failed: $!"; exec @ARGV' pkgutil --expand-full "$input_pkg" "$expanded_pkg" >"$stdout_path" 2>"$stderr_path" &
    expand_pid=$!
    deadline=$((SECONDS + timeout_seconds))

    while kill -0 "$expand_pid" 2>/dev/null; do
        if (( SECONDS >= deadline )); then
            timed_out=true
            printf 'timeout_after_seconds=%s\n' "$timeout_seconds" > "$timeout_marker"
            kill -TERM -- "-$expand_pid" 2>/dev/null || kill "$expand_pid" 2>/dev/null || true
            sleep 2
            # The group leader may exit on TERM while descendants keep running.
            # Always KILL the process group after the grace period; ignore ESRCH
            # when the whole group already exited.
            kill -KILL -- "-$expand_pid" 2>/dev/null || true
            break
        fi
        sleep 1
    done

    set +e
    wait "$expand_pid"
    expand_status=$?
    set -e

    if [[ "$timed_out" == "true" ]]; then
        expand_status=124
    fi

    printf 'status=%s\n' "$expand_status" > "$status_path"

    if [[ "$timed_out" == "true" ]]; then
        log_error "Timed out expanding PKG for payload audit after ${timeout_seconds}s: $input_pkg"
        log_error "Expansion diagnostics: $diagnostics_dir"
        print_tail_if_present "pkgutil stdout" "$stdout_path"
        print_tail_if_present "pkgutil stderr" "$stderr_path"
        return 124
    fi

    if [[ "$expand_status" -ne 0 ]]; then
        log_error "pkgutil --expand-full failed during payload audit with status $expand_status"
        log_error "Expansion diagnostics: $diagnostics_dir"
        print_tail_if_present "pkgutil stdout" "$stdout_path"
        print_tail_if_present "pkgutil stderr" "$stderr_path"
        return "$expand_status"
    fi

    log_info "Expansion diagnostics: $diagnostics_dir"
    return 0
}

if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Dry run: no files will be modified and no Apple services will be contacted."
    log_info "Would audit payload before productsign with:"
    print_command pkgutil --expand-full "$INPUT_PKG" '<temporary-expanded-pkg>' '# bounded by ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS'
    print_command "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity '${ORCHARD_PAYLOAD_SIGNING_IDENTITY}' '<temporary-expanded-pkg>'
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

if ! command -v pkgutil >/dev/null 2>&1; then
    log_error "pkgutil is required but was not found on PATH."
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

if [[ "$NOTARY_AUTH" == "api-key" && ! -f "$NOTARY_API_KEY_PATH" ]]; then
    log_error "App Store Connect API key does not exist: $NOTARY_API_KEY_PATH"
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

EXPAND_TIMEOUT_SECONDS="${ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS:-600}"
validate_positive_integer "$EXPAND_TIMEOUT_SECONDS" "ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS"
reserve_diagnostics_dir
DIAGNOSTICS_DIR="$RESERVED_DIAGNOSTICS_DIR"

WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.orchard-sign.XXXXXX")"
TMP_SIGNED_PKG="$WORK_DIR/$(basename "$OUTPUT_PKG")"
TMP_NOTARY_JSON="$WORK_DIR/notary.json"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

PRODUCTSIGN_CMD=(productsign --sign "$IDENTITY" "$INPUT_PKG" "$TMP_SIGNED_PKG")
NOTARY_CMD=(xcrun notarytool submit "$TMP_SIGNED_PKG" "${NOTARY_AUTH_ARGS[@]}" --wait --output-format json)
STAPLER_CMD=(xcrun stapler staple "$TMP_SIGNED_PKG")
CHECKSUM_CMD=(shasum -a 256 "$TMP_SIGNED_PKG")

log_info "Auditing nested Mach-O payload signatures before productsign..."
EXPANDED_PKG="$WORK_DIR/expanded"
expand_pkg_for_audit "$INPUT_PKG" "$EXPANDED_PKG" "$DIAGNOSTICS_DIR" "$EXPAND_TIMEOUT_SECONDS"
if ! run_payload_audit_verifier --identity "$PAYLOAD_SIGNING_IDENTITY" "$EXPANDED_PKG"; then
    log_error "Refusing to envelope-sign a PKG with unsigned payload Mach-O binaries (run scripts/build-pkg.sh with ORCHARD_PAYLOAD_SIGNING_IDENTITY)."
    exit 1
fi
PAYLOAD_AUDIT_KEYCHAIN_PASSWORD=""
PAYLOAD_AUDIT_KEYCHAIN_PASSWORD_CONFIGURED=false

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
