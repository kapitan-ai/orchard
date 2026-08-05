#!/usr/bin/env bash
# Real macOS PTY coverage for the packaged orchardctl console entry path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
STAGED_ROOT="$TMP_ROOT/staged/Library/Application Support/Orchard"
TOOLS="$TMP_ROOT/tools"
HARNESS="$TMP_ROOT/console-pty-harness"
ORCHARDCTL="$TMP_ROOT/orchardctl"
LAUNCHCTL_MARKER="$TMP_ROOT/launchctl-called"
CONSOLE_ENV="$STAGED_ROOT/config/console.env"
EXPECTED_ENV="$TMP_ROOT/expected-console.env"
RELEASE_SOURCE="$REPO_ROOT/_build/prod/rel/orchard_cli"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'packaged orchardctl PTY failure: %s\n' "$1" >&2
  exit 1
}

cd "$REPO_ROOT"
MIX_ENV=prod mise exec -- mix release orchard_cli --overwrite >/dev/null

mkdir -p "$STAGED_ROOT/releases" "$STAGED_ROOT/support" "$STAGED_ROOT/config" "$TOOLS"
cp -R "$RELEASE_SOURCE" "$STAGED_ROOT/releases/orchard_cli"
printf '%s\n' 'controller' > "$STAGED_ROOT/support/.install-role"
printf '%s\n' 'ORCHARD_CONSOLE_ENABLED="false"' > "$EXPECTED_ENV"
cp "$EXPECTED_ENV" "$CONSOLE_ENV"
chmod 0600 "$CONSOLE_ENV"

cat > "$TOOLS/id" <<'SH'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
  printf '0\n'
else
  exec /usr/bin/id "$@"
fi
SH

cat > "$TOOLS/launchctl" <<'SH'
#!/bin/sh
: > "$ORCHARD_TEST_LAUNCHCTL_MARKER"
exit 113
SH
chmod 0755 "$TOOLS/id" "$TOOLS/launchctl"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$ORCHARDCTL"
chmod 0755 "$ORCHARDCTL"

xcrun clang -std=c11 -Wall -Wextra -Werror \
  "$REPO_ROOT/apps/orchard_cli/test/support/console_pty_harness.c" \
  -o "$HARNESS"

OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    "$HARNESS" pasted-mismatch -- "$ORCHARDCTL" console enable
)
[[ "$OUTPUT" = 'console PTY ok: pasted-mismatch' ]] || fail "unexpected harness result"
cmp -s "$EXPECTED_ENV" "$CONSOLE_ENV" || fail "aborted enable changed console.env"
[[ ! -e "$LAUNCHCTL_MARKER" ]] || fail "aborted enable attempted controller readiness or restart"

printf '%s\n' 'Packaged orchardctl PTY secret-input test passed.'
