#!/bin/bash
#
# Sign, notarize, and staple an Orchard PKG for distribution.
#
# This script intentionally requires an explicit Developer ID Installer
# identity and explicit notarization credentials. Optional ORCHARD_BUILD_KEYCHAIN
# support is limited to payload audit and productsign. In prepared productsign
# mode, the build keychain must already be in the active user keychain search
# list; this script verifies that condition read-only and never mutates default
# keychain or search-list state. Secret and keychain diagnostics are redacted.
#

set -euo pipefail

_sign_pkg_initial_restore_xtrace=0
case "$-" in
    *x*)
        _sign_pkg_initial_restore_xtrace=1
        set +x
        ;;
esac

PAYLOAD_AUDIT_BUILD_KEYCHAIN=""
PAYLOAD_AUDIT_BUILD_KEYCHAIN_CONFIGURED=false
PAYLOAD_AUDIT_KEYCHAIN_PASSWORD=""
PAYLOAD_AUDIT_KEYCHAIN_PASSWORD_CONFIGURED=false
OUTER_PRODUCTSIGN_BUILD_KEYCHAIN=""
OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_CONFIGURED=false
OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED=""
OUTER_PRODUCTSIGN_KEYCHAIN_PASSWORD=""
OUTER_PRODUCTSIGN_KEYCHAIN_PASSWORD_CONFIGURED=false
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
    OUTER_PRODUCTSIGN_BUILD_KEYCHAIN="$ORCHARD_BUILD_KEYCHAIN"
    OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_CONFIGURED=true
    if [[ -n "${ORCHARD_KEYCHAIN_PASSWORD:-}" ]]; then
        PAYLOAD_AUDIT_KEYCHAIN_PASSWORD="$ORCHARD_KEYCHAIN_PASSWORD"
        PAYLOAD_AUDIT_KEYCHAIN_PASSWORD_CONFIGURED=true
        OUTER_PRODUCTSIGN_KEYCHAIN_PASSWORD="$ORCHARD_KEYCHAIN_PASSWORD"
        OUTER_PRODUCTSIGN_KEYCHAIN_PASSWORD_CONFIGURED=true
    fi
fi
unset ORCHARD_KEYCHAIN_PASSWORD
unset ORCHARD_BUILD_KEYCHAIN
if [[ "$_payload_audit_keychain_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _payload_audit_keychain_restore_xtrace

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/build-keychain.sh
source "$REPO_ROOT/scripts/lib/build-keychain.sh"

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
  ORCHARD_BUILD_KEYCHAIN                Optional prepared build keychain for payload audit and productsign
  ORCHARD_KEYCHAIN_PASSWORD             Optional build keychain password for same-process unlock/partition prep
  ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE     auto (default), flag, or prepared when ORCHARD_BUILD_KEYCHAIN is set

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
unset ORCHARD_PKG_SIGNING_IDENTITY
NOTARY_AUTH="${ORCHARD_NOTARY_AUTH:-profile}"
NOTARY_PROFILE="${ORCHARD_NOTARYTOOL_PROFILE:-}"
NOTARY_API_KEY_PATH="${ORCHARD_NOTARY_API_KEY_PATH:-}"
NOTARY_API_KEY_ID="${ORCHARD_NOTARY_API_KEY_ID:-}"
NOTARY_API_KEY_TYPE="${ORCHARD_NOTARY_API_KEY_TYPE:-auto}"
NOTARY_API_ISSUER_ID="${ORCHARD_NOTARY_API_ISSUER_ID:-}"
unset ORCHARD_NOTARY_AUTH
unset ORCHARD_NOTARYTOOL_PROFILE
unset ORCHARD_NOTARY_API_KEY_PATH
unset ORCHARD_NOTARY_API_KEY_ID
unset ORCHARD_NOTARY_API_KEY_TYPE
unset ORCHARD_NOTARY_API_ISSUER_ID
PAYLOAD_SIGNING_IDENTITY="${ORCHARD_PAYLOAD_SIGNING_IDENTITY:-}"
unset ORCHARD_PAYLOAD_SIGNING_IDENTITY
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

NOTARY_AUTH_ARGS=()
NOTARY_DRY_AUTH_ARGS=()

case "$NOTARY_AUTH" in
    profile)
        require_value "$NOTARY_PROFILE" "notarytool profile" "Set --notary-profile or ORCHARD_NOTARYTOOL_PROFILE."
        NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
        NOTARY_DRY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
        ;;
    api-key)
        require_value "$NOTARY_API_KEY_PATH" "ORCHARD_NOTARY_API_KEY_PATH" "Set it to the App Store Connect API key .p8 path."
        require_value "$NOTARY_API_KEY_ID" "ORCHARD_NOTARY_API_KEY_ID" "Set it to the App Store Connect API key ID."
        NOTARY_AUTH_ARGS=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID")
        NOTARY_DRY_AUTH_ARGS=(--key '<notary-api-key>' --key-id '<notary-api-key-id>')
        case "$NOTARY_API_KEY_TYPE" in
            individual)
                ;;
            team)
                require_value "$NOTARY_API_ISSUER_ID" "ORCHARD_NOTARY_API_ISSUER_ID" "Set it to the App Store Connect issuer UUID for Team API Keys."
                if is_uuid "$NOTARY_API_ISSUER_ID"; then
                    NOTARY_AUTH_ARGS+=(--issuer "$NOTARY_API_ISSUER_ID")
                    NOTARY_DRY_AUTH_ARGS+=(--issuer '<notary-issuer-id>')
                else
                    log_error "ORCHARD_NOTARY_API_ISSUER_ID must be a UUID for Team API Keys."
                    exit 2
                fi
                ;;
            auto)
                if [[ -n "$NOTARY_API_ISSUER_ID" ]]; then
                    if is_uuid "$NOTARY_API_ISSUER_ID"; then
                        NOTARY_AUTH_ARGS+=(--issuer "$NOTARY_API_ISSUER_ID")
                        NOTARY_DRY_AUTH_ARGS+=(--issuer '<notary-issuer-id>')
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

PRODUCTSIGN_KEYCHAIN_MODE="auto"
PRODUCTSIGN_KEYCHAIN_STRATEGY="none"
PRODUCTSIGN_PROBE_STATUS="not_configured"
PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="not_probed"
PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS="${ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS:-30}"
PRODUCTSIGN_KEYCHAIN_ARGS=()
PRODUCTSIGN_KEYCHAIN_DRY_ARGS=()
PRODUCTSIGN_CMD=(productsign --sign "$IDENTITY" "$INPUT_PKG" "$OUTPUT_PKG")
NOTARY_CMD=(xcrun notarytool submit "$OUTPUT_PKG" "${NOTARY_AUTH_ARGS[@]}" --wait --output-format json)
STAPLER_CMD=(xcrun stapler staple "$OUTPUT_PKG")
CHECKSUM_CMD=(shasum -a 256 "$OUTPUT_PKG")

if [[ "$_sign_pkg_initial_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _sign_pkg_initial_restore_xtrace

print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
}

redact_build_keychain_path() {
    local keychain_path="$1"
    local keychain_base="${keychain_path##*/}"
    printf '<build-keychain:%s>' "$keychain_base"
}

sanitize_sign_pkg_output_stream() {
    local keychain_resolved_replacement=""
    local keychain_configured_replacement=""
    local restore_xtrace=0
    local status=0

    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    if [[ -n "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED" ]]; then
        keychain_resolved_replacement="$(redact_build_keychain_path "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED")"
    fi
    if [[ -n "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN" ]]; then
        keychain_configured_replacement="$(redact_build_keychain_path "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN")"
    fi

    if ORCHARD_SANITIZE_KEYCHAIN_RESOLVED="$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED" \
    ORCHARD_SANITIZE_KEYCHAIN_RESOLVED_REPLACEMENT="$keychain_resolved_replacement" \
    ORCHARD_SANITIZE_KEYCHAIN_CONFIGURED="$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN" \
    ORCHARD_SANITIZE_KEYCHAIN_CONFIGURED_REPLACEMENT="$keychain_configured_replacement" \
    ORCHARD_SANITIZE_INSTALLER_IDENTITY="$IDENTITY" \
    ORCHARD_SANITIZE_PAYLOAD_IDENTITY="$PAYLOAD_SIGNING_IDENTITY" \
    ORCHARD_SANITIZE_NOTARY_API_KEY_PATH="$NOTARY_API_KEY_PATH" \
    ORCHARD_SANITIZE_NOTARY_API_KEY_ID="$NOTARY_API_KEY_ID" \
    ORCHARD_SANITIZE_NOTARY_API_ISSUER_ID="$NOTARY_API_ISSUER_ID" \
    perl -pe '
        BEGIN {
            @raw_pairs = (
                [$ENV{"ORCHARD_SANITIZE_KEYCHAIN_RESOLVED"}, "__ORCHARD_REDACT_KEYCHAIN_RESOLVED__"],
                [$ENV{"ORCHARD_SANITIZE_KEYCHAIN_CONFIGURED"}, "__ORCHARD_REDACT_KEYCHAIN_CONFIGURED__"],
                [$ENV{"ORCHARD_SANITIZE_INSTALLER_IDENTITY"}, "__ORCHARD_REDACT_INSTALLER_IDENTITY__"],
                [$ENV{"ORCHARD_SANITIZE_PAYLOAD_IDENTITY"}, "__ORCHARD_REDACT_PAYLOAD_IDENTITY__"],
                [$ENV{"ORCHARD_SANITIZE_NOTARY_API_KEY_PATH"}, "__ORCHARD_REDACT_NOTARY_API_KEY_PATH__"],
                [$ENV{"ORCHARD_SANITIZE_NOTARY_API_KEY_ID"}, "__ORCHARD_REDACT_NOTARY_API_KEY_ID__"],
                [$ENV{"ORCHARD_SANITIZE_NOTARY_API_ISSUER_ID"}, "__ORCHARD_REDACT_NOTARY_API_ISSUER_ID__"]
            );
            @sentinel_pairs = (
                ["__ORCHARD_REDACT_KEYCHAIN_RESOLVED__", $ENV{"ORCHARD_SANITIZE_KEYCHAIN_RESOLVED_REPLACEMENT"}],
                ["__ORCHARD_REDACT_KEYCHAIN_CONFIGURED__", $ENV{"ORCHARD_SANITIZE_KEYCHAIN_CONFIGURED_REPLACEMENT"}],
                ["__ORCHARD_REDACT_INSTALLER_IDENTITY__", "<id>"],
                ["__ORCHARD_REDACT_PAYLOAD_IDENTITY__", "<id>"],
                ["__ORCHARD_REDACT_NOTARY_API_KEY_PATH__", "<notary-api-key>"],
                ["__ORCHARD_REDACT_NOTARY_API_KEY_ID__", "<notary-api-key-id>"],
                ["__ORCHARD_REDACT_NOTARY_API_ISSUER_ID__", "<notary-issuer-id>"]
            );
        }
        for my $pair (@raw_pairs) {
            next unless defined $pair->[0] && length $pair->[0];
            s/\Q$pair->[0]\E/$pair->[1]/g;
        }
        for my $pair (@sentinel_pairs) {
            next unless defined $pair->[1] && length $pair->[1];
            s/\Q$pair->[0]\E/$pair->[1]/g;
        }
    '
    then
        status=0
    else
        status=$?
    fi

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$status"
}

sanitize_sign_pkg_value() {
    printf '%s' "$1" | sanitize_sign_pkg_output_stream
}

validate_outer_productsign_keychain() {
    if [[ "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_CONFIGURED" != "true" ]]; then
        return 0
    fi

    local restore_xtrace=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    local resolved=""
    local status=0
    resolved="$(_orchard_canonicalize_build_keychain "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN")" || status=$?
    if [[ "$status" -eq 0 ]]; then
        OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED="$resolved"
    fi

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$status"
}

resolve_productsign_mode() {
    if [[ "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_CONFIGURED" != "true" ]]; then
        PRODUCTSIGN_KEYCHAIN_MODE="ignored"
        return 0
    fi

    local restore_xtrace=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    PRODUCTSIGN_KEYCHAIN_MODE="${ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE:-auto}"
    PRODUCTSIGN_KEYCHAIN_MODE="$(trim "$PRODUCTSIGN_KEYCHAIN_MODE")"
    case "$PRODUCTSIGN_KEYCHAIN_MODE" in
        auto|flag|prepared)
            if [[ "$restore_xtrace" -eq 1 ]]; then
                set -x
            fi
            ;;
        *)
            if [[ "$restore_xtrace" -eq 1 ]]; then
                set -x
            fi
            log_error "Unsupported ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE value."
            log_error "Use 'auto', 'flag', or 'prepared'."
            exit 2
            ;;
    esac
}

set_productsign_keychain_strategy() {
    local strategy="$1"
    local restore_xtrace=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    PRODUCTSIGN_KEYCHAIN_STRATEGY="$strategy"
    PRODUCTSIGN_KEYCHAIN_ARGS=()
    PRODUCTSIGN_KEYCHAIN_DRY_ARGS=()
    case "$strategy" in
        flag)
            PRODUCTSIGN_KEYCHAIN_ARGS=(--keychain "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED")
            PRODUCTSIGN_KEYCHAIN_DRY_ARGS=(--keychain "$(redact_build_keychain_path "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED")")
            ;;
        prepared|none)
            ;;
        *)
            if [[ "$restore_xtrace" -eq 1 ]]; then
                set -x
            fi
            log_error "Internal error: unknown productsign keychain strategy: $strategy"
            exit 1
            ;;
    esac

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
}

classify_productsign_keychain_probe_stderr() {
    local stderr_text="$1"
    local lowered
    lowered="$(printf '%s' "$stderr_text" | tr '[:upper:]' '[:lower:]')"

    if [[ "$lowered" =~ unknown[[:space:]]+option|unrecognized[[:space:]]+option|unknown[[:space:]]+argument|unrecognized[[:space:]]+argument|invalid[[:space:]]+option|unknown[[:space:]]+flag|illegal[[:space:]]+option|no[[:space:]]+such[[:space:]]+option ]]; then
        printf 'no\n'
        return 0
    fi

    if [[ "$lowered" =~ invalid.*(identity|input|package)|cannot[[:space:]]+(open|write)|can.t[[:space:]]+(open|write)|could[[:space:]]+not[[:space:]]+(open|write|find)|keychain.*(open|opened|found|validation)|signing[[:space:]]+identity|no[[:space:]]+such[[:space:]]+file ]]; then
        printf 'yes\n'
        return 0
    fi

    printf 'inconclusive\n'
}

run_productsign_keychain_probe_with_timeout() {
    local timeout_seconds="$1"
    shift

    if [[ "${ORCHARD_DISABLE_PERL_SETSID_FOR_TEST:-}" == "1" ]] || ! command -v perl >/dev/null 2>&1 || ! perl -MPOSIX=setsid -e 'exit 0' >/dev/null 2>&1; then
        log_error "perl with POSIX::setsid is required for bounded productsign probe cleanup" >&2
        return 125
    fi

    perl -MPOSIX=setsid -e '
            my $timeout = shift @ARGV;
            my $pid = fork();
            die "fork failed: $!\n" unless defined $pid;
            if ($pid == 0) {
                setsid() or die "setsid failed: $!\n";
                exec @ARGV or die "exec failed: $!\n";
            }
            local $SIG{ALRM} = sub {
                kill "TERM", -$pid;
                sleep 1;
                kill "KILL", -$pid;
                exit 124;
            };
            alarm $timeout;
            waitpid($pid, 0);
            my $status = $?;
            if ($status == -1) {
                exit 125;
            }
            if ($status & 127) {
                exit(128 + ($status & 127));
            }
            exit($status >> 8);
        ' "$timeout_seconds" "$@"
}

probe_productsign_keychain_flag() {
    local probe_dir=""
    local stderr_path=""
    local stderr_text=""
    local status=0
    local verdict="inconclusive"

    if ! probe_dir="$(mktemp -d 2>/dev/null)"; then
        PRODUCTSIGN_PROBE_STATUS="inconclusive"
        PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="inconclusive"
        log_error "productsign --keychain probe was inconclusive: tempdir creation failed"
        exit 1
    fi
    stderr_path="$probe_dir/productsign-probe.stderr"

    set +e
    run_productsign_keychain_probe_with_timeout "$PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS" \
        productsign --sign 'orchard-flag-probe-invalid-identity' \
            --keychain "$probe_dir/bogus.keychain-db" \
            /dev/null "$probe_dir/bogus-out.pkg" \
            >/dev/null 2>"$stderr_path"
    status=$?
    set -e

    stderr_text="$(cat "$stderr_path" 2>/dev/null || true)"
    rm -rf "$probe_dir"

    if [[ "$status" -eq 124 ]]; then
        PRODUCTSIGN_PROBE_STATUS="inconclusive"
        PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="inconclusive"
        log_error "productsign --keychain probe timed out after ${PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS}s"
        exit 1
    fi

    if [[ "$status" -eq 125 ]]; then
        PRODUCTSIGN_PROBE_STATUS="inconclusive"
        PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="inconclusive"
        log_error "perl with POSIX::setsid is required for bounded productsign probe cleanup"
        exit 1
    fi

    if [[ -n "$stderr_text" ]]; then
        verdict="$(classify_productsign_keychain_probe_stderr "$stderr_text")"
    else
        verdict="inconclusive"
    fi

    PRODUCTSIGN_PROBE_STATUS="run"
    case "$verdict" in
        yes)
            PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="yes"
            ;;
        no)
            PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="no"
            ;;
        *)
            PRODUCTSIGN_PROBE_STATUS="inconclusive"
            PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="inconclusive"
            log_error "productsign --keychain probe was inconclusive"
            if [[ -n "$stderr_text" ]]; then
                log_error "productsign probe stderr tail:"
                printf '%s\n' "$stderr_text" | sanitize_sign_pkg_output_stream | tail -20 >&2 || true
            else
                log_error "productsign probe emitted no stderr"
            fi
            exit 1
            ;;
    esac
    return "$status"
}

resolve_productsign_keychain_strategy() {
    local dry_run="$1"

    if [[ "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_CONFIGURED" != "true" ]]; then
        set_productsign_keychain_strategy none
        return 0
    fi

    validate_outer_productsign_keychain
    resolve_productsign_mode

    case "$PRODUCTSIGN_KEYCHAIN_MODE" in
        flag)
            PRODUCTSIGN_PROBE_STATUS="skipped"
            PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="not_probed"
            set_productsign_keychain_strategy flag
            ;;
        prepared)
            PRODUCTSIGN_PROBE_STATUS="skipped"
            PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="not_probed"
            set_productsign_keychain_strategy prepared
            ;;
        auto)
            if [[ "$dry_run" == "true" ]]; then
                PRODUCTSIGN_PROBE_STATUS="skipped"
                PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED="not_probed"
                set_productsign_keychain_strategy flag
            else
                validate_positive_integer "$PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS" "ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS"
                probe_productsign_keychain_flag || true
                if [[ "$PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED" == "yes" ]]; then
                    set_productsign_keychain_strategy flag
                elif [[ "$PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED" == "no" ]]; then
                    set_productsign_keychain_strategy prepared
                else
                    log_error "productsign --keychain probe was inconclusive"
                    exit 1
                fi
            fi
            ;;
    esac
}

assert_prepared_productsign_keychain_in_search_list() {
    if [[ "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_CONFIGURED" != "true" || "$PRODUCTSIGN_KEYCHAIN_STRATEGY" != "prepared" ]]; then
        return 0
    fi

    local restore_xtrace=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    local search_list_output=""
    local list_status=0
    set +e
    search_list_output="$(security list-keychains 2>/dev/null)"
    list_status=$?
    set -e

    if [[ "$list_status" -ne 0 ]]; then
        if [[ "$restore_xtrace" -eq 1 ]]; then
            set -x
        fi
        log_error "Unable to read active keychain search list for prepared productsign mode."
        return "$list_status"
    fi

    local found=false
    local line=""
    local entry=""
    local canonical_entry=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        entry="$(trim "$line")"
        if [[ "$entry" == \"*\" && "${#entry}" -ge 2 ]]; then
            entry="${entry:1:${#entry}-2}"
        fi
        if [[ -z "$entry" ]]; then
            continue
        fi
        if [[ "$entry" == "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED" ]]; then
            found=true
            break
        fi
        if canonical_entry="$(_orchard_canonicalize_build_keychain "$entry" 2>/dev/null)"; then
            if [[ "$canonical_entry" == "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED" ]]; then
                found=true
                break
            fi
        fi
    done <<< "$search_list_output"

    if [[ "$found" == "true" ]]; then
        if [[ "$restore_xtrace" -eq 1 ]]; then
            set -x
        fi
        return 0
    fi

    local redacted_keychain
    redacted_keychain="$(redact_build_keychain_path "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED")"

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi

    log_error "Prepared productsign keychain is not in the active keychain search list: $redacted_keychain"
    return 1
}

log_productsign_keychain_runtime_row() {
    if [[ "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_CONFIGURED" != "true" ]]; then
        return 0
    fi
    log_info "Productsign keychain runtime: runtime_probe_status=$PRODUCTSIGN_PROBE_STATUS runtime_productsign_keychain_flag_accepted=$PRODUCTSIGN_KEYCHAIN_FLAG_ACCEPTED strategy=$PRODUCTSIGN_KEYCHAIN_STRATEGY mode=$PRODUCTSIGN_KEYCHAIN_MODE"
}

prepare_outer_productsign_build_keychain() {
    if [[ "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_CONFIGURED" != "true" ]]; then
        return 0
    fi

    local restore_xtrace=0
    local status=0
    local old_dry_run="${ORCHARD_BUILD_KEYCHAIN_DRY_RUN:-}"
    local had_dry_run=0

    if [[ -n "${ORCHARD_BUILD_KEYCHAIN_DRY_RUN+x}" ]]; then
        had_dry_run=1
    fi

    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    if [[ "$DRY_RUN" == "true" ]]; then
        export ORCHARD_BUILD_KEYCHAIN_DRY_RUN=1
    fi

    set +e
    orchard_prepare_build_keychain "$OUTER_PRODUCTSIGN_BUILD_KEYCHAIN_RESOLVED" "$OUTER_PRODUCTSIGN_KEYCHAIN_PASSWORD"
    status=$?
    set -e

    if [[ "$had_dry_run" -eq 1 ]]; then
        export ORCHARD_BUILD_KEYCHAIN_DRY_RUN="$old_dry_run"
    else
        unset ORCHARD_BUILD_KEYCHAIN_DRY_RUN
    fi

    OUTER_PRODUCTSIGN_KEYCHAIN_PASSWORD=""
    OUTER_PRODUCTSIGN_KEYCHAIN_PASSWORD_CONFIGURED=false

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$status"
}

run_productsign_command() {
    local restore_xtrace=0
    local status=0
    local stdout_path="$WORK_DIR/productsign.stdout"
    local stderr_path="$WORK_DIR/productsign.stderr"

    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    set +e
    "${PRODUCTSIGN_CMD[@]}" >"$stdout_path" 2>"$stderr_path"
    status=$?
    set -e

    sanitize_sign_pkg_output_stream <"$stdout_path"
    sanitize_sign_pkg_output_stream <"$stderr_path" >&2

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$status"
}

run_notary_command() {
    local restore_xtrace=0
    local status=0
    local stderr_path="$WORK_DIR/notary.stderr"

    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    set +e
    "${NOTARY_CMD[@]}" >"$TMP_NOTARY_JSON" 2>"$stderr_path"
    status=$?
    set -e

    sanitize_sign_pkg_output_stream <"$TMP_NOTARY_JSON"
    sanitize_sign_pkg_output_stream <"$stderr_path" >&2

    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    return "$status"
}

write_sanitized_notary_sidecar() {
    local raw_json_path="$1"
    local sanitized_json_path="$2"
    local temp_path="$sanitized_json_path.tmp"
    local restore_xtrace=0

    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    rm -f "$temp_path"
    if ! sanitize_sign_pkg_output_stream <"$raw_json_path" >"$temp_path"; then
        rm -f "$temp_path"
        if [[ "$restore_xtrace" -eq 1 ]]; then
            set -x
        fi
        log_error "Failed to sanitize notary JSON; refusing to publish notary sidecar."
        return 1
    fi

    if ! /usr/bin/plutil -convert json -o /dev/null "$temp_path" >/dev/null 2>&1; then
        rm -f "$temp_path"
        if [[ "$restore_xtrace" -eq 1 ]]; then
            set -x
        fi
        log_error "Sanitized notary JSON failed validation; refusing to publish notary sidecar."
        return 1
    fi

    mv "$temp_path" "$sanitized_json_path"
    if [[ "$restore_xtrace" -eq 1 ]]; then
        set -x
    fi
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
        # Keep keychain env forwarding here; isolating this child with env -i would break payload audit autonomy.
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
    resolve_productsign_keychain_strategy true
    if [[ "${#PRODUCTSIGN_KEYCHAIN_DRY_ARGS[@]}" -gt 0 ]]; then
        PRODUCTSIGN_DRY_DISPLAY_CMD=(productsign --sign '<id>' "${PRODUCTSIGN_KEYCHAIN_DRY_ARGS[@]}" "$INPUT_PKG" "$OUTPUT_PKG")
    else
        PRODUCTSIGN_DRY_DISPLAY_CMD=(productsign --sign '<id>' "$INPUT_PKG" "$OUTPUT_PKG")
    fi
    NOTARY_DRY_DISPLAY_CMD=(xcrun notarytool submit "$OUTPUT_PKG" "${NOTARY_DRY_AUTH_ARGS[@]}" --wait --output-format json)
    log_warn "Dry run: no files will be modified and no Apple services will be contacted."
    log_productsign_keychain_runtime_row
    log_info "Would audit payload before productsign with:"
    print_command pkgutil --expand-full "$INPUT_PKG" '<temporary-expanded-pkg>' '# bounded by ORCHARD_PKG_EXPAND_TIMEOUT_SECONDS'
    print_command "$REPO_ROOT/scripts/verify-payload-signing.sh" --identity '${ORCHARD_PAYLOAD_SIGNING_IDENTITY}' '<temporary-expanded-pkg>'
    log_info "Would run:"
    print_command "${PRODUCTSIGN_DRY_DISPLAY_CMD[@]}"
    print_command "${NOTARY_DRY_DISPLAY_CMD[@]}"
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

_notary_api_key_check_restore_xtrace=0
case "$-" in
    *x*)
        _notary_api_key_check_restore_xtrace=1
        set +x
        ;;
esac
_notary_api_key_missing=false
if [[ "$NOTARY_AUTH" == "api-key" && ! -f "$NOTARY_API_KEY_PATH" ]]; then
    _notary_api_key_missing=true
fi
if [[ "$_notary_api_key_check_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _notary_api_key_check_restore_xtrace
if [[ "$_notary_api_key_missing" == "true" ]]; then
    log_error "App Store Connect API key does not exist: <notary-api-key>"
    exit 1
fi
unset _notary_api_key_missing

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
resolve_productsign_keychain_strategy false
assert_prepared_productsign_keychain_in_search_list
log_productsign_keychain_runtime_row
reserve_diagnostics_dir
DIAGNOSTICS_DIR="$RESERVED_DIAGNOSTICS_DIR"

WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.orchard-sign.XXXXXX")"
TMP_SIGNED_PKG="$WORK_DIR/$(basename "$OUTPUT_PKG")"
TMP_NOTARY_JSON="$WORK_DIR/notary.json"
TMP_SANITIZED_NOTARY_JSON="$WORK_DIR/notary.sanitized.json"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

_productsign_cmd_restore_xtrace=0
case "$-" in
    *x*)
        _productsign_cmd_restore_xtrace=1
        set +x
        ;;
esac
if [[ "${#PRODUCTSIGN_KEYCHAIN_ARGS[@]}" -gt 0 ]]; then
    PRODUCTSIGN_CMD=(productsign --sign "$IDENTITY" "${PRODUCTSIGN_KEYCHAIN_ARGS[@]}" "$INPUT_PKG" "$TMP_SIGNED_PKG")
else
    PRODUCTSIGN_CMD=(productsign --sign "$IDENTITY" "$INPUT_PKG" "$TMP_SIGNED_PKG")
fi
if [[ "$_productsign_cmd_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _productsign_cmd_restore_xtrace
_notary_cmd_restore_xtrace=0
case "$-" in
    *x*)
        _notary_cmd_restore_xtrace=1
        set +x
        ;;
esac
NOTARY_CMD=(xcrun notarytool submit "$TMP_SIGNED_PKG" "${NOTARY_AUTH_ARGS[@]}" --wait --output-format json)
if [[ "$_notary_cmd_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _notary_cmd_restore_xtrace
STAPLER_CMD=(xcrun stapler staple "$TMP_SIGNED_PKG")
CHECKSUM_CMD=(shasum -a 256 "$TMP_SIGNED_PKG")

log_info "Auditing nested Mach-O payload signatures before productsign..."
EXPANDED_PKG="$WORK_DIR/expanded"
expand_pkg_for_audit "$INPUT_PKG" "$EXPANDED_PKG" "$DIAGNOSTICS_DIR" "$EXPAND_TIMEOUT_SECONDS"
_payload_audit_restore_xtrace=0
case "$-" in
    *x*)
        _payload_audit_restore_xtrace=1
        set +x
        ;;
esac
if run_payload_audit_verifier --identity "$PAYLOAD_SIGNING_IDENTITY" "$EXPANDED_PKG"; then
    _payload_audit_status=0
else
    _payload_audit_status=$?
fi
if [[ "$_payload_audit_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _payload_audit_restore_xtrace
if [[ "$_payload_audit_status" -ne 0 ]]; then
    log_error "Refusing to envelope-sign a PKG with unsigned payload Mach-O binaries (run scripts/build-pkg.sh with ORCHARD_PAYLOAD_SIGNING_IDENTITY)."
    exit 1
fi
unset _payload_audit_status
PAYLOAD_AUDIT_KEYCHAIN_PASSWORD=""
PAYLOAD_AUDIT_KEYCHAIN_PASSWORD_CONFIGURED=false

extract_notary_field() {
    local field="$1"
    local json_path="$2"

    /usr/bin/plutil -extract "$field" raw -o - "$json_path" 2>/dev/null || true
}

log_info "Signing PKG with explicit Developer ID Installer identity..."
prepare_outer_productsign_build_keychain
run_productsign_command

log_info "Submitting signed PKG for notarization and waiting for completion..."
if run_notary_command; then
    NOTARY_EXIT=0
else
    NOTARY_EXIT=$?
fi

_notary_field_restore_xtrace=0
case "$-" in
    *x*)
        _notary_field_restore_xtrace=1
        set +x
        ;;
esac
NOTARY_SUBMISSION_ID="$(extract_notary_field "id" "$TMP_NOTARY_JSON")"
NOTARY_STATUS="$(extract_notary_field "status" "$TMP_NOTARY_JSON")"

if [[ -z "$NOTARY_SUBMISSION_ID" ]]; then
    if [[ "$_notary_field_restore_xtrace" -eq 1 ]]; then
        set -x
    fi
    unset _notary_field_restore_xtrace
    log_error "notarytool output did not include a submission ID"
    exit 1
fi

NOTARY_SUBMISSION_ID_DISPLAY="$(sanitize_sign_pkg_value "$NOTARY_SUBMISSION_ID")"
NOTARY_STATUS_DISPLAY="$(sanitize_sign_pkg_value "${NOTARY_STATUS:-unknown}")"
NOTARY_STATUS_ACCEPTED=false
if [[ "$NOTARY_STATUS" == "Accepted" ]]; then
    NOTARY_STATUS_ACCEPTED=true
fi
if [[ "$_notary_field_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _notary_field_restore_xtrace

if [[ "$NOTARY_EXIT" -ne 0 ]]; then
    log_error "notarytool exited with status $NOTARY_EXIT. Notary status: $NOTARY_STATUS_DISPLAY"
    exit 1
fi

if [[ "$NOTARY_STATUS_ACCEPTED" != "true" ]]; then
    log_error "Notarization did not finish as Accepted. Status: $NOTARY_STATUS_DISPLAY"
    log_error "See notarytool output above for details."
    exit 1
fi

write_sanitized_notary_sidecar "$TMP_NOTARY_JSON" "$TMP_SANITIZED_NOTARY_JSON"

log_info "Stapling notarization ticket..."
"${STAPLER_CMD[@]}"

mv "$TMP_SIGNED_PKG" "$OUTPUT_PKG"
cp "$TMP_SANITIZED_NOTARY_JSON" "$OUTPUT_PKG.notary.json"
SHA256="$(shasum -a 256 "$OUTPUT_PKG" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$OUTPUT_PKG")" > "$OUTPUT_PKG.sha256"

log_info "Signed, notarized, and stapled PKG is ready"
log_info "   Path: $OUTPUT_PKG"
log_info "   SHA-256: $SHA256"
log_info "   Checksum: $OUTPUT_PKG.sha256"
log_info "   Notary submission ID: $NOTARY_SUBMISSION_ID_DISPLAY"
log_info "   Notary status: $NOTARY_STATUS_DISPLAY"
log_info "   Notary JSON: $OUTPUT_PKG.notary.json"
