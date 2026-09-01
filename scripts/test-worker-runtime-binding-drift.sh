#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT="$(mktemp -d /tmp/orchard-worker-runtime-drift.XXXXXX)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

mkdir -p \
  "$FIXTURE_ROOT/apps/orchard_node_agent/lib/orchard/node" \
  "$FIXTURE_ROOT/native/orchard_worker_mlx/src/orchard_worker_mlx/generated" \
  "$FIXTURE_ROOT/proto/orchard/worker/v1"

cp "$REPO_ROOT/apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex" \
  "$FIXTURE_ROOT/apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex"
cp -R "$REPO_ROOT/native/orchard_worker_mlx/src/orchard_worker_mlx/generated/." \
  "$FIXTURE_ROOT/native/orchard_worker_mlx/src/orchard_worker_mlx/generated/"
cp "$REPO_ROOT/proto/orchard/worker/v1/worker_runtime.descriptor.pb" \
  "$FIXTURE_ROOT/proto/orchard/worker/v1/worker_runtime.descriptor.pb"

if ! "$REPO_ROOT/scripts/check-worker-runtime-bindings.sh" \
  --committed-root "$FIXTURE_ROOT" >/dev/null; then
  printf 'clean generated-output fixture was rejected\n' >&2
  exit 1
fi

printf '\n# deliberate drift regression\n' >> \
  "$FIXTURE_ROOT/apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex"

if "$REPO_ROOT/scripts/check-worker-runtime-bindings.sh" \
  --committed-root "$FIXTURE_ROOT" >/dev/null 2>&1; then
  printf 'deliberate generated-output drift was not rejected\n' >&2
  exit 1
fi

printf 'deliberate Worker Runtime binding drift was rejected\n'
