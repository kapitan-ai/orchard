#!/bin/bash
#
# Sign nested Mach-O binaries in an Orchard PKG staging tree.
# Usage: ORCHARD_PAYLOAD_SIGNING_IDENTITY='Developer ID Application: ...' scripts/sign-payload.sh [options] <staging-base>

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

DRY_RUN=false
ENTITLEMENTS_DIR="$REPO_ROOT/packaging/pkg/entitlements"
MANIFEST_OUTPUT=""
STAGING_BASE=""
KEYCHAIN_PATH=""
HAS_KEYCHAIN=false

usage() {
    cat <<'EOF'
Usage: scripts/sign-payload.sh [options] <staging-base>

Signs every Mach-O file under a PKG staging root with an explicit Developer ID
Application identity. Libraries are signed before executables. No --deep signing
or implicit keychain identity fallback is used.

Required environment:
  ORCHARD_PAYLOAD_SIGNING_IDENTITY   Developer ID Application identity label

Options:
  --dry-run                          Print codesign commands without running them
  --entitlements-dir <dir>           Entitlements directory (default: packaging/pkg/entitlements)
  --manifest-output <path>           Write a TSV manifest outside the staging root
  --help                             Show this usage and exit
EOF
}

log_info() { printf '[INFO] %s\n' "$*"; }
log_warn() { printf '[WARN] %s\n' "$*"; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

print_command() {
    printf '  '
    printf '%q ' "$@"
    printf '\n'
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

    if [[ "$DRY_RUN" == "true" ]]; then
        export ORCHARD_BUILD_KEYCHAIN_DRY_RUN=1
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

emit_redacted_diagnostics() {
    local output="$1"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$(printf '%s' "$output" | redact_keychain_diagnostics)" >&2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --entitlements-dir)
            if [[ $# -lt 2 ]]; then
                log_error "Missing value for --entitlements-dir"
                usage
                exit 64
            fi
            ENTITLEMENTS_DIR="$2"
            shift 2
            ;;
        --manifest-output)
            if [[ $# -lt 2 ]]; then
                log_error "Missing value for --manifest-output"
                usage
                exit 64
            fi
            MANIFEST_OUTPUT="$2"
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
            if [[ -n "$STAGING_BASE" ]]; then
                log_error "Only one staging root may be supplied"
                usage
                exit 64
            fi
            STAGING_BASE="$1"
            shift
            ;;
    esac
done

IDENTITY="$(trim "${ORCHARD_PAYLOAD_SIGNING_IDENTITY:-}")"
STAGING_BASE="$(trim "$STAGING_BASE")"
ENTITLEMENTS_DIR="$(trim "$ENTITLEMENTS_DIR")"
MANIFEST_OUTPUT="$(trim "$MANIFEST_OUTPUT")"

if [[ -z "$IDENTITY" ]]; then
    log_error "ORCHARD_PAYLOAD_SIGNING_IDENTITY is required; no signing identity fallback is allowed."
    exit 64
fi

case "$IDENTITY" in
    "Developer ID Application:"*) ;;
    *)
        log_error "Payload signing requires a Developer ID Application identity."
        exit 64
        ;;
esac

if [[ -z "$STAGING_BASE" || ! -d "$STAGING_BASE" ]]; then
    log_error "staging root does not exist: ${STAGING_BASE:-<missing>}"
    exit 66
fi

if [[ ! -d "$ENTITLEMENTS_DIR" ]]; then
    log_error "entitlements directory does not exist: $ENTITLEMENTS_DIR"
    exit 66
fi

if grep -R -F -q 'com.apple.security.cs.disable-library-validation' "$ENTITLEMENTS_DIR"; then
    log_error "Refusing payload signing with com.apple.security.cs.disable-library-validation entitlement. Bundle and sign dependencies instead."
    exit 65
fi

for required in codesign xcrun file shasum; do
    if ! command -v "$required" >/dev/null 2>&1; then
        log_error "$required is required but was not found on PATH."
        exit 69
    fi
done

if ! xcrun -f codesign >/dev/null 2>&1; then
    log_error "xcrun could not locate codesign. Install Xcode Command Line Tools."
    exit 69
fi

if [[ -n "$MANIFEST_OUTPUT" ]]; then
    STAGING_BASE_CANON="$(cd "$STAGING_BASE" && pwd -P)"
    MANIFEST_DIR="$(dirname "$MANIFEST_OUTPUT")"
    MANIFEST_BASE="$(basename "$MANIFEST_OUTPUT")"
    mkdir -p "$MANIFEST_DIR"
    MANIFEST_DIR_CANON="$(cd "$MANIFEST_DIR" && pwd -P)"
    MANIFEST_OUTPUT="$MANIFEST_DIR_CANON/$MANIFEST_BASE"
    case "$MANIFEST_OUTPUT" in
        "$STAGING_BASE_CANON"|"$STAGING_BASE_CANON"/*)
            log_error "manifest output must be outside the staging root: $MANIFEST_OUTPUT"
            exit 64
            ;;
    esac
    : > "$MANIFEST_OUTPUT"
fi

capture_build_keychain_path

if [[ "$HAS_KEYCHAIN" == "true" ]] && ! command -v perl >/dev/null 2>&1; then
    log_error "perl is required for keychain diagnostic redaction when ORCHARD_BUILD_KEYCHAIN is configured."
    exit 69
fi

prepare_build_keychain_if_needed

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orchard-payload-sign.XXXXXX")"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

ALL_FILES="$TMP_DIR/all-files.bin"
LIB_FILES="$TMP_DIR/libs.bin"
EXE_FILES="$TMP_DIR/exes.bin"
: > "$LIB_FILES"
: > "$EXE_FILES"

find -P "$STAGING_BASE" -type f -print0 > "$ALL_FILES"

is_macho() {
    local mime
    mime="$(file -b --mime-type "$1" 2>/dev/null || true)"
    grep -Fq 'application/x-mach-binary' <<< "$mime"
}

relative_path() {
    local path="$1"
    printf '%s' "${path#$STAGING_BASE/}"
}

binary_class() {
    case "$1" in
        *.so|*.dylib|*.bundle) printf 'library' ;;
        *) printf 'executable' ;;
    esac
}

entitlements_class() {
    local path="$1"
    local rel_path
    rel_path="$(relative_path "$path")"

    case "$rel_path" in
        */erts-*/bin/beam.smp)
            printf 'beam'
            return
            ;;
        */.venv/bin/python*|*/.venv/bin/*)
            if [[ "$rel_path" == */.venv/bin/python* || -x "$path" ]]; then
                printf 'python'
                return
            fi
            ;;
    esac

    printf 'default'
}

entitlements_file_for() {
    local class="$1"
    printf '%s/%s.entitlements' "$ENTITLEMENTS_DIR" "$class"
}

while IFS= read -r -d '' path; do
    if ! is_macho "$path"; then
        continue
    fi

    case "$(binary_class "$path")" in
        library) printf '%s\0' "$path" >> "$LIB_FILES" ;;
        *) printf '%s\0' "$path" >> "$EXE_FILES" ;;
    esac
done < "$ALL_FILES"

sign_path() {
    local path="$1"
    local class ent_class entitlements sha rel_path
    local codesign_keychain_arg
    local codesign_args
    local codesign_output
    local codesign_status
    local restore=0

    class="$(binary_class "$path")"
    ent_class="$(entitlements_class "$path")"
    entitlements="$(entitlements_file_for "$ent_class")"

    if [[ ! -f "$entitlements" ]]; then
        log_error "missing entitlements file for $ent_class: $entitlements"
        exit 66
    fi

    if [[ "$HAS_KEYCHAIN" == "true" && "$DRY_RUN" != "true" ]]; then
        if suppress_xtrace; then
            restore=1
        fi
    fi

    codesign_args=(codesign --force --options runtime --timestamp)
    if [[ "$HAS_KEYCHAIN" == "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            codesign_keychain_arg="<build-keychain:${KEYCHAIN_PATH##*/}>"
        else
            codesign_keychain_arg="$KEYCHAIN_PATH"
        fi
        codesign_args+=(--keychain "$codesign_keychain_arg")
    fi
    codesign_args+=(--sign "$IDENTITY" --entitlements "$entitlements" "$path")

    if [[ "$DRY_RUN" == "true" ]]; then
        print_command "${codesign_args[@]}"
    else
        codesign_status=0
        codesign_output="$("${codesign_args[@]}" 2>&1)" || codesign_status=$?
        if [[ "$codesign_status" -ne 0 ]]; then
            emit_redacted_diagnostics "$codesign_output"
            restore_xtrace "$restore"
            exit "$codesign_status"
        fi
        emit_redacted_diagnostics "$codesign_output"
    fi

    restore_xtrace "$restore"

    if [[ -n "$MANIFEST_OUTPUT" ]]; then
        rel_path="$(relative_path "$path")"
        sha="$(shasum -a 256 "$path" | awk '{print $1}')"
        printf '%s\t%s\t%s\t%s\t%s\n' "$rel_path" "$sha" "$class" "$ent_class" "$IDENTITY" >> "$MANIFEST_OUTPUT"
    fi
}

COUNT=0
for list in "$LIB_FILES" "$EXE_FILES"; do
    while IFS= read -r -d '' path; do
        [[ -n "$path" ]] || continue
        COUNT=$((COUNT + 1))
        sign_path "$path"
    done < "$list"
done

if [[ "$COUNT" -eq 0 ]]; then
    log_warn "No Mach-O files found under $STAGING_BASE"
else
    log_info "Signed $COUNT Mach-O payload file(s)."
fi
