#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

mise exec -- mix test \
  apps/orchard_shared/test/orchard/runtime_endpoint/domain_test.exs \
  apps/orchard_shared/test/orchard/runtime_endpoint/grpc_mapping_test.exs \
  apps/orchard_node_agent/test/orchard/node/runtime_endpoint_mapper_test.exs \
  apps/orchard_node_agent/test/orchard/node/tool_capability_catalog_test.exs \
  apps/orchard_node_agent/test/orchard/node/worker_runtime_adapter_test.exs \
  apps/orchard_controller/test/orchard/runtime_endpoint/grpc_compatibility_mapper_test.exs \
  apps/orchard_controller/test/orchard/dispatch/dispatch_capability_gate_test.exs \
  apps/orchard_controller/test/orchard/dispatch_capacity/evaluator_test.exs \
  apps/orchard_controller/test/orchard/scheduler/single_node_test.exs \
  apps/orchard_cli/test/orchard_cli/lifecycle_system_test.exs \
  apps/orchard_cli/test/orchard_cli/commands/lifecycle_support_test.exs
