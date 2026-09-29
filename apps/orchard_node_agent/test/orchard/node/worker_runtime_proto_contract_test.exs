defmodule Orchard.Node.WorkerRuntimeProtoContractTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.CancelInferenceRequest
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.FrozenExecutionInput
  alias Orchard.Cluster.V1.InferenceEvent
  alias Orchard.Cluster.V1.NegotiatedReasoningTuple
  alias Orchard.Cluster.V1.PreparationRedemption
  alias Orchard.Cluster.V1.PrepareInferenceRequest
  alias Orchard.Cluster.V1.PrepareInferenceResponse
  alias Orchard.Cluster.V1.ReasoningEffortSelection
  alias Orchard.Cluster.V1.ReasoningEvidenceEnvelope
  alias Orchard.Cluster.V1.ReasoningObservationRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Cluster.V1.TokenUsage
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Cluster.V1.WorkerLoadedBinding
  alias Orchard.InferenceEvent.{Completed, Failed, ToolCallDelta}
  alias Orchard.Node.Worker.V1.LoadModelRequest
  alias Orchard.Node.Worker.V1.WorkerCapabilities
  alias Orchard.Node.Worker.V1.WorkerCapabilityProfile
  alias Orchard.Node.Worker.V1.WorkerMemoryBudgetStatus
  alias Orchard.Node.Worker.V1.WorkerPrefixCacheStatus
  alias Orchard.Node.Worker.V1.WorkerRuntimeService.Service
  alias Orchard.Node.Worker.V1.WorkerRuntimeService.Stub
  alias Orchard.Node.Worker.V1.WorkerStatusRequest
  alias Orchard.Node.Worker.V1.WorkerStatusResponse
  alias Orchard.TestSupport.GeneratedToolArgumentFixture

  @repo_root Path.expand("../../../../..", __DIR__)
  @fixture_root Path.join(@repo_root, "proto/orchard/worker/v1/fixtures")

  test "SPEC.md section 7.5.2a preserves the Orchard.Node.Worker.V1 consumer surface" do
    expected_modules = [
      WorkerStatusRequest,
      WorkerMemoryBudgetStatus,
      WorkerPrefixCacheStatus,
      WorkerCapabilityProfile,
      WorkerCapabilities,
      WorkerStatusResponse,
      LoadModelRequest,
      Service,
      Stub
    ]

    assert Enum.all?(expected_modules, &Code.ensure_loaded?/1)

    assert %LoadModelRequest{} =
             struct(LoadModelRequest,
               model_id: "mlx-community/Qwen3-4B",
               version: "sha256:orchard-fixture",
               model_path: "/var/lib/orchard/models/qwen3-4b"
             )

    stub_functions = Stub.__info__(:functions)

    for operation <- [
          :get_status,
          :load_model,
          :unload_model,
          :generate,
          :cancel,
          :prepare_inference,
          :score_prefix_cache
        ],
        arity <- [2, 3] do
      assert {operation, arity} in stub_functions
    end

    assert Service.__rpc_calls__() == [
             {:GetStatus, {WorkerStatusRequest, false}, {WorkerStatusResponse, false}, %{}},
             {:LoadModel, {LoadModelRequest, false}, {Ack, false}, %{}},
             {:UnloadModel, {UnloadModelRequest, false}, {Ack, false}, %{}},
             {:Generate, {ExecuteInferenceRequest, false}, {InferenceEvent, true}, %{}},
             {:Cancel, {CancelInferenceRequest, false}, {Ack, false}, %{}},
             {:PrepareInference, {PrepareInferenceRequest, false},
              {PrepareInferenceResponse, false}, %{}},
             {:ScorePrefixCache, {ScorePrefixCacheRequest, false},
              {ScorePrefixCacheResponse, false}, %{}}
           ]
  end

  test "WorkerCapabilities and WorkerCapabilityProfile expose the accepted field numbers and types" do
    assert field_signatures(WorkerCapabilityProfile) == [
             {"profile_id", 1, :string, false},
             {"artifact_format", 2, :string, false},
             {"acceleration", 3, :string, false},
             {"device_binding", 4, :string, false},
             {"memory_semantics", 5, :string, false},
             {"max_concurrency", 6, :uint32, false},
             {"runtime_features", 7, :string, true},
             {"cache_capabilities", 8, :string, true}
           ]

    assert field_signatures(WorkerCapabilities) == [
             {"protocol_major", 1, :uint32, false},
             {"protocol_minor", 2, :uint32, false},
             {"provider_id", 3, :string, false},
             {"provider_version", 4, :string, false},
             {"implementation_version", 5, :string, false},
             {"service_incarnation", 6, :string, false},
             {"profiles", 7, WorkerCapabilityProfile, true},
             {"loaded_binding", 8, WorkerLoadedBinding, false},
             {"reasoning_evidence", 9, ReasoningEvidenceEnvelope, false}
           ]

    assert WorkerStatusResponse.__message_props__().field_tags == %{
             loaded: 1,
             active_request_count: 2,
             ready: 3,
             health_code: 4,
             health_message: 5,
             memory_budget: 6,
             prefix_cache: 7,
             supports_prompt_token_ids: 8,
             max_concurrency: 9,
             capabilities: 10
           }

    assert {"capabilities", 10, WorkerCapabilities, false} in field_signatures(
             WorkerStatusResponse
           )
  end

  test "SPEC.md section 7.5.3a exposes exact reasoning tags and presence" do
    assert field_signatures(WorkerStatusRequest) == [
             {"reasoning_observation", 1, ReasoningObservationRequest, false}
           ]

    assert field_signatures(WorkerLoadedBinding) == [
             {"model_id", 1, :string, false},
             {"model_version", 2, :string, false},
             {"artifact_digest", 3, :string, false},
             {"selected_profile_id", 4, :string, false}
           ]

    assert field_signatures(NegotiatedReasoningTuple) == [
             {"generation_policy", 1, :string, false},
             {"projection", 2, :string, false},
             {"reasoning_effort", 3, ReasoningEffortSelection, false},
             {"model_artifact_digest", 4, :string, false},
             {"chat_template_digest", 5, :string, false},
             {"render_contract", 6, :string, false},
             {"render_contract_version", 7, :string, false},
             {"parser_family", 8, :string, false},
             {"parser_version", 9, :string, false},
             {"runtime_contract_version", 10, :string, false},
             {"event_binding_version", 11, :string, false}
           ]

    assert field_signatures(PrepareInferenceRequest) == [
             {"input", 1, FrozenExecutionInput, false},
             {"tuple", 2, NegotiatedReasoningTuple, false},
             {"expected_binding", 3, WorkerLoadedBinding, false},
             {"expected_service_incarnation", 4, :string, false},
             {"expected_loaded_instance_id", 5, :bytes, false}
           ]

    assert {"preparation_redemption", 14, PreparationRedemption, false} in field_signatures(
             ExecuteInferenceRequest
           )

    assert {"usage", 4, TokenUsage, false} in field_signatures(Orchard.Cluster.V1.Failed)

    absent_usage =
      %Orchard.Cluster.V1.Failed{code: "failed"}
      |> Protobuf.encode()
      |> Protobuf.decode(Orchard.Cluster.V1.Failed)

    present_zero_usage =
      %Orchard.Cluster.V1.Failed{code: "failed", usage: %TokenUsage{}}
      |> Protobuf.encode()
      |> Protobuf.decode(Orchard.Cluster.V1.Failed)

    assert absent_usage.usage == nil
    assert present_zero_usage.usage == %TokenUsage{}
    refute Protobuf.encode(absent_usage) == Protobuf.encode(present_zero_usage)

    absent_effort = reasoning_tuple(nil)

    invalid_effort =
      reasoning_tuple(%ReasoningEffortSelection{effort: :REASONING_EFFORT_UNSPECIFIED})

    assert Protobuf.decode(Protobuf.encode(absent_effort), NegotiatedReasoningTuple).reasoning_effort ==
             nil

    assert %ReasoningEffortSelection{effort: :REASONING_EFFORT_UNSPECIFIED} =
             Protobuf.decode(Protobuf.encode(invalid_effort), NegotiatedReasoningTuple).reasoning_effort

    refute Protobuf.encode(absent_effort) == Protobuf.encode(invalid_effort)
  end

  test "Elixir decodes the previous-revision Python fixture with capabilities absent" do
    encoded = File.read!(Path.join(@fixture_root, "python_worker_status_response.pb"))

    decoded = Protobuf.decode(encoded, WorkerStatusResponse)

    assert decoded.capabilities == nil
    assert decoded == legacy_worker_status_response()
  end

  test "Elixir decodes the current-revision Python fixture with semantic equality" do
    encoded =
      File.read!(Path.join(@fixture_root, "python_worker_status_response_capabilities.pb"))

    assert Protobuf.decode(encoded, WorkerStatusResponse) ==
             %{legacy_worker_status_response() | capabilities: worker_capabilities()}
  end

  test "Elixir decodes the negotiated-reasoning Python fixture with semantic equality" do
    encoded =
      File.read!(Path.join(@fixture_root, "python_worker_status_response_reasoning.pb"))

    assert Protobuf.decode(encoded, WorkerStatusResponse) ==
             %{legacy_worker_status_response() | capabilities: reasoning_capabilities()}
  end

  test "committed Elixir WorkerCapabilities fixture is produced by the compatibility module" do
    assert Protobuf.encode(worker_capabilities()) ==
             File.read!(Path.join(@fixture_root, "elixir_worker_capabilities.pb"))
  end

  test "committed Elixir preparation fixture is produced by the current binding" do
    assert Protobuf.encode(prepare_inference_request()) ==
             File.read!(Path.join(@fixture_root, "elixir_prepare_inference_request.pb"))
  end

  test "older and non-advertising projections contain no reasoning additions" do
    encoded = File.read!(Path.join(@fixture_root, "python_worker_status_response.pb"))
    decoded = Protobuf.decode(encoded, WorkerStatusResponse)

    assert decoded.capabilities == nil
    assert Protobuf.encode(%WorkerStatusRequest{}) == <<>>
    assert Protobuf.encode(%ExecuteInferenceRequest{request_id: "legacy"}) == <<10, 6, "legacy">>

    refute Enum.any?(
             Orchard.Cluster.V1.NodeRuntimeService.Service.__rpc_calls__(),
             fn {operation, _request, _response, _options} -> operation == :PrepareInference end
           )

    assert InferenceEvent.__message_props__().field_tags == %{
             accepted: 1,
             output_text_delta: 2,
             tool_call_delta: 3,
             usage: 4,
             completed: 5,
             failed: 6,
             progress: 7,
             token_delta: 8
           }
  end

  test "committed Elixir fixture is produced by the compatibility module" do
    message = %LoadModelRequest{
      model_id: "mlx-community/Qwen3-4B",
      version: "sha256:orchard-fixture",
      model_path: "/var/lib/orchard/models/qwen3-4b"
    }

    assert Protobuf.encode(message) ==
             File.read!(Path.join(@fixture_root, "elixir_load_model_request.pb"))
  end

  test "SPEC.md section 7.5.2 decodes worker-produced generated argument fixtures" do
    [first, second, completed] =
      GeneratedToolArgumentFixture.events!("successful_ordered_calls")

    [first_arguments, second_arguments] =
      GeneratedToolArgumentFixture.arguments!("successful_ordered_calls")

    assert %Orchard.InferenceEvent{
             event: %ToolCallDelta{tool_call_id: "call_0", delta_json: first_delta}
           } = first

    assert %Orchard.InferenceEvent{
             event: %ToolCallDelta{tool_call_id: "call_1", delta_json: second_delta}
           } = second

    assert %Orchard.InferenceEvent{
             event: %Completed{finish_reason: :finish_reason_tool_calls}
           } = completed

    assert Jason.decode!(first_delta) == %{
             "index" => 0,
             "type" => "function",
             "function" => %{
               "name" => "lookup_weather",
               "arguments_delta" => first_arguments
             }
           }

    assert Jason.decode!(second_delta) == %{
             "index" => 1,
             "type" => "function",
             "function" => %{
               "name" => "lookup_time",
               "arguments_delta" => second_arguments
             }
           }

    assert first_arguments =~ "9007199254740993"
    assert second_arguments =~ "-9007199254740993"

    [earlier_valid, later_failed] =
      GeneratedToolArgumentFixture.events!("valid_then_invalid_block")

    assert %Orchard.InferenceEvent{event: %ToolCallDelta{tool_call_id: "call_0"}} = earlier_valid

    assert %Orchard.InferenceEvent{
             event: %Failed{code: "tool_call_parse_failed", retryable: false}
           } = later_failed

    for scenario <- ~w(
          valid_and_invalid_same_block
          unknown_name
          non_object_arguments
          malformed_object
          malformed_array
          truncated_object
          truncated_array
        ) do
      assert [
               %Orchard.InferenceEvent{
                 event: %Failed{code: "tool_call_parse_failed", retryable: false}
               }
             ] = GeneratedToolArgumentFixture.events!(scenario)
    end
  end

  defp field_signatures(module) do
    module.__message_props__().field_props
    |> Enum.sort_by(fn {fnum, _props} -> fnum end)
    |> Enum.map(fn {fnum, props} -> {props.name, fnum, props.type, props.repeated?} end)
  end

  defp worker_capabilities do
    %WorkerCapabilities{
      protocol_major: 1,
      protocol_minor: 1,
      provider_id: "mlx",
      provider_version: "0.31.2",
      implementation_version: "0.1.0",
      service_incarnation: "0123456789abcdef0123456789abcdef",
      profiles: [
        %WorkerCapabilityProfile{
          profile_id: "mlx-metal-unified-default",
          artifact_format: "safetensors",
          acceleration: "metal",
          device_binding: "apple_gpu_0",
          memory_semantics: "unified",
          max_concurrency: 4,
          runtime_features: ["prompt_token_ids", "streaming"],
          cache_capabilities: ["prefix_cache"]
        },
        %WorkerCapabilityProfile{
          profile_id: "mlx-metal-unified-serial",
          artifact_format: "safetensors",
          acceleration: "metal",
          device_binding: "apple_gpu_0",
          memory_semantics: "unified",
          max_concurrency: 1,
          runtime_features: ["streaming"],
          cache_capabilities: []
        }
      ]
    }
  end

  defp reasoning_capabilities do
    %{
      worker_capabilities()
      | loaded_binding: loaded_binding(),
        reasoning_evidence: %ReasoningEvidenceEnvelope{
          tuples: [reasoning_tuple(%ReasoningEffortSelection{effort: :REASONING_EFFORT_LOW})],
          loaded_instance_id: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
        }
    }
  end

  defp reasoning_tuple(effort) do
    %NegotiatedReasoningTuple{
      generation_policy: "enabled",
      projection: "final_only",
      reasoning_effort: effort,
      model_artifact_digest: "sha256:artifact",
      chat_template_digest: "sha256:template",
      render_contract: "orchard_chat",
      render_contract_version: "1",
      parser_family: "tagged_pair",
      parser_version: "1",
      runtime_contract_version: "1",
      event_binding_version: "1"
    }
  end

  defp loaded_binding do
    %WorkerLoadedBinding{
      model_id: "mlx-community/Qwen3-4B",
      model_version: "sha256:orchard-fixture",
      artifact_digest: "sha256:artifact",
      selected_profile_id: "mlx-metal-unified-default"
    }
  end

  defp prepare_inference_request do
    %PrepareInferenceRequest{
      input: %FrozenExecutionInput{
        request_id: "request-327",
        controller_session_id: "controller-session",
        model_id: "mlx-community/Qwen3-4B",
        version: "sha256:orchard-fixture",
        rendered_prompt_utf8: "prompt",
        input_tokens: 2,
        deadline_unix_ms: 1_800_000_000_000,
        metadata_json: "{}"
      },
      tuple: reasoning_tuple(nil),
      expected_binding: loaded_binding(),
      expected_service_incarnation: "0123456789abcdef0123456789abcdef",
      expected_loaded_instance_id: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
    }
  end

  defp legacy_worker_status_response do
    %WorkerStatusResponse{
      loaded: true,
      active_request_count: 2,
      ready: true,
      health_code: "ok",
      health_message: "ready",
      memory_budget: %WorkerMemoryBudgetStatus{
        mode: "observe",
        budget_available: true,
        headroom_available: true,
        status_code: "ok",
        status_message: "within budget",
        source: "mlx-device-info",
        max_recommended_working_set_size_bytes: 34_359_738_368,
        utilization: 0.625,
        target_working_set_bytes: 21_474_836_480,
        overhead_bytes: 1_073_741_824,
        resident_memory_bytes: 17_179_869_184,
        estimated_headroom_bytes: 12_884_901_888,
        kv_cache_bytes_per_token: 262_144,
        prefill_workspace_bytes_per_token: 524_288,
        recommended_context_tokens: 32_768
      },
      prefix_cache: %WorkerPrefixCacheStatus{
        implementation: "mlx-lm",
        enabled: true,
        entry_count: 3,
        total_bytes: 4_194_304,
        hits: 8,
        misses: 2,
        failures: 1,
        stores: 4,
        evictions: 1,
        configured_max_entries: 16,
        configured_max_bytes: 67_108_864,
        status_code: "ok",
        status_message: "available",
        session_started_unix_ms: 1_788_245_442_000,
        prefix_cache_fingerprints: ["sha256:alpha", "sha256:beta"]
      },
      supports_prompt_token_ids: true,
      max_concurrency: 4
    }
  end
end
