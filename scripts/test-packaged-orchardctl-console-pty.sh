#!/usr/bin/env bash
# Real macOS PTY coverage for the packaged orchardctl console entry path.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
STAGED_ROOT="$TMP_ROOT/staged/Library/Application Support/Orchard"
TOOLS="$TMP_ROOT/tools"
HARNESS="$TMP_ROOT/console-pty-harness"
ORCHARDCTL="$TMP_ROOT/orchardctl"
WAIT_ORCHARDCTL="$TMP_ROOT/orchardctl-wait"
SIGNAL_PROBE_ORCHARDCTL="$TMP_ROOT/orchardctl-signal-probe"
WAIT_PROBE_ORCHARDCTL="$TMP_ROOT/orchardctl-wait-probe"
GUARD_ORCHARDCTL="$TMP_ROOT/orchardctl-guard"
GUARD_READY_PROBE_ORCHARDCTL="$TMP_ROOT/orchardctl-guard-ready-probe"
GUARD_TERM_PROBE_ORCHARDCTL="$TMP_ROOT/orchardctl-guard-term-probe"
LAUNCH_ORCHARDCTL="$TMP_ROOT/orchardctl-launch"
EXIT_ORCHARDCTL="$TMP_ROOT/orchardctl-exit"
CLI_WAIT_ORCHARDCTL="$TMP_ROOT/orchardctl-cli-wait"
GUARD_WAIT_ORCHARDCTL="$TMP_ROOT/orchardctl-guard-wait"
SETUP_FAIL_ORCHARDCTL="$TMP_ROOT/orchardctl-setup-fail"
LAUNCH_WAIT_FIXTURE="$TMP_ROOT/launch-wait"
TRANSIENT_PS_FIXTURE="$TMP_ROOT/transient-ps"
WAIT_FIXTURE="$TMP_ROOT/orchardctl-delayed-term-fixture"
LAUNCHCTL_MARKER="$TMP_ROOT/launchctl-called"
CONSOLE_ENV="$STAGED_ROOT/config/console.env"
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
printf '%s\n' "$*" >> "$ORCHARD_TEST_LAUNCHCTL_MARKER"
case "${ORCHARD_TEST_LAUNCHCTL_LOADED:-}:$*" in
  1:print\ *) exit 0 ;;
  1:kickstart\ *) exit 0 ;;
  *) exit 113 ;;
esac
SH
chmod 0755 "$TOOLS/id" "$TOOLS/launchctl"

cat > "$LAUNCH_WAIT_FIXTURE" <<'SH'
#!/bin/sh
printf '__ORCHARD_LAUNCH_WINDOW__\n'
exec /bin/sleep 0.5
SH
chmod 0755 "$LAUNCH_WAIT_FIXTURE"

cat > "$TRANSIENT_PS_FIXTURE" <<'SH'
#!/bin/sh
IFS= read -r failures < "$ORCHARD_TEST_PS_FAILURE_COUNT" || failures=0
case "$failures" in
  ''|*[!0-9]*) exit 125 ;;
esac
if [ "$failures" -gt 0 ]; then
  printf '%s\n' "$((failures - 1))" > "$ORCHARD_TEST_PS_FAILURE_COUNT"
  exit 1
fi
exec /bin/ps "$@"
SH
chmod 0755 "$TRANSIENT_PS_FIXTURE"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$ORCHARDCTL"
chmod 0755 "$ORCHARDCTL"

xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic \
  "$REPO_ROOT/apps/orchard_cli/test/support/console_pty_harness.c" \
  -o "$HARNESS"
xcrun clang -std=c11 -Wall -Wextra -Werror -pedantic \
  "$REPO_ROOT/apps/orchard_cli/test/support/orchardctl_delayed_term_fixture.c" \
  -o "$WAIT_FIXTURE"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^ORCHARD_CLI=.*$|ORCHARD_CLI=\"$WAIT_FIXTURE\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$WAIT_ORCHARDCTL"
chmod 0755 "$WAIT_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^ORCHARD_CLI=.*$|ORCHARD_CLI=\"$WAIT_FIXTURE\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e "s|^_cli_parent_probe=/bin/ps$|_cli_parent_probe=\"$TRANSIENT_PS_FIXTURE\"|" \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$SIGNAL_PROBE_ORCHARDCTL"
chmod 0755 "$SIGNAL_PROBE_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^ORCHARD_CLI=.*$|ORCHARD_CLI=\"$WAIT_FIXTURE\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e "s|^_cli_process_probe=/bin/ps$|_cli_process_probe=\"$TRANSIENT_PS_FIXTURE\"|" \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$WAIT_PROBE_ORCHARDCTL"
chmod 0755 "$WAIT_PROBE_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^ORCHARD_CLI=.*$|ORCHARD_CLI=\"$WAIT_FIXTURE\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e 's|^guard_pre_ready_barrier() { :; }$|guard_pre_ready_barrier() { while guard_parent_matches; do /bin/sleep 0.01 \|\| :; done; return 1; }|' \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$GUARD_ORCHARDCTL"
chmod 0755 "$GUARD_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e "s|^_guard_process_probe=/bin/ps$|_guard_process_probe=\"$TRANSIENT_PS_FIXTURE\"|" \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$GUARD_READY_PROBE_ORCHARDCTL"
chmod 0755 "$GUARD_READY_PROBE_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^ORCHARD_CLI=.*$|ORCHARD_CLI=\"$WAIT_FIXTURE\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e 's|^guard_pre_ready_barrier() { :; }$|guard_pre_ready_barrier() { while guard_parent_matches; do /bin/sleep 0.01 \|\| :; done; return 1; }|' \
  -e "s|^_guard_parent_probe=/bin/ps$|_guard_parent_probe=\"$TRANSIENT_PS_FIXTURE\"|" \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$GUARD_TERM_PROBE_ORCHARDCTL"
chmod 0755 "$GUARD_TERM_PROBE_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^ORCHARD_CLI=.*$|ORCHARD_CLI=\"$WAIT_FIXTURE\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e 's|^cli_pre_launch_barrier() { :; }$|cli_pre_launch_barrier() { printf "__ORCHARD_PRE_LAUNCH__\\n__ORCHARD_LAUNCHER_PID__:%s\\n" "$_cli_pid"; while [ -z "$_termination_signal" ]; do /bin/sleep 0.01 \|\| :; done; }|' \
  -e "s|^_cli_launch_wait_command=/bin/sleep$|_cli_launch_wait_command=\"$LAUNCH_WAIT_FIXTURE\"|" \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$LAUNCH_ORCHARDCTL"
chmod 0755 "$LAUNCH_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e 's|^cli_pre_exit_barrier() { :; }$|cli_pre_exit_barrier() { printf "__ORCHARD_PRE_EXIT__\\n"; while [ -z "$_termination_signal" ]; do /bin/sleep 0.01 \|\| :; done; }|' \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$EXIT_ORCHARDCTL"
chmod 0755 "$EXIT_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e 's|^cli_post_wait_barrier() { :; }$|cli_post_wait_barrier() { printf "__ORCHARD_CLI_POST_WAIT__\\n"; while [ -z "$_termination_signal" ]; do /bin/sleep 0.01 \|\| :; done; }|' \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$CLI_WAIT_ORCHARDCTL"
chmod 0755 "$CLI_WAIT_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e 's|^guard_post_wait_barrier() { :; }$|guard_post_wait_barrier() { printf "__ORCHARD_GUARD_POST_WAIT__\\n"; while [ -z "$_termination_signal" ]; do /bin/sleep 0.01 \|\| :; done; printf "__ORCHARD_GUARD_POST_SIGNAL__:%s\\n" "$_termination_status"; }|' \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$GUARD_WAIT_ORCHARDCTL"
chmod 0755 "$GUARD_WAIT_ORCHARDCTL"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^SAFE_PATH=.*$|SAFE_PATH=\"$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin\"|" \
  -e 's#^_completion_uid=$(/usr/bin/id -u) || exit 1$#_completion_uid=$(/usr/bin/false) || exit 1#' \
  "$REPO_ROOT/packaging/pkg/bin/orchardctl" > "$SETUP_FAIL_ORCHARDCTL"
chmod 0755 "$SETUP_FAIL_ORCHARDCTL"

SETUP_FAIL_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-setup-failure -- "$SETUP_FAIL_ORCHARDCTL" console enable
)
[[ "$SETUP_FAIL_OUTPUT" = 'console PTY ok: wrapper-setup-failure' ]] || \
  fail "pre-guard setup failure leaked its custody directory"

GUARD_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" guard-pre-ready-death -- "$GUARD_ORCHARDCTL" console enable
)
[[ "$GUARD_OUTPUT" = 'console PTY ok: guard-pre-ready-death' ]] || \
  fail "pre-readiness guard death did not exit safely"

WRAPPER_DEATH_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-pre-ready-death -- "$GUARD_ORCHARDCTL" console enable
)
[[ "$WRAPPER_DEATH_OUTPUT" = 'console PTY ok: wrapper-pre-ready-death' ]] || \
  fail "pre-readiness wrapper death stranded its custody guard"

WRAPPER_TERM_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-pre-ready-term -- "$GUARD_ORCHARDCTL" console enable
)
[[ "$WRAPPER_TERM_OUTPUT" = 'console PTY ok: wrapper-pre-ready-term' ]] || \
  fail "pre-readiness wrapper TERM did not cancel guard startup"

printf '1\n' > "$TMP_ROOT/guard-ready-probe-failures"
GUARD_READY_PROBE_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_PS_FAILURE_COUNT="$TMP_ROOT/guard-ready-probe-failures" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-term-paced -- "$GUARD_READY_PROBE_ORCHARDCTL" console enable
)
[[ "$GUARD_READY_PROBE_OUTPUT" = 'console PTY ok: wrapper-term-paced' ]] || \
  fail "transient guard readiness probe failure stranded startup"

printf '1\n' > "$TMP_ROOT/guard-term-probe-failures"
GUARD_TERM_PROBE_OUTPUT=$(
  ORCHARD_TEST_PS_FAILURE_COUNT="$TMP_ROOT/guard-term-probe-failures" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-pre-ready-term -- "$GUARD_TERM_PROBE_ORCHARDCTL" console enable
)
[[ "$GUARD_TERM_PROBE_OUTPUT" = 'console PTY ok: wrapper-pre-ready-term' ]] || \
  fail "transient guard termination probe failure stranded cancellation"

WRAPPER_LAUNCH_TERM_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-pre-launch-term -- "$LAUNCH_ORCHARDCTL" console enable
)
[[ "$WRAPPER_LAUNCH_TERM_OUTPUT" = 'console PTY ok: wrapper-pre-launch-term' ]] || \
  fail "pre-launch wrapper TERM started a cancelled CLI"

WRAPPER_LAUNCH_INT_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-pre-launch-int -- "$LAUNCH_ORCHARDCTL" console enable
)
[[ "$WRAPPER_LAUNCH_INT_OUTPUT" = 'console PTY ok: wrapper-pre-launch-int' ]] || \
  fail "pre-launch wrapper INT stranded its launch supervisor"

WRAPPER_LAUNCH_QUIT_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-pre-launch-quit -- "$LAUNCH_ORCHARDCTL" console enable
)
[[ "$WRAPPER_LAUNCH_QUIT_OUTPUT" = 'console PTY ok: wrapper-pre-launch-quit' ]] || \
  fail "pre-launch wrapper QUIT stranded its launch supervisor"

WRAPPER_LAUNCH_SUBSTITUTION_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_GUARD_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    "$HARNESS" wrapper-launch-path-substitution -- "$LAUNCH_ORCHARDCTL" console enable
)
[[ "$WRAPPER_LAUNCH_SUBSTITUTION_OUTPUT" = \
  'console PTY ok: wrapper-launch-path-substitution' ]] || \
  fail "launch supervisor trusted a substituted custody path"

WRAPPER_LATE_INT_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    "$HARNESS" wrapper-late-int -- "$EXIT_ORCHARDCTL" console enable
)
[[ "$WRAPPER_LATE_INT_OUTPUT" = 'console PTY ok: wrapper-late-int' ]] || \
  fail "late foreground INT lost its exact wrapper exit status"

WRAPPER_CLI_POST_WAIT_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_CLI_REAPED_MARKER=1 \
    "$HARNESS" wrapper-cli-post-wait-int -- "$CLI_WAIT_ORCHARDCTL" console enable
)
[[ "$WRAPPER_CLI_POST_WAIT_OUTPUT" = \
  'console PTY ok: wrapper-cli-post-wait-int' ]] || \
  fail "post-wait INT overwrote the authoritative CLI status"

WRAPPER_GUARD_POST_WAIT_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    "$HARNESS" wrapper-guard-post-wait-int -- "$GUARD_WAIT_ORCHARDCTL" console enable
)
[[ "$WRAPPER_GUARD_POST_WAIT_OUTPUT" = \
  'console PTY ok: wrapper-guard-post-wait-int' ]] || \
  fail "post-wait INT turned successful guard cleanup into failure"

WAIT_OUTPUT=$(
  ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    ORCHARD_TEST_CLI_REAPED_MARKER=1 \
    "$HARNESS" wrapper-wait-reap -- "$WAIT_ORCHARDCTL" console enable
)
[[ "$WAIT_OUTPUT" = 'console PTY ok: wrapper-wait-reap' ]] || \
  fail "wrapper returned before reaping its interrupted CLI child"

printf '1\n' > "$TMP_ROOT/signal-probe-failures"
SIGNAL_PROBE_OUTPUT=$(
  ORCHARD_TEST_PS_FAILURE_COUNT="$TMP_ROOT/signal-probe-failures" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    ORCHARD_TEST_CLI_REAPED_MARKER=1 \
    "$HARNESS" wrapper-wait-reap -- "$SIGNAL_PROBE_ORCHARDCTL" console enable
)
[[ "$SIGNAL_PROBE_OUTPUT" = 'console PTY ok: wrapper-wait-reap' ]] || \
  fail "transient signal-forward probe failure stranded the CLI"

printf '1\n' > "$TMP_ROOT/wait-probe-failures"
WAIT_PROBE_OUTPUT=$(
  ORCHARD_TEST_PS_FAILURE_COUNT="$TMP_ROOT/wait-probe-failures" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    ORCHARD_TEST_CLI_REAPED_MARKER=1 \
    "$HARNESS" wrapper-wait-reap -- "$WAIT_PROBE_ORCHARDCTL" console enable
)
[[ "$WAIT_PROBE_OUTPUT" = 'console PTY ok: wrapper-wait-reap' ]] || \
  fail "transient post-wait probe failure abandoned the CLI"

OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    "$HARNESS" pasted-mismatch -- "$ORCHARDCTL" console enable
)
[[ "$OUTPUT" = 'console PTY ok: pasted-mismatch' ]] || fail "unexpected harness result"
[[ ! -e "$CONSOLE_ENV" ]] || fail "aborted enable created console.env"
[[ ! -e "$LAUNCHCTL_MARKER" ]] || fail "aborted enable attempted controller readiness or restart"

for _attempt in 1 2 3 4; do
  rm -f "$CONSOLE_ENV" "$LAUNCHCTL_MARKER"
  SUCCESS_OUTPUT=$(
    ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
      ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
      "$HARNESS" wrapper-success-not-loaded -- "$ORCHARDCTL" console enable
  )
  [[ "$SUCCESS_OUTPUT" = 'console PTY ok: wrapper-success-not-loaded' ]] || \
    fail "packaged successful enable did not exit cleanly"
  [[ -f "$CONSOLE_ENV" ]] || fail "packaged successful enable did not persist console.env"
  [[ "$(stat -f '%Lp' "$CONSOLE_ENV")" = '600' ]] || \
    fail "packaged successful enable did not protect console.env"
  grep -q '^ORCHARD_CONSOLE_ENABLED="true"$' "$CONSOLE_ENV" || \
    fail "packaged successful enable did not enable Console"
  grep -q '^ORCHARD_CONSOLE_USERNAME=' "$CONSOLE_ENV" || \
    fail "packaged successful enable did not persist a username"
  grep -q '^ORCHARD_CONSOLE_PASSWORD=' "$CONSOLE_ENV" || \
    fail "packaged successful enable did not persist a password"
  [[ "$(cat "$LAUNCHCTL_MARKER")" = \
    'print system/com.orchard.controller' ]] || \
    fail "packaged successful enable did not complete not-loaded handling"
done

rm -f "$CONSOLE_ENV" "$LAUNCHCTL_MARKER"
LOADED_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    ORCHARD_TEST_LAUNCHCTL_LOADED=1 \
    "$HARNESS" wrapper-success-loaded -- "$ORCHARDCTL" console enable
)
[[ "$LOADED_OUTPUT" = 'console PTY ok: wrapper-success-loaded' ]] || \
  fail "packaged successful enable did not complete loaded restart handling"
[[ -f "$CONSOLE_ENV" ]] || fail "loaded restart did not persist console.env"
[[ "$(stat -f '%Lp' "$CONSOLE_ENV")" = '600' ]] || \
  fail "loaded restart did not protect console.env"
[[ "$(cat "$LAUNCHCTL_MARKER")" = $'print system/com.orchard.controller\nkickstart -k system/com.orchard.controller' ]] || \
  fail "packaged successful enable did not restart a loaded controller"

ENABLED_CHECKSUM=$(cksum "$CONSOLE_ENV")
rm -f "$LAUNCHCTL_MARKER"
ROTATE_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    "$HARNESS" wrapper-success-rotate -- "$ORCHARDCTL" console rotate
)
[[ "$ROTATE_OUTPUT" = 'console PTY ok: wrapper-success-rotate' ]] || \
  fail "packaged successful rotate did not exit cleanly"
[[ -f "$CONSOLE_ENV" ]] || fail "packaged successful rotate removed console.env"
[[ "$(stat -f '%Lp' "$CONSOLE_ENV")" = '600' ]] || \
  fail "packaged successful rotate did not protect console.env"
[[ "$(cksum "$CONSOLE_ENV")" != "$ENABLED_CHECKSUM" ]] || \
  fail "packaged successful rotate did not replace the credential"
[[ "$(cat "$LAUNCHCTL_MARKER")" = \
  'print system/com.orchard.controller' ]] || \
  fail "packaged successful rotate did not complete not-loaded handling"
rm -f "$CONSOLE_ENV" "$LAUNCHCTL_MARKER"

WRAPPER_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    "$HARNESS" wrapper-term-paced -- "$ORCHARDCTL" console enable
)
[[ "$WRAPPER_OUTPUT" = 'console PTY ok: wrapper-term-paced' ]] || \
  fail "wrapper signal did not preserve the PTY cleanup fence"
[[ ! -e "$CONSOLE_ENV" ]] || fail "signalled wrapper created console.env"
[[ ! -e "$LAUNCHCTL_MARKER" ]] || fail "signalled wrapper attempted controller readiness or restart"

WRAPPER_INT_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    "$HARNESS" wrapper-int-paced -- "$ORCHARDCTL" console enable
)
[[ "$WRAPPER_INT_OUTPUT" = 'console PTY ok: wrapper-int-paced' ]] || \
  fail "foreground wrapper INT did not preserve the PTY cleanup fence"
[[ ! -e "$CONSOLE_ENV" ]] || fail "INT-signalled wrapper created console.env"
[[ ! -e "$LAUNCHCTL_MARKER" ]] || \
  fail "INT-signalled wrapper attempted controller readiness or restart"

WRAPPER_QUIT_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    "$HARNESS" wrapper-quit-paced -- "$ORCHARDCTL" console enable
)
[[ "$WRAPPER_QUIT_OUTPUT" = 'console PTY ok: wrapper-quit-paced' ]] || \
  fail "foreground wrapper QUIT did not preserve the PTY cleanup fence"
[[ ! -e "$CONSOLE_ENV" ]] || fail "QUIT-signalled wrapper created console.env"
[[ ! -e "$LAUNCHCTL_MARKER" ]] || \
  fail "QUIT-signalled wrapper attempted controller readiness or restart"

SUBSTITUTION_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_CLI_PID_MARKER=1 \
    ORCHARD_TEST_CLI_REAPED_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    "$HARNESS" wrapper-path-substitution -- "$ORCHARDCTL" console enable
)
[[ "$SUBSTITUTION_OUTPUT" = 'console PTY ok: wrapper-path-substitution' ]] || \
  fail "wrapper released a substituted custody directory"
[[ ! -e "$CONSOLE_ENV" ]] || fail "custody substitution created console.env"
[[ ! -e "$LAUNCHCTL_MARKER" ]] || \
  fail "custody substitution attempted controller readiness or restart"

TERMINAL_CLOSE_OUTPUT=$(
  ORCHARD_SUPPORT_ROOT="$STAGED_ROOT" \
    ORCHARD_TEST_LAUNCHCTL_MARKER="$LAUNCHCTL_MARKER" \
    ORCHARD_TEST_WRAPPER_PID_MARKER=1 \
    ORCHARD_TEST_CUSTODY_DIR_MARKER=1 \
    "$HARNESS" terminal-close -- "$ORCHARDCTL" console enable
)
[[ "$TERMINAL_CLOSE_OUTPUT" = 'console PTY ok: terminal-close' ]] || \
  fail "terminal close leaked protected-input processes or custody"
[[ ! -e "$CONSOLE_ENV" ]] || fail "terminal close created console.env"
[[ ! -e "$LAUNCHCTL_MARKER" ]] || \
  fail "terminal close attempted controller readiness or restart"

unset ORCHARD_CONSOLE_ENABLED ORCHARD_CONSOLE_USERNAME ORCHARD_CONSOLE_PASSWORD
CONSOLE_STATE=$(
  "$STAGED_ROOT/releases/orchard_cli/bin/orchard_cli" eval '
    config = Application.fetch_env!(:orchard_controller, :console)

    if Keyword.fetch!(config, :enabled) == false and
         Keyword.get(config, :username) == nil and
         Keyword.get(config, :password) == nil do
      IO.puts("console-disabled")
    else
      System.halt(1)
    end
  '
)
[[ "$CONSOLE_STATE" = 'console-disabled' ]] || fail "packaged runtime did not keep Console disabled"

printf '%s\n' 'Packaged orchardctl PTY secret-input test passed.'
