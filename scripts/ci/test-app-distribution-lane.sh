#!/usr/bin/env bash
#
# Tests Orchard.app and DMG assembly lane selection and its workflow wiring
# under the Distribution Pause Control (SPEC.md §11.0, openspec
# portability-validation "Paused Distribution Assembly Lanes Are Inapplicable").
# Active-state resolution is exercised only in copied fixture trees.
#
# shellcheck disable=SC2016 # Workflow assertions match literal ${{ }} expressions.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOLVER_RELATIVE="scripts/ci/resolve-app-distribution-lane.sh"
LIB_RELATIVE="scripts/lib/distribution-control.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/required-validation.yml"
CLASSIFIER="$REPO_ROOT/scripts/ci/classify-required-validation-paths.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/orchard-app-distribution-lane.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

fail() {
  printf 'app distribution lane test failed: %s\n' "$1" >&2
  exit 1
}

make_fixture() {
  local name="$1"
  local control="$2"
  local fixture="$TMP_ROOT/$name"

  mkdir -p "$fixture/scripts/ci" "$fixture/scripts/lib" "$fixture/packaging"
  cp -p "$REPO_ROOT/$RESOLVER_RELATIVE" "$fixture/$RESOLVER_RELATIVE"
  cp -p "$REPO_ROOT/$LIB_RELATIVE" "$fixture/$LIB_RELATIVE"
  if [[ -n "$control" ]]; then
    printf '%s' "$control" > "$fixture/packaging/distribution-control"
  fi
  printf '%s' "$fixture"
}

assert_resolves() {
  local name="$1"
  local repo="$2"
  local packaging="$3"
  local expected="$4"
  local actual

  actual="$(
    printf 'portable=true\nconformance=true\nmacos=true\nmlx=false\npackaging=%s\n' "$packaging" |
      "$repo/$RESOLVER_RELATIVE" 2>/dev/null | tr '\n' ' '
  )"
  local want="portable=true conformance=true macos=true mlx=false packaging=$packaging app_distribution=$expected "
  [[ "$actual" == "$want" ]] ||
    fail "$name: expected '$want', got '$actual'"
}

assert_rejects() {
  local name="$1"
  local input="$2"
  local status=0

  printf '%s' "$input" | "$REPO_ROOT/$RESOLVER_RELATIVE" >/dev/null 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || fail "$name: resolver accepted malformed input"
}

# Committed control: paused, so the assembly lane is never required.
assert_resolves committed-packaging "$REPO_ROOT" true false
assert_resolves committed-no-packaging "$REPO_ROOT" false false

# A full push-style classification also stays paused.
push_output="$(printf '%s=true\n' portable conformance macos mlx packaging |
  "$REPO_ROOT/$RESOLVER_RELATIVE" 2>/dev/null)"
grep -Fxq 'app_distribution=false' <<<"$push_output" ||
  fail 'push classification selected the paused assembly lane'

# A packaging-only path change still skips the assembly lane while paused.
pr_output="$(printf 'packaging/app/Sources/OrchardApp/main.swift\n' | "$CLASSIFIER" |
  "$REPO_ROOT/$RESOLVER_RELATIVE" 2>/dev/null)"
grep -Fxq 'packaging=true' <<<"$pr_output" || fail 'packaging path did not select packaging'
grep -Fxq 'app_distribution=false' <<<"$pr_output" ||
  fail 'packaging path selected the paused assembly lane'

active="$(make_fixture active $'# Approved resume fixture.\nstate=active\n')"
assert_resolves active-packaging "$active" true true
assert_resolves active-no-packaging "$active" false false

missing="$(make_fixture missing '')"
assert_resolves missing-control "$missing" true false
malformed="$(make_fixture malformed $'state=active\nstate=active\n')"
assert_resolves duplicate-control "$malformed" true false
unsupported="$(make_fixture unsupported $'state=Active\n')"
assert_resolves unsupported-control "$unsupported" true false

env_output="$(printf 'packaging=true\n' |
  env ORCHARD_DISTRIBUTION_STATE=active ORCHARD_DISTRIBUTION_CONTROL_PATH="$active/packaging/distribution-control" \
    "$REPO_ROOT/$RESOLVER_RELATIVE" 2>/dev/null)"
grep -Fxq 'app_distribution=false' <<<"$env_output" ||
  fail 'environment claims selected the paused assembly lane'

assert_rejects no-packaging $'portable=true\n'
assert_rejects empty ''
assert_rejects malformed-packaging $'packaging=maybe\n'
assert_rejects duplicate-packaging $'packaging=true\npackaging=false\n'
assert_rejects preclassified $'packaging=true\napp_distribution=true\n'

job_block() {
  local job="$1"

  awk -v job="  $job:" '
    $0 == job { capture = 1; print; next }
    capture && /^  [a-zA-Z0-9_-]+:/ { exit }
    capture { print }
  ' "$WORKFLOW"
}

changes_job="$(job_block changes)"
packaging_job="$(job_block packaging-validation)"
assembly_job="$(job_block app-distribution-validation)"
gate_job="$(job_block required-validation-gate)"

[[ -n "$packaging_job" && -n "$assembly_job" && -n "$gate_job" ]] ||
  fail 'expected packaging, assembly, and gate jobs in the workflow'

grep -Fq 'app_distribution: ${{ steps.classify.outputs.app_distribution }}' <<<"$changes_job" ||
  fail 'changes job does not export app_distribution'
[[ "$(grep -Fc 'scripts/ci/resolve-app-distribution-lane.sh' <<<"$changes_job")" -eq 2 ]] ||
  fail 'changes job must resolve app_distribution for push and pull request events'
grep -Fq 'scripts/test-distribution-control.sh' <<<"$changes_job" ||
  fail 'changes job does not run the distribution pause guard tests'
grep -Fq 'scripts/ci/test-app-distribution-lane.sh' <<<"$changes_job" ||
  fail 'changes job does not run the app distribution lane tests'

for assembly in test-build-app.sh test-app-signing.sh test-build-dmg.sh build-app.sh sign-app.sh build-dmg.sh; do
  if grep -Fq "scripts/$assembly" <<<"$packaging_job"; then
    fail "packaging-contract lane runs paused assembly entrypoint scripts/$assembly"
  fi
done
for retained in test-build-payload.sh test-payload-signing-contracts.sh test-app-service-lifecycle.sh \
  test-payload-orchardctl-controller-runtime.sh test-payload-orchardctl-console-pty.sh \
  test-payload-orchardctl-controller-release.sh; do
  grep -Fq "scripts/$retained" <<<"$packaging_job" ||
    fail "packaging-contract lane no longer runs scripts/$retained"
done
grep -Fq 'swift test --package-path packaging/app --enable-code-coverage' <<<"$packaging_job" ||
  fail 'packaging-contract lane no longer runs Swift coverage'

grep -Fq "if: needs.changes.outputs.app_distribution == 'true'" <<<"$assembly_job" ||
  fail 'assembly lane is not selected by app_distribution'
for assembly in test-build-app.sh test-app-signing.sh test-build-dmg.sh; do
  grep -Fq "scripts/$assembly" <<<"$assembly_job" ||
    fail "dormant assembly lane no longer runs scripts/$assembly"
done

grep -Fq -- '- app-distribution-validation' <<<"$gate_job" ||
  fail 'required gate does not need the assembly lane'
grep -Fq 'APP_DISTRIBUTION_REQUIRED: ${{ needs.changes.outputs.app_distribution }}' <<<"$gate_job" ||
  fail 'required gate does not pass the assembly requirement'
grep -Fq 'APP_DISTRIBUTION_RESULT: ${{ needs.app-distribution-validation.result }}' <<<"$gate_job" ||
  fail 'required gate does not pass the assembly result'
grep -Fq 'name: Required Orchard validation gate' <<<"$gate_job" ||
  fail 'required gate check name changed'

workflow_triggers="$(awk '/^on:/ { capture = 1; next } capture && /^[a-z]/ { exit } capture { print }' "$WORKFLOW")"
if grep -Eq 'paths(-ignore)?:' <<<"$workflow_triggers"; then
  fail 'workflow triggers must not use path filtering'
fi

printf 'app distribution lane tests passed\n'
