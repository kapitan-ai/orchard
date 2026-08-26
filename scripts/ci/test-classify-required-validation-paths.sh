#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLASSIFIER="$REPO_ROOT/scripts/ci/classify-required-validation-paths.sh"

assert_case() {
  local name="$1"
  local expected="$2"
  shift 2
  local actual

  actual="$(printf '%s\n' "$@" | "$CLASSIFIER" | tr '\n' ' ')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'classification case failed: %s\nexpected: %s\nactual:   %s\n' \
      "$name" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_case ordinary-docs \
  'portable=false conformance=false macos=false mlx=false packaging=false ' \
  docs/local-dev.md README.md
assert_case controller-only \
  'portable=true conformance=true macos=false mlx=false packaging=false ' \
  apps/orchard_controller/lib/orchard/api/router.ex
assert_case tokenizer \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  native/orchard_tokenizer/src/orchard_tokenizer/cli.py
assert_case macos-packaging \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  packaging/app/Sources/OrchardApp/main.swift
assert_case mlx-provider \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  native/orchard_worker_mlx/src/orchard_worker_mlx/runtime.py
assert_case worker-protocol \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  native/orchard_worker_mlx/proto/orchard/worker/v1/worker_runtime.proto
assert_case worker-package-readme \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  native/orchard_worker_mlx/README.md
assert_case tokenizer-package-readme \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  native/orchard_tokenizer/README.md
assert_case retained-macos-helper-consumer \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/lib/orchard_cli/secret_tty.ex
assert_case retained-macos-test \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/test/orchard_cli/commands/console_pty_test.exs
assert_case macos-pty-support \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  apps/orchard_cli/test/support/console_pty_harness.c
assert_case macos-test-helper \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_cli/test/test_helper.exs
assert_case source-to-doc-rename \
  'portable=true conformance=true macos=false mlx=false packaging=false ' \
  apps/orchard_controller/lib/orchard/api/router.ex docs/router.md
assert_case normative-contract \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  SPEC.md
assert_case shared-protocol \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  proto/orchard_cluster.proto
assert_case accepted-openspec \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  openspec/specs/portability-validation/spec.md
assert_case root-toolchain \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  mise.toml
assert_case workflow \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  .github/workflows/required-validation.yml

printf 'required validation path-classification tests passed\n'
