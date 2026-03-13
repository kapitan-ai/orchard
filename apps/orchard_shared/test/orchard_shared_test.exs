defmodule OrchardSharedTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.{
    Accepted,
    Ack,
    Completed,
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    ExecuteInferenceRequest,
    FinishReason,
    GenerationParams,
    InferenceEvent,
    ModelLoadFailureCategory,
    ModelRef,
    NodeRuntimeService,
    OutputTextDelta,
    PlacementState,
    StatusResponse,
    TokenUsage,
    WorkerState
  }

  test "exposes a version string" do
    assert is_binary(OrchardShared.version())
  end

  test "loads the shared grpc/protobuf contract modules" do
    assert %Ack{} = struct(Ack, ok: true)

    assert %ModelRef{model_id: "mlx-community/phi-3", version: "main"} =
             struct(ModelRef, model_id: "mlx-community/phi-3", version: "main")

    assert %GenerationParams{max_output_tokens: 256, temperature: 0.7} =
             struct(GenerationParams, max_output_tokens: 256, temperature: 0.7)

    assert %EnsureModelLoadedRequest{artifact_sha256: "sha256", preload: true} =
             struct(EnsureModelLoadedRequest, artifact_sha256: "sha256", preload: true)

    assert %EnsureModelLoadedRequest{artifact_source_uri: "hf://org/repo"} =
             struct(EnsureModelLoadedRequest, artifact_source_uri: "hf://org/repo")

    assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
             struct(EnsureModelLoadedResponse, placement_state: :PLACEMENT_STATE_LOADED)

    assert %ExecuteInferenceRequest{request_id: "req_123", params: %GenerationParams{}} =
             struct(ExecuteInferenceRequest, request_id: "req_123", params: %GenerationParams{})

    assert %StatusResponse{loaded_models: [%ModelRef{}], active_request_count: 1} =
             struct(StatusResponse,
               worker_state: :WORKER_STATE_IDLE,
               loaded_models: [%ModelRef{}],
               active_request_count: 1
             )

    assert %InferenceEvent{} = struct(InferenceEvent)
    assert Code.ensure_loaded?(Accepted)
    assert Code.ensure_loaded?(OutputTextDelta)
    assert Code.ensure_loaded?(Completed)
    assert Code.ensure_loaded?(FinishReason)
    assert Code.ensure_loaded?(PlacementState)
    assert %TokenUsage{total_tokens: 42} = struct(TokenUsage, total_tokens: 42)
    assert Code.ensure_loaded?(WorkerState)
    assert Code.ensure_loaded?(ModelLoadFailureCategory)
    assert Code.ensure_loaded?(NodeRuntimeService.Service)
    assert Code.ensure_loaded?(NodeRuntimeService.Stub)
  end

  test "round-trips generated runtime request and event messages" do
    request =
      %ExecuteInferenceRequest{
        request_id: "req_123",
        controller_session_id: "sess_123",
        model_id: "mlx-community/phi-3",
        version: "main",
        rendered_prompt_utf8: "hello",
        input_tokens: 12,
        params: %GenerationParams{max_output_tokens: 64, temperature: 0.7, top_p: 0.95},
        deadline_unix_ms: 1_700_000_000,
        metadata_json: "{}"
      }

    assert request ==
             request |> ExecuteInferenceRequest.encode() |> ExecuteInferenceRequest.decode()

    accepted_event = %InferenceEvent{event: {:accepted, %Accepted{accepted_at_unix_ms: 42}}}

    assert accepted_event ==
             accepted_event |> InferenceEvent.encode() |> InferenceEvent.decode()

    completed_event =
      %InferenceEvent{
        event:
          {:completed,
           %Completed{
             finish_reason: :FINISH_REASON_STOP,
             usage: %TokenUsage{input_tokens: 12, output_tokens: 8, total_tokens: 20}
           }}
      }

    assert completed_event ==
             completed_event |> InferenceEvent.encode() |> InferenceEvent.decode()

    ensure_request = %EnsureModelLoadedRequest{
      node_id: "node-1",
      model_id: "mlx-community/phi-3",
      version: "main",
      artifact_sha256: "sha256:abc",
      preload: false,
      deadline_unix_ms: 1_700_000_000,
      artifact_source_uri: "hf://mlx-community/phi-3"
    }

    assert ensure_request ==
             ensure_request
             |> EnsureModelLoadedRequest.encode()
             |> EnsureModelLoadedRequest.decode()
  end

  test "round-trips EnsureModelLoadedResponse with failure metadata" do
    response = %EnsureModelLoadedResponse{
      already_loaded: false,
      placement_state: :PLACEMENT_STATE_FAILED,
      failure_category: :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE,
      failure_code: "mlx_backend_unavailable",
      failure_message: "Runtime unavailable"
    }

    assert response ==
             response
             |> EnsureModelLoadedResponse.encode()
             |> EnsureModelLoadedResponse.decode()
  end

  test "EnsureModelLoadedResponse proto3 defaults for unset failure fields" do
    decoded =
      %EnsureModelLoadedResponse{}
      |> EnsureModelLoadedResponse.encode()
      |> EnsureModelLoadedResponse.decode()

    assert decoded.placement_state == :PLACEMENT_STATE_UNSPECIFIED
    assert decoded.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_UNSPECIFIED
    assert decoded.failure_code == ""
    assert decoded.failure_message == ""
  end
end
