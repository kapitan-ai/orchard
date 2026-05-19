#!/bin/bash
# Focused regression tests for the build keychain helper contract.
# These tests use fake Apple tooling and do not contact macOS Keychain Services.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/lib/build-keychain.sh"
TMP_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PARTITION_LIST='apple-tool:,apple:,codesign:'
FIXTURE_PASSWORD='fixture-build-keychain-password'
USER_OUTPUT_LOG="$TMP_ROOT/user-facing.log"
SANITIZED_LOG="$TMP_ROOT/sanitized.log"
: > "$USER_OUTPUT_LOG"
: > "$SANITIZED_LOG"

assert_grep() {
    local pattern="$1"
    local file="$2"
    grep -F -- "$pattern" "$file" >/dev/null
}

assert_no_grep() {
    local pattern="$1"
    local file="$2"
    if [[ ! -f "$file" ]]; then
        return 0
    fi
    if grep -F -- "$pattern" "$file" >/dev/null; then
        echo "unexpected match for $pattern" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_file_empty() {
    local file="$1"
    if [[ -s "$file" ]]; then
        echo "expected empty file: $file" >&2
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

assert_status() {
    local expected="$1"
    local actual="$2"
    local out="$3"
    if [[ "$actual" -ne "$expected" ]]; then
        echo "expected exit $expected, got $actual" >&2
        cat "$out" >&2
        exit 1
    fi
}

make_fake_tools() {
    local tools="$1"
    mkdir -p "$tools"

    cat > "$tools/security" <<'SH'
#!/bin/sh
if [ -n "${SECURITY_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$SECURITY_LOG"
fi
case "${1:-}" in
  unlock-keychain)
    exit "${SECURITY_UNLOCK_EXIT:-0}"
    ;;
  set-key-partition-list)
    exit "${SECURITY_PARTITION_EXIT:-0}"
    ;;
  *)
    echo "unexpected security invocation: $*" >&2
    exit 99
    ;;
esac
SH
    chmod +x "$tools/security"
}

if [[ ! -f "$HELPER" ]]; then
    echo "helper not found: scripts/lib/build-keychain.sh" >&2
    exit 1
fi

TOOLS="$TMP_ROOT/tools"
make_fake_tools "$TOOLS"

KC_DIR="$TMP_ROOT/Keychains"
mkdir -p "$KC_DIR"
KC="$KC_DIR/orchard-build.keychain-db"
: > "$KC"
KC_BASE="$(basename "$KC")"
KC_RESOLVED="$(cd "$KC_DIR" && pwd -P)/$KC_BASE"
MISSING_KC="$KC_DIR/missing-build.keychain-db"
MISSING_BASE="$(basename "$MISSING_KC")"
SAME_BASE_DIR="$TMP_ROOT/OtherKeychains"
mkdir -p "$SAME_BASE_DIR"
KC_SAME_BASE="$SAME_BASE_DIR/$KC_BASE"
: > "$KC_SAME_BASE"

# A: unset ORCHARD_BUILD_KEYCHAIN is accepted and produces no output.
env -u ORCHARD_BUILD_KEYCHAIN bash -c 'source "$1"; orchard_assert_build_keychain' bash "$HELPER" > "$TMP_ROOT/a.out" 2> "$TMP_ROOT/a.err"
assert_file_empty "$TMP_ROOT/a.out"
assert_file_empty "$TMP_ROOT/a.err"
cat "$TMP_ROOT/a.err" >> "$USER_OUTPUT_LOG"

# B: missing keychain fails closed with basename only.
assert_fails_with "$MISSING_BASE" "$TMP_ROOT/b.out" \
    env ORCHARD_BUILD_KEYCHAIN="$MISSING_KC" bash -c 'source "$1"; orchard_assert_build_keychain' bash "$HELPER"
cat "$TMP_ROOT/b.out" >> "$USER_OUTPUT_LOG"
assert_no_grep "$MISSING_KC" "$TMP_ROOT/b.out"

# C: existing keychain returns the absolute path for internal command substitution.
env ORCHARD_BUILD_KEYCHAIN="$KC" bash -c 'source "$1"; orchard_assert_build_keychain' bash "$HELPER" > "$TMP_ROOT/c.internal.out" 2> "$TMP_ROOT/c.err"
printf '%s\n' "$KC_RESOLVED" > "$TMP_ROOT/c.expected"
cmp "$TMP_ROOT/c.expected" "$TMP_ROOT/c.internal.out" >/dev/null
assert_file_empty "$TMP_ROOT/c.err"

# C2: canonicalization failure emits only a helper-owned basename diagnostic.
set +e
env ORCHARD_BUILD_KEYCHAIN="$KC" bash -c 'source "$1"; cd() { printf "raw cd leaked dir: %s\n" "$1" >&2; return 1; }; orchard_assert_build_keychain' bash "$HELPER" > "$TMP_ROOT/c2.out" 2>&1
c2_status=$?
set -e
assert_status 66 "$c2_status" "$TMP_ROOT/c2.out"
assert_grep 'build keychain canonicalization failed' "$TMP_ROOT/c2.out"
assert_grep "$KC_BASE" "$TMP_ROOT/c2.out"
assert_no_grep "$KC" "$TMP_ROOT/c2.out"
assert_no_grep "$KC_RESOLVED" "$TMP_ROOT/c2.out"
assert_no_grep "$KC_DIR" "$TMP_ROOT/c2.out"
assert_no_grep 'raw cd leaked dir' "$TMP_ROOT/c2.out"
cat "$TMP_ROOT/c2.out" >> "$USER_OUTPUT_LOG"

# D: password absent means operator-prepared keychain; no security calls.
SECURITY_LOG="$TMP_ROOT/d-security.log"
: > "$SECURITY_LOG"
env -u ORCHARD_KEYCHAIN_PASSWORD ORCHARD_BUILD_KEYCHAIN="$KC" SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS:/usr/bin:/bin" \
    bash -c 'source "$1"; orchard_prepare_build_keychain "$2"' bash "$HELPER" "$KC" > "$TMP_ROOT/d.out" 2> "$TMP_ROOT/d.err"
assert_file_empty "$SECURITY_LOG"
cat "$TMP_ROOT/d.out" "$TMP_ROOT/d.err" >> "$USER_OUTPUT_LOG"
assert_grep 'unlock=skipped' "$TMP_ROOT/d.err"

# D2: set-but-empty password is treated as absent.
SECURITY_LOG="$TMP_ROOT/d2-security.log"
: > "$SECURITY_LOG"
env ORCHARD_KEYCHAIN_PASSWORD= ORCHARD_BUILD_KEYCHAIN="$KC" SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS:/usr/bin:/bin" \
    bash -c 'source "$1"; orchard_prepare_build_keychain "$2"' bash "$HELPER" "$KC" > "$TMP_ROOT/d2.out" 2> "$TMP_ROOT/d2.err"
assert_file_empty "$SECURITY_LOG"
assert_grep 'unlock=skipped' "$TMP_ROOT/d2.err"
cat "$TMP_ROOT/d2.out" "$TMP_ROOT/d2.err" >> "$USER_OUTPUT_LOG"

# E: password present unlocks and sets the partition list exactly once in argv log.
SECURITY_LOG="$TMP_ROOT/e-security.raw.log"
: > "$SECURITY_LOG"
env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS:/usr/bin:/bin" \
    bash -c 'source "$1"; orchard_prepare_build_keychain "$2"' bash "$HELPER" "$KC" > "$TMP_ROOT/e.out" 2> "$TMP_ROOT/e.err"
assert_grep "unlock-keychain -p $FIXTURE_PASSWORD $KC_RESOLVED" "$SECURITY_LOG"
assert_grep "set-key-partition-list -S $PARTITION_LIST -s -k $FIXTURE_PASSWORD $KC_RESOLVED" "$SECURITY_LOG"
cat "$TMP_ROOT/e.out" "$TMP_ROOT/e.err" >> "$USER_OUTPUT_LOG"
sed -e "s|$FIXTURE_PASSWORD|<redacted-password-token>|g" -e "s|$KC|$KC_BASE|g" "$SECURITY_LOG" > "$TMP_ROOT/e-security.sanitized.log"
cat "$TMP_ROOT/e-security.sanitized.log" >> "$SANITIZED_LOG"

# F: unlock failure reports tool and exit code without leaking argv details.
SECURITY_LOG="$TMP_ROOT/f-security.raw.log"
: > "$SECURITY_LOG"
assert_fails_with 'unlock-keychain' "$TMP_ROOT/f.out" \
    env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" SECURITY_LOG="$SECURITY_LOG" SECURITY_UNLOCK_EXIT=7 PATH="$TOOLS:/usr/bin:/bin" \
        bash -c 'source "$1"; orchard_prepare_build_keychain "$2"' bash "$HELPER" "$KC"
assert_grep 'exit=7' "$TMP_ROOT/f.out"
assert_no_grep "$FIXTURE_PASSWORD" "$TMP_ROOT/f.out"
assert_no_grep "$KC" "$TMP_ROOT/f.out"
assert_grep "$KC_BASE" "$TMP_ROOT/f.out"
cat "$TMP_ROOT/f.out" >> "$USER_OUTPUT_LOG"

# F2: partition-list failure reports tool and exit code without leaking argv details.
SECURITY_LOG="$TMP_ROOT/f2-security.raw.log"
: > "$SECURITY_LOG"
assert_fails_with 'set-key-partition-list' "$TMP_ROOT/f2.out" \
    env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" SECURITY_LOG="$SECURITY_LOG" SECURITY_PARTITION_EXIT=8 PATH="$TOOLS:/usr/bin:/bin" \
        bash -c 'source "$1"; orchard_prepare_build_keychain "$2"; status=$?; printf "marker=%s\n" "${ORCHARD_BUILD_KEYCHAIN_PREPARED:-unset}" >&2; exit "$status"' bash "$HELPER" "$KC"
assert_grep 'exit=8' "$TMP_ROOT/f2.out"
assert_grep 'marker=unset' "$TMP_ROOT/f2.out"
assert_no_grep "$FIXTURE_PASSWORD" "$TMP_ROOT/f2.out"
assert_no_grep "$KC" "$TMP_ROOT/f2.out"
assert_grep "$KC_BASE" "$TMP_ROOT/f2.out"
cat "$TMP_ROOT/f2.out" >> "$USER_OUTPUT_LOG"

# H: dry-run prepares nothing, emits only a basename/placeholder, and succeeds.
SECURITY_LOG="$TMP_ROOT/h-security.log"
: > "$SECURITY_LOG"
env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_BUILD_KEYCHAIN_DRY_RUN=1 SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS:/usr/bin:/bin" \
    bash -c 'source "$1"; orchard_prepare_build_keychain "$2"' bash "$HELPER" "$KC" > "$TMP_ROOT/h.out" 2> "$TMP_ROOT/h.err"
assert_file_empty "$SECURITY_LOG"
assert_grep "$KC_BASE" "$TMP_ROOT/h.err"
assert_no_grep "$KC" "$TMP_ROOT/h.err"
assert_file_empty "$TMP_ROOT/h.out"
cat "$TMP_ROOT/h.out" "$TMP_ROOT/h.err" >> "$USER_OUTPUT_LOG"

# I: same-process idempotence is preserved, but child processes prepare independently.
SECURITY_LOG="$TMP_ROOT/i-security.raw.log"
: > "$SECURITY_LOG"
KC_EQUIVALENT="$KC_DIR/../Keychains/$KC_BASE"
env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS:/usr/bin:/bin" \
    bash -c 'source "$1"; orchard_prepare_build_keychain "$2" "$5"; if export -p | grep -F ORCHARD_BUILD_KEYCHAIN_PREPARED >/dev/null; then exit 90; fi; orchard_prepare_build_keychain "$6" "$5"; child_count_before=$(wc -l < "$3"); bash -c '\''source "$1"; orchard_prepare_build_keychain "$2" "$3"'\'' bash "$1" "$2" "$5"; child_count_after=$(wc -l < "$3"); orchard_prepare_build_keychain "$4" "$5"; final_count=$(wc -l < "$3"); printf "%s\n%s\n%s\n" "$child_count_before" "$child_count_after" "$final_count"' bash "$HELPER" "$KC" "$SECURITY_LOG" "$KC_SAME_BASE" "$FIXTURE_PASSWORD" "$KC_EQUIVALENT" > "$TMP_ROOT/i.out" 2> "$TMP_ROOT/i.err"
unlock_count=$(grep -c '^unlock-keychain ' "$SECURITY_LOG" || true)
partition_count=$(grep -c '^set-key-partition-list ' "$SECURITY_LOG" || true)
if [[ "$unlock_count" -ne 3 || "$partition_count" -ne 3 ]]; then
    echo "expected exactly three preparations: canonical keychain, child process, and same-basename different path" >&2
    cat "$SECURITY_LOG" >&2
    exit 1
fi
child_count_before=$(sed -n '1p' "$TMP_ROOT/i.out")
child_count_after=$(sed -n '2p' "$TMP_ROOT/i.out")
final_count=$(sed -n '3p' "$TMP_ROOT/i.out")
if [[ "$child_count_before" -ne 2 || "$child_count_after" -ne 4 || "$final_count" -ne 6 ]]; then
    echo "expected only same-process equivalent path to skip preparation" >&2
    cat "$TMP_ROOT/i.out" >&2
    exit 1
fi
cat "$TMP_ROOT/i.err" >> "$USER_OUTPUT_LOG"

# A new unrelated shell process re-prepares the same keychain because it has no inherited marker.
SECURITY_LOG="$TMP_ROOT/i2-security.raw.log"
: > "$SECURITY_LOG"
for _ in 1 2; do
    env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS:/usr/bin:/bin" \
        bash -c 'source "$1"; orchard_prepare_build_keychain "$2"' bash "$HELPER" "$KC" > "$TMP_ROOT/i2.out" 2> "$TMP_ROOT/i2.err"
    cat "$TMP_ROOT/i2.err" >> "$USER_OUTPUT_LOG"
done
unlock_count=$(grep -c '^unlock-keychain ' "$SECURITY_LOG" || true)
partition_count=$(grep -c '^set-key-partition-list ' "$SECURITY_LOG" || true)
if [[ "$unlock_count" -ne 2 || "$partition_count" -ne 2 ]]; then
    echo "expected unrelated shell processes to prepare independently" >&2
    cat "$SECURITY_LOG" >&2
    exit 1
fi

# I3: inherited ORCHARD_BUILD_KEYCHAIN_PREPARED cannot spoof preparation state.
SECURITY_LOG="$TMP_ROOT/i3-security.raw.log"
: > "$SECURITY_LOG"
spoofed_marker="$(printf '%s' "$KC_RESOLVED" | /usr/bin/shasum -a 256 | awk '{print $1}')"
env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_BUILD_KEYCHAIN_PREPARED="$spoofed_marker" SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS:/usr/bin:/bin" \
    bash -c 'source "$1"; orchard_prepare_build_keychain "$2"; if export -p | grep -F ORCHARD_BUILD_KEYCHAIN_PREPARED >/dev/null; then exit 90; fi' bash "$HELPER" "$KC" > "$TMP_ROOT/i3.out" 2> "$TMP_ROOT/i3.err"
test "$(grep -c '^unlock-keychain ' "$SECURITY_LOG" || true)" -eq 1
test "$(grep -c '^set-key-partition-list ' "$SECURITY_LOG" || true)" -eq 1
cat "$TMP_ROOT/i3.out" "$TMP_ROOT/i3.err" >> "$USER_OUTPUT_LOG"

# I4: fingerprinting fails closed before security when shasum is unavailable or malformed.
SECURITY_LOG="$TMP_ROOT/i4-missing-security.log"
: > "$SECURITY_LOG"
assert_fails_with 'shasum is required' "$TMP_ROOT/i4-missing.out" \
    env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS" \
        /bin/bash -c 'source "$1"; orchard_prepare_build_keychain "$2"' bash "$HELPER" "$KC"
assert_file_empty "$SECURITY_LOG"
assert_no_grep "$FIXTURE_PASSWORD" "$TMP_ROOT/i4-missing.out"
assert_no_grep "$KC" "$TMP_ROOT/i4-missing.out"
cat "$TMP_ROOT/i4-missing.out" >> "$USER_OUTPUT_LOG"

for shasum_case in fail empty malformed; do
    case_tools="$TMP_ROOT/i4-$shasum_case-tools"
    make_fake_tools "$case_tools"
    case "$shasum_case" in
        fail)
            cat > "$case_tools/shasum" <<'SH'
#!/bin/sh
exit 42
SH
            pattern='shasum failed while fingerprinting build keychain exit=42'
            ;;
        empty)
            cat > "$case_tools/shasum" <<'SH'
#!/bin/sh
exit 0
SH
            pattern='invalid build keychain fingerprint'
            ;;
        malformed)
            cat > "$case_tools/shasum" <<'SH'
#!/bin/sh
echo not-a-valid-sha
SH
            pattern='invalid build keychain fingerprint'
            ;;
    esac
    chmod +x "$case_tools/shasum"
    SECURITY_LOG="$TMP_ROOT/i4-$shasum_case-security.log"
    : > "$SECURITY_LOG"
    assert_fails_with "$pattern" "$TMP_ROOT/i4-$shasum_case.out" \
        env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" SECURITY_LOG="$SECURITY_LOG" PATH="$case_tools:/usr/bin:/bin" \
            bash -c 'source "$1"; orchard_prepare_build_keychain "$2"' bash "$HELPER" "$KC"
    assert_file_empty "$SECURITY_LOG"
    assert_no_grep "$FIXTURE_PASSWORD" "$TMP_ROOT/i4-$shasum_case.out"
    assert_no_grep "$KC" "$TMP_ROOT/i4-$shasum_case.out"
    cat "$TMP_ROOT/i4-$shasum_case.out" >> "$USER_OUTPUT_LOG"
done

# J: set -x does not leak password literals from security invocations.
SECURITY_LOG="$TMP_ROOT/j-security.raw.log"
: > "$SECURITY_LOG"
env ORCHARD_BUILD_KEYCHAIN="$KC" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" SECURITY_LOG="$SECURITY_LOG" PATH="$TOOLS:/usr/bin:/bin" \
    bash -c 'source "$1"; set -x; orchard_prepare_build_keychain' bash "$HELPER" > "$TMP_ROOT/j.out" 2> "$TMP_ROOT/j.err"
assert_no_grep "$FIXTURE_PASSWORD" "$TMP_ROOT/j.err"
assert_no_grep "$KC" "$TMP_ROOT/j.err"
cat "$TMP_ROOT/j.out" "$TMP_ROOT/j.err" >> "$USER_OUTPUT_LOG"

# G: user-facing and sanitized durable outputs never contain the password or full keychain path.
cat "$USER_OUTPUT_LOG" "$SANITIZED_LOG" > "$TMP_ROOT/durable-scan.log"
assert_no_grep "$FIXTURE_PASSWORD" "$TMP_ROOT/durable-scan.log"
assert_no_grep "$KC" "$TMP_ROOT/durable-scan.log"
assert_no_grep "$KC_RESOLVED" "$TMP_ROOT/durable-scan.log"
assert_no_grep "$KC_SAME_BASE" "$TMP_ROOT/durable-scan.log"

printf 'ok\tbuild-keychain helper contracts\n'
