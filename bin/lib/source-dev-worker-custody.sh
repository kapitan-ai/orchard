#!/usr/bin/env bash

orchard_source_worker_custody_fail() {
  printf 'orchard-source-worker-custody: %s\n' "$1" >&2
  return "${2:-1}"
}

orchard_source_worker_custody_main() {
  local command=${1:-}
  case "$command" in
    preflight)
      [[ $# -eq 3 ]] || orchard_source_worker_custody_fail "usage: orchard-source-worker-custody preflight POLICY HOST-SNAPSHOT" 64 || return $?
      orchard_source_worker_custody_preflight "$2" "$3"
      ;;
    classify)
      [[ $# -eq 4 ]] || orchard_source_worker_custody_fail "usage: orchard-source-worker-custody classify POLICY INSTALLATION-MANIFEST CUSTODY-SNAPSHOT" 64 || return $?
      orchard_source_worker_custody_classify "$2" "$3" "$4"
      ;;
    validate-launch)
      [[ $# -eq 4 ]] || orchard_source_worker_custody_fail "usage: orchard-source-worker-custody validate-launch POLICY INSTALLATION-MANIFEST REQUEST" 64 || return $?
      orchard_source_worker_custody_validate_launch "$2" "$3" "$4"
      ;;
    *)
      orchard_source_worker_custody_fail "usage: orchard-source-worker-custody preflight|classify|validate-launch ..." 64
      ;;
  esac
}

orchard_source_worker_custody_validate_policy() {
  local policy=$1
  jq -e '
    .schema_version == 1 and
    .profile == "ubuntu_24_04_x86_64_single_host" and
    .activation == "disabled" and .authority == "custody_only" and
    .minimum_host.logical_cpus == 8 and
    .minimum_host.physical_memory_bytes == 34359738368 and
    .minimum_host.required_controllers == ["cpu", "cpuset", "io", "memory", "pids"] and
    .minimum_host.control_cpus == [0, 1] and
    .budgets.fixed_non_worker_bytes == 18253611008 and
    .budgets.orchard_memory_min_bytes == 9663676416 and
    .budgets.controller.memory_min_bytes == 4294967296 and
    .budgets.postgresql.memory_min_bytes == 4294967296 and
    .budgets.agent.memory_min_bytes == 1073741824 and
    .budgets.node.tasks_max == (.budgets.agent.tasks_max + .budgets.workers.tasks_max) and
    .cgroups.worker_leaf_pattern == "worker/<unit>/<generation>" and
    (.providers | type == "array")
  ' "$policy" >/dev/null || orchard_source_worker_custody_fail "Worker custody policy is invalid or ambiguous"
}

orchard_source_worker_custody_preflight() {
  local policy=$1 snapshot=$2
  orchard_source_worker_custody_validate_policy "$policy" || return $?
  jq -e --slurpfile policy "$policy" '
    .controllers as $controllers |
    if .schema_version == 1 and
       .cgroup_version == 2 and
       (.logical_cpus | type == "number") and .logical_cpus >= $policy[0].minimum_host.logical_cpus and
       (.physical_memory_bytes | type == "number") and .physical_memory_bytes >= $policy[0].minimum_host.physical_memory_bytes and
       (.controllers | type == "array") and
       all($policy[0].minimum_host.required_controllers[]; . as $controller | any($controllers[]; . == $controller)) and
       .control_cpus == $policy[0].minimum_host.control_cpus and
       .control_cpu_topology_stable == true and
       (.worker_io.device | type == "string" and length > 0) and
       (.worker_io.read_bytes_per_second | type == "number" and . > 0) and
       (.worker_io.write_bytes_per_second | type == "number" and . > 0) and
       (.worker_storage.quota_bytes | type == "number" and . > 0) and
       .worker_storage.enforceable == true
    then
      ((.physical_memory_bytes / 10 | floor) as $ten_percent |
        (if $ten_percent > $policy[0].budgets.os_reserve_min_bytes then $ten_percent else $policy[0].budgets.os_reserve_min_bytes end)) as $os_reserve |
      (.physical_memory_bytes - $os_reserve - $policy[0].budgets.fixed_non_worker_bytes) as $worker_memory |
      if $worker_memory > 0 then {
        schema_version: 1,
        qualification: "static_preflight_only",
        physical_memory_bytes: .physical_memory_bytes,
        os_reserve_bytes: $os_reserve,
        orchard_memory_max_bytes: (.physical_memory_bytes - $os_reserve),
        worker_memory_max_bytes: $worker_memory,
        node_memory_max_bytes: ($policy[0].budgets.node.fixed_memory_max_bytes + $worker_memory),
        control_cpus: .control_cpus,
        worker_cpus: ([range(0; .logical_cpus)] - .control_cpus),
        worker_io: {
          device: .worker_io.device,
          read_max_bytes_per_second: (.worker_io.read_bytes_per_second * $policy[0].budgets.workers.shared_device_floor_percent / 100 | floor),
          write_max_bytes_per_second: (.worker_io.write_bytes_per_second * $policy[0].budgets.workers.shared_device_floor_percent / 100 | floor)
        },
        worker_storage_quota_bytes: .worker_storage.quota_bytes,
        authority: "custody_only"
      } else error("non-positive Worker memory") end
    else error("unenforceable host snapshot") end
  ' "$snapshot" || orchard_source_worker_custody_fail "host cannot enforce the Worker custody profile"
}

orchard_source_worker_custody_validate_installation() {
  local policy=$1 manifest=$2
  local policy_digest
  policy_digest=$(sha256sum "$policy" | cut -d ' ' -f1) || return $?
  jq -e --arg digest "$policy_digest" '
    .schema_version == 1 and .activation == "disabled" and
    (.installation_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    .worker_custody == {
      policy_path: "rel/linux/source-dev/worker-custody.json",
      policy_sha256: $digest,
      activation: "disabled",
      authority: "custody_only",
      node_uuid: .worker_custody.node_uuid
    } and
    (.worker_custody.node_uuid == null or
      (.worker_custody.node_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")))
  ' "$manifest" >/dev/null || orchard_source_worker_custody_fail "installation manifest does not bind the Worker custody policy"
}

orchard_source_worker_custody_classify() {
  local policy=$1 manifest=$2 snapshot=$3
  orchard_source_worker_custody_validate_policy "$policy" || return $?
  orchard_source_worker_custody_validate_installation "$policy" "$manifest" || return $?
  jq -er --slurpfile manifest "$manifest" '
    def process_valid($cgroup):
      (keys | sort) == ["cgroup", "pid", "start_time_ticks"] and
      (.pid | type == "number" and . > 0 and floor == .) and
      (.start_time_ticks | type == "number" and . > 0 and floor == .) and
      .cgroup == $cgroup;
    . as $snapshot |
    [$snapshot.worker_leaves[].processes[]] as $worker_processes |
    [$snapshot.agent_processes[], $worker_processes[]] as $all_processes |
    if $snapshot.schema_version == 1 and
       $snapshot.installation_uuid == $manifest[0].installation_uuid and
       ($snapshot.agent_processes | type == "array" and
         all($snapshot.agent_processes[]; process_valid("orchard.slice/orchard-node-agent.service/agent"))) and
       ($snapshot.worker_leaves | type == "array") and
       (all($snapshot.worker_leaves[]; . as $leaf |
         ($leaf.unit | test("^[a-z0-9][a-z0-9_-]{0,63}$")) and
         ($leaf.generation | type == "number" and . >= 1 and floor == .) and
         ($leaf.processes | type == "array" and
           all($leaf.processes[]; process_valid("orchard.slice/orchard-node-agent.service/workers/worker/\($leaf.unit)/\($leaf.generation)"))) and
         ($leaf.listeners | type == "array" and
           all($leaf.listeners[]; . == "/run/orchard-worker/\($leaf.unit)-\($leaf.generation).sock")))) and
       ([$snapshot.worker_leaves[] | [.unit, .generation]] | length) == ([$snapshot.worker_leaves[] | [.unit, .generation]] | unique | length) and
       ($all_processes | map(.pid) | length) == ($all_processes | map(.pid) | unique | length) and
       ($all_processes | map([.pid, .start_time_ticks]) | length) == ($all_processes | map([.pid, .start_time_ticks]) | unique | length) and
       ([$snapshot.worker_leaves[].listeners[]] | length) == ([$snapshot.worker_leaves[].listeners[]] | unique | length) and
       ($snapshot.escaped_agent_pids | type == "array" and all(.[]; type == "number" and . > 0)) and
       ($snapshot.escaped_worker_pids | type == "array" and all(.[]; type == "number" and . > 0)) and
       ($snapshot.foreign_pids | type == "array" and all(.[]; type == "number" and . > 0)) and
       ($snapshot.orphan_listeners | type == "array" and all(.[]; type == "string" and startswith("/run/orchard-worker/"))) and
       ($snapshot.launch_gate | IN("closed", "open"))
    then
      if ($snapshot.escaped_agent_pids | length) > 0 or ($snapshot.escaped_worker_pids | length) > 0 or
         ($snapshot.foreign_pids | length) > 0 or ($snapshot.orphan_listeners | length) > 0
      then "blocked_ambiguous_ownership"
      elif $snapshot.launch_gate == "open" and ($snapshot.agent_processes | length) == 0
      then "blocked_open_gate_without_agent"
      elif ($snapshot.agent_processes | length) == 0 and ($worker_processes | length) > 0
      then "recovery_required_owned_survivors"
      elif ($snapshot.agent_processes | length) == 0 and ($worker_processes | length) == 0 and
           ([$snapshot.worker_leaves[].listeners[]] | length) > 0
      then "recovery_required_owned_stale_listeners"
      elif ($snapshot.agent_processes | length) == 0 and ($worker_processes | length) == 0
      then "stopped_empty"
      else "running_owned"
      end
    else error("invalid custody snapshot") end
  ' "$snapshot" || orchard_source_worker_custody_fail "custody snapshot is invalid or ambiguous"
}

orchard_source_worker_custody_validate_launch() {
  local policy=$1 manifest=$2 request=$3
  orchard_source_worker_custody_validate_policy "$policy" || return $?
  orchard_source_worker_custody_validate_installation "$policy" "$manifest" || return $?
  jq -e --slurpfile policy "$policy" --slurpfile manifest "$manifest" '
    (keys | sort) == ["generation", "installation_uuid", "node_uuid", "provider", "provider_sha256", "request_uuid"] and
    .installation_uuid == $manifest[0].installation_uuid and
    (.request_uuid | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")) and
    $manifest[0].worker_custody.node_uuid != null and
    .node_uuid == $manifest[0].worker_custody.node_uuid and
    (.generation | type == "number" and . >= 1 and floor == .) and
    . as $request |
    any($policy[0].providers[];
      .name == $request.provider and
      .sha256 == $request.provider_sha256 and
      .generation == $request.generation and
      .activation == "authorized")
  ' "$request" >/dev/null || orchard_source_worker_custody_fail "launch request is unauthorized or ambiguous"
  printf 'authorized_metadata_only\n'
}
