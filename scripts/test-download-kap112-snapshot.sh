#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$repo_root/scripts/download-kap112-snapshot.sh"
temp_root="$(mktemp -d)"

cleanup() {
  rm -rf -- "$temp_root"
}
trap cleanup EXIT

fail() {
  printf 'test failed: %s\n' "$1" >&2
  exit 1
}

make_case() {
  local root=$1
  mkdir -p "$root/bin" "$root/proof" "$root/state" "$root/tmp"
  chmod 0700 "$root/proof"
  cat >"$root/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state=${FAKE_STATE:?}
printf '%s\n' "$*" >>"${FAKE_LOG:?}"
case "${1:-} ${2:-}" in
  "context inspect")
    [[ "${FAKE_ENDPOINT:-local}" != "error" ]] || exit 1
    [[ "${FAKE_ENDPOINT:-local}" == "local" ]] && printf 'unix:///var/run/docker.sock\n' || printf 'tcp://example:2375\n'
    ;;
  "image inspect")
    [[ "${FAKE_IMAGE:-exact}" != "missing" ]] || exit 1
    [[ "${FAKE_IMAGE:-exact}" == "exact" ]] &&
      printf '%s\n' 'sha256:e0cfcfcb9b86e2c2d0d52a93689773f20f380cb8e050a24ce550c44f6f55c5eb' || printf 'sha256:drift\n'
    ;;
  "container ls") [[ -f "$state/running" ]] && printf 'fixture-id\n' || true ;;
  "container inspect") [[ -f "$state/present" ]] && cat "$state/label" ;;
  "rm --force") rm -f "$state/running" "$state/present" ;;
  "create --pull=never")
    cidfile=""
    previous=""
    for argument in "$@"; do
      [[ "$previous" == "--cidfile" ]] && cidfile="$argument"
      [[ "$previous" == "--label" ]] && printf '%s' "${argument#*=}" >"$state/label"
      previous="$argument"
    done
    [[ -n "$cidfile" ]]
    printf 'fixture-id' >"$cidfile"
    touch "$state/present"
    printf 'fixture-id\n'
    ;;
  "start --attach")
    touch "$state/running"
    if [[ "${FAKE_STALL:-0}" == "1" ]]; then
      while [[ -f "$state/running" ]]; do sleep 0.05; done
      exit 143
    fi
    rm -f "$state/running" "$state/present"
    case "${FAKE_OUTPUT:-exact}" in
      exact) mkdir "$FAKE_PROOF_ROOT/model"; printf '{}\n' >"$FAKE_PROOF_ROOT/model-evidence.json" ;;
      symlink)
        mkdir "$FAKE_PROOF_ROOT/real-model"
        printf '{}\n' >"$FAKE_PROOF_ROOT/real-evidence.json"
        ln -s real-model "$FAKE_PROOF_ROOT/model"
        ln -s real-evidence.json "$FAKE_PROOF_ROOT/model-evidence.json"
        ;;
      unreadable) mkdir "$FAKE_PROOF_ROOT/model"; printf '{}\n' >"$FAKE_PROOF_ROOT/model-evidence.json"; chmod 000 "$FAKE_PROOF_ROOT/model-evidence.json" ;;
    esac
    ;;
  *) printf 'unexpected fake docker invocation: %s\n' "$*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$root/bin/docker"
  cat >"$root/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAKE_FOREIGN:-0}" == "1" && "${*: -1}" == *model-evidence.json && "${1:-}" == "-Lc" ]]; then
  printf '123:456\n'
else
  exec /usr/bin/stat "$@"
fi
EOF
  chmod +x "$root/bin/stat"
}

run_case() {
  local root=$1
  shift
  env PATH="$root/bin:/usr/bin:/bin" TMPDIR="$root/tmp" \
    ORCHARD_CONTAINER_ENGINE=docker FAKE_STATE="$root/state" \
    FAKE_LOG="$root/docker.log" FAKE_PROOF_ROOT="$root/proof" "$@" \
    "$helper" --proof-root "$root/proof" >"$root/out" 2>&1
}

SUCCESS="$temp_root/success"
make_case "$SUCCESS"
run_case "$SUCCESS"
grep -F -- "--user $(id -u):$(id -g)" "$SUCCESS/docker.log" >/dev/null || fail "owner identity missing"
create_line="$(grep '^create ' "$SUCCESS/docker.log")"
[[ "$create_line" == *'--pull=never --rm --name orchard-kap112-download-'* ]] || fail "immutable controls missing"
[[ "$create_line" == *'--network bridge'* ]] || fail "network drifted"
[[ "$create_line" == *'--env HOME=/proof/state --env HF_HOME=/proof/state/.cache/huggingface'* ]] || fail "owner cache path drifted"
[[ "$create_line" == *'--entrypoint /usr/bin/python3.12'* ]] || fail "interpreter drifted"
[[ "$create_line" == *'dst=/proof/verify.py,readonly'* && "$create_line" == *'dst=/proof/fixtures/kap112,readonly'* && "$create_line" == *'dst=/proof/state'* ]] || fail "mounts drifted"
[[ "$create_line" == *'vllm/vllm-openai:v0.27.1@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967 /proof/verify.py /proof/state/model /proof/state/model-evidence.json' ]] || fail "image or verifier arguments drifted"
[[ "$(stat -c %a "$SUCCESS/proof/model-evidence.json")" == "600" ]] || fail "evidence mode drifted"

for scenario in endpoint image; do
  root="$temp_root/$scenario"
  make_case "$root"
  set +e
  if [[ "$scenario" == endpoint ]]; then
    run_case "$root" FAKE_ENDPOINT=remote
  else
    run_case "$root" FAKE_IMAGE=drift
  fi
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$scenario drift passed"
  ! grep -q '^create ' "$root/docker.log" || fail "$scenario drift created container"
done

DANGLING="$temp_root/dangling"
make_case "$DANGLING"
ln -s absent "$DANGLING/proof/model-evidence.json"
set +e
run_case "$DANGLING"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "dangling destination passed"
[[ ! -e "$DANGLING/docker.log" ]] ||
  ! grep -q '^create ' "$DANGLING/docker.log" || fail "dangling destination created container"

SYMLINK_OUTPUT="$temp_root/symlink-output"
make_case "$SYMLINK_OUTPUT"
set +e
run_case "$SYMLINK_OUTPUT" FAKE_OUTPUT=symlink
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "symlinked output passed"

for output in unreadable foreign; do
  root="$temp_root/$output"
  make_case "$root"
  set +e
  if [[ "$output" == unreadable ]]; then
    run_case "$root" FAKE_OUTPUT=unreadable
  else
    run_case "$root" FAKE_FOREIGN=1
  fi
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$output output passed"
done

INTERRUPT="$temp_root/interrupt"
make_case "$INTERRUPT"
env PATH="$INTERRUPT/bin:/usr/bin:/bin" TMPDIR="$INTERRUPT/tmp" \
  ORCHARD_CONTAINER_ENGINE=docker FAKE_STATE="$INTERRUPT/state" \
  FAKE_LOG="$INTERRUPT/docker.log" FAKE_PROOF_ROOT="$INTERRUPT/proof" FAKE_STALL=1 \
  "$helper" --proof-root "$INTERRUPT/proof" >"$INTERRUPT/out" 2>&1 &
helper_pid=$!
for _attempt in {1..100}; do
  [[ -f "$INTERRUPT/state/running" ]] && break
  sleep 0.02
done
[[ -f "$INTERRUPT/state/running" ]] || fail "interrupt fixture did not start"
kill -TERM "$helper_pid"
set +e
wait "$helper_pid"
status=$?
set -e
[[ "$status" -ne 0 ]] || fail "interrupted helper succeeded"
[[ ! -e "$INTERRUPT/state/running" ]] || fail "interrupted helper left container"
[[ ! -e "$INTERRUPT/state/present" ]] || fail "interrupted helper left container metadata"
grep -F -- 'rm --force fixture-id' "$INTERRUPT/docker.log" >/dev/null || fail "interrupted helper did not remove owned container"

printf 'KAP-112 snapshot download helper tests passed\n'
