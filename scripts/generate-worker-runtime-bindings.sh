#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_ROOT="$REPO_ROOT"
PYTHON_TOOLING_ROOT="$REPO_ROOT/proto/orchard/worker/tooling"
PROTOC_GEN_ELIXIR_VERSION="0.16.0"

generated_output_paths() {
  printf '%s\n' \
    apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/common_pb2.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/common_pb2_grpc.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/events_pb2.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/events_pb2_grpc.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/runtime_pb2.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/runtime_pb2_grpc.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2_grpc.py \
    proto/orchard/worker/v1/worker_runtime.descriptor.pb
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-root)
      [[ $# -ge 2 ]] || {
        printf '%s\n' 'generate-worker-runtime-bindings: --output-root requires a value' >&2
        exit 2
      }
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --list-outputs)
      generated_output_paths
      exit 0
      ;;
    *)
      printf 'generate-worker-runtime-bindings: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$OUTPUT_ROOT" in
  /*) ;;
  *) OUTPUT_ROOT="$(pwd)/$OUTPUT_ROOT" ;;
esac

PLUGIN_PATH="$(command -v protoc-gen-elixir || true)"
if [[ -z "$PLUGIN_PATH" ]]; then
  MIX_ESCRIPT_DIRS=("${HOME}/.mix/escripts")
  if [[ -n "${MIX_HOME:-}" ]]; then
    MIX_ESCRIPT_DIRS=("$MIX_HOME/escripts" "${MIX_ESCRIPT_DIRS[@]}")
  fi

  for mix_escript_dir in "${MIX_ESCRIPT_DIRS[@]}"; do
    if [[ -x "$mix_escript_dir/protoc-gen-elixir" ]]; then
      PLUGIN_PATH="$mix_escript_dir/protoc-gen-elixir"
      break
    fi
  done
fi

if [[ -z "$PLUGIN_PATH" ]]; then
  printf '%s\n' \
    "protoc-gen-elixir not found; install the pinned generator with 'mise exec -- mix escript.install hex protobuf $PROTOC_GEN_ELIXIR_VERSION'" >&2
  exit 1
fi

ACTUAL_PLUGIN_VERSION="$($PLUGIN_PATH --version)"
if [[ "$ACTUAL_PLUGIN_VERSION" != "$PROTOC_GEN_ELIXIR_VERSION" ]]; then
  printf 'protoc-gen-elixir %s found, expected %s\n' \
    "$ACTUAL_PLUGIN_VERSION" "$PROTOC_GEN_ELIXIR_VERSION" >&2
  exit 1
fi

STAGE_ROOT="$(mktemp -d /tmp/orchard-worker-runtime-gen.XXXXXX)"
trap 'rm -rf "$STAGE_ROOT"' EXIT

PYTHON_STAGE="$STAGE_ROOT/python"
ELIXIR_STAGE="$STAGE_ROOT/elixir"
DESCRIPTOR_STAGE="$STAGE_ROOT/worker_runtime.descriptor.pb"
mkdir -p "$PYTHON_STAGE" "$ELIXIR_STAGE"

cd "$REPO_ROOT"

mise exec -- uv run --locked --directory "$PYTHON_TOOLING_ROOT" \
  python -m grpc_tools.protoc \
  -I "$REPO_ROOT/proto" \
  --python_out="$PYTHON_STAGE" \
  --grpc_python_out="$PYTHON_STAGE" \
  --descriptor_set_out="$DESCRIPTOR_STAGE" \
  --include_imports \
  "$REPO_ROOT/proto/cluster/v1/common.proto" \
  "$REPO_ROOT/proto/cluster/v1/events.proto" \
  "$REPO_ROOT/proto/cluster/v1/runtime.proto" \
  "$REPO_ROOT/proto/orchard/worker/v1/worker_runtime.proto"

mise exec -- uv run --locked --directory "$PYTHON_TOOLING_ROOT" \
  python -m grpc_tools.protoc \
  -I "$REPO_ROOT/proto" \
  --plugin="protoc-gen-elixir=$PLUGIN_PATH" \
  --elixir_out="plugins=grpc,package_prefix=Orchard:$ELIXIR_STAGE" \
  "$REPO_ROOT/proto/orchard/worker/v1/worker_runtime.proto"

RAW_ELIXIR="$ELIXIR_STAGE/orchard/worker/v1/worker_runtime.pb.ex"
COMPAT_ELIXIR="$STAGE_ROOT/worker_runtime.pb.ex"
sed \
  -e 's/Orchard\.Orchard\.Worker\.V1/Orchard.Node.Worker.V1/g' \
  -e 's/Cluster\.V1/Orchard.Cluster.V1/g' \
  "$RAW_ELIXIR" > "$COMPAT_ELIXIR"
mise exec -- mix format "$COMPAT_ELIXIR"

install_output() {
  local source="$1"
  local relative_path="$2"
  local destination="$OUTPUT_ROOT/$relative_path"

  mkdir -p "$(dirname "$destination")"
  install -m 0644 "$source" "$destination"
}

install_output "$COMPAT_ELIXIR" \
  apps/orchard_node_agent/lib/orchard/node/worker_runtime.pb.ex

for relative_path in \
  cluster/v1/common_pb2.py \
  cluster/v1/common_pb2_grpc.py \
  cluster/v1/events_pb2.py \
  cluster/v1/events_pb2_grpc.py \
  cluster/v1/runtime_pb2.py \
  cluster/v1/runtime_pb2_grpc.py \
  orchard/worker/v1/worker_runtime_pb2.py \
  orchard/worker/v1/worker_runtime_pb2_grpc.py; do
  install_output "$PYTHON_STAGE/$relative_path" \
    "native/orchard_worker_mlx/src/orchard_worker_mlx/generated/$relative_path"
done

install_output "$DESCRIPTOR_STAGE" \
  proto/orchard/worker/v1/worker_runtime.descriptor.pb

printf 'generated Worker Runtime Python and Elixir bindings under %s\n' "$OUTPUT_ROOT"
