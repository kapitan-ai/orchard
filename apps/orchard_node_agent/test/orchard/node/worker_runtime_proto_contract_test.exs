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

  test "Elixir decodes the Python fixture with semantic equality" do
    encoded = File.read!(Path.join(@fixture_root, "python_worker_status_response.pb"))

    assert Protobuf.decode(encoded, WorkerStatusResponse) == %WorkerStatusResponse{
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

  test "committed Elixir fixture is produced by the compatibility module" do
    message = %LoadModelRequest{
      model_id: "mlx-community/Qwen3-4B",
      version: "sha256:orchard-fixture",
      model_path: "/var/lib/orchard/models/qwen3-4b"
    }

    assert Protobuf.encode(message) ==
             File.read!(Path.join(@fixture_root, "elixir_load_model_request.pb"))
  end
end
