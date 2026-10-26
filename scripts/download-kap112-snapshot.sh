#!/usr/bin/env bash
set -euo pipefail

readonly VLLM_IMAGE="vllm/vllm-openai:v0.27.1@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967"
readonly VLLM_IMAGE_ID="sha256:e0cfcfcb9b86e2c2d0d52a93689773f20f380cb8e050a24ce550c44f6f55c5eb"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
container_engine="${ORCHARD_CONTAINER_ENGINE:-docker}"
proof_root=""
temp_root=""
cidfile=""
container_id=""
ownership_label=""
container_name=""
child_pid=""
requested_status=""

usage() {
  printf 'usage: scripts/download-kap112-snapshot.sh --proof-root DIR\n' >&2
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

capture_container_id() {
  if [[ -z "$container_id" && -n "$cidfile" && -s "$cidfile" ]]; then
    container_id="$(cat -- "$cidfile")" || return 1
  fi
}

container_is_present() {
  local output
  output="$($container_engine container ls --all --no-trunc \
    --filter "id=$1" --format '{{.ID}}')" || return 2
  [[ "$output" == "$1" ]]
}

cleanup() {
  local failed=0 label state attempt
  if ! capture_container_id; then
    printf 'error: unable to recover KAP-112 download container ownership\n' >&2
    failed=1
  fi
  if [[ -n "$container_id" ]]; then
    if label="$($container_engine container inspect \
      --format '{{index .Config.Labels "com.orchard.kap112.download"}}' \
      "$container_id" 2>/dev/null)"; then
      if [[ "$label" != "$ownership_label" ]]; then
        printf 'error: refusing to stop download container whose ownership label changed\n' >&2
        failed=1
      elif ! "$container_engine" rm --force "$container_id" >/dev/null; then
        printf 'error: failed to remove owned KAP-112 download container\n' >&2
        failed=1
      fi
    else
      state=0
      container_is_present "$container_id" || state=$?
      if [[ "$state" -ne 1 ]]; then
        printf 'error: unable to prove owned KAP-112 download container state\n' >&2
        failed=1
      fi
    fi
  fi
  [[ -z "$child_pid" ]] || wait "$child_pid" 2>/dev/null || true
  child_pid=""
  for attempt in {1..100}; do
    state=0
    [[ -z "$container_id" ]] || container_is_present "$container_id" || state=$?
    [[ -z "$container_id" || "$state" -eq 1 ]] && break
    sleep 0.1
  done
  if [[ -n "$container_id" && "$state" -ne 1 ]]; then
    printf 'error: owned KAP-112 download container remains or is unobservable\n' >&2
    failed=1
  fi
  [[ -z "$temp_root" ]] || rm -rf -- "$temp_root"
  [[ -z "$temp_root" || ! -e "$temp_root" ]] || failed=1
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

request_stop() {
  requested_status=$2
  exit "$2"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --proof-root)
      [[ "$#" -ge 2 ]] || { usage; exit 64; }
      proof_root="$2"
      shift 2
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

[[ -n "$proof_root" ]] || { usage; exit 64; }
for tool in "$container_engine" id openssl realpath stat; do
  command -v "$tool" >/dev/null || fail "required command not found: $tool"
done

proof_root="$(realpath "$proof_root")"
[[ -d "$proof_root" ]] || fail "proof root does not exist"
[[ "$(stat -c %a "$proof_root")" == "700" ]] || fail "proof root must have mode 0700"
[[ "$(stat -c %u:%g "$proof_root")" == "$(id -u):$(id -g)" ]] ||
  fail "proof root must be owned by the invoking user"
[[ ! -e "$proof_root/model" && ! -L "$proof_root/model" &&
   ! -e "$proof_root/model-evidence.json" && ! -L "$proof_root/model-evidence.json" ]] ||
  fail "snapshot destinations already exist"

engine_host="$("$container_engine" context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" ||
  fail "unable to inspect container engine endpoint"
[[ "$engine_host" == unix://* ]] || fail "container engine must use a local Unix socket"
actual_image_id="$("$container_engine" image inspect --format '{{.Id}}' "$VLLM_IMAGE" 2>/dev/null)" ||
  fail "accepted vLLM image is not cached; refusing to pull"
[[ "$actual_image_id" == "$VLLM_IMAGE_ID" ]] || fail "cached vLLM image identity drifted"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/orchard-kap112-download.XXXXXX")"
chmod 0700 "$temp_root"
cidfile="$temp_root/container.cid"
ownership_label="$(openssl rand -hex 16)"
container_name="orchard-kap112-download-$(id -u)-${ownership_label:0:12}"
trap finish EXIT
trap 'request_stop INT 130' INT
trap 'request_stop TERM 143' TERM

container_id="$($container_engine create --pull=never --rm \
  --name "$container_name" \
  --cidfile "$cidfile" \
  --label "com.orchard.kap112.download=$ownership_label" \
  --network bridge \
  --user "$(id -u):$(id -g)" \
  --env HOME=/proof/state \
  --env HF_HOME=/proof/state/.cache/huggingface \
  --entrypoint /usr/bin/python3.12 \
  --mount "type=bind,src=$repo_root/scripts/kap112_verify_hf_snapshot.py,dst=/proof/verify.py,readonly" \
  --mount "type=bind,src=$repo_root/scripts/fixtures/kap112,dst=/proof/fixtures/kap112,readonly" \
  --mount "type=bind,src=$proof_root,dst=/proof/state" \
  "$VLLM_IMAGE" \
  /proof/verify.py /proof/state/model /proof/state/model-evidence.json)"
[[ -n "$container_id" ]] || fail "unable to capture KAP-112 download container identity"
"$container_engine" start --attach "$container_id" &
child_pid=$!
set +e
wait "$child_pid"
status=$?
set -e
wait "$child_pid" 2>/dev/null || true
child_pid=""
[[ "$status" -eq 0 ]] || exit "$status"

[[ -d "$proof_root/model" && ! -L "$proof_root/model" &&
   -r "$proof_root/model" && -x "$proof_root/model" &&
   -f "$proof_root/model-evidence.json" && ! -L "$proof_root/model-evidence.json" &&
   -r "$proof_root/model-evidence.json" ]] ||
  fail "snapshot download did not produce readable owner outputs"
[[ "$(stat -Lc %u:%g "$proof_root/model")" == "$(id -u):$(id -g)" ]] ||
  fail "snapshot directory ownership drifted"
[[ "$(stat -Lc %u:%g "$proof_root/model-evidence.json")" == "$(id -u):$(id -g)" ]] ||
  fail "snapshot evidence ownership drifted"
chmod 0600 "$proof_root/model-evidence.json"
