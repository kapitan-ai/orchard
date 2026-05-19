#!/bin/bash
#
# Verify nested Mach-O payload signatures in an Orchard PKG staging or expanded tree.
# Usage: scripts/verify-payload-signing.sh --identity 'Developer ID Application: ...' <root>

set -euo pipefail

KEYCHAIN_PASSWORD=""
_keychain_password_restore_xtrace=0
case "$-" in
    *x*)
        _keychain_password_restore_xtrace=1
        set +x
        ;;
esac
if [[ -n "${ORCHARD_KEYCHAIN_PASSWORD:-}" ]]; then
    KEYCHAIN_PASSWORD="$ORCHARD_KEYCHAIN_PASSWORD"
fi
unset ORCHARD_KEYCHAIN_PASSWORD
if [[ "$_keychain_password_restore_xtrace" -eq 1 ]]; then
    set -x
fi
unset _keychain_password_restore_xtrace

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/build-keychain.sh"

IDENTITY=""
ROOT=""
KEYCHAIN_PATH=""
HAS_KEYCHAIN=false

usage() {
    cat <<'EOF'
Usage: scripts/verify-payload-signing.sh --identity <Developer ID Application identity> <root>

Audits every Mach-O file under a staging or expanded PKG root. The verifier
fails when a Mach-O is unsigned, lacks hardened runtime, lacks a secure
timestamp, or is not signed by the expected Developer ID Application identity.
It also enforces whole-payload Mach-O dependency closure and staged Python
virtualenv closure checks before accepting signing metadata.
EOF
}

log_error() { printf '[ERROR] %s\n' "$*" >&2; }

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

xtrace_enabled() {
    case "$-" in
        *x*) return 0 ;;
        *) return 1 ;;
    esac
}

suppress_xtrace() {
    if xtrace_enabled; then
        set +x
        return 0
    fi
    return 1
}

restore_xtrace() {
    local restore="$1"
    if [[ "$restore" -eq 1 ]]; then
        set -x
    fi
    return 0
}

capture_build_keychain_path() {
    local restore=0
    local status=0
    if suppress_xtrace; then
        restore=1
    fi

    KEYCHAIN_PATH="$(orchard_assert_build_keychain)" || status=$?
    if [[ "$status" -eq 0 && -n "$KEYCHAIN_PATH" ]]; then
        HAS_KEYCHAIN=true
    else
        HAS_KEYCHAIN=false
    fi

    restore_xtrace "$restore"
    return "$status"
}

prepare_build_keychain_if_needed() {
    local restore=0
    local status=0
    if [[ "$HAS_KEYCHAIN" != "true" ]]; then
        return 0
    fi

    if suppress_xtrace; then
        restore=1
    fi

    orchard_prepare_build_keychain "$KEYCHAIN_PATH" "$KEYCHAIN_PASSWORD" || status=$?
    restore_xtrace "$restore"
    return "$status"
}

redact_keychain_diagnostics() {
    local token
    if [[ "$HAS_KEYCHAIN" == "true" ]]; then
        token="<build-keychain:${KEYCHAIN_PATH##*/}>"
        ORCHARD_REDACT_KEYCHAIN_PATH="$KEYCHAIN_PATH" ORCHARD_REDACT_KEYCHAIN_TOKEN="$token" \
            perl -0pe 'BEGIN { $path = $ENV{"ORCHARD_REDACT_KEYCHAIN_PATH"}; $token = $ENV{"ORCHARD_REDACT_KEYCHAIN_TOKEN"}; } s/\Q$path\E/$token/g'
    else
        cat
    fi
}

redacted_diagnostics() {
    local output="$1"
    printf '%s' "$output" | redact_keychain_diagnostics
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity)
            if [[ $# -lt 2 ]]; then
                log_error "Missing value for --identity"
                usage
                exit 64
            fi
            IDENTITY="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 64
            ;;
        *)
            if [[ -n "$ROOT" ]]; then
                log_error "Only one root may be supplied"
                usage
                exit 64
            fi
            ROOT="$1"
            shift
            ;;
    esac
done

IDENTITY="$(trim "$IDENTITY")"
ROOT="$(trim "$ROOT")"

if [[ -z "$IDENTITY" ]]; then
    log_error "--identity is required."
    usage
    exit 64
fi

case "$IDENTITY" in
    "Developer ID Application:"*) ;;
    *)
        log_error "Payload verification requires a Developer ID Application identity."
        exit 64
        ;;
esac

if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
    log_error "root does not exist: ${ROOT:-<missing>}"
    exit 66
fi

for required in codesign xcrun file otool; do
    if ! command -v "$required" >/dev/null 2>&1; then
        log_error "$required is required but was not found on PATH."
        exit 69
    fi
done

if ! xcrun -f codesign >/dev/null 2>&1; then
    log_error "xcrun could not locate codesign. Install Xcode Command Line Tools."
    exit 69
fi

capture_build_keychain_path

if [[ "$HAS_KEYCHAIN" == "true" ]] && ! command -v perl >/dev/null 2>&1; then
    log_error "perl is required for keychain diagnostic redaction when ORCHARD_BUILD_KEYCHAIN is configured."
    exit 69
fi

prepare_build_keychain_if_needed

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orchard-payload-verify.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ALL_FILES="$TMP_DIR/all-files.bin"
find -P "$ROOT" -type f -print0 > "$ALL_FILES"

relative_path() {
    local path="$1"
    printf '%s' "${path#$ROOT/}"
}

is_macho() {
    local mime
    mime="$(file -b --mime-type "$1" 2>/dev/null || true)"
    grep -Fq 'application/x-mach-binary' <<< "$mime"
}

emit() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3"
}

FAILURES=0
MACHO_COUNT=0
CLOSURE_OUT="$TMP_DIR/closure.out"
if ! "$REPO_ROOT/scripts/verify-staged-venv-closure.sh" --no-smoke "$ROOT" > "$CLOSURE_OUT" 2>&1; then
    FAILURES=$((FAILURES + 1))
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        emit "closure" "fail" "$line"
    done < "$CLOSURE_OUT"
fi

verify_macho() {
    local path="$1"
    local rel_path display verify_out flags_line timestamp_line leaf_authority entitlements
    local verify_cmd display_cmd entitlements_cmd
    local restore=0

    rel_path="$(relative_path "$path")"

    if [[ "$HAS_KEYCHAIN" == "true" ]]; then
        if suppress_xtrace; then
            restore=1
        fi
    fi

    verify_cmd=(codesign --verify --strict --verbose=4)
    if [[ "$HAS_KEYCHAIN" == "true" ]]; then
        verify_cmd+=(--keychain "$KEYCHAIN_PATH")
    fi
    verify_cmd+=("$path")

    if ! verify_out="$("${verify_cmd[@]}" 2>&1)"; then
        verify_out="$(redacted_diagnostics "$verify_out")"
        restore_xtrace "$restore"
        if grep -Eiq 'not signed|unsigned|adhoc' <<< "$verify_out"; then
            emit "$rel_path" "fail" "unsigned"
        else
            emit "$rel_path" "fail" "codesign verify failed: $verify_out"
        fi
        return 1
    fi

    display_cmd=(codesign --display --verbose=4)
    if [[ "$HAS_KEYCHAIN" == "true" ]]; then
        display_cmd+=(--keychain "$KEYCHAIN_PATH")
    fi
    display_cmd+=("$path")

    if ! display="$("${display_cmd[@]}" 2>&1)"; then
        display="$(redacted_diagnostics "$display")"
        restore_xtrace "$restore"
        emit "$rel_path" "fail" "codesign display failed: $display"
        return 1
    fi

    if grep -Eiq 'Signature=adhoc|code object is not signed|not signed' <<< "$display"; then
        restore_xtrace "$restore"
        emit "$rel_path" "fail" "unsigned"
        return 1
    fi

    flags_line="$(grep -E '^[[:space:]]*CodeDirectory[[:space:]].*[[:space:]]flags=' <<< "$display" | head -1 || true)"
    if [[ -z "$flags_line" || "$flags_line" != *runtime* ]]; then
        restore_xtrace "$restore"
        emit "$rel_path" "fail" "missing hardened runtime"
        return 1
    fi

    timestamp_line="$(grep -E '(^|[[:space:]])Timestamp=' <<< "$display" | tail -1 || true)"
    if [[ -z "$timestamp_line" || "$timestamp_line" == *Timestamp=none* ]]; then
        restore_xtrace "$restore"
        emit "$rel_path" "fail" "missing secure timestamp"
        return 1
    fi

    leaf_authority="$(grep -E '(^|[[:space:]])Authority=' <<< "$display" | head -1 | sed 's/^[[:space:]]*//' || true)"
    if [[ "$leaf_authority" != "Authority=$IDENTITY" ]]; then
        restore_xtrace "$restore"
        emit "$rel_path" "fail" "wrong identity"
        return 1
    fi

    entitlements_cmd=(codesign --display --entitlements :-)
    if [[ "$HAS_KEYCHAIN" == "true" ]]; then
        entitlements_cmd+=(--keychain "$KEYCHAIN_PATH")
    fi
    entitlements_cmd+=("$path")

    entitlements="$("${entitlements_cmd[@]}" 2>&1 || true)"
    entitlements="$(redacted_diagnostics "$entitlements")"
    if grep -Fq 'com.apple.security.cs.disable-library-validation' <<< "$entitlements"; then
        restore_xtrace "$restore"
        emit "$rel_path" "fail" "forbidden entitlement: com.apple.security.cs.disable-library-validation"
        return 1
    fi

    restore_xtrace "$restore"
    emit "$rel_path" "ok" "ok"
}

while IFS= read -r -d '' path; do
    [[ -n "$path" ]] || continue
    if ! is_macho "$path"; then
        continue
    fi
    MACHO_COUNT=$((MACHO_COUNT + 1))
    if ! verify_macho "$path"; then
        FAILURES=$((FAILURES + 1))
    fi
done < "$ALL_FILES"

if [[ "$MACHO_COUNT" -eq 0 ]]; then
    emit "." "fail" "no Mach-O files found"
    FAILURES=$((FAILURES + 1))
fi

if [[ "$FAILURES" -ne 0 ]]; then
    exit 1
fi
