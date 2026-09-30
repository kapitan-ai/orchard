#!/usr/bin/env bash
#
# Tests Orchard.app and DMG assembly lane selection and its workflow wiring
# under the Distribution Pause Control (SPEC.md §11.0, openspec
# portability-validation "Paused Distribution Assembly Lanes Are Inapplicable").
# Paused and active resolution are exercised in copied fixture trees, so
# these tests pass unchanged when an approved change resumes distribution.
#
# shellcheck disable=SC2016 # Workflow assertions match literal ${{ }} expressions.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RESOLVER_RELATIVE="scripts/ci/resolve-app-distribution-lane.sh"
LIB_RELATIVE="scripts/lib/distribution-control.sh"
WORKFLOW="$REPO_ROOT/.github/workflows/required-validation.yml"
CLASSIFIER="$REPO_ROOT/scripts/ci/classify-required-validation-paths.sh"
EVALUATOR="$REPO_ROOT/scripts/ci/evaluate-required-validation.sh"

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

# Prints the resolver output for a push-style (all lanes) classification.
push_classification() {
  printf '%s=true\n' portable conformance macos mlx packaging |
    "$1/$RESOLVER_RELATIVE" 2>/dev/null
}

# Prints the resolver output for a pull request that changes the given paths.
pr_classification() {
  local repo="$1"
  shift
  printf '%s\n' "$@" | "$CLASSIFIER" | "$repo/$RESOLVER_RELATIVE" 2>/dev/null
}

# Feeds resolver output to the aggregate gate evaluator with each required
# lane reporting success and each other lane reporting skipped. An optional
# second argument overrides the assembly lane result.
gate_accepts() {
  local output="$1"
  local assembly_result="${2:-}"
  local envs=(CHANGES_RESULT=success)
  local lane
  local key
  local required
  local result

  for lane in portable conformance macos mlx packaging app_distribution; do
    key="$(printf '%s' "$lane" | tr '[:lower:]' '[:upper:]')"
    required="$(sed -n "s/^$lane=//p" <<<"$output")"
    result=skipped
    [[ "$required" != "true" ]] || result=success
    if [[ "$lane" == "app_distribution" && -n "$assembly_result" ]]; then
      result="$assembly_result"
    fi
    envs+=("${key}_REQUIRED=$required" "${key}_RESULT=$result")
  done
  if grep -Fxq 'portable=true' <<<"$output" || grep -Fxq 'conformance=true' <<<"$output"; then
    envs+=(OPENSPEC_REQUIRED=true OPENSPEC_RESULT=success)
  else
    envs+=(OPENSPEC_REQUIRED=false OPENSPEC_RESULT=skipped)
  fi
  env "${envs[@]}" "$EVALUATOR" >/dev/null 2>&1
}

paused="$(make_fixture paused $'state=paused\n')"
active="$(make_fixture active $'# Approved resume fixture.\nstate=active\n')"

assert_resolves paused-packaging "$paused" true false
assert_resolves paused-no-packaging "$paused" false false
assert_resolves active-packaging "$active" true true
assert_resolves active-no-packaging "$active" false false

# The real resolver follows whatever the committed control declares, so this
# holds both while paused and after an approved resume.
# shellcheck source=scripts/lib/distribution-control.sh
source "$REPO_ROOT/$LIB_RELATIVE"
orchard_distribution_read_state "$REPO_ROOT"
committed_expected=false
[[ "$ORCHARD_DISTRIBUTION_STATE" != "active" ]] || committed_expected=true
assert_resolves committed-packaging "$REPO_ROOT" true "$committed_expected"
assert_resolves committed-no-packaging "$REPO_ROOT" false false

packaging_path='packaging/app/Sources/OrchardApp/main.swift'
portable_path='apps/orchard_controller/lib/orchard/api/router.ex'

# Paused: push and packaging PRs skip the assembly lane, and the gate passes
# only when that lane is skipped.
for output in "$(push_classification "$paused")" "$(pr_classification "$paused" "$packaging_path")"; do
  grep -Fxq 'packaging=true' <<<"$output" || fail 'paused classification lost packaging'
  grep -Fxq 'app_distribution=false' <<<"$output" ||
    fail 'paused classification selected the assembly lane'
  gate_accepts "$output" || fail 'gate rejected a paused run with the assembly lane skipped'
  if gate_accepts "$output" success; then
    fail 'gate accepted a paused run where the assembly lane ran'
  fi
done

# Resume regression: switching the fixture control to active selects the
# assembly lane for push and packaging PRs, and the gate then requires it.
for output in "$(push_classification "$active")" "$(pr_classification "$active" "$packaging_path")"; do
  grep -Fxq 'app_distribution=true' <<<"$output" ||
    fail 'active classification did not select the assembly lane'
  gate_accepts "$output" || fail 'gate rejected an active run with the assembly lane passing'
  if gate_accepts "$output" skipped; then
    fail 'gate accepted an active run where the assembly lane was skipped'
  fi
  if gate_accepts "$output" failure; then
    fail 'gate accepted an active run where the assembly lane failed'
  fi
done

# Non-packaging PRs never select the assembly lane, even when active.
for repo in "$paused" "$active"; do
  output="$(pr_classification "$repo" apps/orchard_controller/test/orchard/api/router_test.exs)"
  grep -Fxq 'app_distribution=false' <<<"$output" ||
    fail 'non-packaging change selected the assembly lane'
  gate_accepts "$output" || fail 'gate rejected a non-packaging run'
done
output="$(pr_classification "$active" "$portable_path")"
grep -Fxq 'packaging=true' <<<"$output" || fail 'release-composition change lost packaging'
grep -Fxq 'app_distribution=true' <<<"$output" ||
  fail 'active release-composition change did not select the assembly lane'

missing="$(make_fixture missing '')"
assert_resolves missing-control "$missing" true false
malformed="$(make_fixture malformed $'state=active\nstate=active\n')"
assert_resolves duplicate-control "$malformed" true false
unsupported="$(make_fixture unsupported $'state=Active\n')"
assert_resolves unsupported-control "$unsupported" true false

env_output="$(printf 'packaging=true\n' |
  env ORCHARD_DISTRIBUTION_STATE=active ORCHARD_DISTRIBUTION_CONTROL_PATH="$active/packaging/distribution-control" \
    REPO_ROOT="$active" CDPATH="$active" \
    "$paused/$RESOLVER_RELATIVE" 2>/dev/null)"
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
# scripts/verify-app-signing.sh, reached by test-app-signing.sh and
# test-build-dmg.sh, needs the pinned toolchain through `mise exec`.
grep -Fq 'mise exec' "$REPO_ROOT/scripts/verify-app-signing.sh" ||
  fail 'verify-app-signing.sh no longer uses mise; revisit the assembly lane toolchain step'
mise_line="$(grep -nF 'uses: jdx/mise-action@' <<<"$assembly_job" | head -n 1 | cut -d: -f1)"
signing_line="$(grep -nF 'scripts/test-app-signing.sh' <<<"$assembly_job" | head -n 1 | cut -d: -f1)"
[[ -n "$mise_line" && -n "$signing_line" && "$mise_line" -lt "$signing_line" ]] ||
  fail 'assembly lane must install the pinned mise toolchain before the assembly tests'

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
