#!/usr/bin/env bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_ROOT=""
BEAM_PID=""
WORKER_PID=""
CONTROL_PID=""
SOCKET_PATH=""
BUNDLE_ROOT="$REPO_ROOT/tmp/dev/models/issue-286-shutdown-custody"
BUNDLE_OWNED=false
PORT="${ORCHARD_SHUTDOWN_CUSTODY_PORT:-50091}"

cleanup() {
  trap - EXIT INT TERM

  for pid in "$WORKER_PID" "$BEAM_PID" "$CONTROL_PID"; do
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done

  exec 9>&- 2>/dev/null || true
  [[ -n "$STATE_ROOT" ]] && rm -rf -- "$STATE_ROOT" >/dev/null 2>&1
  [[ "$BUNDLE_OWNED" == "true" ]] && rm -rf -- "$BUNDLE_ROOT" >/dev/null 2>&1
}

fail() {
  printf '%s\n' \
    "shutdown-custody smoke: FAIL" \
    "  reason: $1"
  exit 1
}

wait_for_port() {
  local deadline=$((SECONDS + 120))

  while ((SECONDS < deadline)); do
    kill -0 "$BEAM_PID" 2>/dev/null || return 1
    nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 && return 0
    sleep 1
  done

  return 1
}

wait_for_file() {
  local path="$1"
  local deadline=$((SECONDS + 30))

  while ((SECONDS < deadline)); do
    [[ -s "$path" ]] && return 0
    kill -0 "$BEAM_PID" 2>/dev/null || return 1
    sleep 1
  done

  return 1
}

wait_for_death() {
  local pid="$1"
  local timeout="$2"
  local deadline=$((SECONDS + timeout))

  while ((SECONDS < deadline)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done

  ! kill -0 "$pid" 2>/dev/null
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

command -v mise >/dev/null 2>&1 || fail "mise unavailable"
command -v nc >/dev/null 2>&1 || fail "nc unavailable"
[[ "$PORT" =~ ^[1-9][0-9]*$ ]] || fail "invalid listen port"
((PORT <= 65535)) || fail "invalid listen port"
nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1 && fail "listen port unavailable"
[[ ! -e "$BUNDLE_ROOT" ]] || fail "issue bundle path already exists"

REAL_WORKER="$REPO_ROOT/native/orchard_worker_mlx/bin/orchard-worker-mlx"
EFFECTIVE_WORKER="$REPO_ROOT/native/orchard_worker_mlx/.venv/bin/orchard-worker-mlx"
SMOKE_WORKER="$REPO_ROOT/scripts/support/shutdown-custody-worker"
LOADER="$REPO_ROOT/scripts/support/shutdown_custody_load.exs"

[[ -x "$REAL_WORKER" && -x "$EFFECTIVE_WORKER" && -x "$SMOKE_WORKER" ]] ||
  fail "worker fixture unavailable"
[[ -f "$LOADER" ]] || fail "loader unavailable"

STATE_ROOT="$(mktemp -d "/tmp/orchard-286.XXXXXX" 2>/dev/null)" ||
  fail "temporary directory unavailable"
mkdir -p -- "$STATE_ROOT/socket" >/dev/null 2>&1 || fail "temporary directory unavailable"
mkfifo "$STATE_ROOT/stdin" >/dev/null 2>&1 || fail "stdin fixture unavailable"
exec 9<>"$STATE_ROOT/stdin" 2>/dev/null || fail "stdin fixture unavailable"

export ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
export ORCHARD_NODE_AGENT_LISTEN_HOST=127.0.0.1
export ORCHARD_NODE_AGENT_LISTEN_PORT="$PORT"
export ORCHARD_RUNTIME_CLIENT_PORT="$PORT"
export ORCHARD_WORKER_BACKEND=stub
export ORCHARD_WORKER_SOCKET_DIR="$STATE_ROOT/socket"
export ORCHARD_WORKER_EXECUTABLE="$SMOKE_WORKER"
export ORCHARD_WORKER_EFFECTIVE_EXECUTABLE="$EFFECTIVE_WORKER"
export ORCHARD_SHUTDOWN_CUSTODY_STATE_DIR="$STATE_ROOT"
export ORCHARD_SHUTDOWN_CUSTODY_REAL_WORKER="$REAL_WORKER"

cd "$REPO_ROOT"
mise exec -- bin/dev-node-agent <&9 >"$STATE_ROOT/node-agent.log" 2>&1 &
BEAM_PID=$!

wait_for_port || fail "launcher readiness timeout"

BUNDLE_OWNED=true
(
  cd "$REPO_ROOT/apps/orchard_node_agent" &&
    mise exec -- mix run --no-start "$LOADER"
) >"$STATE_ROOT/loader.log" 2>&1 || fail "fixture load failed"

wait_for_file "$STATE_ROOT/worker.pid" || fail "worker identity unavailable"
wait_for_file "$STATE_ROOT/worker.socket" || fail "worker socket identity unavailable"
WORKER_PID="$(cat "$STATE_ROOT/worker.pid")"
SOCKET_PATH="$(cat "$STATE_ROOT/worker.socket")"

[[ "$WORKER_PID" =~ ^[1-9][0-9]*$ ]] || fail "invalid worker identity"
kill -0 "$WORKER_PID" 2>/dev/null || fail "exact worker not running"
[[ -S "$SOCKET_PATH" ]] || fail "exact worker socket unavailable"

sleep 3600 &
CONTROL_PID=$!
kill -0 "$CONTROL_PID" 2>/dev/null || fail "control child unavailable"

kill -TERM "$BEAM_PID" 2>/dev/null || fail "foreground termination failed"
wait_for_death "$BEAM_PID" 30 || fail "foreground shutdown timeout"
wait "$BEAM_PID" 2>/dev/null || true

wait_for_death "$WORKER_PID" 10 || fail "exact worker survived"
[[ ! -e "$SOCKET_PATH" ]] || fail "exact worker socket survived"
kill -0 "$CONTROL_PID" 2>/dev/null || fail "control child did not survive"

printf '%s\n' \
  "shutdown-custody smoke: PASS" \
  "  beam: exited on SIGTERM (bounded)" \
  "  worker child: exact pid dead" \
  "  worker socket: removed" \
  "  control child: survived"
