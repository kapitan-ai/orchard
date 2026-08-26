#!/usr/bin/env bash

set -euo pipefail

portable=false
conformance=false
macos=false
mlx=false
packaging=false

enable_all() {
  portable=true
  conformance=true
  macos=true
  mlx=true
  packaging=true
}

enable_macos_consumers() {
  portable=true
  conformance=true
  macos=true
  packaging=true
}

enable_portable_macos_tests() {
  portable=true
  conformance=true
  macos=true
}

saw_path=false

while IFS= read -r path; do
  [[ -n "$path" ]] || continue

  saw_path=true

  case "$path" in
    apps/orchard_shared/test/*)
      portable=true
      conformance=true
      ;;
    SPEC.md|AGENTS.md|mix.exs|mix.lock|mise.toml|Makefile|package.json|package-lock.json|config/*|rel/*|proto/*|openspec/*|.github/workflows/*|apps/orchard_shared/*)
      enable_all
      ;;
    docs/decisions/*|docs/architecture.md|docs/tooling.md|docs/process.md)
      enable_all
      ;;
    native/orchard_worker_mlx/README.md)
      portable=true
      conformance=true
      macos=true
      mlx=true
      packaging=true
      ;;
    native/orchard_tokenizer/README.md)
      portable=true
      conformance=true
      packaging=true
      ;;
    packaging/*|scripts/build-app.sh|scripts/build-dmg.sh|scripts/build-payload.sh|scripts/sign-app.sh|scripts/test-app-*|scripts/test-build-app.sh|scripts/test-build-dmg.sh|scripts/test-build-payload.sh|scripts/test-payload-*)
      macos=true
      packaging=true
      ;;
    docs/*)
      if [[ "$path" != docs/*.md || "$path" == docs/*/* ]]; then
        enable_all
      fi
      ;;
    README.md|CONTRIBUTING.md|CONTEXT-MAP.md|CLAUDE.md)
      ;;
    apps/orchard_cli/lib/orchard_cli/lifecycle_native.ex|apps/orchard_cli/lib/orchard_cli/lifecycle_system.ex|apps/orchard_cli/lib/orchard_cli/secret_tty.ex|apps/orchard_cli/lib/orchard_cli/commands/console.ex|apps/orchard_cli/lib/orchard_cli/commands/node_agent_stop.ex|apps/orchard_cli/test/orchard_cli/lifecycle_native_test.exs|apps/orchard_cli/test/orchard_cli/commands/console_pty_test.exs|apps/orchard_node_agent/lib/orchard/node/beam_peer_grant_store.ex|apps/orchard_node_agent/test/orchard/node/beam_peer_grant_store_test.exs)
      enable_macos_consumers
      ;;
    apps/orchard_cli/test/support/console_pty_harness.c|apps/orchard_cli/test/support/orchardctl_delayed_term_fixture.c)
      macos=true
      packaging=true
      ;;
    apps/orchard_cli/test/orchard_cli/packaging_wrapper_test.exs|apps/orchard_cli/test/orchard_cli/payload_wrapper_script_test.exs)
      macos=true
      packaging=true
      ;;
    apps/orchard_cli/test/support/console_pty_process.ex|apps/orchard_cli/test/support/flock_holder.swift|apps/orchard_cli/test/test_helper.exs|apps/orchard_node_agent/test/test_helper.exs)
      enable_portable_macos_tests
      ;;
    apps/orchard_cli/test/orchard_cli/commands/cluster_test.exs|apps/orchard_cli/test/orchard_cli/commands/status_test.exs|apps/orchard_controller/test/orchard/beam_peer_grants_test.exs|apps/orchard_controller/test/orchard/tokenizer_client_test.exs|apps/orchard_controller/test/orchard/models/bundle_builder_test.exs|apps/orchard_controller/test/orchard/models/safe_tokenization_preflight_test.exs)
      enable_portable_macos_tests
      ;;
    apps/orchard_cli/lib/orchard_cli/platform_acl.ex|apps/orchard_cli/lib/orchard_cli/commands/cluster.ex)
      enable_macos_consumers
      ;;
    native/orchard_worker_mlx/pyproject.toml|native/orchard_worker_mlx/uv.lock|native/orchard_worker_mlx/bin/*|native/orchard_worker_mlx/proto/*|native/orchard_worker_mlx/src/*)
      portable=true
      conformance=true
      macos=true
      mlx=true
      packaging=true
      ;;
    native/orchard_worker_mlx/*)
      portable=true
      conformance=true
      macos=true
      mlx=true
      packaging=true
      ;;
    native/orchard_tokenizer/pyproject.toml|native/orchard_tokenizer/uv.lock|native/orchard_tokenizer/bin/*|native/orchard_tokenizer/src/*)
      portable=true
      conformance=true
      packaging=true
      ;;
    native/orchard_tokenizer/*)
      portable=true
      conformance=true
      packaging=true
      ;;
    apps/orchard_controller/test/*|apps/orchard_node_agent/test/*|apps/orchard_cli/test/*)
      portable=true
      conformance=true
      ;;
    apps/orchard_controller/*|apps/orchard_node_agent/*|apps/orchard_cli/*)
      portable=true
      conformance=true
      packaging=true
      ;;
    scripts/ci/*|scripts/test-linux-portable-core.sh|scripts/test-provider-neutral-conformance.sh)
      enable_all
      ;;
    *)
      enable_all
      ;;
  esac
done

if [[ "$saw_path" != "true" ]]; then
  printf 'classify-required-validation-paths: no changed paths on stdin\n' >&2
  exit 1
fi

printf 'portable=%s\n' "$portable"
printf 'conformance=%s\n' "$conformance"
printf 'macos=%s\n' "$macos"
printf 'mlx=%s\n' "$mlx"
printf 'packaging=%s\n' "$packaging"
