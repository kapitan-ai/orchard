defmodule Orchard.Node.WorkerRuntimeProtoContractTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.Ack
  alias Orchard.Cluster.V1.CancelInferenceRequest
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.InferenceEvent
  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.Node.Worker.V1.LoadModelRequest
  alias Orchard.Node.Worker.V1.WorkerCapabilities
  alias Orchard.Node.Worker.V1.WorkerCapabilityProfile
  alias Orchard.Node.Worker.V1.WorkerMemoryBudgetStatus
  alias Orchard.Node.Worker.V1.WorkerPrefixCacheStatus
  alias Orchard.Node.Worker.V1.WorkerRuntimeService.Service
  alias Orchard.Node.Worker.V1.WorkerRuntimeService.Stub
  alias Orchard.Node.Worker.V1.WorkerStatusRequest
  alias Orchard.Node.Worker.V1.WorkerStatusResponse

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
             {"profiles", 7, WorkerCapabilityProfile, true}
           ]

    refute Map.has_key?(WorkerCapabilities.__message_props__().field_props, 8)

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

  test "committed Elixir WorkerCapabilities fixture is produced by the compatibility module" do
    assert Protobuf.encode(worker_capabilities()) ==
             File.read!(Path.join(@fixture_root, "elixir_worker_capabilities.pb"))
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
