#!/usr/bin/env bash
set -euo pipefail

readonly VLLM_IMAGE="vllm/vllm-openai:v0.27.1@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967"
readonly VLLM_IMAGE_ID="sha256:e0cfcfcb9b86e2c2d0d52a93689773f20f380cb8e050a24ce550c44f6f55c5eb"
readonly GPU_UUID="${ORCHARD_KAP112_GPU_UUID:-}"
readonly SERVED_MODEL="orchard-qwen3.8-27b-poc"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
snapshot_root="${ORCHARD_KAP112_SNAPSHOT_ROOT:-}"
container_engine="${ORCHARD_CONTAINER_ENGINE:-docker}"
container_name="${ORCHARD_KAP112_VLLM_CONTAINER_NAME:-orchard-kap112-vllm-${UID}}"
ready_attempts="${ORCHARD_KAP112_VLLM_READY_ATTEMPTS:-600}"
port=58080
model_dir=""
evidence_file=""
temp_root=""
cidfile=""
owned_container_id=""
ownership_label=""
child_pid=""
child_pgid=""
provider_pid=""
requested_status=""
command_signal_failed=0
pre_gpu_processes=""
pre_volumes=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/with-kap112-vllm-poc.sh --model-dir DIR --evidence FILE -- COMMAND [ARG...]

Runs COMMAND while supervising the exact KAP-112 loopback-only vLLM tuple.
The immutable model snapshot must already be downloaded and verified by
scripts/kap112_verify_hf_snapshot.py under a separately approved Gate-2 run.
ORCHARD_KAP112_GPU_UUID must name the owner-approved GPU; there is no default.
ORCHARD_KAP112_SNAPSHOT_ROOT is required; model and evidence must be beneath it.
EOF
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

port_state() {
  local output
  if ! output="$(ss -H -ltn "sport = :$port" 2>/dev/null)"; then
    printf 'unknown\n'
  elif [[ -n "$output" ]]; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
}

container_id_by_name() {
  local output id name
  output="$("$container_engine" container ls --all --no-trunc \
    --format '{{.ID}} {{.Names}}')" || return 2
  while read -r id name; do
    [[ "$name" != "$container_name" ]] || printf '%s\n' "$id"
  done <<<"$output"
  return 0
}

container_id_is_present() {
  local container_id=$1 output
  output="$($container_engine container ls --all --no-trunc \
    --filter "id=$container_id" --format '{{.ID}}')" || return 2
  [[ "$output" == "$container_id" ]]
}

gpu_processes() {
  nvidia-smi --query-compute-apps=gpu_uuid,pid --format=csv,noheader,nounits 2>/dev/null |
    awk -F, -v gpu="$GPU_UUID" '{gsub(/ /, "", $1); gsub(/ /, "", $2); if ($1 == gpu) print $2}' |
    sort -n
}

capture_owned_container_id() {
  if [[ -z "$owned_container_id" && -n "$cidfile" && -s "$cidfile" ]]; then
    owned_container_id="$(cat -- "$cidfile")" || return 1
  fi
  if [[ -z "$owned_container_id" && -n "$ownership_label" ]]; then
    owned_container_id="$("$container_engine" container ls --all --no-trunc \
      --filter "label=com.orchard.kap112.vllm=$ownership_label" --format '{{.ID}}')" || return 1
  fi
}

signal_owned_command() {
  local signal=$1
  [[ -n "$child_pgid" ]] || return 0
  if ! kill -s "$signal" -- "-$child_pgid" 2>/dev/null; then
    # A vanished group is a benign race; failed observation is not absence.
    if [[ "$(process_group_state)" != absent ]]; then
      printf 'error: failed to signal owned command group with %s\n' "$signal" >&2
      command_signal_failed=1
    fi
  fi
}

process_group_state() {
  local output
  [[ -n "$child_pgid" ]] || { printf 'absent\n'; return; }
  if ! output="$(ps -eo pgid=,stat= 2>/dev/null)"; then
    printf 'unobservable\n'
  else
    awk -v group="$child_pgid" '$1 == group { found = 1 }
      END { print found ? "running" : "absent" }' <<<"$output"
  fi
}

request_stop() {
  local signal=$1 status=$2
  requested_status="$status"
  signal_owned_command "$signal"
  exit "$status"
}

terminate_owned_command() {
  local attempt state
  [[ -n "$child_pgid" ]] || return "$command_signal_failed"
  if [[ "$(process_group_state)" != absent ]]; then
    signal_owned_command TERM
    for attempt in {1..50}; do
      [[ "$(process_group_state)" != absent ]] || break
      sleep 0.1
    done
    if [[ "$(process_group_state)" != absent ]]; then
      signal_owned_command KILL
    fi
  fi
  for attempt in {1..50}; do
    if [[ -n "$child_pid" && "$(process_state "$child_pid")" == absent ]]; then
      wait "$child_pid" 2>/dev/null || true
      child_pid=""
    fi
    state="$(process_group_state)"
    [[ "$state" != absent ]] || break
    sleep 0.1
  done
  if [[ "$state" != absent ]]; then
    printf 'error: owned command group remains or is unobservable after bounded cleanup\n' >&2
    return 1
  fi
  [[ -z "$child_pid" ]] || wait "$child_pid" 2>/dev/null || true
  child_pid=""
  child_pgid=""
  return "$command_signal_failed"
}

process_state() {
  local pid=$1 output
  [[ -n "$pid" ]] || { printf 'absent\n'; return; }
  if ! output="$(ps -eo pid=,stat= 2>/dev/null)"; then
    printf 'unobservable\n'
  else
    awk -v pid="$pid" '$1 == pid && $2 !~ /^Z/ { found=1 }
      END { print found ? "running" : "absent" }' <<<"$output"
  fi
}

terminate_provider_client() {
  local attempt signal failed=0
  [[ -n "$provider_pid" ]] || return 0
  for attempt in {1..50}; do
    [[ "$(process_state "$provider_pid")" != absent ]] || break
    sleep 0.1
  done
  for signal in TERM KILL; do
    [[ "$(process_state "$provider_pid")" != absent ]] || break
    if ! kill -s "$signal" "$provider_pid" 2>/dev/null; then
      [[ "$(process_state "$provider_pid")" == absent ]] || failed=1
    fi
    for attempt in {1..50}; do
      [[ "$(process_state "$provider_pid")" != absent ]] || break
      sleep 0.1
    done
  done
  if [[ "$(process_state "$provider_pid")" != absent ]]; then
    printf 'error: provider client remains or is unobservable after bounded cleanup\n' >&2
    return 1
  fi
  wait "$provider_pid" 2>/dev/null || true
  provider_pid=""
  return "$failed"
}

cleanup() {
  local failed=0 state label attempt post_gpu_processes post_volumes
  if ! capture_owned_container_id; then
    printf 'error: unable to recover KAP-112 vLLM ownership\n' >&2
    failed=1
  fi
  terminate_owned_command || failed=1

  if [[ -n "$owned_container_id" ]]; then
    if label="$($container_engine container inspect \
      --format '{{index .Config.Labels "com.orchard.kap112.vllm"}}' \
      "$owned_container_id" 2>/dev/null)"; then
      if [[ "$label" != "$ownership_label" ]]; then
        printf 'error: refusing to stop vLLM container whose ownership label changed\n' >&2
        failed=1
      else
        "$container_engine" stop --time 30 "$owned_container_id" >/dev/null 2>&1 || true
        state=0
        container_id_is_present "$owned_container_id" || state=$?
        if [[ "$state" -eq 0 ]]; then
          if ! "$container_engine" rm --force "$owned_container_id" >/dev/null; then
            for attempt in {1..100}; do
              state=0
              container_id_is_present "$owned_container_id" || state=$?
              [[ "$state" -eq 1 ]] && break
              sleep 0.1
            done
            if [[ "$state" -ne 1 ]]; then
              printf 'error: failed to remove owned KAP-112 vLLM container\n' >&2
              failed=1
            fi
          fi
        elif [[ "$state" -ne 1 ]]; then
          printf 'error: unable to prove owned KAP-112 vLLM container state\n' >&2
          failed=1
        fi
      fi
    else
      state=0
      container_id_is_present "$owned_container_id" || state=$?
      if [[ "$state" -ne 1 ]]; then
        printf 'error: unable to prove owned KAP-112 vLLM container state\n' >&2
        failed=1
      fi
    fi
  fi
  terminate_provider_client || failed=1

  for attempt in {1..100}; do
    state=0
    [[ -z "$owned_container_id" ]] || container_id_is_present "$owned_container_id" || state=$?
    [[ -z "$owned_container_id" || "$state" -eq 1 ]] && break
    sleep 0.1
  done
  if [[ -n "$owned_container_id" && "$state" -ne 1 ]]; then
    printf 'error: owned KAP-112 vLLM container remains or is unobservable\n' >&2
    failed=1
  fi

  for attempt in {1..100}; do
    state="$(port_state)"
    [[ "$state" != "present" ]] && break
    sleep 0.1
  done
  if [[ "$state" != "absent" ]]; then
    printf 'error: unable to prove KAP-112 vLLM port is clear\n' >&2
    failed=1
  fi

  if post_gpu_processes="$(gpu_processes)"; then
    if [[ "$post_gpu_processes" != "$pre_gpu_processes" ]]; then
      printf 'error: selected GPU process baseline was not restored\n' >&2
      failed=1
    fi
  else
    printf 'error: unable to prove selected GPU process baseline\n' >&2
    failed=1
  fi

  if post_volumes="$($container_engine volume ls --quiet)"; then
    if [[ "$post_volumes" != "$pre_volumes" ]]; then
      printf 'error: container volume inventory changed during KAP-112 vLLM run\n' >&2
      failed=1
    fi
  else
    printf 'error: unable to prove container volume inventory\n' >&2
    failed=1
  fi

  [[ -z "$temp_root" ]] || rm -rf -- "$temp_root"
  if [[ -n "$temp_root" && -e "$temp_root" ]]; then
    printf 'error: KAP-112 vLLM temporary state remains\n' >&2
    failed=1
  fi
  if [[ "$failed" -eq 0 ]]; then
    printf '==> Cleanup verified: owned command group, vLLM port, container, volume, GPU, and temporary state restored\n'
  fi
  return "$failed"
}

finish() {
  local status=$?
  trap - EXIT
  trap ':' INT TERM
  if ! cleanup; then
    status=1
  fi
  if [[ -n "$requested_status" && "$status" -eq 0 ]]; then
    status="$requested_status"
  fi
  exit "$status"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --model-dir)
      [[ "$#" -ge 2 ]] || { usage; exit 64; }
      model_dir="$2"
      shift 2
      ;;
    --evidence)
      [[ "$#" -ge 2 ]] || { usage; exit 64; }
      evidence_file="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[[ -n "$model_dir" && -n "$evidence_file" && "$#" -gt 0 ]] || { usage; exit 64; }
[[ -n "$GPU_UUID" ]] || fail "ORCHARD_KAP112_GPU_UUID is required"
[[ "$GPU_UUID" =~ ^GPU-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  fail "ORCHARD_KAP112_GPU_UUID must be a single GPU UUID"
[[ -n "$snapshot_root" ]] || fail "ORCHARD_KAP112_SNAPSHOT_ROOT is required"
[[ -d "$snapshot_root" ]] || fail "ORCHARD_KAP112_SNAPSHOT_ROOT must be an existing directory"
[[ "$ready_attempts" =~ ^[1-9][0-9]*$ ]] || fail "readiness attempts must be positive"
[[ -d "$model_dir" ]] || fail "verified model directory is missing"
[[ -f "$evidence_file" ]] || fail "verified model evidence is missing"
for tool in "$container_engine" ss curl nvidia-smi openssl ps awk grep sort realpath setsid mise tail; do
  command -v "$tool" >/dev/null || fail "required command not found: $tool"
done
snapshot_root="$(realpath "$snapshot_root")"
model_dir="$(realpath "$model_dir")"
evidence_file="$(realpath "$evidence_file")"
[[ "$model_dir" != *,* ]] || fail "model mount source must not contain commas"
[[ "$model_dir" == "${snapshot_root%/}/"* && "$evidence_file" == "${snapshot_root%/}/"* ]] ||
  fail "model and evidence must remain beneath ORCHARD_KAP112_SNAPSHOT_ROOT"
mise exec -- uv run --directory "$repo_root/native/orchard_worker_mlx" python \
  "$repo_root/scripts/kap112_verify_hf_snapshot.py" --verify "$model_dir" "$evidence_file" \
  >/dev/null || fail "model snapshot does not match its exact evidence"
engine_host="$("$container_engine" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" ||
  fail "unable to inspect container engine endpoint"
[[ "$engine_host" == unix://* ]] || fail "container engine must use a local Unix socket"
"$container_engine" info >/dev/null 2>&1 || fail "unable to query local container engine"
actual_image_id="$("$container_engine" image inspect --format '{{.Id}}' "$VLLM_IMAGE" 2>/dev/null)" ||
  fail "accepted vLLM image is not cached; refusing to pull"
[[ "$actual_image_id" == "$VLLM_IMAGE_ID" ]] || fail "cached vLLM image identity drifted"

case "$(port_state)" in
  present) fail "vLLM port is already occupied: $port" ;;
  unknown) fail "unable to observe vLLM port before mutation" ;;
esac
existing_container_id="$(container_id_by_name)" || fail "unable to observe container names before mutation"
[[ -z "$existing_container_id" ]] || fail "KAP-112 vLLM container name is already present"
pre_gpu_processes="$(gpu_processes)" || fail "unable to inspect selected GPU"
[[ -z "$pre_gpu_processes" ]] || fail "selected KAP-112 GPU is already in use"
pre_volumes="$($container_engine volume ls --quiet)" || fail "unable to capture volume pre-state"

trap finish EXIT
trap 'request_stop INT 130' INT
trap 'request_stop TERM 143' TERM
temp_root="$(mktemp -d "${TMPDIR:-/tmp}/orchard-kap112-vllm.XXXXXX")"
chmod 0700 "$temp_root"
cidfile="$temp_root/container.cid"
ownership_label="$(openssl rand -hex 16)"

owned_container_id="$("$container_engine" create --pull=never --rm \
  --name "$container_name" \
  --cidfile "$cidfile" \
  --label "com.orchard.kap112.vllm=$ownership_label" \
  --network host \
  --gpus "device=$GPU_UUID" \
  --shm-size 1g \
  --mount "type=bind,src=$model_dir,dst=/model,readonly" \
  "$VLLM_IMAGE" \
  --model /model \
  --served-model-name "$SERVED_MODEL" \
  --host 127.0.0.1 \
  --port "$port" \
  --dtype bfloat16 \
  --kv-cache-dtype auto \
  --max-model-len 139264 \
  --max-num-seqs 1 \
  --gpu-memory-utilization 0.80)"
[[ -n "$owned_container_id" ]] || fail "unable to capture KAP-112 vLLM container identity"
"$container_engine" start --attach "$owned_container_id" >"$temp_root/vllm.log" 2>&1 &
provider_pid=$!

ready=0
for ((attempt = 1; attempt <= ready_attempts; attempt++)); do
  [[ -z "$requested_status" ]] || exit "$requested_status"
  provider_state="$(process_state "$provider_pid")"
  [[ "$provider_state" != unobservable ]] || fail "unable to observe provider before readiness"
  if [[ "$provider_state" == absent ]]; then
    set +e
    wait "$provider_pid"
    provider_status=$?
    set -e
    provider_pid=""
    tail -n 40 "$temp_root/vllm.log" >&2 || true
    fail "KAP-112 vLLM exited before readiness with status $provider_status"
  fi
  if response="$(curl --silent --show-error --fail --max-time 2 \
    "http://127.0.0.1:${port}/v1/models" 2>/dev/null)" &&
    [[ "$response" == *"\"id\":\"$SERVED_MODEL\""* ||
       "$response" == *"\"id\": \"$SERVED_MODEL\""* ]]; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" -eq 1 ]] || fail "KAP-112 vLLM did not become ready with exact served identity"

setsid -- "$@" &
child_pid=$!
child_pgid="$child_pid"
while :; do
  # Query the full process table: ps -p uses failure for both absence and errors.
  process_table="$(ps -eo pid=,stat=)" || fail "unable to observe supervised processes"
  if ! awk -v pid="$provider_pid" '$1 == pid && $2 !~ /^Z/ { found=1 } END { exit !found }' <<<"$process_table"; then
    fail "KAP-112 vLLM provider exited after readiness"
  fi
  container_running="$("$container_engine" container inspect --format '{{.State.Running}}' "$owned_container_id")" ||
    fail "unable to observe provider container after readiness"
  [[ "$container_running" == true ]] || fail "KAP-112 vLLM container exited after readiness"
  awk -v pid="$child_pid" '$1 == pid && $2 !~ /^Z/ { found=1 } END { exit !found }' <<<"$process_table" || break
  sleep 0.1
done
set +e
wait "$child_pid"
status=$?
set -e
wait "$child_pid" 2>/dev/null || true
child_pid=""
exit "$status"
