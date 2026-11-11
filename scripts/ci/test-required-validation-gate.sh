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
  APP_DISTRIBUTION_REQUIRED=false APP_DISTRIBUTION_RESULT=skipped
  OPENSPEC_REQUIRED=true OPENSPEC_RESULT=success
  SUPPLY_CHAIN_REQUIRED=false SUPPLY_CHAIN_RESULT=skipped
)

# Packaging change while the Distribution Pause Control is paused.
PAUSED_PACKAGING=(
  "${COMMON[@]}"
  MACOS_REQUIRED=true MACOS_RESULT=success
  PACKAGING_REQUIRED=true PACKAGING_RESULT=success
)

run_case pass applicable-lanes-pass "${COMMON[@]}"
run_case fail required-lane-fails "${COMMON[@]}" PORTABLE_RESULT=failure
run_case fail required-lane-skips "${COMMON[@]}" CONFORMANCE_RESULT=skipped
run_case fail inapplicable-lane-runs "${COMMON[@]}" MACOS_RESULT=success
run_case fail classifier-fails "${COMMON[@]}" CHANGES_RESULT=failure
run_case fail openspec-pin-check-fails "${COMMON[@]}" OPENSPEC_RESULT=failure
run_case fail required-openspec-pin-check-skips "${COMMON[@]}" OPENSPEC_RESULT=skipped
run_case fail empty-requirement "${COMMON[@]}" PORTABLE_REQUIRED=
run_case fail malformed-requirement "${COMMON[@]}" CONFORMANCE_REQUIRED=maybe

run_case pass supply-chain-lane-passes "${COMMON[@]}" \
  SUPPLY_CHAIN_REQUIRED=true SUPPLY_CHAIN_RESULT=success
run_case fail supply-chain-lane-fails "${COMMON[@]}" \
  SUPPLY_CHAIN_REQUIRED=true SUPPLY_CHAIN_RESULT=failure
run_case fail required-supply-chain-lane-skips "${COMMON[@]}" \
  SUPPLY_CHAIN_REQUIRED=true SUPPLY_CHAIN_RESULT=skipped
run_case fail inapplicable-supply-chain-lane-runs "${COMMON[@]}" SUPPLY_CHAIN_RESULT=success
run_case fail empty-supply-chain-requirement "${COMMON[@]}" SUPPLY_CHAIN_REQUIRED=

run_case pass paused-assembly-lane-skipped "${PAUSED_PACKAGING[@]}"
run_case fail paused-assembly-lane-runs "${PAUSED_PACKAGING[@]}" APP_DISTRIBUTION_RESULT=success
run_case fail paused-assembly-lane-fails "${PAUSED_PACKAGING[@]}" APP_DISTRIBUTION_RESULT=failure
run_case fail paused-packaging-lane-fails "${PAUSED_PACKAGING[@]}" PACKAGING_RESULT=failure
run_case pass resumed-assembly-lane-passes "${PAUSED_PACKAGING[@]}" \
  APP_DISTRIBUTION_REQUIRED=true APP_DISTRIBUTION_RESULT=success
run_case fail resumed-assembly-lane-fails "${PAUSED_PACKAGING[@]}" \
  APP_DISTRIBUTION_REQUIRED=true APP_DISTRIBUTION_RESULT=failure
run_case fail resumed-assembly-lane-skips "${PAUSED_PACKAGING[@]}" \
  APP_DISTRIBUTION_REQUIRED=true APP_DISTRIBUTION_RESULT=skipped
run_case fail assembly-without-packaging "${COMMON[@]}" \
  APP_DISTRIBUTION_REQUIRED=true APP_DISTRIBUTION_RESULT=success
run_case fail empty-assembly-requirement "${COMMON[@]}" APP_DISTRIBUTION_REQUIRED=
run_case fail malformed-assembly-requirement "${COMMON[@]}" APP_DISTRIBUTION_REQUIRED=paused

run_case pass all-lanes-skipped \
  CHANGES_RESULT=success \
  PORTABLE_REQUIRED=false PORTABLE_RESULT=skipped \
  CONFORMANCE_REQUIRED=false CONFORMANCE_RESULT=skipped \
  MACOS_REQUIRED=false MACOS_RESULT=skipped \
  MLX_REQUIRED=false MLX_RESULT=skipped \
  PACKAGING_REQUIRED=false PACKAGING_RESULT=skipped \
  APP_DISTRIBUTION_REQUIRED=false APP_DISTRIBUTION_RESULT=skipped \
  OPENSPEC_REQUIRED=false OPENSPEC_RESULT=skipped \
  SUPPLY_CHAIN_REQUIRED=false SUPPLY_CHAIN_RESULT=skipped

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

namespace_step="$(awk '
  /^      - name: Run Linux unreadable proc custody regression$/ { step = 1; next }
  step && /^        run: \|$/ { body = 1; next }
  body && /^          / { sub(/^          /, ""); print; next }
  body { exit }
' "$REPO_ROOT/.github/workflows/required-validation.yml")"
# Substitute only the sysctl existence check; no host namespace or sysctl is touched.
touch "$TMP_ROOT/userns-restriction"
namespace_step="${namespace_step//\/proc\/sys\/kernel\/apparmor_restrict_unprivileged_userns/$TMP_ROOT/userns-restriction}"

unshare() {
  printf '%s\n' "$NAMESPACE_OUTPUT"
  return "$NAMESPACE_STATUS"
}

sysctl() {
  if [[ "$1" == -n ]]; then
    printf '1\n'
  else
    printf '%s\n' "$2" >> "$RUNNER_TEMP/sysctl-writes"
  fi
}

sudo() { "$@"; }
export -f unshare sysctl sudo

namespace_case() {
  local expected="$1" output="$2" status="${3:-0}" actual
  rm -f "$TMP_ROOT/sysctl-writes"
  if RUNNER_TEMP="$TMP_ROOT" NAMESPACE_OUTPUT="$output" NAMESPACE_STATUS="$status" \
    bash -euo pipefail -c "$namespace_step" >/dev/null 2>&1; then
    actual=pass
  else
    actual=fail
  fi

  if [[ "$actual" != "$expected" ]]; then
    printf 'namespace gate failed: %s (expected %s, got %s)\n' "$output" "$expected" "$actual" >&2
    exit 1
  fi

  diff -u <(printf '%s\n' \
    kernel.apparmor_restrict_unprivileged_userns=0 \
    kernel.apparmor_restrict_unprivileged_userns=1) "$TMP_ROOT/sysctl-writes"
}

namespace_case pass 'Result: 1 passed, 25 excluded'
namespace_case pass 'Result: 1 passed'
namespace_case fail 'Result: 0 tests, 1 skipped, 25 excluded'
namespace_case fail 'There was no test executed'
namespace_case fail 'Result: 1 passed, 1 skipped, 24 excluded'
namespace_case fail 'Result: 2 passed, 24 excluded'
namespace_case fail 'Result: 1 failed, 25 excluded'
namespace_case fail 'Result: 1 passed, 25 excluded' 1

printf 'required validation aggregate-gate tests passed\n'
