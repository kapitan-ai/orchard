#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EVALUATOR="$REPO_ROOT/scripts/ci/evaluate-required-validation.sh"

run_case() {
  local expected="$1"
  local name="$2"
  shift 2

  if env "$@" "$EVALUATOR" >/dev/null 2>&1; then
    actual=pass
  else
    actual=fail
  fi

  if [[ "$actual" != "$expected" ]]; then
    printf 'required-gate case failed: %s (expected %s, got %s)\n' \
      "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

COMMON=(
  CHANGES_RESULT=success
  PORTABLE_REQUIRED=true PORTABLE_RESULT=success
  CONFORMANCE_REQUIRED=true CONFORMANCE_RESULT=success
  MACOS_REQUIRED=false MACOS_RESULT=skipped
  MLX_REQUIRED=false MLX_RESULT=skipped
  PACKAGING_REQUIRED=false PACKAGING_RESULT=skipped
  OPENSPEC_REQUIRED=true OPENSPEC_RESULT=success
)

run_case pass applicable-lanes-pass "${COMMON[@]}"
run_case fail required-lane-fails "${COMMON[@]}" PORTABLE_RESULT=failure
run_case fail required-lane-skips "${COMMON[@]}" CONFORMANCE_RESULT=skipped
run_case fail inapplicable-lane-runs "${COMMON[@]}" MACOS_RESULT=success
run_case fail classifier-fails "${COMMON[@]}" CHANGES_RESULT=failure

run_case pass all-lanes-skipped \
  CHANGES_RESULT=success \
  PORTABLE_REQUIRED=false PORTABLE_RESULT=skipped \
  CONFORMANCE_REQUIRED=false CONFORMANCE_RESULT=skipped \
  MACOS_REQUIRED=false MACOS_RESULT=skipped \
  MLX_REQUIRED=false MLX_RESULT=skipped \
  PACKAGING_REQUIRED=false PACKAGING_RESULT=skipped \
  OPENSPEC_REQUIRED=false OPENSPEC_RESULT=skipped

printf 'required validation aggregate-gate tests passed\n'
