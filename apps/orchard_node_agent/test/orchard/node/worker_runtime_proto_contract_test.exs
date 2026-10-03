defmodule Orchard.Node.WorkerRuntimeProtoContractTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.CancelInferenceRequest
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.FrozenExecutionInput
  alias Orchard.Cluster.V1.InferenceEvent
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Cluster.V1.NegotiatedReasoningTuple
  alias Orchard.Cluster.V1.PreparationRedemption
  alias Orchard.Cluster.V1.PrepareInferenceRequest
  alias Orchard.Cluster.V1.PrepareInferenceResponse
  alias Orchard.Cluster.V1.ReasoningEffortSelection
  alias Orchard.Cluster.V1.ReasoningEvidence
  alias Orchard.Cluster.V1.ReasoningEvidenceEnvelope
  alias Orchard.Cluster.V1.ReasoningLiveObservation
  alias Orchard.Cluster.V1.ReasoningNonAdvertising
  alias Orchard.Cluster.V1.ReasoningObservationRequest
  alias Orchard.Cluster.V1.ReasoningUnknown
  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Cluster.V1.StatusRequest
  alias Orchard.Cluster.V1.StatusResponse
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
  alias Protobuf.Protoc.CLI, as: ProtocCLI
  alias Protobuf.Protoc.Context, as: ProtocContext
  alias Protobuf.Protoc.Generator, as: ProtocGenerator

  @repo_root Path.expand("../../../../..", __DIR__)
  @fixture_root Path.join(@repo_root, "proto/orchard/worker/v1/fixtures")

  Code.require_file(
    Path.join(@repo_root, "scripts/support/worker-runtime-preparation-fixture.exs")
  )

  # N-1 golden: the Worker Runtime descriptor set from the merge base with
  # main before negotiated reasoning (126eb1bc). Modules are generated from
  # it under Orchard.NMinus1 so tests decode across a real schema revision.
  @n_minus_1_descriptor Path.join(@fixture_root, "n_minus_1/worker_runtime.descriptor.pb")
  @n_minus_1_descriptor_sha256 "6e51e68783dc7e5768d80c559616feaea3df1797ab38a3d5c7c4ef0e94fc27d9"
  @n_minus_1_execution Orchard.NMinus1.Cluster.V1.ExecuteInferenceRequest
  @n_minus_1_failed Orchard.NMinus1.Cluster.V1.Failed
  @n_minus_1_status_request Orchard.NMinus1.Cluster.V1.StatusRequest
  @n_minus_1_status_response Orchard.NMinus1.Cluster.V1.StatusResponse
  @n_minus_1_worker_status_request Orchard.NMinus1.Orchard.Worker.V1.WorkerStatusRequest
  @n_minus_1_worker_status_response Orchard.NMinus1.Orchard.Worker.V1.WorkerStatusResponse
  @n_minus_1_worker_capabilities Orchard.NMinus1.Orchard.Worker.V1.WorkerCapabilities

  setup_all do
    compile_n_minus_1_modules!()
    :ok
  end

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

  test "SPEC.md section 7.5.3a keeps frozen input in descriptor parity with execution" do
    {redemption, execution_input} =
      ExecuteInferenceRequest
      |> field_signatures()
      |> Enum.split_with(fn {_name, number, _type, _repeated?} -> number == 14 end)

    assert redemption == [{"preparation_redemption", 14, PreparationRedemption, false}]
    assert execution_input == field_signatures(FrozenExecutionInput)
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

  test "preparation fixture round-trips N/N and its frozen input maps onto current execution fields 1-13" do
    encoded = File.read!(Path.join(@fixture_root, "elixir_prepare_inference_request.pb"))
    expected = Orchard.WorkerRuntimePreparationFixture.request()

    assert Protobuf.encode(expected) == encoded
    assert Protobuf.decode(encoded, PrepareInferenceRequest) == expected

    frozen_encoded = Protobuf.encode(expected.input)
    execution = Protobuf.decode(frozen_encoded, ExecuteInferenceRequest)

    assert execution.preparation_redemption == nil
    assert Protobuf.encode(execution) == frozen_encoded
    assert Protobuf.decode(Protobuf.encode(execution), FrozenExecutionInput) == expected.input
  end

  test "N-1 golden is the pre-reasoning merge-base Worker Runtime descriptor" do
    assert :crypto.hash(:sha256, File.read!(@n_minus_1_descriptor)) |> Base.encode16(case: :lower) ==
             @n_minus_1_descriptor_sha256

    assert Enum.map(field_signatures(@n_minus_1_execution), &elem(&1, 1)) == Enum.to_list(1..13)

    assert Enum.map(field_signatures(@n_minus_1_failed), &elem(&1, 0)) ==
             ~w(code message retryable)

    assert field_signatures(@n_minus_1_status_request) == []
    assert field_signatures(@n_minus_1_worker_status_request) == []
    refute Enum.any?(field_signatures(@n_minus_1_status_response), &(elem(&1, 1) == 14))

    assert Enum.map(field_signatures(@n_minus_1_worker_capabilities), &elem(&1, 1)) ==
             Enum.to_list(1..7)
  end

  test "N-1 execution decodes current bytes with field 14 set, and current decodes N-1 execution bytes" do
    input = Orchard.WorkerRuntimePreparationFixture.request().input
    redemption = %PreparationRedemption{authorization: :binary.copy(<<0xA5>>, 32)}
    current = struct(ExecuteInferenceRequest, Map.from_struct(input))
    current_bytes = Protobuf.encode(%{current | preparation_redemption: redemption})

    old_view = Protobuf.decode(current_bytes, @n_minus_1_execution)
    assert plain(old_view) == plain(input)
    assert old_view.__unknown_fields__ == [{14, 2, Protobuf.encode(redemption)}]
    assert Protobuf.encode(old_view) == current_bytes

    frozen_view = Protobuf.decode(current_bytes, FrozenExecutionInput)
    assert %{frozen_view | __unknown_fields__: []} == input
    assert frozen_view.__unknown_fields__ == [{14, 2, Protobuf.encode(redemption)}]

    old_bytes = Protobuf.encode(to_n_minus_1(input, @n_minus_1_execution))
    assert old_bytes == Protobuf.encode(input)
    assert Protobuf.decode(old_bytes, ExecuteInferenceRequest) == current
    assert Protobuf.decode(old_bytes, FrozenExecutionInput) == input
  end

  test "N-1 Failed keeps present-zero usage as unknown bytes and current reads N-1 Failed as missing usage" do
    present_zero =
      Protobuf.encode(%Orchard.Cluster.V1.Failed{
        code: "failed",
        retryable: true,
        usage: %TokenUsage{}
      })

    old_view = Protobuf.decode(present_zero, @n_minus_1_failed)
    assert {old_view.code, old_view.retryable} == {"failed", true}
    assert old_view.__unknown_fields__ == [{4, 2, <<>>}]

    old_bytes = Protobuf.encode(struct(@n_minus_1_failed, code: "failed", retryable: true))
    assert Protobuf.decode(old_bytes, Orchard.Cluster.V1.Failed).usage == nil
  end

  test "N-1 Worker capabilities ignore fields 8 and 9, and current reads N-1 capabilities as non-advertising" do
    reasoning_bytes =
      File.read!(Path.join(@fixture_root, "python_worker_status_response_reasoning.pb"))

    old_view = Protobuf.decode(reasoning_bytes, @n_minus_1_worker_status_response)

    assert plain(old_view.capabilities) ==
             worker_capabilities() |> plain() |> Map.drop([:loaded_binding, :reasoning_evidence])

    assert Enum.map(old_view.capabilities.__unknown_fields__, &elem(&1, 0)) == [8, 9]

    old_bytes =
      worker_capabilities()
      |> to_n_minus_1(@n_minus_1_worker_capabilities)
      |> Protobuf.encode()

    assert old_bytes == File.read!(Path.join(@fixture_root, "elixir_worker_capabilities.pb"))
    current_view = Protobuf.decode(old_bytes, WorkerCapabilities)
    assert current_view == worker_capabilities()
    assert current_view.loaded_binding == nil
    assert current_view.reasoning_evidence == nil
  end

  test "SPEC.md section 7.5.3a opt-in observation selector and every live result variant cross N/N and N/N-1" do
    selector = %ReasoningObservationRequest{
      model_ref: %ModelRef{model_id: "mlx-community/Qwen3-4B", version: "sha256:orchard-fixture"}
    }

    for {current_module, old_module} <- [
          {WorkerStatusRequest, @n_minus_1_worker_status_request},
          {StatusRequest, @n_minus_1_status_request}
        ] do
      bytes = Protobuf.encode(struct(current_module, reasoning_observation: selector))
      assert Protobuf.decode(bytes, current_module).reasoning_observation == selector

      assert Protobuf.decode(bytes, old_module).__unknown_fields__ == [
               {1, 2, Protobuf.encode(selector)}
             ]

      assert Protobuf.encode(struct(old_module)) == <<>>
      assert Protobuf.decode(<<>>, current_module).reasoning_observation == nil
    end

    variants = [
      evidence: %ReasoningEvidence{
        loaded_binding: loaded_binding(),
        envelope: reasoning_capabilities().reasoning_evidence,
        service_incarnation: "0123456789abcdef0123456789abcdef",
        remaining_freshness_ms: 1_500
      },
      non_advertising: %ReasoningNonAdvertising{},
      unknown: %ReasoningUnknown{}
    ]

    encoded_variants =
      for {tag, value} <- variants do
        observation = %ReasoningLiveObservation{result: {tag, value}}

        bytes =
          Protobuf.encode(%StatusResponse{max_concurrency: 4, reasoning_observation: observation})

        assert Protobuf.decode(bytes, StatusResponse).reasoning_observation == observation

        old_view = Protobuf.decode(bytes, @n_minus_1_status_response)
        assert old_view.max_concurrency == 4
        assert [{14, 2, _observation}] = old_view.__unknown_fields__
        bytes
      end

    assert length(Enum.uniq(encoded_variants)) == 3

    old_status = Protobuf.encode(struct(@n_minus_1_status_response, max_concurrency: 4))
    assert Protobuf.decode(old_status, StatusResponse).reasoning_observation == nil
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

  defp compile_n_minus_1_modules! do
    descriptor_set =
      @n_minus_1_descriptor
      |> File.read!()
      |> Protobuf.decode(Google.Protobuf.FileDescriptorSet)

    files = descriptor_set.file

    context =
      %ProtocContext{}
      |> ProtocCLI.parse_params("package_prefix=Orchard.NMinus1")
      |> ProtocCLI.find_types(files, Enum.map(files, & &1.name))

    for file <- files,
        {_extensions, generated} = ProtocGenerator.generate(context, file),
        %{content: content} <- generated do
      Code.compile_string(content)
    end
  end

  # Rebuilds a current message as the N-1 generated message with the same
  # values. struct!/2 raises if the current message sets a field N-1 lacks.
  defp to_n_minus_1(%_{} = message, target) do
    fields =
      message
      |> plain_fields()
      |> Enum.reject(fn {_name, value} -> is_nil(value) end)
      |> Map.new(fn {name, value} -> {name, to_n_minus_1_value(value, target, name)} end)

    struct!(target, fields)
  end

  defp to_n_minus_1_value(values, target, name) when is_list(values),
    do: Enum.map(values, &to_n_minus_1_value(&1, target, name))

  defp to_n_minus_1_value(%_{} = value, target, name),
    do: to_n_minus_1(value, target.__message_props__().field_props |> field_type(name))

  defp to_n_minus_1_value(value, _target, _name), do: value

  defp field_type(field_props, name) do
    Enum.find_value(field_props, fn {_number, props} ->
      if props.name_atom == name, do: props.type
    end)
  end

  defp plain(values) when is_list(values), do: Enum.map(values, &plain/1)

  defp plain(%_{} = message),
    do: message |> plain_fields() |> Map.new(fn {k, v} -> {k, plain(v)} end)

  defp plain(value), do: value

  defp plain_fields(message),
    do: message |> Map.from_struct() |> Map.drop([:__unknown_fields__, :__protobuf__])

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
