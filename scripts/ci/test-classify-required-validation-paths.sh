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

assert_rejects() {
  local name="$1"
  local input="$2"
  local status=0

  printf '%s' "$input" | "$CLASSIFIER" >/dev/null 2>&1 || status=$?
  if [[ "$status" -eq 0 ]]; then
    printf 'classification case failed: %s\nexpected a non-zero exit, got 0\n' \
      "$name" >&2
    exit 1
  fi
}

assert_case ordinary-docs \
  'portable=false conformance=false macos=false mlx=false packaging=false ' \
  docs/local-dev.md README.md
assert_case unknown-nested-doc \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  docs/new-area/contract.md
assert_case unknown-nested-doc-support \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  docs/new-area/check.sh
assert_case unknown-top-level-doc-support \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  docs/check.sh
assert_case controller-only \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_controller/lib/orchard/api/router.ex
assert_case controller-release-boot \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_controller/lib/orchard/application.ex
assert_case app-test-only \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_controller/test/orchard/api/router_test.exs
assert_case tokenizer \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  native/orchard_tokenizer/src/orchard_tokenizer/cli.py
assert_case macos-packaging \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  packaging/app/Sources/OrchardApp/main.swift
assert_case distribution-pause-control \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  packaging/distribution-control
assert_case packaging-contract-readme \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  packaging/dmg/README.md
assert_case mlx-provider \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  native/orchard_worker_mlx/src/orchard_worker_mlx/runtime.py
assert_case worker-protocol \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  proto/orchard/worker/v1/worker_runtime.proto
assert_case worker-elixir-binding \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex
assert_case worker-binding-generator \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  scripts/generate-worker-runtime-bindings.sh
assert_case worker-binding-drift-check \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  scripts/check-worker-runtime-bindings.sh
assert_case worker-package-readme \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  native/orchard_worker_mlx/README.md
assert_case tokenizer-package-readme \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  native/orchard_tokenizer/README.md
assert_case worker-unknown-package-metadata \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  native/orchard_worker_mlx/MANIFEST.in
assert_case tokenizer-unknown-package-metadata \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  native/orchard_tokenizer/MANIFEST.in
assert_case retained-macos-helper-consumer \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/lib/orchard_cli/secret_tty.ex
assert_case retained-macos-test \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/test/orchard_cli/commands/console_pty_test.exs
assert_case case-tagged-macos-cluster-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_cli/test/orchard_cli/commands/cluster_test.exs
assert_case case-tagged-macos-status-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_cli/test/orchard_cli/commands/status_test.exs
assert_case case-tagged-macos-peer-grant-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_controller/test/orchard/beam_peer_grants_test.exs
assert_case bsd-stat-tokenizer-transport-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_controller/test/orchard/tokenizer_client_test.exs
assert_case bsd-stat-catalog-transport-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_controller/test/orchard/models/bundle_builder_test.exs
assert_case bsd-stat-preflight-transport-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_controller/test/orchard/models/safe_tokenization_preflight_test.exs
assert_case portable-shared-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_shared/test/orchard/runtime_endpoint/target_test.exs
assert_case macos-pty-support \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  apps/orchard_cli/test/support/console_pty_harness.c
assert_case macos-payload-wrapper-test \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  apps/orchard_cli/test/orchard_cli/packaging_wrapper_test.exs
assert_case macos-payload-script-test \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  apps/orchard_cli/test/orchard_cli/payload_wrapper_script_test.exs
assert_case portable-platform-acl \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/lib/orchard_cli/platform_acl.ex
assert_case portable-cluster-init \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/lib/orchard_cli/commands/cluster.ex
assert_case macos-test-helper \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_cli/test/test_helper.exs
assert_case source-to-doc-rename \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
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

# Retained macOS-tagged tests exercise application source across module and
# application boundaries, so every first-party application source, test, and
# child manifest change also selects the macOS host lane (SPEC.md §1.4).
assert_case new-cli-source \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/lib/orchard_cli/new_module.ex
assert_case new-controller-source \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_controller/lib/orchard/new_module.ex
assert_case new-controller-mix-task \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_controller/lib/mix/tasks/orchard.new_task.ex
assert_case new-node-agent-source \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_node_agent/lib/orchard/node/new_module.ex
assert_case new-shared-source \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  apps/orchard_shared/lib/orchard/new_module.ex
assert_case new-cli-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_cli/test/orchard_cli/new_module_test.exs
assert_case new-controller-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_controller/test/orchard/new_module_test.exs
assert_case new-node-agent-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_node_agent/test/orchard/node/new_module_test.exs
assert_case new-shared-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_shared/test/orchard/new_module_test.exs
assert_case shared-test-support \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_shared/test/support/new_support.ex
assert_case controller-test-fixture \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_controller/test/fixtures/new_fixture.json
assert_case cli-child-manifest \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/mix.exs
assert_case controller-child-manifest \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_controller/mix.exs
assert_case node-agent-child-manifest \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_node_agent/mix.exs
assert_case shared-child-manifest \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  apps/orchard_shared/mix.exs
assert_case cli-status-command \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/lib/orchard_cli/commands/status.ex
assert_case cli-lifecycle-support \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_cli/lib/orchard_cli/commands/lifecycle_support.ex
assert_case cli-lifecycle-support-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_cli/test/orchard_cli/commands/lifecycle_support_test.exs
assert_case controller-peer-grants \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_controller/lib/orchard/beam_peer_grants.ex
assert_case controller-peer-grant-control-listener \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_controller/lib/orchard/beam_peer_grants/control_listener.ex
assert_case controller-asset-without-macos \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  apps/orchard_controller/assets/js/app.js
assert_case controller-asset-lib-lookalike \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  apps/orchard_controller/assets/vendor/lib/topbar.js
assert_case controller-migration-without-macos \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  apps/orchard_controller/priv/repo/migrations/20260101000000_new.exs
assert_case cli-test-prefix-lookalike \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  apps/orchard_cli/testdata/fixture.txt
assert_case cli-top-level-file-without-macos \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  apps/orchard_cli/.formatter.exs
assert_case cli-nested-manifest-without-macos \
  'portable=true conformance=true macos=false mlx=false packaging=true ' \
  apps/orchard_cli/tools/mix.exs
assert_case macos-pty-fixture-stays-off-portable \
  'portable=false conformance=false macos=true mlx=false packaging=true ' \
  apps/orchard_cli/test/support/orchardctl_delayed_term_fixture.c
assert_case retained-macos-node-test \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_node_agent/test/orchard/node/beam_peer_grant_store_test.exs
assert_case node-macos-test-helper \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  apps/orchard_node_agent/test/test_helper.exs
assert_case docs-plus-cli-source \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  docs/local-dev.md apps/orchard_cli/lib/orchard_cli/commands/status.ex
assert_case docs-plus-controller-test \
  'portable=true conformance=true macos=true mlx=false packaging=false ' \
  README.md apps/orchard_controller/test/orchard/api/router_test.exs
assert_case asset-plus-shared-test \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  apps/orchard_controller/assets/js/app.js apps/orchard_shared/test/orchard/new_module_test.exs
assert_case shared-test-plus-mlx-provider \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  apps/orchard_shared/test/orchard/new_module_test.exs native/orchard_worker_mlx/src/orchard_worker_mlx/runtime.py
assert_case packaging-plus-node-test \
  'portable=true conformance=true macos=true mlx=false packaging=true ' \
  packaging/app/Sources/OrchardApp/main.swift apps/orchard_node_agent/test/orchard/node/new_module_test.exs
assert_case app-source-plus-unknown \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  apps/orchard_cli/lib/orchard_cli/commands/status.ex Dockerfile

assert_case unclassified-new-surface \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  Dockerfile
assert_case unclassified-path-overrides-docs-only \
  'portable=true conformance=true macos=true mlx=true packaging=true ' \
  docs/local-dev.md Dockerfile

assert_rejects empty-diff ''
assert_rejects blank-line-only-diff $'\n\n'

printf 'required validation path-classification tests passed\n'
