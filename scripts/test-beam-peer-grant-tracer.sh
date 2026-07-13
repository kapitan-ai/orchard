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

IPV4="${ORCHARD_BEAM_TRACER_IPV4:-}"
if [[ -z "$IPV4" ]]; then
  IPV4="$(discover_private_ipv4 || true)"
fi

if [[ -z "$IPV4" ]]; then
  echo "error: set ORCHARD_BEAM_TRACER_IPV4 to a private IPv4 address" >&2
  exit 64
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-beam-peer-grant-smoke.XXXXXX")"
chmod 700 "$SMOKE_ROOT"

NODE_PID=""
EPMD_PORT="${ORCHARD_BEAM_TRACER_EPMD_PORT:-$((43000 + $$ % 1000))}"
CONTROLLER_DIST_PORT="${ORCHARD_BEAM_TRACER_CONTROLLER_DIST_PORT:-$((52000 + $$ % 1000))}"
NODE_DIST_PORT="${ORCHARD_BEAM_TRACER_NODE_DIST_PORT:-$((54000 + $$ % 1000))}"

cleanup() {
  if [[ -n "$NODE_PID" ]]; then
    kill "$NODE_PID" 2>/dev/null || true
    wait "$NODE_PID" 2>/dev/null || true
  fi

  ERL_EPMD_PORT="$EPMD_PORT" "$EPMD_BIN" -stop >/dev/null 2>&1 || true
  rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

export MIX_ENV=test
SHARED_EBIN="$REPO_ROOT/_build/test/lib/orchard_shared/ebin"

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

NODE_READY="$SMOKE_ROOT/node.ready"
NODE_LOG="$SMOKE_ROOT/node.log"

NODE_ERL_ARGS="-proto_dist inet_tls -ssl_dist_optfile $NODE_TLS_OPTIONS -kernel inet_dist_use_interface $IP_TUPLE inet_dist_listen_min $NODE_DIST_PORT inet_dist_listen_max $NODE_DIST_PORT"
CONTROLLER_ERL_ARGS="-proto_dist inet_tls -ssl_dist_optfile $CONTROLLER_TLS_OPTIONS -kernel inet_dist_use_interface $IP_TUPLE inet_dist_listen_min $CONTROLLER_DIST_PORT inet_dist_listen_max $CONTROLLER_DIST_PORT"
FORGED_ERL_ARGS="-proto_dist inet_tls -ssl_dist_optfile $FORGED_TLS_OPTIONS -kernel inet_dist_use_interface $IP_TUPLE inet_dist_listen_min $CONTROLLER_DIST_PORT inet_dist_listen_max $CONTROLLER_DIST_PORT"

HOME="$NODE_HOME" \
ERL_EPMD_ADDRESS="$IPV4" \
ERL_EPMD_PORT="$EPMD_PORT" \
ORCHARD_PEER_COOKIE_FILE="$GRANT_FILE" \
ORCHARD_PEER_NAME="$CONTROLLER_NAME" \
ORCHARD_READY_FILE="$NODE_READY" \
  "$ELIXIR_BIN" \
    --name "$NODE_NAME" \
    --erl "$NODE_ERL_ARGS" \
    -pa "$SHARED_EBIN" \
    -e '
      peer = System.fetch_env!("ORCHARD_PEER_NAME") |> String.to_atom()
      cookie = System.fetch_env!("ORCHARD_PEER_COOKIE_FILE") |> File.read!() |> String.trim() |> String.to_atom()
      true = Node.set_cookie(peer, cookie)
      File.write!(System.fetch_env!("ORCHARD_READY_FILE"), "ready")
      Process.sleep(:infinity)
    ' >"$NODE_LOG" 2>&1 &
NODE_PID=$!

for _attempt in $(seq 1 100); do
  if [[ -f "$NODE_READY" ]]; then
    break
  fi

  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    echo "error: TLS Distribution Node exited before readiness" >&2
    sed -n '1,120p' "$NODE_LOG" >&2
    exit 1
  fi

  sleep 0.1
done

if [[ ! -f "$NODE_READY" ]]; then
  echo "error: TLS Distribution Node did not become ready" >&2
  sed -n '1,120p' "$NODE_LOG" >&2
  exit 1
fi

run_controller_probe() {
  local name="$1"
  local home="$2"
  local tls_args="$3"
  local cookie_file="$4"
  local expected="$5"
  local mode="$6"

  HOME="$home" \
  ERL_EPMD_ADDRESS="$IPV4" \
  ERL_EPMD_PORT="$EPMD_PORT" \
  ORCHARD_EXPECTED_PING="$expected" \
  ORCHARD_PEER_COOKIE_FILE="$cookie_file" \
  ORCHARD_PEER_NAME="$NODE_NAME" \
  ORCHARD_PROBE_MODE="$mode" \
    "$ELIXIR_BIN" \
      --name "$name" \
      --erl "$tls_args" \
      -pa "$SHARED_EBIN" \
      -e '
        peer = System.fetch_env!("ORCHARD_PEER_NAME") |> String.to_atom()
        cookie = System.fetch_env!("ORCHARD_PEER_COOKIE_FILE") |> File.read!() |> String.trim() |> String.to_atom()
        expected = System.fetch_env!("ORCHARD_EXPECTED_PING") |> String.to_atom()
        true = Node.set_cookie(peer, cookie)
        result = Node.ping(peer)

        if result != expected do
          raise "unexpected TLS Distribution result"
        end

        if expected == :pong do
          ^peer = :rpc.call(peer, :erlang, :node, [])
        end

        if System.fetch_env!("ORCHARD_PROBE_MODE") == "mapping_change" do
          true = :rpc.call(peer, Node, :set_cookie, [Node.self(), :orchard_revoked_peer_grant])
          true = Node.disconnect(peer)
          Process.sleep(100)
          :pang = Node.ping(peer)
        end
      '
}

run_controller_probe "$CONTROLLER_NAME" "$CONTROLLER_HOME" "$CONTROLLER_ERL_ARGS" "$WRONG_GENERATION_FILE" pang wrong_generation
run_controller_probe "$WRONG_NAME" "$CONTROLLER_HOME" "$CONTROLLER_ERL_ARGS" "$GRANT_FILE" pang wrong_name
run_controller_probe "$CONTROLLER_NAME" "$FORGED_HOME" "$FORGED_ERL_ARGS" "$GRANT_FILE" pang wrong_certificate
run_controller_probe "$CONTROLLER_NAME" "$CONTROLLER_HOME" "$CONTROLLER_ERL_ARGS" "$GRANT_FILE" pong valid
run_controller_probe "$CONTROLLER_NAME" "$CONTROLLER_HOME" "$CONTROLLER_ERL_ARGS" "$GRANT_FILE" pong mapping_change

echo "BEAM Peer Grant TLS Distribution mechanics smoke passed"
echo "Validated: exact pair accepted; wrong generation, wrong name, wrong certificate, and changed peer mapping rejected"
echo "No gRPC Runtime Endpoint fallback was invoked"
