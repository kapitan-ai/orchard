#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$REPO_ROOT/scripts/with-kap112-vllm-poc.sh"
TMP_ROOT="$(mktemp -d)"

cleanup() {
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'test failed: %s\n' "$1" >&2
  exit 1
}

assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "missing '$1' in $2"
}

make_case() {
  local root=$1
  mkdir -p "$root/bin" "$root/state" "$root/tmp" "$root/model"
  printf '%s\n' '{"model_id":"Qwen/Qwen3.8-27B","revision":"1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0","total_bytes":55615875685,"files":[]}' >"$root/evidence.json"

  cat >"$root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${FAKE_STATE:?}
log=${FAKE_LOG:?}
printf '%s\n' "$*" >>"$log"
case "${1:-} ${2:-}" in
  "context inspect") printf 'unix:///var/run/docker.sock\n' ;;
  "info ") ;;
  "image inspect")
    printf '%s\n' "${FAKE_IMAGE_ID:-sha256:e0cfcfcb9b86e2c2d0d52a93689773f20f380cb8e050a24ce550c44f6f55c5eb}"
    ;;
  "container ls")
    if [[ " $* " == *'{{.Names}}'* ]]; then
      [[ -z "${FAKE_EXISTING_NAME:-}" ]] || printf 'preexisting-id %s\n' "$FAKE_EXISTING_NAME"
    elif [[ -f "$state/present" ]]; then
      printf 'fixture-id\n'
    fi
    ;;
  "container inspect")
    [[ -f "$state/present" ]]
    if [[ " $* " == *'{{.State.Running}}'* ]]; then
      [[ ! -f "$state/container-exited" ]] && printf 'true\n' || printf 'false\n'
    else
      cat "$state/label"
    fi
    ;;
  "volume ls") printf '%s' "${FAKE_VOLUMES:-}" ;;
  "create --pull=never")
    cidfile=""
    previous=""
    for argument in "$@"; do
      if [[ "$previous" == "--cidfile" ]]; then
        cidfile="$argument"
      elif [[ "$previous" == "--label" ]]; then
        printf '%s' "${argument#*=}" >"$state/label"
      fi
      previous="$argument"
    done
    [[ -n "$cidfile" ]]
    printf 'fixture-id' >"$cidfile"
    touch "$state/present"
    printf 'fixture-id\n'
    ;;
  "start --attach")
    if [[ "${FAKE_START_FAIL:-0}" == "1" ]]; then
      printf 'fixture attach failed before start\n' >&2
      exit 8
    fi
    touch "$state/running"
    if [[ "${FAKE_PROVIDER_EXIT:-0}" == "1" ]]; then
      printf 'fixture provider failed during startup\n' >&2
      rm -f "$state/running" "$state/present"
      exit 9
    fi
    if [[ "${FAKE_PROVIDER_AFTER_READY:-0}" != "0" ]]; then
      while [[ ! -f "$state/command-ran" ]]; do sleep 0.02; done
      if [[ "$FAKE_PROVIDER_AFTER_READY" == client ]]; then
        exit 0
      fi
      touch "$state/container-exited"
    fi
    while [[ -f "$state/present" ]]; do sleep 0.02; done
    ;;
  "stop --time")
    if [[ -f "$state/running" ]]; then
      rm -f "$state/running"
      [[ "${FAKE_STOP_LEAVES_PRESENT:-0}" == "1" ]] || rm -f "$state/present"
    fi
    ;;
  "rm --force")
    rm -f "$state/running" "$state/present"
    [[ "${FAKE_REMOVE_RACE:-0}" != "1" ]]
    ;;
  *) printf 'unexpected fake docker invocation: %s\n' "$*" >&2; exit 99 ;;
esac
EOF

  cat >"$root/bin/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_PORT_BUSY:-0}" == "1" ]]; then
  printf 'LISTEN 0 4096 127.0.0.1:58080 0.0.0.0:*\n'
fi
EOF

  cat >"$root/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${FAKE_GPU_PROCESSES:-}"
EOF

  cat >"$root/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_READY_STALL:-0}" == "1" ]]; then
  sleep 0.2
  exit 22
fi
printf '%s\n' '{"data":[{"id":"orchard-qwen3.8-27b-poc"}]}'
EOF

  cat >"$root/bin/mise" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_SNAPSHOT_INVALID:-0}" != "1" ]]
EOF

  cat >"$root/bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fedcba9876543210fedcba9876543210\n'
EOF
  cat >"$root/bin/setsid" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$FAKE_STATE/group"
exec /usr/bin/setsid "$@"
EOF
  cat >"$root/bin/ps" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == '-eo pgid=,stat=' ]]; then
  [[ "${FAKE_GROUP_UNKNOWN:-0}" != 1 ]] || exit 42
  if [[ "${FAKE_GROUP_UNSETTLED:-0}" == 1 && -f "$FAKE_STATE/killed" ]]; then
    printf '%s S\n' "$(cat "$FAKE_STATE/group")"
    exit 0
  fi
  if [[ "${FAKE_GROUP_ZOMBIE:-0}" == 1 && -f "$FAKE_STATE/killed" ]]; then
    printf '%s Z\n' "$(cat "$FAKE_STATE/group")"
    exit 0
  fi
fi
exec /usr/bin/ps "$@"
EOF
  cat >"$root/signal-env" <<'EOF'
kill() {
  if [[ "${1:-}" == -s ]]; then
    [[ "$2" != KILL ]] || touch "$FAKE_STATE/killed"
    if [[ "${FAKE_SIGNAL_FAILURE:-}" == "$2" ]]; then
      # Independently settle the real fixture after reporting a failed signal.
      if [[ "$2" == KILL ]]; then
        (sleep 0.3; /bin/kill -KILL -- "${@: -1}") &
      fi
      return 42
    fi
    builtin kill "$@"
  else
    builtin kill "$@"
  fi
}
EOF
  chmod +x "$root/bin/"*
}

run_case() {
  local root=$1 output=$2
  shift 2
  env \
    PATH="$root/bin:/usr/bin:/bin" \
    TMPDIR="$root/tmp" \
    FAKE_STATE="$root/state" \
    FAKE_LOG="$root/docker.log" \
    ORCHARD_CONTAINER_ENGINE=docker \
    ORCHARD_KAP112_VLLM_CONTAINER_NAME=orchard-kap112-vllm-fixture \
    ORCHARD_KAP112_VLLM_READY_ATTEMPTS=1 \
    ORCHARD_KAP112_GPU_UUID=GPU-00000000-0000-4000-8000-000000000000 \
    ORCHARD_KAP112_SNAPSHOT_ROOT="$root" \
    "$@" \
    "$HELPER" --model-dir "$root/model" --evidence "$root/evidence.json" -- \
    bash "$root/command.sh" >"$output" 2>&1
}

background_case() {
  local root=$1 output=$2
  shift 2
  exec env \
    PATH="$root/bin:/usr/bin:/bin" \
    TMPDIR="$root/tmp" \
    FAKE_STATE="$root/state" \
    FAKE_LOG="$root/docker.log" \
    ORCHARD_CONTAINER_ENGINE=docker \
    ORCHARD_KAP112_VLLM_CONTAINER_NAME=orchard-kap112-vllm-fixture \
    ORCHARD_KAP112_VLLM_READY_ATTEMPTS=1 \
    ORCHARD_KAP112_GPU_UUID=GPU-00000000-0000-4000-8000-000000000000 \
    ORCHARD_KAP112_SNAPSHOT_ROOT="$root" \
    "$@" \
    "$HELPER" --model-dir "$root/model" --evidence "$root/evidence.json" -- \
    bash "$root/command.sh" >"$output" 2>&1
}

SUCCESS="$TMP_ROOT/success"
make_case "$SUCCESS"
cat >"$SUCCESS/command.sh" <<EOF
#!/usr/bin/env bash
printf 'ran\n' >"$SUCCESS/state/command-ran"
EOF
chmod +x "$SUCCESS/command.sh"
for gpu_case in missing invalid; do
  GPU_REJECTION="$TMP_ROOT/gpu-$gpu_case"
  make_case "$GPU_REJECTION"
  gpu_value=""
  [[ "$gpu_case" == missing ]] || gpu_value="all"
  if run_case "$GPU_REJECTION" "$GPU_REJECTION/out" ORCHARD_KAP112_GPU_UUID="$gpu_value"; then
    fail "missing or invalid GPU selection was accepted"
  fi
  assert_grep 'ORCHARD_KAP112_GPU_UUID' "$GPU_REJECTION/out"
  [[ ! -e "$GPU_REJECTION/docker.log" ]] || fail "GPU rejection invoked container engine"
done
if env -u ORCHARD_KAP112_GPU_UUID "$HELPER" --model-dir "$SUCCESS/model" \
  --evidence "$SUCCESS/evidence.json" -- true >"$SUCCESS/unset.out" 2>&1; then
  fail "unset GPU selection was accepted"
fi
assert_grep 'ORCHARD_KAP112_GPU_UUID is required' "$SUCCESS/unset.out"
for snapshot_case in missing absent outside symlink; do
  SNAPSHOT_REJECTION="$TMP_ROOT/snapshot-$snapshot_case"
  make_case "$SNAPSHOT_REJECTION"
  snapshot_value=""
  case "$snapshot_case" in
    absent) snapshot_value="$SNAPSHOT_REJECTION/absent" ;;
    outside) snapshot_value="$SNAPSHOT_REJECTION/tmp" ;;
    symlink)
      snapshot_value="$SNAPSHOT_REJECTION"
      rmdir "$SNAPSHOT_REJECTION/model"
      ln -s "$SUCCESS/model" "$SNAPSHOT_REJECTION/model"
      ;;
  esac
  if run_case "$SNAPSHOT_REJECTION" "$SNAPSHOT_REJECTION/out" \
    ORCHARD_KAP112_SNAPSHOT_ROOT="$snapshot_value"; then
    fail "missing, absent, or escaped snapshot root was accepted"
  fi
  assert_grep 'ORCHARD_KAP112_SNAPSHOT_ROOT' "$SNAPSHOT_REJECTION/out"
  [[ ! -e "$SNAPSHOT_REJECTION/docker.log" ]] || fail "snapshot rejection invoked container engine"
done
if env -u ORCHARD_KAP112_SNAPSHOT_ROOT \
  ORCHARD_KAP112_GPU_UUID=GPU-00000000-0000-4000-8000-000000000000 \
  "$HELPER" --model-dir "$SUCCESS/model" --evidence "$SUCCESS/evidence.json" -- true \
  >"$SUCCESS/snapshot-unset.out" 2>&1; then
  fail "unset snapshot root was accepted"
fi
assert_grep 'ORCHARD_KAP112_SNAPSHOT_ROOT is required' "$SUCCESS/snapshot-unset.out"
run_case "$SUCCESS" "$SUCCESS/out"
[[ -f "$SUCCESS/state/command-ran" ]] || fail "supervised command did not run"
[[ ! -e "$SUCCESS/state/running" ]] || fail "vLLM container was not removed"
assert_grep 'create --pull=never --rm' "$SUCCESS/docker.log"
assert_grep '--network host' "$SUCCESS/docker.log"
assert_grep '--gpus device=GPU-00000000-0000-4000-8000-000000000000' "$SUCCESS/docker.log"
assert_grep '--mount type=bind,' "$SUCCESS/docker.log"
assert_grep 'dst=/model,readonly' "$SUCCESS/docker.log"
assert_grep '--host 127.0.0.1 --port 58080' "$SUCCESS/docker.log"
assert_grep '--max-model-len 139264 --max-num-seqs 1 --gpu-memory-utilization 0.80' "$SUCCESS/docker.log"
if grep -F -- '--disable-log-requests' "$SUCCESS/docker.log" >/dev/null; then
  fail "removed vLLM request-log flag was restored"
fi
assert_grep 'Cleanup verified' "$SUCCESS/out"
if find "$SUCCESS/tmp" -mindepth 1 -print -quit | grep -q .; then
  fail "temporary state was not removed"
fi

REMOVE_RACE="$TMP_ROOT/remove-race"
make_case "$REMOVE_RACE"
printf '#!/usr/bin/env bash\nexit 0\n' >"$REMOVE_RACE/command.sh"
chmod +x "$REMOVE_RACE/command.sh"
run_case "$REMOVE_RACE" "$REMOVE_RACE/out" \
  FAKE_STOP_LEAVES_PRESENT=1 FAKE_REMOVE_RACE=1
assert_grep 'Cleanup verified' "$REMOVE_RACE/out"

COMMAND_FAILURE="$TMP_ROOT/command-failure"
make_case "$COMMAND_FAILURE"
printf '#!/usr/bin/env bash\nexit 7\n' >"$COMMAND_FAILURE/command.sh"
chmod +x "$COMMAND_FAILURE/command.sh"
set +e
run_case "$COMMAND_FAILURE" "$COMMAND_FAILURE/out"
status=$?
set -e
[[ "$status" -eq 7 ]] || fail "supervised command status was not preserved"
[[ ! -e "$COMMAND_FAILURE/state/running" ]] || fail "failed command left container"

PROVIDER_FAILURE="$TMP_ROOT/provider-failure"
make_case "$PROVIDER_FAILURE"
printf '#!/usr/bin/env bash\ntouch %q\n' "$PROVIDER_FAILURE/state/command-ran" >"$PROVIDER_FAILURE/command.sh"
chmod +x "$PROVIDER_FAILURE/command.sh"
set +e
run_case "$PROVIDER_FAILURE" "$PROVIDER_FAILURE/out" \
  FAKE_PROVIDER_EXIT=1 FAKE_READY_STALL=1 ORCHARD_KAP112_VLLM_READY_ATTEMPTS=5
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "failed provider startup was accepted"
[[ ! -e "$PROVIDER_FAILURE/state/command-ran" ]] || fail "command ran after provider startup failure"
assert_grep 'fixture provider failed during startup' "$PROVIDER_FAILURE/out"
assert_grep 'vLLM exited before readiness with status 9' "$PROVIDER_FAILURE/out"

START_FAILURE="$TMP_ROOT/start-failure"
make_case "$START_FAILURE"
printf '#!/usr/bin/env bash\ntouch %q\n' "$START_FAILURE/state/command-ran" >"$START_FAILURE/command.sh"
chmod +x "$START_FAILURE/command.sh"
set +e
run_case "$START_FAILURE" "$START_FAILURE/out" \
  FAKE_START_FAIL=1 FAKE_READY_STALL=1 ORCHARD_KAP112_VLLM_READY_ATTEMPTS=5
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "failed provider attach was accepted"
[[ ! -e "$START_FAILURE/state/command-ran" ]] || fail "command ran after provider attach failure"
[[ ! -e "$START_FAILURE/state/present" ]] || fail "never-started provider survived cleanup"
assert_grep 'fixture attach failed before start' "$START_FAILURE/out"

PORT_COLLISION="$TMP_ROOT/port-collision"
make_case "$PORT_COLLISION"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PORT_COLLISION/command.sh"
chmod +x "$PORT_COLLISION/command.sh"
set +e
run_case "$PORT_COLLISION" "$PORT_COLLISION/out" FAKE_PORT_BUSY=1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "occupied provider port was accepted"
assert_grep 'vLLM port is already occupied' "$PORT_COLLISION/out"

IMAGE_DRIFT="$TMP_ROOT/image-drift"
make_case "$IMAGE_DRIFT"
printf '#!/usr/bin/env bash\nexit 0\n' >"$IMAGE_DRIFT/command.sh"
chmod +x "$IMAGE_DRIFT/command.sh"
set +e
run_case "$IMAGE_DRIFT" "$IMAGE_DRIFT/out" FAKE_IMAGE_ID=sha256:wrong
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "vLLM image drift was accepted"
assert_grep 'image identity drifted' "$IMAGE_DRIFT/out"

GPU_COLLISION="$TMP_ROOT/gpu-collision"
make_case "$GPU_COLLISION"
printf '#!/usr/bin/env bash\nexit 0\n' >"$GPU_COLLISION/command.sh"
chmod +x "$GPU_COLLISION/command.sh"
set +e
run_case "$GPU_COLLISION" "$GPU_COLLISION/out" \
  FAKE_GPU_PROCESSES='GPU-00000000-0000-4000-8000-000000000000, 4242'
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "busy selected GPU was accepted"
assert_grep 'selected KAP-112 GPU is already in use' "$GPU_COLLISION/out"

EVIDENCE_DRIFT="$TMP_ROOT/evidence-drift"
make_case "$EVIDENCE_DRIFT"
sed -i 's/55615875685/1/' "$EVIDENCE_DRIFT/evidence.json"
printf '#!/usr/bin/env bash\nexit 0\n' >"$EVIDENCE_DRIFT/command.sh"
chmod +x "$EVIDENCE_DRIFT/command.sh"
set +e
run_case "$EVIDENCE_DRIFT" "$EVIDENCE_DRIFT/out" FAKE_SNAPSHOT_INVALID=1
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "model evidence drift was accepted"
assert_grep 'model snapshot does not match its exact evidence' "$EVIDENCE_DRIFT/out"

READINESS_SIGNAL="$TMP_ROOT/readiness-signal"
make_case "$READINESS_SIGNAL"
printf '#!/usr/bin/env bash\ntouch %q\n' "$READINESS_SIGNAL/state/command-ran" >"$READINESS_SIGNAL/command.sh"
chmod +x "$READINESS_SIGNAL/command.sh"
set +e
background_case "$READINESS_SIGNAL" "$READINESS_SIGNAL/out" \
  FAKE_READY_STALL=1 ORCHARD_KAP112_VLLM_READY_ATTEMPTS=20 &
helper_pid=$!
sleep 0.1
kill -TERM "$helper_pid"
wait "$helper_pid"
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "readiness cancellation status was not preserved"
[[ ! -e "$READINESS_SIGNAL/state/command-ran" ]] || fail "command ran after readiness cancellation"
[[ ! -e "$READINESS_SIGNAL/state/running" ]] || fail "readiness cancellation left container"

IGNORES_TERM="$TMP_ROOT/ignores-term"
make_case "$IGNORES_TERM"
cat >"$IGNORES_TERM/command.sh" <<EOF
#!/usr/bin/env bash
trap '' TERM
touch "$IGNORES_TERM/state/command-ran"
while true; do sleep 1; done
EOF
chmod +x "$IGNORES_TERM/command.sh"
set +e
background_case "$IGNORES_TERM" "$IGNORES_TERM/out" &
helper_pid=$!
for _attempt in {1..50}; do
  [[ -e "$IGNORES_TERM/state/command-ran" ]] && break
  sleep 0.1
done
[[ -e "$IGNORES_TERM/state/command-ran" ]] || fail "TERM-ignoring command did not start"
kill -TERM "$helper_pid"
wait "$helper_pid"
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "command cancellation status was not preserved"
[[ ! -e "$IGNORES_TERM/state/running" ]] || fail "command cancellation left container"

SURVIVING_DESCENDANT="$TMP_ROOT/surviving-descendant"
make_case "$SURVIVING_DESCENDANT"
cat >"$SURVIVING_DESCENDANT/command.sh" <<EOF
#!/usr/bin/env bash
trap 'exit 0' TERM
bash -c 'trap "" TERM; while true; do sleep 1; done' &
printf '%s\n' "\$!" >"$SURVIVING_DESCENDANT/state/descendant-pid"
while true; do sleep 1; done
EOF
chmod +x "$SURVIVING_DESCENDANT/command.sh"
set +e
background_case "$SURVIVING_DESCENDANT" "$SURVIVING_DESCENDANT/out" &
helper_pid=$!
for _attempt in {1..50}; do
  [[ -s "$SURVIVING_DESCENDANT/state/descendant-pid" ]] && break
  sleep 0.1
done
[[ -s "$SURVIVING_DESCENDANT/state/descendant-pid" ]] || fail "descendant did not start"
descendant_pid="$(cat "$SURVIVING_DESCENDANT/state/descendant-pid")"
kill -TERM "$helper_pid"
wait "$helper_pid"
status=$?
set -e
[[ "$status" -eq 143 ]] || fail "descendant cancellation status was not preserved"
if ps -eo pid= | awk -v pid="$descendant_pid" '$1 == pid { found=1 } END { exit !found }'; then
  fail "TERM-ignoring descendant survived cleanup"
fi
[[ ! -e "$SURVIVING_DESCENDANT/state/running" ]] || fail "descendant cancellation left container"

NORMAL_DESCENDANT="$TMP_ROOT/normal-descendant"
make_case "$NORMAL_DESCENDANT"
cat >"$NORMAL_DESCENDANT/command.sh" <<EOF
bash -c 'trap "" TERM; touch "$NORMAL_DESCENDANT/state/descendant-ready"; while true; do sleep 1; done' &
printf '%s\n' "\$!" >"$NORMAL_DESCENDANT/state/descendant-pid"
while [[ ! -e "$NORMAL_DESCENDANT/state/descendant-ready" ]]; do sleep 0.02; done
exit 0
EOF
run_case "$NORMAL_DESCENDANT" "$NORMAL_DESCENDANT/out"
descendant_pid="$(cat "$NORMAL_DESCENDANT/state/descendant-pid")"
if ps -eo pid= | awk -v pid="$descendant_pid" '$1 == pid { found=1 } END { exit !found }'; then
  fail "normal command exit left a descendant"
fi
assert_grep 'Cleanup verified' "$NORMAL_DESCENDANT/out"

# Review item 7: literal names and mount grammar must fail before mutation.
for name_case in exact regex-similar substring; do
  ROOT="$TMP_ROOT/name-$name_case"
  make_case "$ROOT"
  printf 'exit 0\n' >"$ROOT/command.sh"
  existing='orchardXfixture'
  [[ "$name_case" != exact ]] || existing='orchard.fixture'
  [[ "$name_case" != substring ]] || existing='prefix-orchard.fixture-suffix'
  if run_case "$ROOT" "$ROOT/out" ORCHARD_KAP112_VLLM_CONTAINER_NAME=orchard.fixture \
    FAKE_EXISTING_NAME="$existing"; then
    [[ "$name_case" != exact ]] || fail "exact name collision accepted"
  else
    [[ "$name_case" == exact ]] || fail "nonliteral name collision rejected"
    assert_grep 'container name is already present' "$ROOT/out"
    ! grep -q '^create ' "$ROOT/docker.log" || fail "collision mutated engine"
  fi
done
ROOT="$TMP_ROOT/comma,source"
make_case "$ROOT"
if run_case "$ROOT" "$ROOT/out"; then fail "comma mount source accepted"; fi
assert_grep 'mount source must not contain commas' "$ROOT/out"
[[ ! -e "$ROOT/docker.log" ]] || fail "comma source invoked engine"

for provider_case in client container; do
  ROOT="$TMP_ROOT/after-ready-$provider_case"
  make_case "$ROOT"
  printf 'touch %q\nwhile true; do sleep 1; done\n' "$ROOT/state/command-ran" >"$ROOT/command.sh"
  if run_case "$ROOT" "$ROOT/out" FAKE_PROVIDER_AFTER_READY="$provider_case"; then
    fail "provider exit after readiness accepted"
  fi
  assert_grep 'after readiness' "$ROOT/out"
  assert_grep 'Cleanup verified' "$ROOT/out"
  [[ ! -e "$ROOT/state/present" ]] || fail "provider failure left container"
  group="$(cat "$ROOT/state/group")"
  if ps -eo pgid=,stat= | awk -v group="$group" '$1 == group { found=1 } END { exit !found }'; then
    fail "provider exit left owned command group"
  fi
done

for failure_case in TERM KILL unknown unsettled zombie; do
  ROOT="$TMP_ROOT/group-$failure_case"
  make_case "$ROOT"
  printf 'trap "" TERM\ntouch %q\nwhile true; do sleep 1; done\n' "$ROOT/state/command-ran" >"$ROOT/command.sh"
  options=(BASH_ENV="$ROOT/signal-env" FAKE_PROVIDER_AFTER_READY=client)
  case "$failure_case" in
    TERM|KILL) options+=(FAKE_SIGNAL_FAILURE="$failure_case") ;;
    unknown) options+=(FAKE_GROUP_UNKNOWN=1) ;;
    unsettled) options+=(FAKE_GROUP_UNSETTLED=1) ;;
    zombie) options+=(FAKE_GROUP_ZOMBIE=1) ;;
  esac
  started=$SECONDS
  if run_case "$ROOT" "$ROOT/out" "${options[@]}"; then fail "group failure accepted"; fi
  [[ $((SECONDS - started)) -lt 20 ]] || fail "group cleanup was not bounded"
  if [[ "$failure_case" == TERM || "$failure_case" == KILL ]]; then
    assert_grep "failed to signal owned command group with $failure_case" "$ROOT/out"
  else
    assert_grep 'group remains or is unobservable after bounded cleanup' "$ROOT/out"
  fi
  ! grep -q 'Cleanup verified' "$ROOT/out" || fail "unverified cleanup claimed success"
  [[ ! -e "$ROOT/state/present" ]] || fail "group failure skipped container cleanup"
done

printf 'KAP-112 vLLM supervisor tests passed (32 scenarios)\n'
