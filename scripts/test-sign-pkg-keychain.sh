#!/bin/bash
# Focused regression tests for scripts/sign-pkg.sh productsign build-keychain support.
# Uses fake Apple tooling only; does not mutate macOS keychain search/default state.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

INSTALLER_IDENTITY='Developer ID Installer: Example, Inc. (TEAMID)'
PAYLOAD_IDENTITY='Developer ID Application: Example, Inc. (TEAMID)'
FIXTURE_PASSWORD='fixture-productsign-keychain-password'

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

make_fixture() {
    local case_dir="$1"
    mkdir -p "$case_dir/Keychains"
    : > "$case_dir/Orchard.pkg"
    : > "$case_dir/Keychains/orchard-build.keychain-db"
}

keychain_path() {
    local case_dir="$1"
    local keychain_dir="$case_dir/Keychains"
    printf '%s/orchard-build.keychain-db\n' "$(cd "$keychain_dir" && pwd -P)"
}

make_fake_tools() {
    local tools="$1"
    mkdir -p "$tools"

    cat > "$tools/orchard-fake-env-guard" <<'SH'
#!/bin/sh
set -eu
tool_name="${1:-unknown}"
for name in ORCHARD_NOTARY_API_KEY_PATH ORCHARD_NOTARY_API_KEY_ID ORCHARD_NOTARY_API_KEY_TYPE ORCHARD_NOTARY_API_ISSUER_ID ORCHARD_PKG_SIGNING_IDENTITY ORCHARD_PAYLOAD_SIGNING_IDENTITY; do
  eval "present=\${$name+x}"
  if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
    printf '%s\t%s_present=%s\n' "$tool_name" "$name" "$present" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
  fi
  if [ -n "$present" ]; then
    echo "$tool_name inherited $name" >&2
    exit 97
  fi
done
SH

    cat > "$tools/productsign" <<'SH'
#!/bin/sh
set -eu
exec </dev/null
original_args="$*"
unexpected_productsign() {
  echo "unexpected productsign invocation: $original_args" >&2
  exit 99
}
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'productsign\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" productsign
fi
if [ -n "${ORCHARD_KEYCHAIN_PASSWORD+x}" ]; then
  echo "productsign inherited ORCHARD_KEYCHAIN_PASSWORD" >&2
  exit 97
fi
kind=real
last=""
saw_keychain=0
for arg in "$@"; do
  case "$arg" in
    orchard-flag-probe-invalid-identity|/dev/null) kind=probe ;;
    --keychain) saw_keychain=1 ;;
  esac
  last="$arg"
done
case "$kind" in
  probe)
    if [ "$#" -ne 6 ] || [ "${1:-}" != "--sign" ] || [ "${3:-}" != "--keychain" ] || [ "${5:-}" != "/dev/null" ] || [ -z "${6:-}" ]; then
      unexpected_productsign
    fi
    ;;
  real)
    case "$#" in
      4)
        if [ "${1:-}" != "--sign" ] || [ -z "${4:-}" ]; then
          unexpected_productsign
        fi
        ;;
      6)
        if [ "${1:-}" != "--sign" ] || [ "${3:-}" != "--keychain" ] || [ -z "${6:-}" ]; then
          unexpected_productsign
        fi
        ;;
      *) unexpected_productsign ;;
    esac
    ;;
esac
if [ -n "${PRODUCTSIGN_LOG:-}" ]; then
  printf '%s\t%s\n' "$kind" "$*" >> "$PRODUCTSIGN_LOG"
fi
if [ "$kind" = "probe" ]; then
  case "${PRODUCTSIGN_PROBE_BUCKET:-}" in
    accept|validation)
      echo "productsign: invalid signing identity" >&2
      exit 1
      ;;
    reject|unknown)
      echo "productsign: unknown option --keychain" >&2
      exit 64
      ;;
    illegal)
      echo "productsign: illegal option -- keychain" >&2
      exit 64
      ;;
    unrecognized-arguments)
      echo "productsign: unrecognized argument(s): --keychain" >&2
      exit 64
      ;;
    no-such-option)
      echo "productsign: no such option: --keychain" >&2
      exit 64
      ;;
    keychain-validation)
      echo "productsign: keychain could not be opened" >&2
      exit 1
      ;;
    empty)
      exit 0
      ;;
    exec-failure)
      exit 126
      ;;
    hang)
      sleep 300
      ;;
    unparseable|*)
      echo "productsign: unexpected probe response" >&2
      exit 1
      ;;
  esac
fi
if [ "$saw_keychain" = "1" ] && [ "${ORCHARD_FAKE_PRODUCTSIGN_ALLOW_KEYCHAIN:-}" != "1" ]; then
  echo "productsign must not receive --keychain unless allowed by test" >&2
  exit 98
fi
if [ -n "${ORCHARD_FAKE_PRODUCTSIGN_ECHO_ARGV_AND_FAIL:-}" ]; then
  echo "fake productsign argv: $*" >&2
  exit 65
fi
if [ -n "${TOOL_ORDER_LOG:-}" ]; then
  printf 'productsign\treal\n' >> "$TOOL_ORDER_LOG"
fi
if [ "$last" = "-" ] || [ -p "$last" ]; then
  echo "unsafe productsign output target: $last" >&2
  exit 99
fi
: > "$last"
exit 0
SH

    cat > "$tools/pkgutil" <<'SH'
#!/bin/sh
set -eu
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'pkgutil\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" pkgutil
fi
if [ "${1:-}" != "--expand-full" ]; then
  echo "unexpected pkgutil invocation: $*" >&2
  exit 1
fi
if [ -n "${TOOL_ORDER_LOG:-}" ]; then
  printf 'pkgutil\texpand-full\n' >> "$TOOL_ORDER_LOG"
fi
mkdir -p "$3/Library/Application Support/Orchard/share/bin"
: > "$3/Library/Application Support/Orchard/share/bin/orchardctl"
exit 0
SH

    cat > "$tools/file" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'file\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" file
fi
echo application/x-mach-binary
SH

    cat > "$tools/otool" <<'SH'
#!/bin/sh
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'otool\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" otool
fi
exit 0
SH

    cat > "$tools/codesign" <<'SH'
#!/bin/sh
set -eu
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'codesign\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" codesign
fi
case "${1:-}" in
  --verify) exit 0 ;;
  --display)
    for arg in "$@"; do
      if [ "$arg" = "--entitlements" ]; then
        exit 0
      fi
    done
    echo "Signature size=9000" >&2
    echo "CodeDirectory v=20500 size=475 flags=0x10000(runtime) hashes=10+7 location=embedded" >&2
    echo "Timestamp=May 12, 2026" >&2
    echo "Authority=Developer ID Application: Example, Inc. (TEAMID)" >&2
    exit 0
    ;;
esac
exit 0
SH

    cat > "$tools/security" <<'SH'
#!/bin/sh
set -eu
if [ -n "${SECURITY_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$SECURITY_LOG"
fi
if [ -n "${TOOL_ORDER_LOG:-}" ]; then
  printf 'security\t%s\n' "${1:-}" >> "$TOOL_ORDER_LOG"
fi
case "${1:-}" in
  unlock-keychain) exit "${SECURITY_UNLOCK_EXIT:-0}" ;;
  set-key-partition-list) exit "${SECURITY_PARTITION_EXIT:-0}" ;;
  list-keychains)
    if [ "$#" -ne 1 ]; then
      echo "forbidden persistent keychain mutation: $*" >&2
      exit 99
    fi
    case "${ORCHARD_FAKE_SECURITY_SEARCH_LIST_MODE:-quoted}" in
      quoted) printf '    "%s"\n' "${ORCHARD_FAKE_SECURITY_SEARCH_LIST:-}" ;;
      unquoted) printf '%s\n' "${ORCHARD_FAKE_SECURITY_SEARCH_LIST:-}" ;;
      empty) exit 0 ;;
      fail) echo "security list-keychains failed" >&2; exit 42 ;;
      *) echo "unknown search list mode" >&2; exit 99 ;;
    esac
    ;;
  default-keychain) echo "forbidden persistent keychain mutation: $*" >&2; exit 99 ;;
  *) echo "unexpected security invocation: $*" >&2; exit 99 ;;
esac
SH

    cat > "$tools/xcrun" <<'SH'
#!/bin/sh
set -eu
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'xcrun\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" xcrun
fi
if [ "${1:-}" = "-f" ]; then
  case "${2:-}" in
    notarytool|stapler|codesign) command -v "$2"; exit 0 ;;
  esac
fi
case "${1:-}" in
  notarytool)
    if [ -n "${ORCHARD_KEYCHAIN_PASSWORD+x}" ]; then echo "notarytool inherited ORCHARD_KEYCHAIN_PASSWORD" >&2; exit 97; fi
    if [ -n "${TOOL_ORDER_LOG:-}" ]; then printf 'notarytool\n' >> "$TOOL_ORDER_LOG"; fi
    if [ -n "${XCRUN_LOG:-}" ]; then printf '%s\n' "$*" >> "$XCRUN_LOG"; fi
    notary_key=""
    notary_key_id=""
    notary_issuer=""
    notary_next=""
    for arg in "$@"; do
      if [ -n "$notary_next" ]; then
        case "$notary_next" in
          key) notary_key="$arg" ;;
          key-id) notary_key_id="$arg" ;;
          issuer) notary_issuer="$arg" ;;
        esac
        notary_next=""
        continue
      fi
      case "$arg" in
        --key) notary_next=key ;;
        --key-id) notary_next=key-id ;;
        --issuer) notary_next=issuer ;;
      esac
    done
    if [ "${ORCHARD_FAKE_NOTARY_ECHO_AUTH:-}" = "1" ]; then
      printf 'notarytool stderr key=%s key-id=%s issuer=%s\n' "$notary_key" "$notary_key_id" "$notary_issuer" >&2
      printf '{"id":"fake-submission-%s","status":"Accepted","key":"%s","keyId":"%s","issuer":"%s"}\n' "$notary_key_id" "$notary_key" "$notary_key_id" "$notary_issuer"
    else
      printf '{"id":"fake-submission","status":"Accepted"}\n'
    fi
    exit 0
    ;;
  stapler)
    if [ -n "${ORCHARD_KEYCHAIN_PASSWORD+x}" ]; then echo "stapler inherited ORCHARD_KEYCHAIN_PASSWORD" >&2; exit 97; fi
    if [ -n "${TOOL_ORDER_LOG:-}" ]; then printf 'stapler\n' >> "$TOOL_ORDER_LOG"; fi
    if [ -n "${XCRUN_LOG:-}" ]; then printf '%s\n' "$*" >> "$XCRUN_LOG"; fi
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
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'stapler\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" stapler
fi
exit 0
SH

    cat > "$tools/shasum" <<'SH'
#!/bin/sh
set -eu
if [ -n "${ORCHARD_FAKE_ENV_PRESENCE_LOG:-}" ]; then
  printf 'shasum\tORCHARD_KEYCHAIN_PASSWORD_present=%s\n' "${ORCHARD_KEYCHAIN_PASSWORD+x}" >> "$ORCHARD_FAKE_ENV_PRESENCE_LOG"
fi
if [ -x "${0%/*}/orchard-fake-env-guard" ]; then
  "${0%/*}/orchard-fake-env-guard" shasum
fi
if [ -n "${ORCHARD_KEYCHAIN_PASSWORD+x}" ]; then
  echo "shasum inherited ORCHARD_KEYCHAIN_PASSWORD" >&2
  exit 97
fi
exec /usr/bin/shasum "$@"
SH

    chmod +x "$tools/orchard-fake-env-guard" "$tools/productsign" "$tools/pkgutil" "$tools/file" "$tools/otool" "$tools/codesign" "$tools/security" "$tools/xcrun" "$tools/notarytool" "$tools/stapler" "$tools/shasum"
}

# PS0: fake productsign is noninteractive and fails closed for malformed argv.
case_dir="$TMP_ROOT/ps0-fake-productsign-contract"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
set +e
env -i PATH="/usr/bin:/bin" perl -e 'alarm 5; exec @ARGV' "$tools/productsign" --unexpected < /dev/null > "$case_dir/malformed.out" 2>&1
malformed_status=$?
set -e
test "$malformed_status" -ne 0
assert_grep 'unexpected productsign invocation' "$case_dir/malformed.out"
set +e
env -i PATH="/usr/bin:/bin" PRODUCTSIGN_PROBE_BUCKET=accept perl -e 'alarm 5; exec @ARGV' "$tools/productsign" --sign orchard-flag-probe-invalid-identity --keychain "$case_dir/bogus.keychain-db" /dev/null "$case_dir/bogus-out.pkg" < /dev/null > "$case_dir/probe.out" 2>&1
probe_status=$?
set -e
test "$probe_status" -eq 1
assert_grep 'invalid signing identity' "$case_dir/probe.out"

run_with_timeout() {
    local timeout_seconds="${ORCHARD_SIGN_PKG_TEST_TIMEOUT_SECONDS:-45}"
    perl -MPOSIX=setsid -e '
        my $timeout = $ENV{"ORCHARD_SIGN_PKG_TEST_TIMEOUT_SECONDS"} || 45;
        my $pid = fork();
        die "fork failed: $!\n" unless defined $pid;
        if ($pid == 0) {
            setsid() or die "setsid failed: $!\n";
            exec @ARGV or die "exec failed: $!\n";
        }
        local $SIG{ALRM} = sub {
            warn "test command timed out after ${timeout}s: @ARGV\n";
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
    ' "$@"
}

run_sign_pkg() {
    local tools="$1"
    local case_dir="$2"
    local output_pkg="$3"
    shift 3
    run_with_timeout env -i \
        PATH="$tools:/usr/bin:/bin" \
        PRODUCTSIGN_LOG="$case_dir/productsign.log" \
        XCRUN_LOG="$case_dir/xcrun.log" \
        SECURITY_LOG="$case_dir/security.log" \
        TOOL_ORDER_LOG="$case_dir/order.log" \
        ORCHARD_FAKE_ENV_PRESENCE_LOG="$case_dir/env-presence.log" \
        ORCHARD_FAKE_PRODUCTSIGN_ALLOW_KEYCHAIN=1 \
        ORCHARD_FAKE_SECURITY_SEARCH_LIST="$(keychain_path "$case_dir")" \
        ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
        "$@" \
        "$REPO_ROOT/scripts/sign-pkg.sh" \
            --identity "$INSTALLER_IDENTITY" \
            --notary-profile orchard-notary \
            --input "$case_dir/Orchard.pkg" \
            --output "$output_pkg"
}

run_sign_pkg_xtrace() {
    local tools="$1"
    local case_dir="$2"
    local output_pkg="$3"
    shift 3
    run_with_timeout env -i \
        PATH="$tools:/usr/bin:/bin" \
        PRODUCTSIGN_LOG="$case_dir/productsign.log" \
        XCRUN_LOG="$case_dir/xcrun.log" \
        SECURITY_LOG="$case_dir/security.log" \
        TOOL_ORDER_LOG="$case_dir/order.log" \
        ORCHARD_FAKE_ENV_PRESENCE_LOG="$case_dir/env-presence.log" \
        ORCHARD_FAKE_PRODUCTSIGN_ALLOW_KEYCHAIN=1 \
        ORCHARD_FAKE_SECURITY_SEARCH_LIST="$(keychain_path "$case_dir")" \
        ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
        "$@" \
        bash -x "$REPO_ROOT/scripts/sign-pkg.sh" \
            --identity "$INSTALLER_IDENTITY" \
            --notary-profile orchard-notary \
            --input "$case_dir/Orchard.pkg" \
            --output "$output_pkg"
}

run_sign_pkg_dry() {
    local tools="$1"
    local case_dir="$2"
    local output_pkg="$3"
    shift 3
    run_with_timeout env -i \
        PATH="$tools:/usr/bin:/bin" \
        PRODUCTSIGN_LOG="$case_dir/productsign.log" \
        XCRUN_LOG="$case_dir/xcrun.log" \
        SECURITY_LOG="$case_dir/security.log" \
        ORCHARD_FAKE_ENV_PRESENCE_LOG="$case_dir/env-presence.log" \
        ORCHARD_FAKE_PRODUCTSIGN_ALLOW_KEYCHAIN=1 \
        ORCHARD_PAYLOAD_SIGNING_IDENTITY="$PAYLOAD_IDENTITY" \
        ORCHARD_FAKE_SECURITY_SEARCH_LIST="$(keychain_path "$case_dir")" \
        "$@" \
        "$REPO_ROOT/scripts/sign-pkg.sh" --dry-run \
            --identity "$INSTALLER_IDENTITY" \
            --notary-profile orchard-notary \
            --input "$case_dir/Orchard.pkg" \
            --output "$output_pkg"
}

assert_common_hygiene() {
    local case_dir="$1"
    local combined="$2"
    local keychain="$3"
    assert_no_grep "$FIXTURE_PASSWORD" "$combined"
    if [[ -n "$keychain" ]]; then
        assert_no_grep "$keychain" "$combined"
    fi
    assert_no_grep "$INSTALLER_IDENTITY" "$combined"
    assert_no_grep "$PAYLOAD_IDENTITY" "$combined"
    assert_no_grep 'ORCHARD_KEYCHAIN_PASSWORD_present=x' "$case_dir/env-presence.log"
    assert_no_grep 'ORCHARD_NOTARY_API_KEY_PATH_present=x' "$case_dir/env-presence.log"
    assert_no_grep 'ORCHARD_NOTARY_API_KEY_ID_present=x' "$case_dir/env-presence.log"
    assert_no_grep 'ORCHARD_NOTARY_API_KEY_TYPE_present=x' "$case_dir/env-presence.log"
    assert_no_grep 'ORCHARD_NOTARY_API_ISSUER_ID_present=x' "$case_dir/env-presence.log"
    assert_no_grep 'list-keychains -' "$case_dir/security.log"
    assert_no_grep 'default-keychain' "$case_dir/security.log"
}

assert_security_prepared_for_sign_pkg_and_payload_child() {
    local security_log="$1"
    test "$(grep -c '^unlock-keychain ' "$security_log" || true)" -eq 2
    test "$(grep -c '^set-key-partition-list ' "$security_log" || true)" -eq 2
}

assert_helper_before_real_productsign() {
    local order_log="$1"
    local first_unlock_line
    local first_partition_line
    local real_productsign_line
    first_unlock_line="$(grep -n $'^security\tunlock-keychain$' "$order_log" | sed -n '1s/:.*//p')"
    first_partition_line="$(grep -n $'^security\tset-key-partition-list$' "$order_log" | sed -n '1s/:.*//p')"
    real_productsign_line="$(grep -n $'^productsign\treal$' "$order_log" | sed -n '1s/:.*//p')"
    test -n "$first_unlock_line"
    test -n "$first_partition_line"
    test -n "$real_productsign_line"
    test "$first_unlock_line" -lt "$real_productsign_line"
    test "$first_partition_line" -lt "$real_productsign_line"
}

assert_helper_after_payload_audit() {
    local order_log="$1"
    local first_unlock_line
    local expand_line
    first_unlock_line="$(grep -n $'^security\tunlock-keychain$' "$order_log" | sed -n '1s/:.*//p')"
    expand_line="$(grep -n $'^pkgutil\texpand-full$' "$order_log" | sed -n '1s/:.*//p')"
    test -n "$first_unlock_line"
    test -n "$expand_line"
    test "$expand_line" -lt "$first_unlock_line"
}

assert_no_real_productsign() {
    local productsign_log="$1"
    assert_no_grep $'real\t' "$productsign_log"
}

assert_real_productsign_no_keychain() {
    local productsign_log="$1"
    if grep -F $'real\t' "$productsign_log" | grep -F ' --keychain ' >/dev/null; then
        echo "real productsign argv must omit --keychain" >&2
        cat "$productsign_log" >&2
        exit 1
    fi
}

# PS1: no build keychain keeps productsign argv keychain-free and ignores mode env.
for mode in unset auto flag prepared invalid; do
    case_dir="$TMP_ROOT/ps1-$mode"
    tools="$case_dir/tools"
    make_fixture "$case_dir"
    make_fake_tools "$tools"
    : > "$case_dir/security.log"
    : > "$case_dir/productsign.log"
    : > "$case_dir/env-presence.log"
    output_pkg="$case_dir/out.pkg"
    if [[ "$mode" == "unset" ]]; then
        run_sign_pkg "$tools" "$case_dir" "$output_pkg" PRODUCTSIGN_PROBE_BUCKET=unparseable > "$case_dir/real.out" 2>&1
        run_sign_pkg_dry "$tools" "$case_dir" "$case_dir/dry.pkg" PRODUCTSIGN_PROBE_BUCKET=unparseable > "$case_dir/dry.out" 2>&1
    else
        run_sign_pkg "$tools" "$case_dir" "$output_pkg" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE="$mode" PRODUCTSIGN_PROBE_BUCKET=unparseable > "$case_dir/real.out" 2>&1
        run_sign_pkg_dry "$tools" "$case_dir" "$case_dir/dry.pkg" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE="$mode" PRODUCTSIGN_PROBE_BUCKET=unparseable > "$case_dir/dry.out" 2>&1
    fi
    assert_real_productsign_no_keychain "$case_dir/productsign.log"
    if grep -F 'productsign --sign ' "$case_dir/dry.out" | grep -F ' --keychain ' >/dev/null; then
        echo "dry-run productsign argv must omit --keychain without build keychain" >&2
        cat "$case_dir/dry.out" >&2
        exit 1
    fi
    assert_file_empty "$case_dir/security.log"
done

# PS2: Strategy A real signing inserts --keychain after --sign and prepares once.
case_dir="$TMP_ROOT/ps2-flag-real"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET=accept > "$case_dir/out.log" 2>&1
assert_grep $'probe\t--sign orchard-flag-probe-invalid-identity --keychain' "$case_dir/productsign.log"
assert_grep $'real\t--sign Developer ID Installer: Example, Inc. (TEAMID) --keychain ' "$case_dir/productsign.log"
assert_grep "--keychain $keychain" "$case_dir/productsign.log"
assert_security_prepared_for_sign_pkg_and_payload_child "$case_dir/security.log"
assert_helper_after_payload_audit "$case_dir/order.log"
assert_helper_before_real_productsign "$case_dir/order.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

case_dir="$TMP_ROOT/ps2-flag-xtrace"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
run_sign_pkg_xtrace "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET=accept > "$case_dir/xtrace.out" 2>&1
assert_common_hygiene "$case_dir" "$case_dir/xtrace.out" "$keychain"
assert_security_prepared_for_sign_pkg_and_payload_child "$case_dir/security.log"

# PS3: Strategy A dry-run redacts the keychain path and never calls security.
case_dir="$TMP_ROOT/ps3-dry-redaction"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
run_sign_pkg_dry "$tools" "$case_dir" "$case_dir/dry.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" > "$case_dir/dry.out" 2>&1
assert_grep '--keychain' "$case_dir/dry.out"
assert_grep '\<id\>' "$case_dir/dry.out"
assert_grep '<build-keychain:orchard-build.keychain-db' "$case_dir/dry.out"
assert_common_hygiene "$case_dir" "$case_dir/dry.out" "$keychain"
assert_file_empty "$case_dir/security.log"
productsign_line="$(grep -F 'productsign --sign ' "$case_dir/dry.out")"
case "$productsign_line" in
  *"$keychain"*|*"$INSTALLER_IDENTITY"*|*"$PAYLOAD_IDENTITY"*)
    echo "dry-run productsign line leaked sensitive values" >&2
    printf '%s\n' "$productsign_line" >&2
    exit 1
    ;;
esac

# PS4: Strategy D real signing omits --keychain but still prepares once.
case_dir="$TMP_ROOT/ps4-prepared-real"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET=reject > "$case_dir/out.log" 2>&1
assert_grep $'probe\t--sign orchard-flag-probe-invalid-identity --keychain' "$case_dir/productsign.log"
assert_grep $'real\t--sign Developer ID Installer: Example, Inc. (TEAMID) ' "$case_dir/productsign.log"
assert_real_productsign_no_keychain "$case_dir/productsign.log"
assert_security_prepared_for_sign_pkg_and_payload_child "$case_dir/security.log"
test "$(grep -c '^list-keychains$' "$case_dir/security.log" || true)" -eq 1
assert_helper_before_real_productsign "$case_dir/order.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

case_dir="$TMP_ROOT/ps4-prepared-xtrace"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
run_sign_pkg_xtrace "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET=reject > "$case_dir/xtrace.out" 2>&1
assert_common_hygiene "$case_dir" "$case_dir/xtrace.out" "$keychain"
assert_security_prepared_for_sign_pkg_and_payload_child "$case_dir/security.log"
test "$(grep -c '^list-keychains$' "$case_dir/security.log" || true)" -eq 1

# PS4b: prepared mode fails closed when the build keychain is absent from the active search list.
case_dir="$TMP_ROOT/ps4b-prepared-missing-search-list"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
diag_dir="$case_dir/diagnostics"
assert_fails_with 'Prepared productsign keychain is not in the active keychain search list' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=prepared ORCHARD_FAKE_SECURITY_SEARCH_LIST_MODE=empty PRODUCTSIGN_PROBE_BUCKET=accept
assert_no_real_productsign "$case_dir/productsign.log"
assert_no_grep 'unlock-keychain ' "$case_dir/security.log"
assert_no_grep 'set-key-partition-list ' "$case_dir/security.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
test ! -e "$diag_dir"

case_dir="$TMP_ROOT/ps4b-prepared-missing-search-list-xtrace"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
assert_fails_with 'Prepared productsign keychain is not in the active keychain search list' "$case_dir/xtrace.out" \
    run_sign_pkg_xtrace "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=prepared ORCHARD_FAKE_SECURITY_SEARCH_LIST_MODE=empty PRODUCTSIGN_PROBE_BUCKET=accept
assert_no_real_productsign "$case_dir/productsign.log"
assert_no_grep 'unlock-keychain ' "$case_dir/security.log"
assert_no_grep 'set-key-partition-list ' "$case_dir/security.log"
assert_common_hygiene "$case_dir" "$case_dir/xtrace.out" "$keychain"

case_dir="$TMP_ROOT/ps4b-auto-fallback-missing-search-list"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
diag_dir="$case_dir/diagnostics"
assert_fails_with 'Prepared productsign keychain is not in the active keychain search list' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_FAKE_SECURITY_SEARCH_LIST_MODE=empty PRODUCTSIGN_PROBE_BUCKET=reject
assert_grep $'probe\t' "$case_dir/productsign.log"
assert_no_real_productsign "$case_dir/productsign.log"
assert_no_grep 'unlock-keychain ' "$case_dir/security.log"
assert_no_grep 'set-key-partition-list ' "$case_dir/security.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
test ! -e "$diag_dir"

case_dir="$TMP_ROOT/ps4b-search-list-failure"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
assert_fails_with 'Unable to read active keychain search list for prepared productsign mode' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=prepared ORCHARD_FAKE_SECURITY_SEARCH_LIST_MODE=fail PRODUCTSIGN_PROBE_BUCKET=accept
assert_no_real_productsign "$case_dir/productsign.log"
assert_no_grep 'unlock-keychain ' "$case_dir/security.log"
assert_no_grep 'set-key-partition-list ' "$case_dir/security.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

# PS5: operator-prepared keychain leaves security unmutated while strategy still controls argv.
for bucket in accept reject; do
    case_dir="$TMP_ROOT/ps5-$bucket"
    tools="$case_dir/tools"
    make_fixture "$case_dir"
    make_fake_tools "$tools"
    keychain="$(keychain_path "$case_dir")"
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" PRODUCTSIGN_PROBE_BUCKET="$bucket" > "$case_dir/out.log" 2>&1
    if [[ "$bucket" == "accept" ]]; then
        assert_file_empty "$case_dir/security.log"
        assert_grep "--keychain $keychain" "$case_dir/productsign.log"
    else
        test "$(grep -c '^list-keychains$' "$case_dir/security.log" || true)" -eq 1
        assert_no_grep 'unlock-keychain ' "$case_dir/security.log"
        assert_no_grep 'set-key-partition-list ' "$case_dir/security.log"
        assert_real_productsign_no_keychain "$case_dir/productsign.log"
    fi
    assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
done

# PS6: missing keychain fails before diagnostics reservation, productsign, or security.
case_dir="$TMP_ROOT/ps6-missing-keychain"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
missing_keychain="$case_dir/Keychains/missing-build.keychain-db"
diag_dir="$case_dir/diagnostics"
assert_fails_with 'missing-build.keychain-db' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_BUILD_KEYCHAIN="$missing_keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET=accept
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$missing_keychain"
test ! -e "$diag_dir"
assert_file_empty "$case_dir/productsign.log"
assert_file_empty "$case_dir/security.log"

# PS6b: helper failure stops before real productsign/notary/stapler/checksum.
case_dir="$TMP_ROOT/ps6b-helper-failure"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
assert_fails_with 'unlock-keychain' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET=accept SECURITY_UNLOCK_EXIT=7
assert_no_real_productsign "$case_dir/productsign.log"
assert_no_grep 'notarytool' "$case_dir/order.log"
assert_no_grep 'stapler' "$case_dir/order.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

# PS7: mode overrides skip or run probe deterministically.
case_dir="$TMP_ROOT/ps7-auto"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=auto PRODUCTSIGN_PROBE_BUCKET=accept > "$case_dir/out.log" 2>&1
assert_grep $'probe\t' "$case_dir/productsign.log"
assert_grep "--keychain $keychain" "$case_dir/productsign.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

case_dir="$TMP_ROOT/ps7-force-flag"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=flag PRODUCTSIGN_PROBE_BUCKET=reject > "$case_dir/out.log" 2>&1
assert_no_grep $'probe\t' "$case_dir/productsign.log"
assert_grep "--keychain $keychain" "$case_dir/productsign.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

case_dir="$TMP_ROOT/ps7-force-prepared"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=prepared PRODUCTSIGN_PROBE_BUCKET=accept > "$case_dir/out.log" 2>&1
assert_no_grep $'probe\t' "$case_dir/productsign.log"
assert_real_productsign_no_keychain "$case_dir/productsign.log"
test "$(grep -c '^list-keychains$' "$case_dir/security.log" || true)" -eq 1
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

case_dir="$TMP_ROOT/ps7-invalid"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
diag_dir="$case_dir/diagnostics"
assert_fails_with 'Unsupported ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE value.' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=bogus PRODUCTSIGN_PROBE_BUCKET=accept
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
test ! -e "$diag_dir"
assert_file_empty "$case_dir/security.log"
assert_file_empty "$case_dir/productsign.log"

for invalid_mode in "$FIXTURE_PASSWORD" "$keychain" "$INSTALLER_IDENTITY"; do
    case_dir="$TMP_ROOT/ps7-invalid-secret-$RANDOM"
    tools="$case_dir/tools"
    make_fixture "$case_dir"
    make_fake_tools "$tools"
    keychain="$(keychain_path "$case_dir")"
    diag_dir="$case_dir/diagnostics"
    assert_fails_with 'Unsupported ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE value.' "$case_dir/out.log" \
        run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE="$invalid_mode" PRODUCTSIGN_PROBE_BUCKET=accept
    assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
    test ! -e "$diag_dir"
    assert_file_empty "$case_dir/security.log"
    assert_file_empty "$case_dir/productsign.log"
done

for mode in unset auto flag prepared; do
    case_dir="$TMP_ROOT/ps7-dry-$mode"
    tools="$case_dir/tools"
    make_fixture "$case_dir"
    make_fake_tools "$tools"
    keychain="$(keychain_path "$case_dir")"
    if [[ "$mode" == "unset" ]]; then
        run_sign_pkg_dry "$tools" "$case_dir" "$case_dir/dry.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" > "$case_dir/dry.out" 2>&1
    else
        run_sign_pkg_dry "$tools" "$case_dir" "$case_dir/dry.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE="$mode" > "$case_dir/dry.out" 2>&1
    fi
    assert_file_empty "$case_dir/productsign.log"
    if [[ "$mode" == "prepared" ]]; then
        if grep -F 'productsign --sign ' "$case_dir/dry.out" | grep -F ' --keychain ' >/dev/null; then
            echo "prepared dry-run productsign argv must omit --keychain" >&2
            cat "$case_dir/dry.out" >&2
            exit 1
        fi
    else
        assert_grep '--keychain' "$case_dir/dry.out"
        assert_grep '<build-keychain:orchard-build.keychain-db' "$case_dir/dry.out"
    fi
    assert_common_hygiene "$case_dir" "$case_dir/dry.out" "$keychain"
done

case_dir="$TMP_ROOT/ps7-dry-invalid"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
assert_fails_with 'Unsupported ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE value.' "$case_dir/dry-invalid.out" \
    run_sign_pkg_dry "$tools" "$case_dir" "$case_dir/dry.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=bogus
assert_common_hygiene "$case_dir" "$case_dir/dry-invalid.out" "$keychain"

# PS8: probe classifier buckets fail closed when inconclusive and continue for known option rejections.
for bucket in illegal unrecognized-arguments no-such-option keychain-validation; do
    case_dir="$TMP_ROOT/ps8-$bucket"
    tools="$case_dir/tools"
    make_fixture "$case_dir"
    make_fake_tools "$tools"
    keychain="$(keychain_path "$case_dir")"
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET="$bucket" > "$case_dir/out.log" 2>&1
    if [[ "$bucket" == "illegal" || "$bucket" == "unrecognized-arguments" || "$bucket" == "no-such-option" ]]; then
        assert_real_productsign_no_keychain "$case_dir/productsign.log"
    else
        assert_grep "--keychain $keychain" "$case_dir/productsign.log"
    fi
    assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
done

case_dir="$TMP_ROOT/ps8-timeout-hang"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
assert_fails_with 'productsign --keychain probe timed out after 2s' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS=2 ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET=hang
assert_no_real_productsign "$case_dir/productsign.log"
assert_file_empty "$case_dir/security.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

case_dir="$TMP_ROOT/ps8-no-setsid-fail-closed"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
assert_fails_with 'perl with POSIX::setsid is required for bounded productsign probe cleanup' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_DISABLE_PERL_SETSID_FOR_TEST=1 ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET=accept
assert_no_real_productsign "$case_dir/productsign.log"
assert_file_empty "$case_dir/security.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

for timeout_mode in no-build-keychain flag prepared dry-auto; do
    case_dir="$TMP_ROOT/ps8-timeout-validation-$timeout_mode"
    tools="$case_dir/tools"
    make_fixture "$case_dir"
    make_fake_tools "$tools"
    keychain="$(keychain_path "$case_dir")"
    case "$timeout_mode" in
      no-build-keychain)
        run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS=not-an-int PRODUCTSIGN_PROBE_BUCKET=accept > "$case_dir/out.log" 2>&1
        assert_real_productsign_no_keychain "$case_dir/productsign.log"
        ;;
      flag)
        run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS=not-an-int ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=flag PRODUCTSIGN_PROBE_BUCKET=accept > "$case_dir/out.log" 2>&1
        assert_no_grep $'probe\t' "$case_dir/productsign.log"
        assert_grep "--keychain $keychain" "$case_dir/productsign.log"
        ;;
      prepared)
        run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS=not-an-int ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=prepared PRODUCTSIGN_PROBE_BUCKET=accept > "$case_dir/out.log" 2>&1
        assert_no_grep $'probe\t' "$case_dir/productsign.log"
        assert_real_productsign_no_keychain "$case_dir/productsign.log"
        ;;
      dry-auto)
        run_sign_pkg_dry "$tools" "$case_dir" "$case_dir/dry.pkg" ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS=not-an-int ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=auto > "$case_dir/out.log" 2>&1
        assert_file_empty "$case_dir/productsign.log"
        ;;
    esac
    assert_no_grep 'ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS must be a positive integer' "$case_dir/out.log"
    assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
done

case_dir="$TMP_ROOT/ps8-timeout-validation-auto"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
assert_fails_with 'ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS must be a positive integer' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_PRODUCTSIGN_KEYCHAIN_PROBE_TIMEOUT_SECONDS=not-an-int ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=auto PRODUCTSIGN_PROBE_BUCKET=accept
assert_no_real_productsign "$case_dir/productsign.log"
assert_file_empty "$case_dir/security.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

for bucket in empty unparseable exec-failure; do
    case_dir="$TMP_ROOT/ps8-inconclusive-$bucket"
    tools="$case_dir/tools"
    make_fixture "$case_dir"
    make_fake_tools "$tools"
    keychain="$(keychain_path "$case_dir")"
    assert_fails_with 'productsign --keychain probe was inconclusive' "$case_dir/out.log" \
        run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" PRODUCTSIGN_PROBE_BUCKET="$bucket"
    assert_no_real_productsign "$case_dir/productsign.log"
    assert_file_empty "$case_dir/security.log"
    assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
done

# PS9: real productsign stderr is sanitized while preserving failure status.
case_dir="$TMP_ROOT/ps9-productsign-stderr-redaction"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
assert_fails_with 'fake productsign argv:' "$case_dir/out.log" \
    run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN="$keychain" ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_FAKE_PRODUCTSIGN_ECHO_ARGV_AND_FAIL=1 ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=flag PRODUCTSIGN_PROBE_BUCKET=accept
assert_grep '<id>' "$case_dir/out.log"
assert_grep '<build-keychain:orchard-build.keychain-db>' "$case_dir/out.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"
assert_no_grep 'notarytool' "$case_dir/order.log"
assert_no_grep 'stapler' "$case_dir/order.log"

# PS9b: sanitizer must not re-redact inside its own keychain placeholder when configured path is basename-only.
case_dir="$TMP_ROOT/ps9b-productsign-stderr-nested-placeholder"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
keychain="$(keychain_path "$case_dir")"
(
    cd "$case_dir/Keychains"
    assert_fails_with 'fake productsign argv:' "$case_dir/out.log" \
        run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_BUILD_KEYCHAIN=orchard-build.keychain-db ORCHARD_KEYCHAIN_PASSWORD="$FIXTURE_PASSWORD" ORCHARD_FAKE_PRODUCTSIGN_ECHO_ARGV_AND_FAIL=1 ORCHARD_PRODUCTSIGN_KEYCHAIN_MODE=flag PRODUCTSIGN_PROBE_BUCKET=accept
)
assert_grep '<build-keychain:orchard-build.keychain-db>' "$case_dir/out.log"
assert_no_grep '<build-keychain:<build-keychain:' "$case_dir/out.log"
assert_common_hygiene "$case_dir" "$case_dir/out.log" "$keychain"

# PS10: real notarytool stdout/stderr and sidecar are sanitized for API-key auth.
case_dir="$TMP_ROOT/ps10-notary-output-redaction"
tools="$case_dir/tools"
make_fixture "$case_dir"
make_fake_tools "$tools"
api_key="$case_dir/AuthKey_TEST.p8"
api_key_id='KEY123LEAK'
issuer_id='12345678-1234-1234-1234-123456789abc'
diag_dir="$case_dir/diagnostics"
: > "$api_key"
run_sign_pkg "$tools" "$case_dir" "$case_dir/out.pkg" ORCHARD_SIGN_PKG_DIAGNOSTICS_DIR="$diag_dir" ORCHARD_NOTARY_AUTH=api-key ORCHARD_NOTARY_API_KEY_TYPE=team ORCHARD_NOTARY_API_KEY_PATH="$api_key" ORCHARD_NOTARY_API_KEY_ID="$api_key_id" ORCHARD_NOTARY_API_ISSUER_ID="$issuer_id" ORCHARD_FAKE_NOTARY_ECHO_AUTH=1 PRODUCTSIGN_PROBE_BUCKET=accept > "$case_dir/out.log" 2>&1
assert_grep '<notary-api-key>' "$case_dir/out.log"
assert_grep '<notary-api-key-id>' "$case_dir/out.log"
assert_grep '<notary-issuer-id>' "$case_dir/out.log"
assert_grep '<notary-api-key>' "$case_dir/out.pkg.notary.json"
assert_grep '<notary-api-key-id>' "$case_dir/out.pkg.notary.json"
assert_grep '<notary-issuer-id>' "$case_dir/out.pkg.notary.json"
assert_grep 'fake-submission' "$case_dir/out.pkg.notary.json"
assert_grep 'Accepted' "$case_dir/out.pkg.notary.json"
cat "$case_dir/out.log" "$case_dir/out.pkg.notary.json" "$case_dir/out.pkg.sha256" "$diag_dir"/* > "$case_dir/product-durable-combined.log"
assert_no_grep "$api_key" "$case_dir/product-durable-combined.log"
assert_no_grep "$api_key_id" "$case_dir/product-durable-combined.log"
assert_no_grep "$issuer_id" "$case_dir/product-durable-combined.log"
assert_common_hygiene "$case_dir" "$case_dir/product-durable-combined.log" ""

printf 'ok\tsign-pkg productsign keychain contracts\n'
