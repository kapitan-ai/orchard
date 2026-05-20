#!/bin/bash
# Shared helpers for opt-in build keychain preparation during package signing.
#
# Security note: these helpers suppress shell xtrace around sensitive commands
# and avoid durable logging of keychain paths/passwords. macOS security(1) and
# codesign(1) still receive keychain/password values as argv while commands run,
# so use this only on trusted build hosts. The helper unlocks/partition-lists a
# specific keychain only; callers that rely on search-list discovery must verify
# membership separately without mutating keychain defaults or search lists.

unset ORCHARD_BUILD_KEYCHAIN_PREPARED
__orchard_build_keychain_prepared_fingerprint=""

_orchard_canonicalize_build_keychain() {
    local keychain="$1"
    local keychain_base="${keychain##*/}"

    if [[ ! -f "$keychain" || ! -r "$keychain" ]]; then
        printf 'build keychain not found: %s\n' "$keychain_base" >&2
        return 66
    fi

    local keychain_dir="${keychain%/*}"
    if [[ "$keychain_dir" = "$keychain" ]]; then
        keychain_dir="."
    elif [[ -z "$keychain_dir" ]]; then
        keychain_dir="/"
    fi

    local absolute_dir
    if ! absolute_dir="$({ cd "$keychain_dir" && pwd -P; } 2>/dev/null)"; then
        printf 'build keychain canonicalization failed: %s\n' "$keychain_base" >&2
        return 66
    fi
    if [[ "$absolute_dir" = "/" ]]; then
        printf '/%s\n' "$keychain_base"
    else
        printf '%s/%s\n' "$absolute_dir" "$keychain_base"
    fi
}

_orchard_build_keychain_fingerprint() {
    local canonical_keychain_path="$1"
    local output=""
    local status=0
    local fingerprint=""

    if ! command -v shasum >/dev/null 2>&1; then
        printf 'shasum is required to fingerprint build keychain\n' >&2
        return 69
    fi

    output="$(printf '%s' "$canonical_keychain_path" | shasum -a 256 2>&1)" || status=$?
    if [[ "$status" -ne 0 ]]; then
        printf 'shasum failed while fingerprinting build keychain exit=%s\n' "$status" >&2
        return 69
    fi

    fingerprint="${output%%[[:space:]]*}"
    if [[ ! "$fingerprint" =~ ^[[:xdigit:]]{64}$ ]]; then
        printf 'invalid build keychain fingerprint\n' >&2
        return 65
    fi

    printf '%s\n' "$fingerprint"
}

orchard_assert_build_keychain() {
    local restore_xtrace=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    local keychain="${ORCHARD_BUILD_KEYCHAIN:-}"
    if [[ -z "$keychain" ]]; then
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return 0
    fi

    _orchard_canonicalize_build_keychain "$keychain"
    local status=$?
    if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
    return "$status"
}

orchard_prepare_build_keychain() {
    local restore_xtrace=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    unset ORCHARD_BUILD_KEYCHAIN_PREPARED

    local keychain_path="${1:-${ORCHARD_BUILD_KEYCHAIN:-}}"
    local password=""
    if [[ $# -ge 2 ]]; then
        password="$2"
    else
        password="${ORCHARD_KEYCHAIN_PASSWORD:-}"
    fi
    unset ORCHARD_KEYCHAIN_PASSWORD

    if [[ -z "$keychain_path" ]]; then
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return 0
    fi

    local canonical_keychain_path
    local canonical_status=0
    canonical_keychain_path="$(_orchard_canonicalize_build_keychain "$keychain_path")" || canonical_status=$?
    if [[ "$canonical_status" -ne 0 ]]; then
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return "$canonical_status"
    fi

    local keychain_base="${canonical_keychain_path##*/}"

    if [[ "${ORCHARD_BUILD_KEYCHAIN_DRY_RUN:-}" = "1" ]]; then
        printf 'build-keychain dry-run keychain=<build-keychain:%s>\n' "$keychain_base" >&2
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return 0
    fi

    if [[ -z "$password" ]]; then
        printf 'build-keychain unlock=skipped keychain=%s\n' "$keychain_base" >&2
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return 0
    fi

    local fingerprint=""
    local fingerprint_status=0
    fingerprint="$(_orchard_build_keychain_fingerprint "$canonical_keychain_path")" || fingerprint_status=$?
    if [[ "$fingerprint_status" -ne 0 ]]; then
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return "$fingerprint_status"
    fi

    if [[ "${__orchard_build_keychain_prepared_fingerprint:-}" = "$fingerprint" ]]; then
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return 0
    fi

    local partition_list='apple-tool:,apple:,codesign:'
    local unlock_exit=0
    if security unlock-keychain -p "$password" "$canonical_keychain_path" >/dev/null 2>&1; then
        unlock_exit=0
    else
        unlock_exit=$?
    fi

    if [[ "$unlock_exit" -ne 0 ]]; then
        printf 'build keychain unlock-keychain failed exit=%s keychain=%s\n' "$unlock_exit" "$keychain_base" >&2
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return "$unlock_exit"
    fi

    local partition_exit=0
    if security set-key-partition-list -S "$partition_list" -s -k "$password" "$canonical_keychain_path" >/dev/null 2>&1; then
        partition_exit=0
    else
        partition_exit=$?
    fi

    if [[ "$partition_exit" -ne 0 ]]; then
        printf 'build keychain set-key-partition-list failed exit=%s keychain=%s\n' "$partition_exit" "$keychain_base" >&2
        if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
        return "$partition_exit"
    fi

    __orchard_build_keychain_prepared_fingerprint="$fingerprint"
    if [[ "$restore_xtrace" -eq 1 ]]; then set -x; fi
    return 0
}
