defmodule Orchard.WorkerRuntimePreparationFixture do
  @moduledoc false

  # Wire coverage only. This request populates every frozen execution field
  # with a non-default value so schema tests can prove encoding and parity.
  # It is not a valid negotiated request: it sets return_token_ids and
  # return_logprobs, which negotiated execution rejects under SPEC.md §7.5.3,
  # and its cache_affinity_fingerprint is not the hmac-sha256:<64 hex> form.
  # Later slices must not reuse it as a happy-path preparation.

  alias Orchard.Cluster.V1.FrozenExecutionInput
  alias Orchard.Cluster.V1.GenerationParams
  alias Orchard.Cluster.V1.NegotiatedReasoningTuple
  alias Orchard.Cluster.V1.PrepareInferenceRequest
  alias Orchard.Cluster.V1.WorkerLoadedBinding

  @spec request() :: PrepareInferenceRequest.t()
  def request do
    %PrepareInferenceRequest{
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
      expected_loaded_instance_id: :binary.list_to_bin(Enum.to_list(0..15))
    }
  end

  @spec write!(Path.t()) :: :ok
  def write!(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Protobuf.encode(request()))
  end
end
