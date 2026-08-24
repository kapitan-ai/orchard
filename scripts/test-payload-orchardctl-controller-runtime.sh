#!/usr/bin/env bash
# Regression coverage for payload orchardctl Controller-runtime routing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_WRAPPER="$REPO_ROOT/packaging/payload/bin/orchardctl"
TMP_ROOT="$(mktemp -d)"
PACKAGE_ROOT="$TMP_ROOT/Library/Application Support/Orchard"
TOOLS="$TMP_ROOT/tools"
WRAPPER="$TMP_ROOT/orchardctl"
INVOCATIONS="$TMP_ROOT/invocations.log"
UNTRUSTED_TOOL_CALLS="$TMP_ROOT/untrusted-tool-calls.log"
PRIVATE_TMP="$TMP_ROOT/private-tmp"
UNTRUSTED_TMP="$TMP_ROOT/untrusted-tmp"
RPC_PROCESS_EVENTS="$TMP_ROOT/rpc-process-events.log"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  echo "$1" >&2
  exit 1
}

assert_file_contains() {
  local expected="$1"
  local path="$2"

  grep -F -- "$expected" "$path" >/dev/null || {
    echo "expected $path to contain: $expected" >&2
    cat "$path" >&2
    exit 1
  }
}

assert_file_empty() {
  local path="$1"

  if [[ -s "$path" ]]; then
    echo "expected $path to be empty" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_invocation() {
  local expected="$1"

  assert_file_contains "$expected" "$INVOCATIONS"
}

assert_no_invocation() {
  local unexpected="$1"

  if grep -F -- "$unexpected" "$INVOCATIONS" >/dev/null; then
    echo "unexpected invocation: $unexpected" >&2
    cat "$INVOCATIONS" >&2
    exit 1
  fi
}

run_case() {
  local label="$1"
  local mode="$2"
  shift 2

  : > "$INVOCATIONS"
  RUN_STDOUT="$TMP_ROOT/$label.stdout"
  RUN_STDERR="$TMP_ROOT/$label.stderr"

  set +e
  FAKE_RPC_MODE="$mode" FAKE_INVOCATIONS="$INVOCATIONS" \
    FAKE_RPC_PROCESS_EVENTS="$RPC_PROCESS_EVENTS" \
    UNTRUSTED_TOOL_CALLS="$UNTRUSTED_TOOL_CALLS" \
    TMPDIR="$UNTRUSTED_TMP" PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$WRAPPER" "$@" >"$RUN_STDOUT" 2>"$RUN_STDERR"
  RUN_STATUS=$?
  set -e
}

mkdir -p "$PACKAGE_ROOT/releases/orchard_cli/bin"
mkdir -p "$PACKAGE_ROOT/releases/orchard_controller/bin"
mkdir -p "$PACKAGE_ROOT/config"
mkdir -p "$TOOLS"
mkdir -p "$PRIVATE_TMP"
mkdir -p "$UNTRUSTED_TMP"
printf 'controller-cookie\n' > "$PACKAGE_ROOT/config/beam.cookie"
chmod 0600 "$PACKAGE_ROOT/config/beam.cookie"

# The packaged wrapper requires a root-owned 0600 cookie, which an unprivileged
# test fixture cannot create. Fake ownership for that file only; every other
# query (including the standalone custody identity checks) must stay truthful.
cat > "$TOOLS/stat" <<'SH'
#!/bin/sh
if [ "${2:-}" = '%u:%Lp' ]; then
  case "${3:-}" in
    */config/beam.cookie) printf '0:600\n' ; exit 0 ;;
  esac
fi
exec /usr/bin/stat "$@"
SH
chmod +x "$TOOLS/stat"

cat > "$TOOLS/mktemp" <<'SH'
#!/bin/sh
printf 'mktemp:%s\n' "$*" >> "$UNTRUSTED_TOOL_CALLS"
exec /usr/bin/mktemp "$@"
SH
chmod +x "$TOOLS/mktemp"

cat > "$TOOLS/lsof" <<'SH'
#!/bin/sh
case "$*" in
  *-iTCP:4369*) port=4369 ;;
  *-iTCP:52171*) port=52171 ;;
  *) exit 1 ;;
esac
printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
if [ "${FAKE_LSOF_MODE:-loopback}" = wildcard ]; then
  printf 'beam 123 root 0u IPv4 0 0t0 TCP *:%s (LISTEN)\n' "$port"
else
  printf 'beam 123 root 0u IPv4 0 0t0 TCP 127.0.0.1:%s (LISTEN)\n' "$port"
fi
SH
chmod +x "$TOOLS/lsof"

cat > "$PACKAGE_ROOT/releases/orchard_cli/bin/orchard_cli" <<'SH'
#!/bin/sh
printf 'standalone:%s\n' "$*" >> "$FAKE_INVOCATIONS"
printf 'standalone_umask=%s\n' "$(umask)" >> "$FAKE_INVOCATIONS"
printf 'standalone cli\n'
SH
chmod +x "$PACKAGE_ROOT/releases/orchard_cli/bin/orchard_cli"

cat > "$PACKAGE_ROOT/releases/orchard_controller/bin/orchard_controller" <<'SH'
#!/bin/sh
printf 'controller:%s\n' "$*" >> "$FAKE_INVOCATIONS"
printf 'release_node=%s\n' "${RELEASE_NODE:-missing}" >> "$FAKE_INVOCATIONS"
printf 'release_cookie=%s\n' "${RELEASE_COOKIE:-missing}" >> "$FAKE_INVOCATIONS"
printf 'epmd_port=%s\n' "${ERL_EPMD_PORT:-missing}" >> "$FAKE_INVOCATIONS"
printf 'epmd_address=%s\n' "${ERL_EPMD_ADDRESS:-missing}" >> "$FAKE_INVOCATIONS"
printf 'erl_aflags=%s\n' "${ERL_AFLAGS:-missing}" >> "$FAKE_INVOCATIONS"
printf 'rpc_umask=%s\n' "$(umask)" >> "$FAKE_INVOCATIONS"

case "$FAKE_RPC_MODE" in
  success)
    printf 'ORCHARDCTL_RPC_V1:0:stdout:Y29udHJvbGxlciBzdWNjZXNz\n'
    ;;
  error)
    printf 'ORCHARDCTL_RPC_V1:7:stderr:RXJyb3I6IGNvbnRyb2xsZXIgcmVqZWN0ZWQ=\n'
    ;;
  none)
    printf 'ORCHARDCTL_RPC_V1:0:none:\n'
    ;;
  malformed)
    printf 'not-an-orchard-envelope\n'
    ;;
  extra-blank-line)
    printf 'ORCHARDCTL_RPC_V1:0:stdout:Y29udHJvbGxlciBzdWNjZXNz\n\n'
    ;;
  nonresponsive)
    # sh defers the trap until the foreground sleep returns, so keep the sleep
    # granularity well under RPC_TERM_GRACE_SECONDS or the watchdog SIGKILLs
    # this fixture before it can record the TERM it received.
    trap 'printf "terminated\n" >> "$FAKE_RPC_PROCESS_EVENTS"; exit 143' TERM
    while :; do /bin/sleep 0.05; done
    ;;
  term-resistant)
    printf 'term-resistant:%s\n' "$$" >> "$FAKE_RPC_PROCESS_EVENTS"
    trap '' TERM
    while :; do /bin/sleep 1; done
    ;;
  oversized)
    set -e
    /usr/bin/yes X
    printf 'oversized-complete\n' >> "$FAKE_RPC_PROCESS_EVENTS"
    ;;
  failure)
    printf 'simulated rpc failure\n' >&2
    exit 1
    ;;
  *)
    printf 'unexpected fake mode: %s\n' "$FAKE_RPC_MODE" >&2
    exit 2
    ;;
esac
SH
chmod +x "$PACKAGE_ROOT/releases/orchard_controller/bin/orchard_controller"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$PACKAGE_ROOT\"|" \
  -e "s|^RPC_TMP_PARENT=.*$|RPC_TMP_PARENT=\"$PRIVATE_TMP\"|" \
  -e 's|^RPC_TIMEOUT_SECONDS=.*$|RPC_TIMEOUT_SECONDS=2|' \
  -e 's|^RPC_TERM_GRACE_SECONDS=.*$|RPC_TERM_GRACE_SECONDS=1|' \
  -e 's|^RPC_OUTPUT_LIMIT_BLOCKS=.*$|RPC_OUTPUT_LIMIT_BLOCKS=8|' \
  -e "s|/usr/bin/stat|$TOOLS/stat|g" \
  -e "s|/usr/sbin/lsof|$TOOLS/lsof|g" \
  "$SOURCE_WRAPPER" > "$WRAPPER"
chmod +x "$WRAPPER"

node_commands=(
  list inspect pending admit reject cordon uncordon drain cancel-drain maintenance resume decommission
)

for command in "${node_commands[@]}"; do
  run_case "route-$command" success nodes "$command" node-id --yes
  if [[ "$RUN_STATUS" -ne 0 ]]; then
    cat "$RUN_STDOUT" "$RUN_STDERR" >&2
    fail "expected nodes $command to succeed through Controller RPC"
  fi
  assert_invocation "controller:rpc "
  assert_no_invocation "standalone:"
  assert_file_contains "controller success" "$RUN_STDOUT"
  assert_file_empty "$RUN_STDERR"
done

standalone_cases=(
  "status"
  "nodes --help"
  "nodes admit --help"
  "nodes enrollment create"
  "nodes trust init"
  "nodes"
)

for invocation in "${standalone_cases[@]}"; do
  # shellcheck disable=SC2086 # Each fixture deliberately describes argv words.
  run_case "standalone-${invocation// /-}" success $invocation
  [[ "$RUN_STATUS" -eq 0 ]] || fail "expected standalone invocation to succeed: $invocation"
  assert_invocation "standalone:eval "
  assert_no_invocation "controller:"
  assert_file_contains "standalone cli" "$RUN_STDOUT"
done

run_case error error nodes admit node-id --yes
[[ "$RUN_STATUS" -eq 7 ]] || fail "expected Controller command error exit 7, got $RUN_STATUS"
assert_file_empty "$RUN_STDOUT"
assert_file_contains "Error: controller rejected" "$RUN_STDERR"
assert_no_invocation "standalone:"

run_case none none nodes list
[[ "$RUN_STATUS" -eq 0 ]] || fail "expected no-output Controller result to succeed"
assert_file_empty "$RUN_STDOUT"
assert_file_empty "$RUN_STDERR"

hostile_reason='capacity "quoted" #{System.halt(9)}
second line'
run_case hostile success nodes admit node-id --capacity-policy-reason "$hostile_reason" --yes
[[ "$RUN_STATUS" -eq 0 ]] || fail "expected hostile argument fixture to remain data"
assert_no_invocation "$hostile_reason"
assert_invocation "OrchardCLI.ControllerRPC.main_base64("

run_case rpc-failure failure nodes admit node-id --yes
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected RPC failure exit 1, got $RUN_STATUS"
assert_no_invocation "standalone:"
assert_file_contains "controller runtime" "$RUN_STDERR"

run_case rpc-json-failure failure nodes admit node-id --yes --json
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected JSON RPC failure exit 1, got $RUN_STATUS"
assert_file_empty "$RUN_STDOUT"
assert_file_contains '"code":"controller_runtime_unavailable"' "$RUN_STDERR"
if grep -F -- "simulated rpc failure" "$RUN_STDERR" >/dev/null; then
  fail "expected JSON RPC failure to omit release diagnostics"
fi
assert_no_invocation "standalone:"

: > "$INVOCATIONS"
set +e
ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc FAKE_RPC_MODE=success FAKE_INVOCATIONS="$INVOCATIONS" \
  FAKE_RPC_PROCESS_EVENTS="$RPC_PROCESS_EVENTS" \
  PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$WRAPPER" nodes admit node-id --yes >"$TMP_ROOT/grpc.stdout" 2>"$TMP_ROOT/grpc.stderr"
grpc_status=$?
set -e
[[ "$grpc_status" -eq 0 ]] || fail "expected gRPC compatibility mode to retain Controller RPC"
assert_file_contains "controller success" "$TMP_ROOT/grpc.stdout"
assert_file_empty "$TMP_ROOT/grpc.stderr"
assert_invocation "release_node=orchard_controller_management@127.0.0.1"
assert_invocation "epmd_address=127.0.0.1"
assert_invocation "erl_aflags=-kernel inet_dist_use_interface {127,0,0,1}"
assert_no_invocation "standalone:"

: > "$INVOCATIONS"
set +e
ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc FAKE_LSOF_MODE=wildcard FAKE_RPC_MODE=success \
  FAKE_INVOCATIONS="$INVOCATIONS" FAKE_RPC_PROCESS_EVENTS="$RPC_PROCESS_EVENTS" \
  PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$WRAPPER" nodes pending >"$TMP_ROOT/wildcard.stdout" 2>"$TMP_ROOT/wildcard.stderr"
wildcard_status=$?
set -e
[[ "$wildcard_status" -eq 1 ]] || fail "expected wildcard management listener to fail closed"
assert_file_contains "controller runtime" "$TMP_ROOT/wildcard.stderr"
assert_no_invocation "standalone:"
assert_no_invocation "controller:"

for invocation in "nodes enrollment future-mutation" "nodes trust future-mutation"; do
  # shellcheck disable=SC2086 # Each fixture deliberately describes argv words.
  run_case "unknown-${invocation// /-}" success $invocation
  [[ "$RUN_STATUS" -eq 1 ]] || fail "expected unknown offline namespace command to be denied: $invocation"
  assert_file_contains "unknown packaged nodes command" "$RUN_STDERR"
  assert_no_invocation "standalone:"
  assert_no_invocation "controller:"
done

run_case unknown-node success nodes future-mutation --yes
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected unknown nodes command to be denied"
assert_file_empty "$RUN_STDOUT"
assert_file_contains "unknown packaged nodes command" "$RUN_STDERR"
assert_no_invocation "standalone:"
assert_no_invocation "controller:"

run_case unknown-node-json success nodes future-mutation --yes --json
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected unknown JSON nodes command to be denied"
assert_file_empty "$RUN_STDOUT"
assert_file_contains '"code":"unknown_packaged_nodes_command"' "$RUN_STDERR"
assert_no_invocation "standalone:"
assert_no_invocation "controller:"

run_case malformed malformed nodes admit node-id --yes
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected malformed RPC response exit 1, got $RUN_STATUS"
assert_no_invocation "standalone:"
assert_file_contains "controller runtime" "$RUN_STDERR"

run_case extra-blank-line extra-blank-line nodes admit node-id --yes
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected an extra RPC output line to fail closed"
assert_no_invocation "standalone:"
assert_file_contains "controller runtime" "$RUN_STDERR"

: > "$UNTRUSTED_TOOL_CALLS"
run_case untrusted-environment success nodes pending
[[ "$RUN_STATUS" -eq 0 ]] || fail "expected a hostile inherited environment to be ignored"
assert_file_empty "$UNTRUSTED_TOOL_CALLS"
if find "$UNTRUSTED_TMP" -mindepth 1 -print -quit | grep -q .; then
  fail "expected inherited TMPDIR to remain unused"
fi

: > "$RPC_PROCESS_EVENTS"
timeout_started=$(/bin/date +%s)
run_case nonresponsive nonresponsive nodes pending
timeout_elapsed=$(( $(/bin/date +%s) - timeout_started ))
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected nonresponsive Controller RPC to fail closed"
[[ "$timeout_elapsed" -le 5 ]] || fail "expected Controller RPC watchdog to bound execution"
assert_file_contains "terminated" "$RPC_PROCESS_EVENTS"
assert_file_contains "controller runtime" "$RUN_STDERR"
assert_no_invocation "standalone:"
if find "$PRIVATE_TMP" -mindepth 1 -print -quit | grep -q .; then
  fail "expected watchdog cleanup to remove private RPC state"
fi

: > "$RPC_PROCESS_EVENTS"
resistant_started=$(/bin/date +%s)
run_case term-resistant term-resistant nodes pending
resistant_elapsed=$(( $(/bin/date +%s) - resistant_started ))
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected TERM-resistant Controller RPC to fail closed"
[[ "$resistant_elapsed" -le 7 ]] || fail "expected TERM-resistant RPC to be killed within the watchdog bound"
resistant_pid=$(sed -n 's/^term-resistant://p' "$RPC_PROCESS_EVENTS" | tail -1)
[[ "$resistant_pid" =~ ^[0-9]+$ ]] || fail "expected TERM-resistant fixture PID evidence"
if kill -0 "$resistant_pid" 2>/dev/null; then
  fail "expected TERM-resistant RPC process to be killed and reaped"
fi
assert_file_contains "controller runtime" "$RUN_STDERR"
assert_no_invocation "standalone:"
if find "$PRIVATE_TMP" -mindepth 1 -print -quit | grep -q .; then
  fail "expected TERM-resistant watchdog cleanup to remove private RPC state"
fi

: > "$RPC_PROCESS_EVENTS"
run_case oversized oversized nodes pending
[[ "$RUN_STATUS" -eq 1 ]] || fail "expected oversized Controller RPC output to fail closed"
assert_file_contains "controller runtime" "$RUN_STDERR"
assert_no_invocation "standalone:"
if grep -F -- "oversized-complete" "$RPC_PROCESS_EVENTS" >/dev/null; then
  fail "expected output limit to terminate the RPC producer"
fi
if find "$PRIVATE_TMP" -mindepth 1 -print -quit | grep -q .; then
  fail "expected oversized-output cleanup to remove private RPC state"
fi

run_case configured success nodes pending
assert_invocation "release_node=orchard_controller@127.0.0.1"
assert_invocation "release_cookie=controller-cookie"
assert_invocation "epmd_port=4369"
assert_invocation "rpc_umask=0077"

caller_umask="$(umask)"
run_case umask-standalone success status
[[ "$RUN_STATUS" -eq 0 ]] || fail "expected standalone invocation to succeed"
assert_invocation "standalone_umask=$caller_umask"

printf 'payload orchardctl Controller-runtime routing tests passed\n'
