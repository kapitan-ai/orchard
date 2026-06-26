#!/usr/bin/env bash
# Focused tests for the source-dev BEAM shell bootstrap contract.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/bin/lib/source-dev-beam.sh"
TMP_ROOT="$(mktemp -d)"
DEFAULT_TOOLS="$TMP_ROOT/tools-default"
EPMD_CALL_LOG="$TMP_ROOT/epmd-calls.log"
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

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

assert_succeeds() {
  local out="$1"
  shift
  if ! "$@" >"$out" 2>&1; then
    echo "expected command to succeed" >&2
    cat "$out" >&2
    exit 1
  fi
}

assert_files_equal() {
  local left="$1"
  local right="$2"
  if ! cmp -s "$left" "$right"; then
    echo "expected files to match: $left $right" >&2
    echo "--- $left" >&2
    cat "$left" >&2
    echo "--- $right" >&2
    cat "$right" >&2
    exit 1
  fi
}

assert_mode() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected $path mode $expected, got $actual" >&2
    exit 1
  fi
}

run_helper() {
  local role="$1"
  local repo_root="$2"
  local probe_script
  shift 2

  # shellcheck disable=SC2016 # Expanded by the child bash -c process.
  probe_script='set -euo pipefail; source "$1"; orchard_source_dev_beam_bootstrap "$2" "$3"; printf "transport=%s\n" "${ORCHARD_RUNTIME_ENDPOINT_TRANSPORT:-unset}"; printf "node=%s\n" "${ORCHARD_BEAM_NODE_NAME:-unset}"; printf "cookie=%s\n" "${ORCHARD_BEAM_COOKIE_FILE:-unset}"; printf "epmd=%s\n" "${ORCHARD_BEAM_EPMD_PORT:-unset}"; printf "epmd_address=%s\n" "${ERL_EPMD_ADDRESS:-unset}"; printf "dist=%s..%s\n" "${ORCHARD_BEAM_DIST_PORT_MIN:-unset}" "${ORCHARD_BEAM_DIST_PORT_MAX:-unset}"; printf "home=%s\n" "$HOME"; printf "mix_home=%s\n" "${MIX_HOME:-unset}"; printf "hex_home=%s\n" "${HEX_HOME:-unset}"; printf "args=%s\n" "${ORCHARD_BEAM_IEX_ARGS[*]-}"'

  env -i \
    PATH="$DEFAULT_TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$TMP_ROOT/home" \
    FAKE_EPMD_CALL_LOG="$EPMD_CALL_LOG" \
    "$@" \
    bash -c "$probe_script" \
      bash "$HELPER" "$role" "$repo_root"
}

if [[ ! -f "$HELPER" ]]; then
  echo "helper not found: bin/lib/source-dev-beam.sh" >&2
  exit 1
fi

mkdir -p "$TMP_ROOT/home"
mkdir -p "$DEFAULT_TOOLS"

cat > "$DEFAULT_TOOLS/epmd" <<'SH'
#!/bin/sh
if [ -n "${FAKE_EPMD_CALL_LOG:-}" ]; then
  printf 'epmd %s\n' "$*" >> "$FAKE_EPMD_CALL_LOG"
fi

case " $* " in
  *" -names "*)
    exit "${FAKE_EPMD_NAMES_EXIT:-1}"
    ;;
  *" -daemon "*)
    exit "${FAKE_EPMD_DAEMON_EXIT:-0}"
    ;;
esac

exit 0
SH

cat > "$DEFAULT_TOOLS/lsof" <<'SH'
#!/bin/sh
if [ "${FAKE_LSOF_EXIT:-0}" -ne 0 ]; then
  exit "$FAKE_LSOF_EXIT"
fi

if [ -n "${FAKE_LSOF_OUTPUT:-}" ]; then
  printf '%s\n' "$FAKE_LSOF_OUTPUT"
  exit 0
fi

printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
printf 'epmd 100 user 3u IPv4 0t0 TCP %s:%s (LISTEN)\n' "${ERL_EPMD_ADDRESS:-127.0.0.1}" "${ERL_EPMD_PORT:-4369}"
SH

chmod +x "$DEFAULT_TOOLS/epmd" "$DEFAULT_TOOLS/lsof"

# A: unset or grpc mode is a no-op for IEx distribution args.
assert_succeeds "$TMP_ROOT/a0.out" run_helper controller "$TMP_ROOT/repo-a0"
assert_grep 'transport=grpc' "$TMP_ROOT/a0.out"
assert_grep 'node=unset' "$TMP_ROOT/a0.out"
assert_grep 'args=' "$TMP_ROOT/a0.out"
assert_succeeds "$TMP_ROOT/a.out" run_helper controller "$TMP_ROOT/repo-a" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
assert_grep 'transport=grpc' "$TMP_ROOT/a.out"
assert_grep 'node=unset' "$TMP_ROOT/a.out"
assert_grep 'args=' "$TMP_ROOT/a.out"

# B: controller BEAM mode creates the same-host default cookie with strict permissions.
REPO_B="$TMP_ROOT/repo-b"
assert_succeeds "$TMP_ROOT/b.out" run_helper controller "$REPO_B" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
COOKIE_B="$REPO_B/tmp/dev/beam.cookie"
[[ -s "$COOKIE_B" ]] || { echo "expected non-empty cookie at $COOKIE_B" >&2; exit 1; }
assert_mode 600 "$COOKIE_B"
assert_grep 'node=orchard_controller@127.0.0.1' "$TMP_ROOT/b.out"
assert_grep "cookie=$COOKIE_B" "$TMP_ROOT/b.out"
assert_files_equal "$COOKIE_B" "$REPO_B/tmp/dev/beam-home/controller/.erlang.cookie"
assert_grep 'epmd=4369' "$TMP_ROOT/b.out"
assert_grep 'epmd_address=127.0.0.1' "$TMP_ROOT/b.out"
assert_grep 'dist=52171..52171' "$TMP_ROOT/b.out"
assert_grep '--name orchard_controller@127.0.0.1' "$TMP_ROOT/b.out"
assert_grep 'inet_dist_use_interface {127,0,0,1}' "$TMP_ROOT/b.out"
assert_grep 'epmd -daemon -address 127.0.0.1 -port 4369' "$EPMD_CALL_LOG"
assert_no_grep "$(cat "$COOKIE_B")" "$TMP_ROOT/b.out"

# C: node-agent BEAM mode gets its own role default node and distribution port.
REPO_C="$TMP_ROOT/repo-c"
assert_succeeds "$TMP_ROOT/c.out" run_helper node_agent "$REPO_C" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
assert_grep 'node=orchard_node_agent@127.0.0.1' "$TMP_ROOT/c.out"
assert_grep 'dist=52172..52172' "$TMP_ROOT/c.out"
assert_grep '--name orchard_node_agent@127.0.0.1' "$TMP_ROOT/c.out"
assert_grep 'inet_dist_use_interface {127,0,0,1}' "$TMP_ROOT/c.out"

# C2: concurrent split-role bootstrap from a clean checkout stages the final default cookie for both roles.
REPO_C2="$TMP_ROOT/repo-c2"
run_helper controller "$REPO_C2" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam >"$TMP_ROOT/c2-controller.out" 2>&1 &
pid_controller=$!
run_helper node_agent "$REPO_C2" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam >"$TMP_ROOT/c2-node.out" 2>&1 &
pid_node=$!
wait "$pid_controller"
wait "$pid_node"
COOKIE_C2="$REPO_C2/tmp/dev/beam.cookie"
assert_mode 600 "$COOKIE_C2"
assert_files_equal "$COOKIE_C2" "$REPO_C2/tmp/dev/beam-home/controller/.erlang.cookie"
assert_files_equal "$COOKIE_C2" "$REPO_C2/tmp/dev/beam-home/node_agent/.erlang.cookie"

# D: explicit cookie files must exist, be non-empty, and owner-only.
MISSING_COOKIE="$TMP_ROOT/missing.cookie"
assert_fails_with 'ORCHARD_BEAM_COOKIE_FILE must point to an existing regular file' "$TMP_ROOT/d1.out" \
  run_helper controller "$TMP_ROOT/repo-d1" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_COOKIE_FILE="$MISSING_COOKIE"
EMPTY_COOKIE="$TMP_ROOT/empty.cookie"
: > "$EMPTY_COOKIE"
chmod 600 "$EMPTY_COOKIE"
assert_fails_with 'ORCHARD_BEAM_COOKIE_FILE must not be empty' "$TMP_ROOT/d2.out" \
  run_helper controller "$TMP_ROOT/repo-d2" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_COOKIE_FILE="$EMPTY_COOKIE"
WEAK_COOKIE="$TMP_ROOT/weak.cookie"
printf 'fixture-cookie\n' > "$WEAK_COOKIE"
chmod 644 "$WEAK_COOKIE"
assert_fails_with 'ORCHARD_BEAM_COOKIE_FILE must be owner-only' "$TMP_ROOT/d3.out" \
  run_helper controller "$TMP_ROOT/repo-d3" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_COOKIE_FILE="$WEAK_COOKIE"
FAKE_GNU_STAT_DIR="$TMP_ROOT/fake-gnu-stat-bin"
mkdir -p "$FAKE_GNU_STAT_DIR"
cat > "$FAKE_GNU_STAT_DIR/stat" <<'STAT'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-c" ]]; then
  printf '644\n'
  exit 0
fi
if [[ "${1:-}" == "-f" ]]; then
  printf '100\n'
  exit 0
fi
exec /usr/bin/stat "$@"
STAT
chmod +x "$FAKE_GNU_STAT_DIR/stat"
assert_fails_with 'ORCHARD_BEAM_COOKIE_FILE must be owner-only' "$TMP_ROOT/d3-fake-gnu-stat.out" \
  run_helper controller "$TMP_ROOT/repo-d3-fake-gnu-stat" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam PATH="$FAKE_GNU_STAT_DIR:/usr/bin:/bin:/usr/sbin:/sbin" ORCHARD_BEAM_COOKIE_FILE="$WEAK_COOKIE"
STRICT_COOKIE="$TMP_ROOT/strict.cookie"
printf 'fixture-cookie\n' > "$STRICT_COOKIE"
chmod 600 "$STRICT_COOKIE"
FAKE_NON_OCTAL_STAT_DIR="$TMP_ROOT/fake-non-octal-stat-bin"
mkdir -p "$FAKE_NON_OCTAL_STAT_DIR"
cat > "$FAKE_NON_OCTAL_STAT_DIR/stat" <<'STAT'
#!/usr/bin/env bash
set -euo pipefail
printf 'not-octal\n'
STAT
chmod +x "$FAKE_NON_OCTAL_STAT_DIR/stat"
assert_fails_with 'ORCHARD_BEAM_COOKIE_FILE must be owner-only' "$TMP_ROOT/d3-non-octal-stat.out" \
  run_helper controller "$TMP_ROOT/repo-d3-non-octal-stat" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam PATH="$FAKE_NON_OCTAL_STAT_DIR:/usr/bin:/bin:/usr/sbin:/sbin" ORCHARD_BEAM_COOKIE_FILE="$STRICT_COOKIE"
assert_succeeds "$TMP_ROOT/d4.out" run_helper controller "$TMP_ROOT/repo-d4" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_COOKIE_FILE="$STRICT_COOKIE"
assert_grep "cookie=$STRICT_COOKIE" "$TMP_ROOT/d4.out"
assert_no_grep 'fixture-cookie' "$TMP_ROOT/d4.out"

# E: BEAM node names must be role-appropriate long names with IPv4-literal hosts.
assert_fails_with 'ORCHARD_BEAM_NODE_NAME must be a long BEAM node name' "$TMP_ROOT/e1.out" \
  run_helper controller "$TMP_ROOT/repo-e1" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_controller
assert_fails_with 'ORCHARD_BEAM_NODE_NAME host must be an IPv4 literal' "$TMP_ROOT/e2.out" \
  run_helper controller "$TMP_ROOT/repo-e2" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_controller@localhost
assert_fails_with 'ORCHARD_BEAM_NODE_NAME host must be an IPv4 literal' "$TMP_ROOT/e2-invalid-ipv6.out" \
  run_helper controller "$TMP_ROOT/repo-e2-invalid-ipv6" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_controller@::::
assert_fails_with 'ORCHARD_BEAM_NODE_NAME host must be an IPv4 literal' "$TMP_ROOT/e2-ipv6.out" \
  run_helper node_agent "$TMP_ROOT/repo-e2-ipv6" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_node_agent@::1
assert_fails_with 'ORCHARD_BEAM_NODE_NAME host must not be an unspecified or wildcard address' "$TMP_ROOT/e2-wildcard-v4.out" \
  run_helper controller "$TMP_ROOT/repo-e2-wildcard-v4" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_controller@0.0.0.0
assert_fails_with 'ORCHARD_BEAM_NODE_NAME host must be an IPv4 literal' "$TMP_ROOT/e2-wildcard-v6.out" \
  run_helper controller "$TMP_ROOT/repo-e2-wildcard-v6" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_controller@::
assert_fails_with 'controller BEAM node service must start with orchard_controller' "$TMP_ROOT/e3.out" \
  run_helper controller "$TMP_ROOT/repo-e3" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_node_agent@127.0.0.1
assert_fails_with 'node-agent BEAM node service must be exactly orchard_node_agent' "$TMP_ROOT/e4.out" \
  run_helper node_agent "$TMP_ROOT/repo-e4" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_controller@127.0.0.1
assert_succeeds "$TMP_ROOT/e4-exact.out" \
  run_helper node_agent "$TMP_ROOT/repo-e4-exact" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_node_agent@127.0.0.1
assert_grep 'node=orchard_node_agent@127.0.0.1' "$TMP_ROOT/e4-exact.out"
assert_fails_with 'node-agent BEAM node service must be exactly orchard_node_agent' "$TMP_ROOT/e4-suffix.out" \
  run_helper node_agent "$TMP_ROOT/repo-e4-suffix" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_node_agent_dev@127.0.0.1
assert_fails_with 'ORCHARD_BEAM_NODE_NAME service contains invalid characters' "$TMP_ROOT/e5-space.out" \
  run_helper controller "$TMP_ROOT/repo-e5-space" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME='orchard_controller bad@127.0.0.1'
assert_fails_with 'ORCHARD_BEAM_NODE_NAME service contains invalid characters' "$TMP_ROOT/e5-slash.out" \
  run_helper node_agent "$TMP_ROOT/repo-e5-slash" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME='orchard_node_agent/@127.0.0.1'
assert_fails_with 'ORCHARD_BEAM_NODE_NAME service contains invalid characters' "$TMP_ROOT/e5-colon.out" \
  run_helper controller "$TMP_ROOT/repo-e5-colon" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME='orchard_controller:dev@127.0.0.1'
assert_succeeds "$TMP_ROOT/e5.out" run_helper controller "$TMP_ROOT/repo-e5" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_controller_dev@127.0.0.1
assert_grep 'node=orchard_controller_dev@127.0.0.1' "$TMP_ROOT/e5.out"
assert_succeeds "$TMP_ROOT/e6.out" run_helper controller "$TMP_ROOT/repo-e6" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_NODE_NAME=orchard_controller@192.0.2.10
assert_grep 'epmd_address=192.0.2.10' "$TMP_ROOT/e6.out"
assert_grep 'inet_dist_use_interface {192,0,2,10}' "$TMP_ROOT/e6.out"

# F: EPMD and distribution ports are validated before Mix starts.
assert_fails_with 'ORCHARD_BEAM_EPMD_PORT must be an integer from 1 to 65535' "$TMP_ROOT/f1.out" \
  run_helper controller "$TMP_ROOT/repo-f1" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_EPMD_PORT=70000
assert_fails_with 'ORCHARD_BEAM_DIST_PORT_MIN and ORCHARD_BEAM_DIST_PORT_MAX must be set together' "$TMP_ROOT/f2.out" \
  run_helper controller "$TMP_ROOT/repo-f2" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_DIST_PORT_MIN=52180
assert_fails_with 'ORCHARD_BEAM_DIST_PORT_MIN must be less than or equal to ORCHARD_BEAM_DIST_PORT_MAX' "$TMP_ROOT/f3.out" \
  run_helper controller "$TMP_ROOT/repo-f3" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_DIST_PORT_MIN=52182 ORCHARD_BEAM_DIST_PORT_MAX=52181
assert_succeeds "$TMP_ROOT/f4.out" run_helper controller "$TMP_ROOT/repo-f4" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_BEAM_EPMD_PORT=4370 ORCHARD_BEAM_DIST_PORT_MIN=52180 ORCHARD_BEAM_DIST_PORT_MAX=52181
assert_grep 'epmd=4370' "$TMP_ROOT/f4.out"
assert_grep 'dist=52180..52181' "$TMP_ROOT/f4.out"
assert_fails_with 'EPMD listener on port 4369 is wildcard-bound' "$TMP_ROOT/f5.out" \
  run_helper controller "$TMP_ROOT/repo-f5" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam FAKE_EPMD_NAMES_EXIT=0 FAKE_LSOF_OUTPUT='epmd 100 user 3u IPv4 0t0 TCP *:4369 (LISTEN)'
assert_fails_with 'EPMD listener on port 4369 is not constrained to 127.0.0.1' "$TMP_ROOT/f6.out" \
  run_helper controller "$TMP_ROOT/repo-f6" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam FAKE_EPMD_NAMES_EXIT=0 FAKE_LSOF_OUTPUT='epmd 100 user 3u IPv4 0t0 TCP 10.0.0.2:4369 (LISTEN)'
assert_succeeds "$TMP_ROOT/f7.out" \
  run_helper controller "$TMP_ROOT/repo-f7" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam FAKE_EPMD_NAMES_EXIT=0 FAKE_LSOF_OUTPUT='epmd 100 user 3u IPv4 0t0 TCP 127.0.0.1:4369 (LISTEN)'
assert_fails_with 'EPMD listener on port 4369 is not constrained to 127.0.0.1' "$TMP_ROOT/f8.out" \
  run_helper controller "$TMP_ROOT/repo-f8" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam FAKE_EPMD_NAMES_EXIT=0 FAKE_LSOF_OUTPUT='COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
epmd 100 user 3u IPv4 0t0 TCP 127.0.0.1:4369 (LISTEN)
epmd 100 user 4u IPv4 0t0 TCP 10.0.0.2:4369 (LISTEN)'

# G: the helper rejects unknown transport values early.
assert_fails_with 'ORCHARD_RUNTIME_ENDPOINT_TRANSPORT must be grpc|beam' "$TMP_ROOT/g.out" \
  run_helper controller "$TMP_ROOT/repo-g" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=http

ENTRYPOINT_REPO="$TMP_ROOT/entrypoint-repo"
mkdir -p "$ENTRYPOINT_REPO/bin/lib" "$ENTRYPOINT_REPO/apps/orchard_controller" "$ENTRYPOINT_REPO/apps/orchard_node_agent"
cp "$REPO_ROOT/bin/dev" "$ENTRYPOINT_REPO/bin/dev"
cp "$REPO_ROOT/bin/dev-controller" "$ENTRYPOINT_REPO/bin/dev-controller"
cp "$REPO_ROOT/bin/dev-node-agent" "$ENTRYPOINT_REPO/bin/dev-node-agent"
cp "$HELPER" "$ENTRYPOINT_REPO/bin/lib/source-dev-beam.sh"
chmod +x "$ENTRYPOINT_REPO/bin/dev" "$ENTRYPOINT_REPO/bin/dev-controller" "$ENTRYPOINT_REPO/bin/dev-node-agent"
: > "$ENTRYPOINT_REPO/mix.exs"

# H: all-in-one bin/dev rejects explicit BEAM mode before running Mix.
TOOLS_H="$TMP_ROOT/tools-h"
mkdir -p "$TOOLS_H"
cat > "$TOOLS_H/mix" <<'SH'
#!/bin/sh
printf 'mix called: %s\n' "$*" >> "$MIX_CALL_LOG"
exit 0
SH
chmod +x "$TOOLS_H/mix"
: > "$TMP_ROOT/h-mix.log"
assert_fails_with 'all-in-one bin/dev does not support BEAM source-dev mode yet' "$TMP_ROOT/h.out" \
  env -i PATH="$TOOLS_H:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP_ROOT/home" MIX_CALL_LOG="$TMP_ROOT/h-mix.log" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=' beam ' "$ENTRYPOINT_REPO/bin/dev"
if [[ -s "$TMP_ROOT/h-mix.log" ]]; then
  echo "bin/dev should reject BEAM mode before running mix" >&2
  cat "$TMP_ROOT/h-mix.log" >&2
  exit 1
fi

# I: split-role entrypoints pass named-node BEAM launch flags to IEx.
TOOLS_I="$TMP_ROOT/tools-i"
mkdir -p "$TOOLS_I"
cat > "$TOOLS_I/mix" <<'SH'
#!/bin/sh
printf 'mix called: %s\n' "$*" >> "$MIX_CALL_LOG"
exit 0
SH
cat > "$TOOLS_I/iex" <<'SH'
#!/bin/sh
printf 'ERL_EPMD_ADDRESS=%s\n' "${ERL_EPMD_ADDRESS:-unset}" > "$IEX_ARG_LOG"
printf '%s\n' "$*" >> "$IEX_ARG_LOG"
exit 0
SH
cat > "$TOOLS_I/pgrep" <<'SH'
#!/bin/sh
exit 1
SH
cp "$DEFAULT_TOOLS/epmd" "$TOOLS_I/epmd"
cp "$DEFAULT_TOOLS/lsof" "$TOOLS_I/lsof"
chmod +x "$TOOLS_I/mix" "$TOOLS_I/iex" "$TOOLS_I/pgrep" "$TOOLS_I/epmd" "$TOOLS_I/lsof"

CONTROLLER_REPO="$TMP_ROOT/controller-entrypoint"
mkdir -p "$CONTROLLER_REPO"
: > "$TMP_ROOT/i-controller-mix.log"
assert_succeeds "$TMP_ROOT/i-controller.out" \
  env -i PATH="$TOOLS_I:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP_ROOT/home" MIX_CALL_LOG="$TMP_ROOT/i-controller-mix.log" IEX_ARG_LOG="$TMP_ROOT/i-controller-iex.log" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam ORCHARD_RUNTIME_ENDPOINT_TARGETS=orchard_node_agent@127.0.0.1 "$ENTRYPOINT_REPO/bin/dev-controller"
assert_grep 'mix called: ecto.create --quiet' "$TMP_ROOT/i-controller-mix.log"
assert_grep 'mix called: ecto.migrate --quiet' "$TMP_ROOT/i-controller-mix.log"
assert_grep 'ERL_EPMD_ADDRESS=127.0.0.1' "$TMP_ROOT/i-controller-iex.log"
assert_grep '--name orchard_controller@127.0.0.1 --erl -kernel inet_dist_use_interface {127,0,0,1} inet_dist_listen_min 52171 inet_dist_listen_max 52171 -S mix phx.server' "$TMP_ROOT/i-controller-iex.log"
assert_grep 'BEAM cookie file:' "$TMP_ROOT/i-controller.out"

: > "$TMP_ROOT/i-node-mix.log"
assert_succeeds "$TMP_ROOT/i-node.out" \
  env -i PATH="$TOOLS_I:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP_ROOT/home" MIX_CALL_LOG="$TMP_ROOT/i-node-mix.log" IEX_ARG_LOG="$TMP_ROOT/i-node-iex.log" ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam "$ENTRYPOINT_REPO/bin/dev-node-agent"
assert_grep 'ERL_EPMD_ADDRESS=127.0.0.1' "$TMP_ROOT/i-node-iex.log"
assert_grep '--name orchard_node_agent@127.0.0.1 --erl -kernel inet_dist_use_interface {127,0,0,1} inet_dist_listen_min 52172 inet_dist_listen_max 52172 -S mix run --no-halt' "$TMP_ROOT/i-node-iex.log"

printf 'source-dev BEAM bootstrap tests passed\n'
