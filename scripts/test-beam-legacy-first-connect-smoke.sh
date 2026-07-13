#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-beam-legacy-connect.XXXXXX")"
EPMD_PORT="${ORCHARD_BEAM_LEGACY_EPMD_PORT:-$((45000 + $$ % 1000))}"
NODE_DIST_PORT="${ORCHARD_BEAM_LEGACY_NODE_DIST_PORT:-$((53000 + $$ % 500))}"
CONTROLLER_DIST_PORT="${ORCHARD_BEAM_LEGACY_CONTROLLER_DIST_PORT:-$((54000 + $$ % 500))}"
COOKIE="orchard_legacy_first_connect_$$_${RANDOM}"
COOKIE_FILE="$SMOKE_ROOT/beam.cookie"
NODE_NAME="orchard_node_agent@127.0.0.1"
CONTROLLER_NAME="orchard_controller@127.0.0.1"
NODE_PID=""

stop_process() {
  local pid="$1"
  local attempts=0

  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    if (( attempts >= 50 )); then
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
    sleep 0.1
    attempts=$((attempts + 1))
  done
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  stop_process "$NODE_PID"
  ERL_EPMD_PORT="$EPMD_PORT" mise exec -- epmd -stop >/dev/null 2>&1 || true
  rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

cd "$REPO_ROOT"
chmod 700 "$SMOKE_ROOT"
printf '%s\n' "$COOKIE" > "$COOKIE_FILE"
chmod 600 "$COOKIE_FILE"

ERL_EPMD_ADDRESS=127.0.0.1 ERL_EPMD_PORT="$EPMD_PORT" mise exec -- epmd -daemon

ERL_EPMD_ADDRESS=127.0.0.1 \
ERL_EPMD_PORT="$EPMD_PORT" \
mise exec -- elixir \
  --name "$NODE_NAME" \
  --cookie "$COOKIE" \
  --erl "-kernel inet_dist_listen_min $NODE_DIST_PORT inet_dist_listen_max $NODE_DIST_PORT" \
  --no-halt \
  >"$SMOKE_ROOT/node.log" 2>&1 &
NODE_PID=$!

ready=0
for _attempt in $(seq 1 100); do
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    break
  fi

  if ERL_EPMD_PORT="$EPMD_PORT" mise exec -- epmd -names 2>/dev/null | \
      grep -F 'name orchard_node_agent at port' >/dev/null; then
    ready=1
    break
  fi

  sleep 0.1
done

if (( ready != 1 )); then
  cat "$SMOKE_ROOT/node.log" >&2
  echo "error: legacy compatibility Node did not become ready" >&2
  exit 1
fi

ERL_EPMD_ADDRESS=127.0.0.1 \
ERL_EPMD_PORT="$EPMD_PORT" \
MIX_ENV=dev \
ORCHARD_SOURCE_DEV_ROLE=controller \
ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam \
ORCHARD_RUNTIME_ENDPOINT_TARGETS="$NODE_NAME" \
ORCHARD_BEAM_PEER_GRANTS_ENABLED=false \
ORCHARD_BEAM_NODE_NAME="$CONTROLLER_NAME" \
ORCHARD_BEAM_COOKIE_FILE="$COOKIE_FILE" \
mise exec -- elixir \
  --name "$CONTROLLER_NAME" \
  --cookie "$COOKIE" \
  --erl "-kernel inet_dist_listen_min $CONTROLLER_DIST_PORT inet_dist_listen_max $CONTROLLER_DIST_PORT" \
  -S mix run --no-start \
  "$SCRIPT_DIR/support/beam-legacy-first-connect-smoke.exs"

echo "Legacy BEAM compatibility first-connect smoke passed"
