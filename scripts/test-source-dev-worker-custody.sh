#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMAND="$REPO_ROOT/bin/orchard-source-worker-custody"
POLICY="$REPO_ROOT/rel/linux/source-dev/worker-custody.json"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-worker-custody-test.XXXXXX")"
INSTALLATION_UUID=11111111-1111-4111-8111-111111111111
NODE_UUID=22222222-2222-4222-8222-222222222222
REQUEST_UUID=33333333-3333-4333-8333-333333333333

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fail() {
  printf 'test-source-dev-worker-custody: %s\n' "$1" >&2
  exit 1
}

expect_failure() {
  local expected=$1
  shift
  if "$@" >"$TMP_ROOT/failure.out" 2>&1; then
    fail "command unexpectedly succeeded; expected $expected"
  fi
  grep -F "$expected" "$TMP_ROOT/failure.out" >/dev/null || {
    cat "$TMP_ROOT/failure.out" >&2
    fail "failure did not contain: $expected"
  }
}

write_host() {
  jq -n \
    --argjson cpus "${1:-8}" \
    --argjson memory "${2:-34359738368}" \
    '{
      schema_version: 1,
      cgroup_version: 2,
      logical_cpus: $cpus,
      physical_memory_bytes: $memory,
      controllers: ["cpu", "cpuset", "io", "memory", "pids"],
      control_cpus: [0, 1],
      control_cpu_topology_stable: true,
      worker_io: {device: "259:2", read_bytes_per_second: 400000000, write_bytes_per_second: 200000000},
      worker_storage: {quota_bytes: 120000000000, enforceable: true}
    }' >"$TMP_ROOT/host.json"
}

write_manifest() {
  local policy=$1
  jq -n \
    --arg uuid "$INSTALLATION_UUID" \
    --arg digest "$(sha256sum "$policy" | cut -d ' ' -f1)" \
    '{
      schema_version: 1,
      installation_uuid: $uuid,
      activation: "disabled",
      worker_custody: {
        policy_path: "rel/linux/source-dev/worker-custody.json",
        policy_sha256: $digest,
        activation: "disabled",
        authority: "custody_only",
        node_uuid: null
      }
    }' >"$TMP_ROOT/manifest.json"
}

write_snapshot() {
  local agent=${1:-'[]'} leaves=${2:-'[]'} gate=${3:-closed}
  local escaped_agent=${4:-'[]'} escaped_worker=${5:-'[]'} foreign=${6:-'[]'} orphan=${7:-'[]'}
  jq -n \
    --arg uuid "$INSTALLATION_UUID" \
    --arg gate "$gate" \
    --argjson agent "$agent" \
    --argjson leaves "$leaves" \
    --argjson escaped_agent "$escaped_agent" \
    --argjson escaped_worker "$escaped_worker" \
    --argjson foreign "$foreign" \
    --argjson orphan "$orphan" \
    '{
      schema_version: 1,
      installation_uuid: $uuid,
      launch_gate: $gate,
      agent_processes: $agent,
      worker_leaves: $leaves,
      escaped_agent_pids: $escaped_agent,
      escaped_worker_pids: $escaped_worker,
      foreign_pids: $foreign,
      orphan_listeners: $orphan
    }' >"$TMP_ROOT/custody.json"
}

write_host
preflight="$($COMMAND preflight "$POLICY" "$TMP_ROOT/host.json")"
jq -e '
  .qualification == "static_preflight_only" and
  .os_reserve_bytes == 4294967296 and
  .orchard_memory_max_bytes == 30064771072 and
  .worker_memory_max_bytes == 11811160064 and
  .node_memory_max_bytes == 13958643712 and
  .worker_cpus == [2, 3, 4, 5, 6, 7] and
  .worker_io.read_max_bytes_per_second == 200000000 and
  .worker_io.write_max_bytes_per_second == 100000000 and
  .authority == "custody_only"
' <<<"$preflight" >/dev/null || fail "preflight calculated the wrong deterministic budget"

for mutation in \
  '.cgroup_version = 1' \
  '.logical_cpus = 7' \
  '.physical_memory_bytes = 34359738367' \
  '.controllers -= ["io"]' \
  '.control_cpus = [0, 2]' \
  '.control_cpu_topology_stable = false' \
  '.worker_io.read_bytes_per_second = 0' \
  '.worker_storage.enforceable = false'; do
  jq "$mutation" "$TMP_ROOT/host.json" >"$TMP_ROOT/invalid-host.json"
  expect_failure 'host cannot enforce the Worker custody profile' \
    "$COMMAND" preflight "$POLICY" "$TMP_ROOT/invalid-host.json"
done

jq '.controllers += ["hugetlb"]' "$TMP_ROOT/host.json" >"$TMP_ROOT/host-with-extra-controller.json"
$COMMAND preflight "$POLICY" "$TMP_ROOT/host-with-extra-controller.json" >/dev/null ||
  fail "an additional cgroup controller incorrectly blocked preflight"

write_manifest "$POLICY"
write_snapshot
[[ "$($COMMAND classify "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/custody.json")" == stopped_empty ]] ||
  fail "empty stopped hierarchy was not classified"

agent_running='[{"pid":101,"start_time_ticks":1001,"cgroup":"orchard.slice/orchard-node-agent.service/agent"}]'
leaf_running='[{"unit":"runtime_a","generation":7,"processes":[{"pid":202,"start_time_ticks":2002,"cgroup":"orchard.slice/orchard-node-agent.service/workers/worker/runtime_a/7"}],"listeners":["/run/orchard-worker/runtime_a-7.sock"]}]'
write_snapshot "$agent_running" "$leaf_running" open
[[ "$($COMMAND classify "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/custody.json")" == running_owned ]] ||
  fail "owned Agent and Worker were not classified running"

write_snapshot '[]' "$leaf_running" closed
[[ "$($COMMAND classify "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/custody.json")" == recovery_required_owned_survivors ]] ||
  fail "Worker survivor did not require recovery"

stale_listener='[{"unit":"runtime_a","generation":7,"processes":[],"listeners":["/run/orchard-worker/runtime_a-7.sock"]}]'
write_snapshot '[]' "$stale_listener" closed
[[ "$($COMMAND classify "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/custody.json")" == recovery_required_owned_stale_listeners ]] ||
  fail "owned stale listener did not require recovery"

write_snapshot '[]' '[]' open
[[ "$($COMMAND classify "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/custody.json")" == blocked_open_gate_without_agent ]] ||
  fail "open gate without Agent was not blocked"

for position in escaped-agent escaped-worker foreign orphan; do
  case "$position" in
    escaped-agent) write_snapshot "$agent_running" '[]' closed '[301]' ;;
    escaped-worker) write_snapshot "$agent_running" '[]' closed '[]' '[302]' ;;
    foreign) write_snapshot "$agent_running" '[]' closed '[]' '[]' '[303]' ;;
    orphan) write_snapshot "$agent_running" '[]' closed '[]' '[]' '[]' '["/run/orchard-worker/orphan.sock"]' ;;
  esac
  [[ "$($COMMAND classify "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/custody.json")" == blocked_ambiguous_ownership ]] ||
    fail "$position ownership was not blocked"
done

jq '.installation_uuid = "99999999-9999-4999-8999-999999999999"' "$TMP_ROOT/custody.json" >"$TMP_ROOT/foreign-custody.json"
expect_failure 'custody snapshot is invalid or ambiguous' \
  "$COMMAND" classify "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/foreign-custody.json"

for leaves in \
  '[{"unit":"runtime_a","generation":1,"processes":[{"pid":101,"start_time_ticks":1001,"cgroup":"orchard.slice/orchard-node-agent.service/workers/worker/runtime_a/1"}],"listeners":[]}]' \
  '[{"unit":"runtime_a","generation":1,"processes":[],"listeners":[]},{"unit":"runtime_a","generation":1,"processes":[],"listeners":[]}]' \
  '[{"unit":"runtime_a","generation":1,"processes":[{"pid":201,"start_time_ticks":2001,"cgroup":"orchard.slice/orchard-node-agent.service/workers/worker/runtime_a/1"}],"listeners":[]},{"unit":"runtime_b","generation":1,"processes":[{"pid":201,"start_time_ticks":2001,"cgroup":"orchard.slice/orchard-node-agent.service/workers/worker/runtime_b/1"}],"listeners":[]}]' \
  '[{"unit":"runtime_a","generation":1,"processes":[],"listeners":["/run/orchard-worker/../same.sock"]}]'; do
  write_snapshot "$agent_running" "$leaves" closed
  expect_failure 'custody snapshot is invalid or ambiguous' \
    "$COMMAND" classify "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/custody.json"
done

jq '.worker_custody.policy_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  "$TMP_ROOT/manifest.json" >"$TMP_ROOT/foreign-manifest.json"
expect_failure 'installation manifest does not bind the Worker custody policy' \
  "$COMMAND" classify "$POLICY" "$TMP_ROOT/foreign-manifest.json" "$TMP_ROOT/custody.json"

jq -n \
  --arg installation "$INSTALLATION_UUID" \
  --arg node "$NODE_UUID" \
  --arg request "$REQUEST_UUID" \
  '{installation_uuid:$installation,node_uuid:$node,request_uuid:$request,provider:"fixture",provider_sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",generation:1}' \
  >"$TMP_ROOT/request.json"
expect_failure 'launch request is unauthorized or ambiguous' \
  "$COMMAND" validate-launch "$POLICY" "$TMP_ROOT/manifest.json" "$TMP_ROOT/request.json"

jq '.providers = [{name:"fixture",sha256:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",generation:1,activation:"authorized"}]' \
  "$POLICY" >"$TMP_ROOT/authorized-policy.json"
write_manifest "$TMP_ROOT/authorized-policy.json"
expect_failure 'launch request is unauthorized or ambiguous' \
  "$COMMAND" validate-launch "$TMP_ROOT/authorized-policy.json" "$TMP_ROOT/manifest.json" "$TMP_ROOT/request.json"
jq --arg node "$NODE_UUID" '.worker_custody.node_uuid = $node' "$TMP_ROOT/manifest.json" >"$TMP_ROOT/bound-manifest.json"
mv "$TMP_ROOT/bound-manifest.json" "$TMP_ROOT/manifest.json"
[[ "$($COMMAND validate-launch "$TMP_ROOT/authorized-policy.json" "$TMP_ROOT/manifest.json" "$TMP_ROOT/request.json")" == authorized_metadata_only ]] ||
  fail "exact immutable provider metadata was not authorized"

for mutation in \
  '.environment = {PATH:"/tmp"}' \
  '.provider = "other"' \
  '.generation = 2' \
  '.provider_sha256 = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  '.node_uuid = "44444444-4444-4444-8444-444444444444"' \
  '.installation_uuid = "99999999-9999-4999-8999-999999999999"'; do
  jq "$mutation" "$TMP_ROOT/request.json" >"$TMP_ROOT/invalid-request.json"
  expect_failure 'launch request is unauthorized or ambiguous' \
    "$COMMAND" validate-launch "$TMP_ROOT/authorized-policy.json" "$TMP_ROOT/manifest.json" "$TMP_ROOT/invalid-request.json"
done

grep -F 'MemoryMin=9G' "$REPO_ROOT/rel/linux/source-dev/systemd/orchard.slice" >/dev/null || fail "parent memory reserve is absent"
grep -F 'AllowedCPUs=0-1' "$REPO_ROOT/rel/linux/source-dev/systemd/orchard-control.slice" >/dev/null || fail "Controller CPU reserve is absent"
grep -F 'MemoryMax=8G' "$REPO_ROOT/rel/linux/source-dev/systemd/orchard-database.slice" >/dev/null || fail "database ceiling is absent"
grep -F 'TasksMax=256' "$REPO_ROOT/rel/linux/source-dev/systemd/orchard-lifecycle.slice" >/dev/null || fail "lifecycle helper aggregate ceiling is absent"
grep -F 'TasksMax=8192' "$REPO_ROOT/rel/linux/source-dev/systemd/orchard-node-agent.service" >/dev/null || fail "Node task ceiling is absent"
grep -F 'KillMode=control-group' "$REPO_ROOT/rel/linux/source-dev/systemd/orchard-node-agent.service" >/dev/null || fail "full cgroup cleanup is absent"

printf 'test-source-dev-worker-custody: all cases passed\n'
