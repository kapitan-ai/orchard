#!/usr/bin/env bash

set -euo pipefail

if [[ "$(uname -s)" != "Linux" ]]; then
  printf 'test-linux-portable-core: Linux host required\n' >&2
  exit 69
fi

EXCLUDES=(
  --exclude integration
  --exclude macos
  --exclude mlx_smoke
  --exclude mlx_benchmark
)

# Optional bounded lane report (docs/tooling.md). When
# ORCHARD_LINUX_PORTABLE_REPORT_DIR is unset, every command runs exactly as in
# a plain `set -e` script. When it is set, each command's output still streams
# to stdout, a private temporary copy is parsed for allowlisted facts and then
# deleted, and the command's own exit status always decides this script's.
REPORT_DIR="${ORCHARD_LINUX_PORTABLE_REPORT_DIR:-}"
REPORT_HELPER="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ci/linux-portable-validation-report.sh"
EXPECTED_STEPS=10
step_index=0
current_step=none
capture_dir=""
interrupted=""

# Reporting failures are warnings only. Neither the helper nor the warning
# itself (for example on an unwritable stderr) may change the lane result.
report() {
  local command_name="$1"
  shift

  "$REPORT_HELPER" "$command_name" "$REPORT_DIR" "$@" ||
    printf 'test-linux-portable-core: report %s failed; command status is unaffected\n' "$command_name" >&2 ||
    true
  return 0
}

now_ms() {
  local micros

  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    micros="${EPOCHREALTIME//[!0-9]/}"
    printf '%s\n' "$((micros / 1000))"
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

# EXIT trap: every command here is guarded so the original status survives.
finish_report() {
  local status="$1"
  local reason=completed

  if [[ -n "$interrupted" ]]; then
    reason="signal_$interrupted"
  elif [[ "$status" -ne 0 ]]; then
    reason=failed
  fi
  report run-end "$status" "$reason" "$current_step" || true
  if [[ -n "$capture_dir" ]]; then
    rm -f -- "$capture_dir"/step-*.log 2>/dev/null || true
    rmdir -- "$capture_dir" 2>/dev/null || true
  fi
  exit "$status"
}

run_step() {
  local label="$1"
  local kind="$2"
  local status=0
  local capture=""
  local capture_status=unavailable
  local started
  local finished
  local pipe_status=()
  shift 2

  if [[ -z "$REPORT_DIR" ]]; then
    "$@" || status=$?
    [[ "$status" -eq 0 ]] || exit "$status"
    return 0
  fi

  step_index=$((step_index + 1))
  current_step="$step_index"
  started="$(now_ms)" || started=0
  if [[ -n "$capture_dir" ]]; then
    capture="$capture_dir/step-$step_index.log"
    set +e
    "$@" | tee "$capture"
    pipe_status=("${PIPESTATUS[@]}")
    set -e
    status="${pipe_status[0]}"
    capture_status=ok
    [[ "${pipe_status[1]}" -eq 0 ]] || capture_status=failed
  else
    "$@" || status=$?
  fi
  finished="$(now_ms)" || finished=0

  report step "$step_index" "$label" "$kind" "$status" "$((finished - started))" "$capture" "$capture_status" || true
  [[ -z "$capture" ]] || rm -f -- "$capture" 2>/dev/null || true
  current_step=none
  [[ "$status" -eq 0 ]] || exit "$status"
}

if [[ -n "$REPORT_DIR" ]]; then
  capture_dir="$(mktemp -d "${TMPDIR:-/tmp}/orchard-portable-capture.XXXXXX" 2>/dev/null)" || capture_dir=""
  trap 'finish_report "$?"' EXIT
  trap 'interrupted=int; exit 130' INT
  trap 'interrupted=term; exit 143' TERM
  report run-start "$EXPECTED_STEPS" || true
fi

run_step mix-test exunit mise exec -- mix test "${EXCLUDES[@]}"
run_step mix-test-cover exunit mise exec -- mix test --cover "${EXCLUDES[@]}"

run_step tokenizer-ruff-format none mise exec -- uv run --locked --directory native/orchard_tokenizer ruff format --check
run_step tokenizer-ruff-check none mise exec -- uv run --locked --directory native/orchard_tokenizer ruff check
run_step tokenizer-pytest pytest mise exec -- uv run --locked --directory native/orchard_tokenizer pytest
run_step tokenizer-pytest-cov pytest mise exec -- uv run --locked --directory native/orchard_tokenizer pytest --cov

run_step worker-ruff-format none mise exec -- uv run --locked --directory native/orchard_worker_mlx ruff format --check
run_step worker-ruff-check none mise exec -- uv run --locked --directory native/orchard_worker_mlx ruff check
run_step worker-pytest pytest mise exec -- uv run --locked --directory native/orchard_worker_mlx \
  pytest tests/test_backends.py tests/test_service.py
run_step worker-pytest-cov pytest mise exec -- uv run --locked --directory native/orchard_worker_mlx \
  pytest --cov=orchard_worker_mlx tests/test_backends.py tests/test_service.py
