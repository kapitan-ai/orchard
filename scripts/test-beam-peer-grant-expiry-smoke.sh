#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ELIXIR_BIN="$(mise which elixir)"
EPMD_BIN="$(mise which epmd)"

discover_private_ipv4() {
  local interface address

  for interface in en0 en1 en2; do
    address="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
    if [[ "$address" == 10.* || "$address" == 192.168.* ]]; then
      printf '%s\n' "$address"
      return 0
    fi

    if [[ "$address" =~ ^172\.([0-9]+)\. ]]; then
      local second="${BASH_REMATCH[1]}"
      if (( second >= 16 && second <= 31 )); then
        printf '%s\n' "$address"
        return 0
      fi
    fi
  done

  return 1
}

wait_for_file() {
  local path="$1"
  local pid="$2"

  for _attempt in $(seq 1 100); do
    if [[ -f "$path" ]]; then
      return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi

    sleep 0.1
  done

  return 1
}

IPV4="${ORCHARD_BEAM_TRACER_IPV4:-}"
if [[ -z "$IPV4" ]]; then
  IPV4="$(discover_private_ipv4 || true)"
fi

if [[ -z "$IPV4" ]]; then
  echo "error: set ORCHARD_BEAM_TRACER_IPV4 to a private IPv4 address" >&2
  exit 64
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-beam-peer-grant-expiry.XXXXXX")"
chmod 700 "$SMOKE_ROOT"

NODE_PID=""
CONTROLLER_PID=""
EPMD_PORT="${ORCHARD_BEAM_TRACER_EXPIRY_EPMD_PORT:-$((45000 + $$ % 1000))}"
CONTROLLER_DIST_PORT="${ORCHARD_BEAM_TRACER_EXPIRY_CONTROLLER_DIST_PORT:-$((58000 + $$ % 500))}"
NODE_DIST_PORT="${ORCHARD_BEAM_TRACER_EXPIRY_NODE_DIST_PORT:-$((59000 + $$ % 500))}"

cleanup() {
  if [[ -n "$CONTROLLER_PID" ]]; then
    kill "$CONTROLLER_PID" 2>/dev/null || true
    wait "$CONTROLLER_PID" 2>/dev/null || true
  fi

  if [[ -n "$NODE_PID" ]]; then
    kill "$NODE_PID" 2>/dev/null || true
    wait "$NODE_PID" 2>/dev/null || true
  fi

  ERL_EPMD_PORT="$EPMD_PORT" "$EPMD_BIN" -stop >/dev/null 2>&1 || true
  if [[ "${ORCHARD_BEAM_SMOKE_KEEP:-0}" == "1" ]]; then
    echo "kept expiry smoke root: $SMOKE_ROOT" >&2
  else
    rm -rf "$SMOKE_ROOT"
  fi
}
trap cleanup EXIT

export MIX_ENV=test
export ORCHARD_BEAM_TRACER_VALIDITY_SECONDS=12
SHARED_EBIN="$REPO_ROOT/_build/test/lib/orchard_shared/ebin"
JASON_EBIN="$REPO_ROOT/_build/test/lib/jason/ebin"

MANIFEST_PATH="$(
  mise exec -- mix run \
    --no-start \
    --no-compile \
    "$REPO_ROOT/scripts/support/beam-peer-grant-tracer-setup.exs" \
    -- \
    "$SMOKE_ROOT" \
    "$IPV4"
)"

source "$MANIFEST_PATH"

ERL_EPMD_ADDRESS="$IPV4" ERL_EPMD_PORT="$EPMD_PORT" "$EPMD_BIN" -daemon

NODE_READY="$SMOKE_ROOT/node.ready"
CONTROLLER_READY="$SMOKE_ROOT/controller.ready"
NODE_LOG="$SMOKE_ROOT/node.log"
CONTROLLER_LOG="$SMOKE_ROOT/controller.log"

NODE_ERL_ARGS="-proto_dist inet_tls -ssl_dist_optfile $NODE_TLS_OPTIONS -kernel inet_dist_use_interface $IP_TUPLE inet_dist_listen_min $NODE_DIST_PORT inet_dist_listen_max $NODE_DIST_PORT"
CONTROLLER_ERL_ARGS="-proto_dist inet_tls -ssl_dist_optfile $CONTROLLER_TLS_OPTIONS -kernel inet_dist_use_interface $IP_TUPLE inet_dist_listen_min $CONTROLLER_DIST_PORT inet_dist_listen_max $CONTROLLER_DIST_PORT"

HOME="$NODE_HOME" \
ERL_EPMD_ADDRESS="$IPV4" \
ERL_EPMD_PORT="$EPMD_PORT" \
ORCHARD_EXPIRY_LAUNCH_MANIFEST="$NODE_LAUNCH_MANIFEST" \
ORCHARD_LOCAL_NODE_NAME="$NODE_NAME" \
ORCHARD_PEER_COOKIE_FILE="$GRANT_FILE" \
ORCHARD_PEER_NAME="$CONTROLLER_NAME" \
ORCHARD_READY_FILE="$NODE_READY" \
  "$ELIXIR_BIN" \
    --erl "$NODE_ERL_ARGS" \
    -pa "$SHARED_EBIN" \
    -pa "$JASON_EBIN" \
    -e '
      {:ok, _apps} = Application.ensure_all_started(:crypto)
      {:ok, _net_kernel} = Node.start(System.fetch_env!("ORCHARD_LOCAL_NODE_NAME") |> String.to_atom(), :longnames)
      peer = System.fetch_env!("ORCHARD_PEER_NAME") |> String.to_atom()
      cookie = System.fetch_env!("ORCHARD_PEER_COOKIE_FILE") |> File.read!() |> String.trim() |> String.to_atom()
      true = Node.set_cookie(peer, cookie)
      {:ok, _guard} = Orchard.RuntimeEndpoint.DistributionExpiryGuard.start_link(
        manifest_path: System.fetch_env!("ORCHARD_EXPIRY_LAUNCH_MANIFEST")
      )
      File.write!(System.fetch_env!("ORCHARD_READY_FILE"), "ready")
      Process.sleep(:infinity)
    ' >"$NODE_LOG" 2>&1 &
NODE_PID=$!

if ! wait_for_file "$NODE_READY" "$NODE_PID"; then
  sed -n '1,160p' "$NODE_LOG" >&2
  echo "error: expiry Node did not become ready" >&2
  exit 1
fi

HOME="$CONTROLLER_HOME" \
ERL_EPMD_ADDRESS="$IPV4" \
ERL_EPMD_PORT="$EPMD_PORT" \
ORCHARD_EXPIRY_LAUNCH_MANIFEST="$CONTROLLER_LAUNCH_MANIFEST" \
ORCHARD_LOCAL_NODE_NAME="$CONTROLLER_NAME" \
ORCHARD_PEER_COOKIE_FILE="$GRANT_FILE" \
ORCHARD_PEER_NAME="$NODE_NAME" \
ORCHARD_READY_FILE="$CONTROLLER_READY" \
  "$ELIXIR_BIN" \
    --erl "$CONTROLLER_ERL_ARGS" \
    -pa "$SHARED_EBIN" \
    -pa "$JASON_EBIN" \
    -e '
      {:ok, _apps} = Application.ensure_all_started(:crypto)
      {:ok, _net_kernel} = Node.start(System.fetch_env!("ORCHARD_LOCAL_NODE_NAME") |> String.to_atom(), :longnames)
      peer = System.fetch_env!("ORCHARD_PEER_NAME") |> String.to_atom()
      cookie = System.fetch_env!("ORCHARD_PEER_COOKIE_FILE") |> File.read!() |> String.trim() |> String.to_atom()
      true = Node.set_cookie(peer, cookie)
      :pong = Node.ping(peer)
      {:ok, _guard} = Orchard.RuntimeEndpoint.DistributionExpiryGuard.start_link(
        manifest_path: System.fetch_env!("ORCHARD_EXPIRY_LAUNCH_MANIFEST")
      )
      File.write!(System.fetch_env!("ORCHARD_READY_FILE"), "ready")
      Process.sleep(:infinity)
    ' >"$CONTROLLER_LOG" 2>&1 &
CONTROLLER_PID=$!

if ! wait_for_file "$CONTROLLER_READY" "$CONTROLLER_PID"; then
  sed -n '1,160p' "$CONTROLLER_LOG" >&2
  echo "error: expiry Controller did not become ready" >&2
  exit 1
fi

controller_service="${CONTROLLER_NAME%%@*}"
node_service="${NODE_NAME%%@*}"
expired=0

for _attempt in $(seq 1 200); do
  names="$(ERL_EPMD_PORT="$EPMD_PORT" "$EPMD_BIN" -names 2>/dev/null || true)"
  if [[ "$names" != *"name $controller_service "* && "$names" != *"name $node_service "* ]]; then
    expired=1
    break
  fi
  sleep 0.1
done

if (( expired != 1 )); then
  sed -n '1,160p' "$NODE_LOG" >&2
  sed -n '1,160p' "$CONTROLLER_LOG" >&2
  echo "error: peer-grant expiry did not stop both Distribution identities" >&2
  exit 1
fi

if ! kill -0 "$NODE_PID" 2>/dev/null || ! kill -0 "$CONTROLLER_PID" 2>/dev/null; then
  sed -n '1,160p' "$NODE_LOG" >&2
  sed -n '1,160p' "$CONTROLLER_LOG" >&2
  echo "error: an expiry VM exited instead of remaining alive after Distribution shutdown" >&2
  exit 1
fi

HOME="$CONTROLLER_HOME" \
ERL_EPMD_ADDRESS="$IPV4" \
ERL_EPMD_PORT="$EPMD_PORT" \
ORCHARD_PEER_COOKIE_FILE="$GRANT_FILE" \
ORCHARD_PEER_NAME="$NODE_NAME" \
  "$ELIXIR_BIN" \
    --name "$CONTROLLER_NAME" \
    --erl "$CONTROLLER_ERL_ARGS" \
    -e '
      peer = System.fetch_env!("ORCHARD_PEER_NAME") |> String.to_atom()
      cookie = System.fetch_env!("ORCHARD_PEER_COOKIE_FILE") |> File.read!() |> String.trim() |> String.to_atom()
      true = Node.set_cookie(peer, cookie)
      :pang = Node.ping(peer)
    '

echo "BEAM Peer Grant expiry smoke passed"
echo "Validated: both VMs stayed alive, both TLS Distribution identities stopped at expiry, and the formerly valid secret could not reconnect"
