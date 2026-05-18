#!/bin/bash
# Focused regression tests for scripts/sign-pkg.sh notarization auth argument construction.
# Uses --dry-run only; does not sign packages or contact Apple services.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

INSTALLER_IDENTITY='Developer ID Installer: Example, Inc. (TEAMID)'
PAYLOAD_IDENTITY='Developer ID Application: Example, Inc. (TEAMID)'
API_KEY="$TMP_ROOT/AuthKey_TEST.p8"
INPUT_PKG="$TMP_ROOT/Orchard.pkg"
: > "$API_KEY"
: > "$INPUT_PKG"

assert_grep() {
    local pattern="$1"
    local file="$2"
    grep -F -- "$pattern" "$file" >/dev/null
}

assert_no_grep() {
    local pattern="$1"
    local file="$2"
    if grep -F -- "$pattern" "$file" >/dev/null; then
        echo "unexpected match for $pattern" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_fails_with() {
    local pattern="$1"
    local out="$2"
    shift 2
    if "$@" >"$out" 2>&1; then
        echo "expected command to fail with: $pattern" >&2
        cat "$out" >&2
        exit 1
    fi
    assert_grep "$pattern" "$out"
}

sign_pkg_dry_run() {
    "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run \
        --identity "$INSTALLER_IDENTITY" \
        --input "$INPUT_PKG" \
        --output "$1"
}

# Individual API Keys must omit --issuer, even if a stale issuer env var exists.
ORCHARD_NOTARY_AUTH=api-key \
ORCHARD_NOTARY_API_KEY_TYPE=individual \
ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
ORCHARD_NOTARY_API_KEY_ID=KEY123 \
ORCHARD_NOTARY_API_ISSUER_ID=stale-non-uuid \
ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
sign_pkg_dry_run "$TMP_ROOT/individual.pkg" > "$TMP_ROOT/individual.out" 2>&1
assert_grep '--key' "$TMP_ROOT/individual.out"
assert_grep '--key-id' "$TMP_ROOT/individual.out"
assert_no_grep '--issuer' "$TMP_ROOT/individual.out"
assert_grep '--output-format' "$TMP_ROOT/individual.out"

# Team API Keys must include a valid issuer UUID.
ORCHARD_NOTARY_AUTH=api-key \
ORCHARD_NOTARY_API_KEY_TYPE=team \
ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
ORCHARD_NOTARY_API_KEY_ID=KEY123 \
ORCHARD_NOTARY_API_ISSUER_ID=12345678-1234-1234-1234-123456789abc \
ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
sign_pkg_dry_run "$TMP_ROOT/team.pkg" > "$TMP_ROOT/team.out" 2>&1
assert_grep '--key' "$TMP_ROOT/team.out"
assert_grep '--key-id' "$TMP_ROOT/team.out"
assert_grep '--issuer' "$TMP_ROOT/team.out"
assert_grep '12345678-1234-1234-1234-123456789abc' "$TMP_ROOT/team.out"
assert_grep '--output-format' "$TMP_ROOT/team.out"

# Auto mode omits issuer when absent, but rejects malformed issuer values.
ORCHARD_NOTARY_AUTH=api-key \
ORCHARD_NOTARY_API_KEY_TYPE=auto \
ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
ORCHARD_NOTARY_API_KEY_ID=KEY123 \
ORCHARD_NOTARY_API_ISSUER_ID= \
ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
sign_pkg_dry_run "$TMP_ROOT/auto-no-issuer.pkg" > "$TMP_ROOT/auto-no-issuer.out" 2>&1
assert_no_grep '--issuer' "$TMP_ROOT/auto-no-issuer.out"

for issuer in not-a-uuid zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz; do
    assert_fails_with 'ORCHARD_NOTARY_API_ISSUER_ID must be a UUID' "$TMP_ROOT/invalid-$issuer.out" \
        env ORCHARD_NOTARY_AUTH=api-key \
            ORCHARD_NOTARY_API_KEY_TYPE=auto \
            ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
            ORCHARD_NOTARY_API_KEY_ID=KEY123 \
            ORCHARD_NOTARY_API_ISSUER_ID="$issuer" \
            ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
            "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run \
                --identity "$INSTALLER_IDENTITY" \
                --input "$INPUT_PKG" \
                --output "$TMP_ROOT/invalid.pkg"
done

assert_fails_with 'ORCHARD_NOTARY_API_ISSUER_ID is required' "$TMP_ROOT/team-missing-issuer.out" \
    env ORCHARD_NOTARY_AUTH=api-key \
        ORCHARD_NOTARY_API_KEY_TYPE=team \
        ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
        ORCHARD_NOTARY_API_KEY_ID=KEY123 \
        ORCHARD_NOTARY_API_ISSUER_ID= \
        ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
        "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run \
            --identity "$INSTALLER_IDENTITY" \
            --input "$INPUT_PKG" \
            --output "$TMP_ROOT/team-missing-issuer.pkg"

assert_fails_with 'Unsupported ORCHARD_NOTARY_API_KEY_TYPE' "$TMP_ROOT/unsupported-type.out" \
    env ORCHARD_NOTARY_AUTH=api-key \
        ORCHARD_NOTARY_API_KEY_TYPE=enterprise \
        ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
        ORCHARD_NOTARY_API_KEY_ID=KEY123 \
        ORCHARD_NOTARY_API_ISSUER_ID= \
        ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
        "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run \
            --identity "$INSTALLER_IDENTITY" \
            --input "$INPUT_PKG" \
            --output "$TMP_ROOT/unsupported-type.pkg"

printf 'ok\tsign-pkg notary auth contracts\n'
