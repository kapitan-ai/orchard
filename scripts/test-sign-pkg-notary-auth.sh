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

make_fake_tools() {
    local tools="$1"
    mkdir -p "$tools"

    cat > "$tools/productsign" <<'SH'
#!/bin/sh
set -eu
last=""
for arg in "$@"; do
  last="$arg"
done
: > "$last"
SH

    cat > "$tools/pkgutil" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" != "--expand-full" ]; then
  echo "unexpected pkgutil invocation: $*" >&2
  exit 1
fi
mkdir -p "$3/Library/Application Support/Orchard/share/bin"
: > "$3/Library/Application Support/Orchard/share/bin/orchardctl"
SH

    cat > "$tools/file" <<'SH'
#!/bin/sh
echo application/x-mach-binary
SH

    cat > "$tools/otool" <<'SH'
#!/bin/sh
exit 0
SH

    cat > "$tools/codesign" <<'SH'
#!/bin/sh
set -eu
case "${1:-}" in
  --verify) exit 0 ;;
  --display)
    for arg in "$@"; do
      if [ "$arg" = "--entitlements" ]; then
        exit 0
      fi
    done
    echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
    echo "Timestamp=May 20, 2026" >&2
    echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
    exit 0
    ;;
esac
exit 0
SH

    cat > "$tools/xcrun" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = "-f" ]; then
  case "${2:-}" in
    notarytool|stapler|codesign) command -v "$2"; exit 0 ;;
  esac
fi
case "${1:-}" in
  notarytool)
    printf '{"id":"%s","status":"%s"}\n' "${ORCHARD_FAKE_NOTARY_SECRET_ID:-fake-submission}" "${ORCHARD_FAKE_NOTARY_STATUS:-Accepted}"
    exit 0
    ;;
  stapler)
    exit 0
    ;;
esac
echo "unexpected xcrun invocation: $*" >&2
exit 1
SH

    cat > "$tools/notarytool" <<'SH'
#!/bin/sh
exit 0
SH

    cat > "$tools/stapler" <<'SH'
#!/bin/sh
exit 0
SH

    cat > "$tools/shasum" <<'SH'
#!/bin/sh
exec /usr/bin/shasum "$@"
SH

    chmod +x "$tools/productsign" "$tools/pkgutil" "$tools/file" "$tools/otool" "$tools/codesign" "$tools/xcrun" "$tools/notarytool" "$tools/stapler" "$tools/shasum"
}

run_sign_pkg_xtrace() {
    local tools="$1"
    local output_pkg="$2"
    shift 2
    env -i \
        PATH="$tools:/usr/bin:/bin" \
        ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
        ORCHARD_FAKE_NOTARY_SECRET_ID="${ORCHARD_FAKE_NOTARY_SECRET_ID:-}" \
        ORCHARD_FAKE_NOTARY_STATUS="${ORCHARD_FAKE_NOTARY_STATUS:-}" \
        ORCHARD_NOTARY_AUTH="${ORCHARD_NOTARY_AUTH:-}" \
        ORCHARD_NOTARY_API_KEY_TYPE="${ORCHARD_NOTARY_API_KEY_TYPE:-}" \
        ORCHARD_NOTARY_API_KEY_PATH="${ORCHARD_NOTARY_API_KEY_PATH:-}" \
        ORCHARD_NOTARY_API_KEY_ID="${ORCHARD_NOTARY_API_KEY_ID:-}" \
        "$@" \
        bash -x "$REPO_ROOT/scripts/sign-pkg.sh" \
            --identity "$INSTALLER_IDENTITY" \
            --input "$INPUT_PKG" \
            --output "$output_pkg"
}

# Xtrace must not expose raw notary JSON fields when they match auth-like secrets.
case_dir="$TMP_ROOT/xtrace-notary-fields"
tools="$case_dir/tools"
mkdir -p "$case_dir"
make_fake_tools "$tools"
notary_secret='KEY123SECRET'
set +e
ORCHARD_FAKE_NOTARY_SECRET_ID="$notary_secret" \
ORCHARD_NOTARY_AUTH=api-key \
ORCHARD_NOTARY_API_KEY_TYPE=individual \
ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
ORCHARD_NOTARY_API_KEY_ID="$notary_secret" \
run_sign_pkg_xtrace "$tools" "$case_dir/signed.pkg" > "$case_dir/xtrace.out" 2>&1
xtrace_status=$?
set -e
if [[ "$xtrace_status" -ne 0 ]]; then
    cat "$case_dir/xtrace.out" >&2
    exit "$xtrace_status"
fi
assert_no_grep "$notary_secret" "$case_dir/xtrace.out"

case_dir="$TMP_ROOT/xtrace-notary-status"
tools="$case_dir/tools"
mkdir -p "$case_dir"
make_fake_tools "$tools"
notary_status_secret='KEY123STATUSSECRET'
set +e
ORCHARD_FAKE_NOTARY_STATUS="$notary_status_secret" \
ORCHARD_NOTARY_AUTH=api-key \
ORCHARD_NOTARY_API_KEY_TYPE=individual \
ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
ORCHARD_NOTARY_API_KEY_ID="$notary_status_secret" \
run_sign_pkg_xtrace "$tools" "$case_dir/signed.pkg" > "$case_dir/xtrace.out" 2>&1
xtrace_status=$?
set -e
if [[ "$xtrace_status" -eq 0 ]]; then
    echo "expected notary status failure" >&2
    cat "$case_dir/xtrace.out" >&2
    exit 1
fi
assert_grep 'Notarization did not finish as Accepted' "$case_dir/xtrace.out"
assert_no_grep "$notary_status_secret" "$case_dir/xtrace.out"

# Individual API Keys must omit --issuer, even if a stale issuer env var exists.
ORCHARD_NOTARY_AUTH=api-key \
ORCHARD_NOTARY_API_KEY_TYPE=individual \
ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
ORCHARD_NOTARY_API_KEY_ID=KEY123 \
ORCHARD_NOTARY_API_ISSUER_ID=stale-non-uuid \
ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
sign_pkg_dry_run "$TMP_ROOT/individual.pkg" > "$TMP_ROOT/individual.out" 2>&1
assert_grep '--key' "$TMP_ROOT/individual.out"
assert_grep '\<notary-api-key\>' "$TMP_ROOT/individual.out"
assert_grep '--key-id' "$TMP_ROOT/individual.out"
assert_grep '\<notary-api-key-id\>' "$TMP_ROOT/individual.out"
assert_no_grep '--issuer' "$TMP_ROOT/individual.out"
assert_grep '--output-format' "$TMP_ROOT/individual.out"
assert_no_grep "$API_KEY" "$TMP_ROOT/individual.out"
assert_no_grep 'KEY123' "$TMP_ROOT/individual.out"
assert_no_grep 'stale-non-uuid' "$TMP_ROOT/individual.out"

# Team API Keys must include a valid issuer UUID.
ORCHARD_NOTARY_AUTH=api-key \
ORCHARD_NOTARY_API_KEY_TYPE=team \
ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
ORCHARD_NOTARY_API_KEY_ID=KEY123 \
ORCHARD_NOTARY_API_ISSUER_ID=12345678-1234-1234-1234-123456789abc \
ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
sign_pkg_dry_run "$TMP_ROOT/team.pkg" > "$TMP_ROOT/team.out" 2>&1
assert_grep '--key' "$TMP_ROOT/team.out"
assert_grep '\<notary-api-key\>' "$TMP_ROOT/team.out"
assert_grep '--key-id' "$TMP_ROOT/team.out"
assert_grep '\<notary-api-key-id\>' "$TMP_ROOT/team.out"
assert_grep '--issuer' "$TMP_ROOT/team.out"
assert_grep '\<notary-issuer-id\>' "$TMP_ROOT/team.out"
assert_grep '--output-format' "$TMP_ROOT/team.out"
assert_no_grep "$API_KEY" "$TMP_ROOT/team.out"
assert_no_grep 'KEY123' "$TMP_ROOT/team.out"
assert_no_grep '12345678-1234-1234-1234-123456789abc' "$TMP_ROOT/team.out"

# API-key auth trims surrounding whitespace before validation and dry-run display.
ORCHARD_NOTARY_AUTH=' api-key ' \
ORCHARD_NOTARY_API_KEY_TYPE=' team ' \
ORCHARD_NOTARY_API_KEY_PATH="  $API_KEY  " \
ORCHARD_NOTARY_API_KEY_ID='  KEY123  ' \
ORCHARD_NOTARY_API_ISSUER_ID=' 12345678-1234-1234-1234-123456789abc ' \
ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
sign_pkg_dry_run "$TMP_ROOT/team-trimmed.pkg" > "$TMP_ROOT/team-trimmed.out" 2>&1
assert_grep '--key' "$TMP_ROOT/team-trimmed.out"
assert_grep '\<notary-api-key\>' "$TMP_ROOT/team-trimmed.out"
assert_grep '--key-id' "$TMP_ROOT/team-trimmed.out"
assert_grep '\<notary-api-key-id\>' "$TMP_ROOT/team-trimmed.out"
assert_grep '--issuer' "$TMP_ROOT/team-trimmed.out"
assert_grep '\<notary-issuer-id\>' "$TMP_ROOT/team-trimmed.out"
assert_no_grep "$API_KEY" "$TMP_ROOT/team-trimmed.out"
assert_no_grep 'KEY123' "$TMP_ROOT/team-trimmed.out"
assert_no_grep '12345678-1234-1234-1234-123456789abc' "$TMP_ROOT/team-trimmed.out"

# Auto mode omits issuer when absent, but rejects malformed issuer values.
ORCHARD_NOTARY_AUTH=api-key \
ORCHARD_NOTARY_API_KEY_TYPE=auto \
ORCHARD_NOTARY_API_KEY_PATH="$API_KEY" \
ORCHARD_NOTARY_API_KEY_ID=KEY123 \
ORCHARD_NOTARY_API_ISSUER_ID= \
ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
sign_pkg_dry_run "$TMP_ROOT/auto-no-issuer.pkg" > "$TMP_ROOT/auto-no-issuer.out" 2>&1
assert_grep '\<notary-api-key\>' "$TMP_ROOT/auto-no-issuer.out"
assert_grep '\<notary-api-key-id\>' "$TMP_ROOT/auto-no-issuer.out"
assert_no_grep '--issuer' "$TMP_ROOT/auto-no-issuer.out"
assert_no_grep "$API_KEY" "$TMP_ROOT/auto-no-issuer.out"
assert_no_grep 'KEY123' "$TMP_ROOT/auto-no-issuer.out"

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
