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
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/reasoning_pb2.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/reasoning_pb2_grpc.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/runtime_pb2.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/cluster/v1/runtime_pb2_grpc.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2.py \
    native/orchard_worker_mlx/src/orchard_worker_mlx/generated/orchard/worker/v1/worker_runtime_pb2_grpc.py \
    proto/orchard/worker/v1/worker_runtime.descriptor.pb \
    proto/orchard/worker/v1/fixtures/elixir_prepare_inference_request.pb
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
  "$REPO_ROOT/proto/cluster/v1/reasoning.proto" \
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
  cluster/v1/reasoning_pb2.py \
  cluster/v1/reasoning_pb2_grpc.py \
  cluster/v1/runtime_pb2.py \
  cluster/v1/runtime_pb2_grpc.py \
  orchard/worker/v1/worker_runtime_pb2.py \
  orchard/worker/v1/worker_runtime_pb2_grpc.py; do
  install_output "$PYTHON_STAGE/$relative_path" \
    "native/orchard_worker_mlx/src/orchard_worker_mlx/generated/$relative_path"
done

install_output "$DESCRIPTOR_STAGE" \
  proto/orchard/worker/v1/worker_runtime.descriptor.pb

ELIXIR_FIXTURE_GENERATOR="$STAGE_ROOT/generate_elixir_fixture.exs"
cat > "$ELIXIR_FIXTURE_GENERATOR" <<'ELIXIR'
alias Orchard.Cluster.V1.FrozenExecutionInput
alias Orchard.Cluster.V1.GenerationParams
alias Orchard.Cluster.V1.NegotiatedReasoningTuple
alias Orchard.Cluster.V1.PrepareInferenceRequest
alias Orchard.Cluster.V1.WorkerLoadedBinding

request = %PrepareInferenceRequest{
  input: %FrozenExecutionInput{
    request_id: "request-327",
    controller_session_id: "controller-session",
    model_id: "mlx-community/Qwen3-4B",
    version: "sha256:orchard-fixture",
    rendered_prompt_utf8: "prompt",
    input_tokens: 2,
    params: %GenerationParams{
      max_output_tokens: 257,
      temperature: 0.25,
      top_p: 0.875,
      stop_sequences: ["<stop-a>", "<stop-b>"],
      tools_json: ~s([{"type":"function","name":"lookup"}]),
      tool_choice_json: ~s({"type":"function","name":"lookup"})
    },
    deadline_unix_ms: 1_800_000_000_000,
    metadata_json: ~s({"tenant":"fixture"}),
    cache_affinity_fingerprint: "sha256:cache-affinity",
    prompt_token_ids: [7, 11, 42],
    return_token_ids: true,
    return_logprobs: true
  },
  tuple: %NegotiatedReasoningTuple{
    generation_policy: "enabled",
    projection: "final_only",
    model_artifact_digest: "sha256:artifact",
    chat_template_digest: "sha256:template",
    render_contract: "orchard_chat",
    render_contract_version: "1",
    parser_family: "tagged_pair",
    parser_version: "1",
    runtime_contract_version: "1",
    event_binding_version: "1"
  },
  expected_binding: %WorkerLoadedBinding{
    model_id: "mlx-community/Qwen3-4B",
    model_version: "sha256:orchard-fixture",
    artifact_digest: "sha256:artifact",
    selected_profile_id: "mlx-metal-unified-default"
  },
  expected_service_incarnation: "0123456789abcdef0123456789abcdef",
  expected_loaded_instance_id: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
}

output = System.fetch_env!("ORCHARD_PROTO_FIXTURE_OUTPUT")
File.mkdir_p!(Path.dirname(output))
File.write!(output, Protobuf.encode(request))
ELIXIR

ORCHARD_PROTO_FIXTURE_OUTPUT="$OUTPUT_ROOT/proto/orchard/worker/v1/fixtures/elixir_prepare_inference_request.pb" \
  mise exec -- mix run --no-start "$ELIXIR_FIXTURE_GENERATOR"

printf 'generated Worker Runtime Python and Elixir bindings under %s\n' "$OUTPUT_ROOT"
