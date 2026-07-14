#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

command -v psql >/dev/null || {
  echo "error: psql is required for the composed source-dev smoke" >&2
  exit 64
}

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
  local attempts=0

  while [[ ! -f "$path" ]]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      return 1
    fi

    if (( attempts >= 300 )); then
      return 1
    fi

    sleep 0.1
    attempts=$((attempts + 1))
  done
}

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

IPV4="${ORCHARD_BEAM_TRACER_IPV4:-}"
if [[ -z "$IPV4" ]]; then
  IPV4="$(discover_private_ipv4 || true)"
fi

if [[ -z "$IPV4" ]]; then
  echo "error: set ORCHARD_BEAM_TRACER_IPV4 to a private IPv4 address" >&2
  exit 64
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-beam-peer-grant-app.XXXXXX")"
chmod 700 "$SMOKE_ROOT"
mkdir -p "$SMOKE_ROOT/descriptor"
chmod 700 "$SMOKE_ROOT/descriptor"
mkfifo "$SMOKE_ROOT/node.stdin" "$SMOKE_ROOT/controller.stdin"
exec 8<>"$SMOKE_ROOT/node.stdin"
exec 9<>"$SMOKE_ROOT/controller.stdin"

CONTROL_PID=""
NODE_PID=""
CONTROLLER_PID=""
EPMD_PORT="${ORCHARD_BEAM_TRACER_EPMD_PORT:-$((44000 + $$ % 1000))}"
CONTROL_PORT="${ORCHARD_BEAM_TRACER_CONTROL_PORT:-$((55000 + $$ % 500))}"
CONTROLLER_DIST_PORT="${ORCHARD_BEAM_TRACER_CONTROLLER_DIST_PORT:-$((56000 + $$ % 500))}"
NODE_DIST_PORT="${ORCHARD_BEAM_TRACER_NODE_DIST_PORT:-$((57000 + $$ % 500))}"
DATABASE="orchard_peer_grant_smoke_$$"

cleanup() {
  stop_process "$CONTROLLER_PID"
  stop_process "$NODE_PID"
  stop_process "$CONTROL_PID"
  ERL_EPMD_PORT="$EPMD_PORT" mise exec -- epmd -stop >/dev/null 2>&1 || true
  MIX_ENV=dev PGDATABASE="$DATABASE" mise exec -- mix ecto.drop --quiet >/dev/null 2>&1 || true
  exec 8>&-
  exec 9>&-
  if [[ "${ORCHARD_BEAM_SMOKE_KEEP:-0}" == "1" ]]; then
    echo "kept smoke root: $SMOKE_ROOT" >&2
  else
    rm -rf "$SMOKE_ROOT"
  fi
}
trap cleanup EXIT

export MIX_ENV=dev
export PGDATABASE="$DATABASE"
export ORCHARD_BEAM_TRACER_IPV4="$IPV4"
export ORCHARD_BEAM_EPMD_PORT="$EPMD_PORT"
export ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST="$IPV4"
export ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT="$CONTROL_PORT"
export ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH="$SMOKE_ROOT/authorization-root"
export ORCHARD_NODE_TRUST_ROOT="$SMOKE_ROOT/node-trust"
export ORCHARD_NODE_IDENTITY_ROOT="$SMOKE_ROOT/node-identity"
export ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR="$SMOKE_ROOT/descriptor/peer-grant.json"
export ORCHARD_BEAM_PEER_GRANT_STATE_ROOT="$SMOKE_ROOT/launch"
export ORCHARD_BEAM_PEER_GRANTS_ENABLED=true
export ORCHARD_BEAM_PEER_GRANT_MODE=grant_control
export ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam
export ORCHARD_SOURCE_DEV_ROLE=controller
export ORCHARD_BEAM_DIST_PORT_MIN="$CONTROLLER_DIST_PORT"
export ORCHARD_BEAM_DIST_PORT_MAX="$CONTROLLER_DIST_PORT"
export PORT="$((58000 + $$ % 500))"

mise exec -- mix ecto.create --quiet
mise exec -- mix ecto.migrate --quiet

mise exec -- mix run --no-start \
  "$REPO_ROOT/scripts/support/beam-peer-grant-control-application.exs" \
  "$SMOKE_ROOT" "$IPV4" >"$SMOKE_ROOT/control.log" 2>&1 &
CONTROL_PID=$!

if ! wait_for_file "$SMOKE_ROOT/control.ready" "$CONTROL_PID"; then
  cat "$SMOKE_ROOT/control.log" >&2
  echo "error: grant-control application did not become ready" >&2
  exit 1
fi

source "$SMOKE_ROOT/scope.env"
export ORCHARD_BEAM_NODE_NAME="$NODE_NAME"

mise exec -- "$REPO_ROOT/bin/source-dev-peer-grant" node-retrieve
mise exec -- "$REPO_ROOT/bin/source-dev-peer-grant" node-preflight

export ORCHARD_BEAM_NODE_NAME="$CONTROLLER_NAME"
mise exec -- "$REPO_ROOT/bin/source-dev-peer-grant" controller-preflight

printf 'stop\n' > "$SMOKE_ROOT/control.stop"
chmod 600 "$SMOKE_ROOT/control.stop"
wait "$CONTROL_PID"
CONTROL_PID=""

export ORCHARD_BEAM_NODE_NAME="orchard_node_agent_eeeeeeeeeeee4eee8eeeeeeeeeeeeeee@$IPV4"
if mise exec -- "$REPO_ROOT/bin/source-dev-peer-grant" node-run \
  >"$SMOKE_ROOT/wrong-name.log" 2>&1; then
  echo "error: wrong canonical Node launch name unexpectedly started" >&2
  exit 1
fi

printf 'tampered\n' >> "$SMOKE_ROOT/launch/node_agent/ssl-dist.conf"
export ORCHARD_BEAM_NODE_NAME="$NODE_NAME"
if mise exec -- "$REPO_ROOT/bin/source-dev-peer-grant" node-run \
  >"$SMOKE_ROOT/tampered-optfile.log" 2>&1; then
  echo "error: tampered TLS Distribution optfile unexpectedly started" >&2
  exit 1
fi

mise exec -- "$REPO_ROOT/bin/source-dev-peer-grant" node-preflight

export ORCHARD_BEAM_DIST_PORT_MIN="$NODE_DIST_PORT"
export ORCHARD_BEAM_DIST_PORT_MAX="$NODE_DIST_PORT"
mise exec -- "$REPO_ROOT/bin/source-dev-peer-grant" node-run \
  <&8 >"$SMOKE_ROOT/node.log" 2>&1 &
NODE_PID=$!

export ORCHARD_BEAM_NODE_NAME="$CONTROLLER_NAME"
export ORCHARD_BEAM_DIST_PORT_MIN="$CONTROLLER_DIST_PORT"
export ORCHARD_BEAM_DIST_PORT_MAX="$CONTROLLER_DIST_PORT"
mise exec -- "$REPO_ROOT/bin/source-dev-peer-grant" controller-run \
  <&9 >"$SMOKE_ROOT/controller.log" 2>&1 &
CONTROLLER_PID=$!

active=0
for _attempt in $(seq 1 120); do
  if ! kill -0 "$NODE_PID" 2>/dev/null || ! kill -0 "$CONTROLLER_PID" 2>/dev/null; then
    break
  fi

  observed="$(
    psql --no-psqlrc --tuples-only --no-align \
      --command "SELECT state::text || ':' || canonical_beam_name FROM nodes WHERE id = '$NODE_ID'" \
      2>"$SMOKE_ROOT/active.log" || true
  )"

  if [[ "$observed" == "active:$NODE_NAME" ]]; then
    printf 'active over BEAM: %s\n' "$NODE_NAME" >"$SMOKE_ROOT/active.log"
    active=1
    break
  fi

  sleep 0.25
done

if (( active != 1 )); then
  cat "$SMOKE_ROOT/node.log" >&2
  cat "$SMOKE_ROOT/controller.log" >&2
  cat "$SMOKE_ROOT/active.log" >&2
  echo "error: composed application tracer did not activate over BEAM" >&2
  exit 1
fi

cat "$SMOKE_ROOT/active.log"

stop_process "$CONTROLLER_PID"
CONTROLLER_PID=""
stop_process "$NODE_PID"
NODE_PID=""

MIX_ENV=test mise exec -- mix test \
  apps/orchard_controller/test/application_test.exs \
  apps/orchard_controller/test/orchard/beam_peer_grants_test.exs \
  apps/orchard_controller/test/orchard/beam_peer_grants/controller_preflight_test.exs \
  apps/orchard_controller/test/orchard/beam_peer_grants/controller_startup_verifier_test.exs \
  apps/orchard_controller/test/orchard/runtime_endpoint/beam_client_test.exs \
  apps/orchard_node_agent/test/application_test.exs \
  apps/orchard_node_agent/test/orchard/node/beam_peer_grant_bootstrap_test.exs \
  apps/orchard_node_agent/test/orchard/node/beam_peer_grant_preflight_test.exs \
  apps/orchard_node_agent/test/orchard/node/beam_peer_grant_startup_verifier_test.exs \
  apps/orchard_node_agent/test/orchard/node/beam_peer_grant_store_test.exs \
  apps/orchard_shared/test/orchard/runtime_endpoint/distribution_expiry_guard_test.exs \
  apps/orchard_shared/test/orchard/runtime_endpoint/distribution_launch_test.exs \
  apps/orchard_shared/test/orchard/runtime_endpoint/distribution_tls_test.exs

"$SCRIPT_DIR/test-beam-peer-grant-expiry-smoke.sh"
"$SCRIPT_DIR/test-beam-peer-grant-tracer.sh"
"$SCRIPT_DIR/test-beam-legacy-first-connect-smoke.sh"

echo "BEAM Peer Grant composed source-dev application tracer passed"
echo "Validated: real grant-control application, real mTLS retrieval, owner-only preflight, exact TLS Distribution application launches, admitted-to-active BEAM observation, and explicit legacy BEAM first-connect compatibility"
echo "Negative paths: wrong canonical launch name, tampered optfile, wrong certificate and grant scope, revoked or expired grant, active-peer expiry with failed reconnection, and no automatic gRPC fallback"
echo "This is source-dev single-Mac evidence, not packaged or two-Mac acceptance"
