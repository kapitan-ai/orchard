#!/usr/bin/env bash
# Integration coverage for payload orchardctl against an assembled Controller release.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
STAGED_ROOT="$TMP_ROOT/staged/Library/Application Support/Orchard"
RUNTIME_ROOT="$TMP_ROOT/runtime-root"
TOOLS="$TMP_ROOT/tools"
CONTROLLER_LAUNCHER="$TMP_ROOT/orchard-controller"
ORCHARDCTL_LAUNCHER="$TMP_ROOT/orchardctl"
CONTROLLER_LOG="$TMP_ROOT/controller.log"
CONTROLLER_PID=""
HELD_RPC_PID=""
DATABASE_CREATED=false

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
DATABASE_NAME="orchard_release_rpc_test_$$"
HTTP_PORT=$((40000 + $$ % 1000))
EPMD_PORT=$((44000 + $$ % 1000))
DIST_PORT=$((52000 + $$ % 1000))
MANAGEMENT_NODE="orchard_controller_management_$$@127.0.0.1"
COOKIE_VALUE="release-rpc-cookie-$$"
RELEASE_SOURCE="$REPO_ROOT/_build/prod/rel/orchard_controller"
RELEASE_BIN="$STAGED_ROOT/releases/orchard_controller/bin/orchard_controller"
PRODUCT_VERSION=$(cat "$REPO_ROOT/VERSION")

fail() {
  printf 'release RPC integration failure: %s\n' "$1" >&2
  if [[ -f "$CONTROLLER_LOG" ]]; then
    printf '%s\n' '--- controller log ---' >&2
    tail -100 "$CONTROLLER_LOG" >&2 || true
  fi
  exit 1
}

assert_empty() {
  local path="$1"
  [[ ! -s "$path" ]] || fail "expected $path to be empty"
}

assert_contains() {
  local expected="$1"
  local path="$2"
  grep -F -- "$expected" "$path" >/dev/null || fail "expected $path to contain $expected"
}

assert_matches() {
  local expected="$1"
  local path="$2"
  grep -E -- "$expected" "$path" >/dev/null || fail "expected $path to match $expected"
}

assert_loopback_listener() {
  local port="$1"
  local label="$2"
  local listeners
  listeners=$(/usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null) ||
    fail "$label did not expose its expected listener"
  printf '%s\n' "$listeners" | grep -F -- "127.0.0.1:$port" >/dev/null ||
    fail "$label listener was not bound to IPv4 loopback"
  if printf '%s\n' "$listeners" | grep -E -- "(\\*|0\\.0\\.0\\.0|\\[::\\]):$port" >/dev/null; then
    fail "$label exposed a wildcard listener"
  fi
}

stop_controller() {
  if [[ -n "$CONTROLLER_PID" ]] && kill -0 "$CONTROLLER_PID" 2>/dev/null; then
    kill -TERM "$CONTROLLER_PID" 2>/dev/null || true
    for _ in $(seq 1 40); do
      kill -0 "$CONTROLLER_PID" 2>/dev/null || break
      /bin/sleep 0.25
    done
    if kill -0 "$CONTROLLER_PID" 2>/dev/null; then
      kill -KILL "$CONTROLLER_PID" 2>/dev/null || true
    fi
    wait "$CONTROLLER_PID" 2>/dev/null || true
  fi
  CONTROLLER_PID=""
}

cleanup() {
  if [[ -n "$HELD_RPC_PID" ]] && kill -0 "$HELD_RPC_PID" 2>/dev/null; then
    kill -KILL "$HELD_RPC_PID" 2>/dev/null || true
    wait "$HELD_RPC_PID" 2>/dev/null || true
  fi
  HELD_RPC_PID=""
  stop_controller
  ERL_EPMD_PORT="$EPMD_PORT" mise exec -- epmd -kill >/dev/null 2>&1 || true
  if [[ "$DATABASE_CREATED" == true ]]; then
    PGDATABASE_TEST="$DATABASE_NAME" MIX_ENV=test mise exec -- mix ecto.drop >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

release_rpc() {
  env \
    RELEASE_DISTRIBUTION=name \
    RELEASE_NODE="$MANAGEMENT_NODE" \
    RELEASE_COOKIE="$COOKIE_VALUE" \
    ERL_EPMD_PORT="$EPMD_PORT" \
    ERL_EPMD_ADDRESS=127.0.0.1 \
    ERL_AFLAGS='-kernel inet_dist_use_interface {127,0,0,1}' \
    "$RELEASE_BIN" rpc "$1"
}

cd "$REPO_ROOT"
MIX_ENV=prod mise exec -- mix release orchard_controller --overwrite >/dev/null

mkdir -p "$STAGED_ROOT/share/bin" "$STAGED_ROOT/releases" "$STAGED_ROOT/config" "$RUNTIME_ROOT" "$TOOLS"
cp "$REPO_ROOT/packaging/payload/bin/orchardctl" "$STAGED_ROOT/share/bin/orchardctl"
cp "$REPO_ROOT/packaging/payload/bin/orchard-controller" "$STAGED_ROOT/share/bin/orchard-controller"
cp -R "$RELEASE_SOURCE" "$STAGED_ROOT/releases/orchard_controller"
chmod 0755 "$STAGED_ROOT/share/bin/orchardctl" "$STAGED_ROOT/share/bin/orchard-controller"

cmp -s "$REPO_ROOT/packaging/payload/bin/orchardctl" "$STAGED_ROOT/share/bin/orchardctl" ||
  fail "staged orchardctl does not match the changed source wrapper"
CONTROLLER_RPC_BEAM=$(find "$STAGED_ROOT/releases/orchard_controller/lib" -path '*/ebin/Elixir.OrchardCLI.ControllerRPC.beam' -print -quit)
[[ -n "$CONTROLLER_RPC_BEAM" ]] || fail "assembled Controller release is missing ControllerRPC"
REL_FILE="$STAGED_ROOT/releases/orchard_controller/releases/$PRODUCT_VERSION/orchard_controller.rel"
assert_contains "{orchard_cli,\"$PRODUCT_VERSION\",load}" "$REL_FILE"

cat > "$TOOLS/stat" <<'SH'
#!/bin/sh
case "${2:-}" in
  '%u:%Lp') printf '0:600\n' ;;
  '%z') /usr/bin/stat -f '%z' "$3" ;;
  *) exit 1 ;;
esac
SH
chmod 0755 "$TOOLS/stat"

sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  "$STAGED_ROOT/share/bin/orchard-controller" > "$CONTROLLER_LAUNCHER"
sed \
  -e "s|^ORCHARD_ROOT=.*$|ORCHARD_ROOT=\"$STAGED_ROOT\"|" \
  -e "s|^RPC_TMP_PARENT=.*$|RPC_TMP_PARENT=\"$TMP_ROOT\"|" \
  -e 's|^RPC_TIMEOUT_SECONDS=.*$|RPC_TIMEOUT_SECONDS=5|' \
  -e "s|/usr/bin/stat|$TOOLS/stat|g" \
  "$STAGED_ROOT/share/bin/orchardctl" > "$ORCHARDCTL_LAUNCHER"
chmod 0755 "$CONTROLLER_LAUNCHER" "$ORCHARDCTL_LAUNCHER"

printf '%s\n' "$COOKIE_VALUE" > "$STAGED_ROOT/config/beam.cookie"
chmod 0600 "$STAGED_ROOT/config/beam.cookie"

DATABASE_URL="ecto://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${DATABASE_NAME}"
cat > "$STAGED_ROOT/config/controller.env" <<ENV
DATABASE_URL="$DATABASE_URL"
SECRET_KEY_BASE="$(printf 'release-rpc-secret-%.0s' {1..8})"
ORCHARD_SUPPORT_ROOT="$RUNTIME_ROOT"
ORCHARD_NODE_TRUST_ROOT="$RUNTIME_ROOT/node-trust"
ORCHARD_TRANSPORT_MODE=plain_http_localhost
ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc
ORCHARD_RUNTIME_CLIENT_TARGETS="127.0.0.1:59999"
ORCHARD_CONTROLLER_MANAGEMENT_NODE_NAME="$MANAGEMENT_NODE"
ORCHARD_CONTROLLER_MANAGEMENT_COOKIE_FILE="$STAGED_ROOT/config/beam.cookie"
ORCHARD_CONTROLLER_MANAGEMENT_EPMD_PORT=$EPMD_PORT
ORCHARD_CONTROLLER_MANAGEMENT_DIST_PORT=$DIST_PORT
ORCHARD_CONSOLE_ENABLED=false
PORT=$HTTP_PORT
POOL_SIZE=4
ENV
chmod 0600 "$STAGED_ROOT/config/controller.env"

PGDATABASE_TEST="$DATABASE_NAME" MIX_ENV=test mise exec -- mix ecto.create >/dev/null
DATABASE_CREATED=true
PGDATABASE_TEST="$DATABASE_NAME" MIX_ENV=test mise exec -- mix ecto.migrate >/dev/null

PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" "$CONTROLLER_LAUNCHER" start >"$CONTROLLER_LOG" 2>&1 &
CONTROLLER_PID=$!

for _ in $(seq 1 40); do
  if ERL_EPMD_PORT="$EPMD_PORT" mise exec -- epmd -names 2>/dev/null | grep -F -- "name ${MANAGEMENT_NODE%@*}" >/dev/null; then
    break
  fi
  kill -0 "$CONTROLLER_PID" 2>/dev/null || fail "assembled Controller exited before EPMD registration"
  /bin/sleep 0.25
done

DIRECT_READY_STDOUT="$TMP_ROOT/direct-ready.stdout"
DIRECT_READY_STDERR="$TMP_ROOT/direct-ready.stderr"
release_rpc 'IO.puts(Process.group_leader(), "release-rpc-ready")' >"$DIRECT_READY_STDOUT" 2>"$DIRECT_READY_STDERR" &
DIRECT_READY_PID=$!
direct_ready=false
for _ in $(seq 1 40); do
  if ! kill -0 "$DIRECT_READY_PID" 2>/dev/null; then
    set +e
    wait "$DIRECT_READY_PID"
    DIRECT_READY_STATUS=$?
    set -e
    if [[ "$DIRECT_READY_STATUS" -eq 0 ]] && grep -Fx -- 'release-rpc-ready' "$DIRECT_READY_STDOUT" >/dev/null; then
      direct_ready=true
    fi
    break
  fi
  /bin/sleep 0.25
done
if [[ "$direct_ready" != true ]]; then
  kill -TERM "$DIRECT_READY_PID" 2>/dev/null || true
  wait "$DIRECT_READY_PID" 2>/dev/null || true
  {
    printf '%s\n' '--- direct release RPC stdout ---'
    cat "$DIRECT_READY_STDOUT" 2>/dev/null || true
    printf '%s\n' '--- direct release RPC stderr ---'
    cat "$DIRECT_READY_STDERR" 2>/dev/null || true
  } >> "$CONTROLLER_LOG"
  fail "assembled release could not target the running Controller"
fi

assert_loopback_listener "$EPMD_PORT" "management EPMD"
assert_loopback_listener "$DIST_PORT" "Controller management distribution"

release_rpc 'Process.sleep(10_000)' >/dev/null 2>&1 &
HELD_RPC_PID=$!
RPC_CLIENT_PORT=""
for _ in $(seq 1 40); do
  RPC_CLIENT_PORT=$(ERL_EPMD_PORT="$EPMD_PORT" mise exec -- epmd -names 2>/dev/null |
    awk '/name rpc-/ {print $NF; exit}')
  [[ "$RPC_CLIENT_PORT" =~ ^[0-9]+$ ]] && break
  kill -0 "$HELD_RPC_PID" 2>/dev/null || fail "temporary release RPC exited before listener inspection"
  /bin/sleep 0.1
done
[[ "$RPC_CLIENT_PORT" =~ ^[0-9]+$ ]] || fail "temporary release RPC did not register with management EPMD"
assert_loopback_listener "$RPC_CLIENT_PORT" "temporary release RPC distribution"
kill -TERM "$HELD_RPC_PID" 2>/dev/null || true
wait "$HELD_RPC_PID" 2>/dev/null || true
HELD_RPC_PID=""

READY_STDOUT="$TMP_ROOT/ready.stdout"
READY_STDERR="$TMP_ROOT/ready.stderr"
ready=false
for _ in $(seq 1 40); do
  if PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
       "$ORCHARDCTL_LAUNCHER" nodes list --json >"$READY_STDOUT" 2>"$READY_STDERR"; then
    ready=true
    break
  fi
  kill -0 "$CONTROLLER_PID" 2>/dev/null || fail "assembled Controller exited during startup"
  /bin/sleep 0.25
done
if [[ "$ready" != true ]]; then
  {
    printf '%s\n' '--- EPMD names ---'
    ERL_EPMD_PORT="$EPMD_PORT" mise exec -- epmd -names 2>&1 || true
    printf '%s\n' '--- management listeners ---'
    /usr/sbin/lsof -nP -iTCP:"$EPMD_PORT" -sTCP:LISTEN 2>&1 || true
    /usr/sbin/lsof -nP -iTCP:"$DIST_PORT" -sTCP:LISTEN 2>&1 || true
    printf '%s\n' '--- orchardctl stderr ---'
    cat "$READY_STDERR" 2>/dev/null || true
  } >> "$CONTROLLER_LOG"
  fail "assembled Controller did not become RPC-ready"
fi
assert_empty "$READY_STDERR"
assert_contains 'cluster_management.node_status_list' "$READY_STDOUT"

MODULE_OUTPUT=$(release_rpc 'IO.puts(Process.group_leader(), if(:code.which(OrchardCLI.ControllerRPC) == :non_existing, do: "missing", else: "loaded"))')
[[ "$MODULE_OUTPUT" == "loaded" ]] || fail "ControllerRPC module was not loaded in the running release"

DIRECT_ENVELOPE=$(release_rpc 'OrchardCLI.ControllerRPC.main_base64(["bm9kZXM=", "bGlzdA==", "LS1qc29u"])')
if [[ $(printf '%s\n' "$DIRECT_ENVELOPE" | awk 'END {print NR}') -ne 1 ]]; then
  printf '%s\n' '--- direct envelope output ---' "$DIRECT_ENVELOPE" >> "$CONTROLLER_LOG"
  fail "real release RPC emitted more than one envelope line"
fi
[[ "$DIRECT_ENVELOPE" == ORCHARDCTL_RPC_V1:0:stdout:* ]] || fail "real release RPC did not emit the stdout envelope"

ERROR_ENVELOPE=$(release_rpc 'OrchardCLI.ControllerRPC.main_base64(["bm9kZXM=", "ZW5yb2xsbWVudA=="])')
[[ $(printf '%s\n' "$ERROR_ENVELOPE" | awk 'END {print NR}') -eq 1 ]] || fail "real release RPC error emitted more than one envelope line"
[[ "$ERROR_ENVELOPE" == ORCHARDCTL_RPC_V1:1:stderr:* ]] || fail "real release RPC did not emit the stderr envelope"

AUTHORITY_BEFORE=$(release_rpc 'pid = Process.whereis(Orchard.DispatchCapacity.AllocationAuthority); supervised = Enum.any?(Supervisor.which_children(Orchard.Inference), fn {id, child, _, _} -> id == Orchard.DispatchCapacity.AllocationAuthority and child == pid end); IO.puts(Process.group_leader(), "#{inspect(pid)}:#{supervised}:#{Process.alive?(pid)}")')
[[ "$AUTHORITY_BEFORE" == '#PID<'*':true:true' ]] || fail "AllocationAuthority is not the supervised Controller authority"

NODE_ID=$(release_rpc 'root = System.fetch_env!("ORCHARD_NODE_TRUST_ROOT"); {:ok, _trust} = Orchard.NodeTrust.initialize(root: root); node_id = Ecto.UUID.generate(); attrs = %{id: node_id, hostname: "release-rpc-node.local", display_name: "release-rpc-node", advertise_addr: "127.0.0.2", rpc_port: 50071, state: :registered, health: :healthy, capabilities: %{}, agent_version: "0.5.0", last_heartbeat_at: DateTime.utc_now()}; %Orchard.Nodes.Node{} |> Orchard.Nodes.Node.changeset(attrs) |> Orchard.Repo.insert!(); IO.puts(Process.group_leader(), node_id)' | grep -E '^[0-9a-f-]{36}$' | tail -1)
[[ "$NODE_ID" =~ ^[0-9a-f-]{36}$ ]] || fail "release RPC did not seed a registered node"

POOL_ID="11111111-1111-4111-8111-111111111111"
ROUTING_POLICY_ID="22222222-2222-4222-8222-222222222222"
ADMIT_STDOUT="$TMP_ROOT/admit.stdout"
ADMIT_STDERR="$TMP_ROOT/admit.stderr"
set +e
PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$ORCHARDCTL_LAUNCHER" nodes admit "$NODE_ID" --yes --json \
  --trust-evidence-ref registration-audit:release-rpc \
  --pool-id "$POOL_ID" \
  --routing-policy-id "$ROUTING_POLICY_ID" \
  --capacity-policy-reason "assembled release RPC integration" \
  >"$ADMIT_STDOUT" 2>"$ADMIT_STDERR"
ADMIT_STATUS=$?
set -e
[[ "$ADMIT_STATUS" -eq 0 ]] || fail "authoritative admission failed through packaged wrapper"
assert_empty "$ADMIT_STDERR"
assert_matches '"action"[[:space:]]*:[[:space:]]*"node_admission.admitted"' "$ADMIT_STDOUT"
assert_matches '"controller_dispatch_ceiling"[[:space:]]*:[[:space:]]*1' "$ADMIT_STDOUT"

AUTHORITY_AFTER=$(release_rpc 'pid = Process.whereis(Orchard.DispatchCapacity.AllocationAuthority); supervised = Enum.any?(Supervisor.which_children(Orchard.Inference), fn {id, child, _, _} -> id == Orchard.DispatchCapacity.AllocationAuthority and child == pid end); IO.puts(Process.group_leader(), "#{inspect(pid)}:#{supervised}:#{Process.alive?(pid)}")')
[[ "$AUTHORITY_AFTER" == "$AUTHORITY_BEFORE" ]] || fail "authoritative operation did not preserve the supervised AllocationAuthority"

ERROR_STDOUT="$TMP_ROOT/error.stdout"
ERROR_STDERR="$TMP_ROOT/error.stderr"
set +e
PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
  "$ORCHARDCTL_LAUNCHER" nodes inspect 00000000-0000-4000-a000-000000000000 --json \
  >"$ERROR_STDOUT" 2>"$ERROR_STDERR"
ERROR_STATUS=$?
set -e
[[ "$ERROR_STATUS" -eq 1 ]] || fail "packaged wrapper did not preserve Controller command error status"
assert_empty "$ERROR_STDOUT"
[[ -s "$ERROR_STDERR" ]] || fail "packaged wrapper did not preserve Controller command stderr"

kill -0 "$CONTROLLER_PID" 2>/dev/null || fail "Controller did not survive release RPC commands"
SURVIVAL=$(release_rpc 'IO.puts(Process.group_leader(), "controller-alive=#{Process.alive?(Process.whereis(Orchard.Supervisor))}")')
[[ "$SURVIVAL" == "controller-alive=true" ]] || fail "Controller supervision tree did not survive RPC commands"

printf 'assembled Controller release RPC integration tests passed\n'
