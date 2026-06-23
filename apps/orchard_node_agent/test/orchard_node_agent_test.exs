defmodule OrchardNodeAgentTest do
  use ExUnit.Case, async: false

  alias Orchard.ArtifactBundle
  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef, as: CanonicalModelRef
  alias Orchard.Cluster.V1.Accepted
  alias Orchard.Cluster.V1.CancelInferenceRequest
  alias Orchard.Cluster.V1.Completed
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.EnsureModelLoadedResponse
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.GenerationParams
  alias Orchard.Cluster.V1.HostedToolCapability
  alias Orchard.Cluster.V1.HostedToolReadiness
  alias Orchard.Cluster.V1.InferenceEvent, as: RPCInferenceEvent
  alias Orchard.Cluster.V1.ModelRef, as: RPCModelRef
  alias Orchard.Cluster.V1.NodeRuntimeService.Stub, as: NodeRuntimeStub
  alias Orchard.Cluster.V1.OutputTextDelta
  alias Orchard.Cluster.V1.ScorePrefixCacheRequest
  alias Orchard.Cluster.V1.ScorePrefixCacheResponse
  alias Orchard.Cluster.V1.StatusRequest
  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.Cluster.V1.TokenUsage
  alias Orchard.Cluster.V1.UnloadModelRequest
  alias Orchard.InferenceEvent, as: OrchardInferenceEvent
  alias Orchard.Licensing.Gate
  alias Orchard.Licensing.LocalStore
  alias Orchard.ModelManifest
  alias Orchard.ModelManifest.RuntimeRequirements
  alias Orchard.ModelManifest.Tokenizer
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.Node.RuntimeServer
  alias Orchard.Node.SentryTelemetryBridge
  alias Orchard.Node.SharedContract
  alias Orchard.Node.Status, as: NodeStatus
  alias Orchard.Node.Supervisor, as: NodeSupervisor
  alias Orchard.Node.WorkerSupervisor
  alias Orchard.NodeAgent.Supervisor, as: NodeAgentSupervisor

  @test_model_id "mlx-community/phi-3"
  @test_version "main"
  @licensing_fixture_dir Path.expand("../../orchard_shared/test/fixtures/licensing", __DIR__)
  @licensing_public_key_hex "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"
  @licensing_local_node_id "11111111-2222-4333-8444-555555555555"

  defmodule BlockingRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef
    alias Orchard.InferenceEvent

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(adapter_state, %ExecuteInferenceRequest{} = request, opts) do
      owner = Keyword.fetch!(opts, :owner)
      generation_ref = make_ref()

      {:ok, pid} =
        Task.start(fn ->
          receive do
            {:release, ^generation_ref} ->
              usage = %InferenceEvent.Usage{
                input_tokens: request.input_tokens,
                output_tokens: 1,
                total_tokens: request.input_tokens + 1
              }

              send(
                owner,
                {:runtime_adapter_event, generation_ref,
                 InferenceEvent.output_text_delta("released")}
              )

              send(
                owner,
                {:runtime_adapter_event, generation_ref,
                 InferenceEvent.completed(:finish_reason_stop, usage)}
              )

              send(owner, {:runtime_adapter_done, generation_ref})
          after
            30_000 -> :ok
          end
        end)

      generations =
        Map.put(adapter_state.generations, generation_ref, %{pid: pid, owner: owner})

      {:ok, generation_ref, %{adapter_state | generations: generations}}
    end

    @impl true
    def cancel_generation(adapter_state, generation_ref, _opts) do
      case Map.pop(adapter_state.generations, generation_ref) do
        {nil, _generations} ->
          {:ok, adapter_state}

        {%{pid: pid, owner: owner}, generations} ->
          Process.exit(pid, :kill)

          send(
            owner,
            {:runtime_adapter_event, generation_ref,
             InferenceEvent.failed("cancelled", "request cancelled", false)}
          )

          send(owner, {:runtime_adapter_done, generation_ref})
          {:ok, %{adapter_state | generations: generations}}
      end
    end

    @impl true
    def finish_generation(adapter_state, generation_ref, _opts) do
      generations = Map.delete(adapter_state.generations, generation_ref)
      %{adapter_state | generations: generations}
    end
  end

  defmodule UnavailableDoneRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(adapter_state, %ExecuteInferenceRequest{} = request, opts) do
      owner = Keyword.fetch!(opts, :owner)
      generation_ref = make_ref()

      {:ok, pid} =
        Task.start(fn ->
          send(owner, {:runtime_adapter_done, generation_ref, :worker_unavailable})
        end)

      generations =
        Map.put(adapter_state.generations, generation_ref, %{
          pid: pid,
          request_id: request.request_id
        })

      {:ok, generation_ref, %{adapter_state | generations: generations}}
    end

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, generation_ref, _opts) do
      %{adapter_state | generations: Map.delete(adapter_state.generations, generation_ref)}
    end
  end

  defmodule FailingUnloadAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: {:error, :simulated_unload_failure}

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule MemoryBudgetRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok,
       %{
         ready: true,
         health_code: "",
         health_message: "",
         memory_budget: %{
           mode: "observe",
           budget_available: true,
           headroom_available: true,
           status_code: "ok",
           status_message: "",
           source: "mlx.core.device_info.max_recommended_working_set_size",
           max_recommended_working_set_size_bytes: 8_000_000_000,
           utilization: 0.75,
           target_working_set_bytes: 6_000_000_000,
           overhead_bytes: 268_435_456,
           resident_memory_bytes: 2_048_000,
           estimated_headroom_bytes: 5_731_516_544,
           kv_cache_bytes_per_token: 16_384,
           prefill_workspace_bytes_per_token: 2_048
         },
         prefix_cache_status: %{
           implementation: "kv",
           enabled: true,
           entry_count: 2,
           total_bytes: 32_768,
           hits: 12,
           misses: 4,
           failures: 1,
           stores: 8,
           evictions: 3,
           configured_max_entries: 64,
           configured_max_bytes: 1_048_576,
           status_code: "ok",
           status_message: "",
           session_started_unix_ms: 1_713_726_400_000
         }
       }}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule ScorePrefixCacheRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef
    alias Orchard.Cluster.V1.ScorePrefixCacheResponse

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state

    def score_prefix_cache(_adapter_state, _request, _opts) do
      mode =
        Application.fetch_env!(:orchard_node_agent, :runtime)
        |> Keyword.get(:test_score_prefix_cache_mode, :ok)

      case mode do
        :ok ->
          {:ok,
           %ScorePrefixCacheResponse{
             status_code: "ok",
             status_message: "",
             resident_fingerprint_match: true,
             score_tier: "resident_fingerprint",
             session_started_unix_ms: 1_713_726_400_000
           }}

        :timeout ->
          {:error, :timeout}

        :contradictory_timeout ->
          {:ok,
           %ScorePrefixCacheResponse{
             status_code: "timeout",
             status_message: "timed out",
             resident_fingerprint_match: true,
             score_tier: "resident_fingerprint",
             session_started_unix_ms: 1_713_726_400_000
           }}

        :malformed ->
          {:ok, %{status_code: "unknown", score_tier: "invalid"}}

        _other ->
          {:error, :boom}
      end
    end
  end

  defmodule CountingStatusRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def get_status(_adapter_state, _opts) do
      if pid = Process.whereis(:load_timeout_test_pid) do
        send(pid, {:counting_status_probe, self()})
      end

      {:ok,
       %{
         ready: true,
         health_code: "",
         health_message: "",
         memory_budget: %{
           mode: "observe",
           budget_available: true,
           headroom_available: true,
           status_code: "ok",
           status_message: "",
           source: "mlx.core.device_info.max_recommended_working_set_size",
           max_recommended_working_set_size_bytes: 8_000_000_000,
           utilization: 0.5,
           target_working_set_bytes: 4_000_000_000,
           overhead_bytes: 128_000_000,
           resident_memory_bytes: 2_048_000,
           estimated_headroom_bytes: 3_870_000_000,
           kv_cache_bytes_per_token: 16_384,
           prefill_workspace_bytes_per_token: 2_048
         },
         prefix_cache_status: %{
           implementation: "kv",
           enabled: true,
           entry_count: 1,
           total_bytes: 16_384,
           hits: 3,
           misses: 1,
           failures: 0,
           stores: 2,
           evictions: 0,
           configured_max_entries: 64,
           configured_max_bytes: 1_048_576,
           status_code: "ok",
           status_message: "",
           session_started_unix_ms: 1_713_726_400_000
         }
       }}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule PromptTokenIdsRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @legacy_model_id "prompt-token-ids/legacy"
    @status_error_model_id "prompt-token-ids/status-error"

    @impl true
    def get_status(adapter_state, _opts) do
      if pid = Process.whereis(:load_timeout_test_pid) do
        send(pid, {:prompt_token_ids_status_probe, self(), adapter_state.model_ref})
      end

      status_sleep_ms =
        Application.fetch_env!(:orchard_node_agent, :runtime)
        |> Keyword.get(:test_prompt_token_ids_status_sleep_ms, 0)

      if status_sleep_ms > 0, do: Process.sleep(status_sleep_ms)

      status = %{ready: true, health_code: "", health_message: ""}

      cond do
        adapter_state.model_ref.model_id == @status_error_model_id ->
          {:error, :simulated_status_failure}

        adapter_state.model_ref.model_id == @legacy_model_id ->
          {:ok, status}

        true ->
          {:ok, Map.put(status, :supports_prompt_token_ids, true)}
      end
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule StatusProbeShortCircuitAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @blocked_model_id "status-probe/blocked"

    @impl true
    def get_status(adapter_state, _opts) do
      if pid = Process.whereis(:load_timeout_test_pid) do
        send(pid, {:short_circuit_status_probe, self(), adapter_state.model_ref})
      end

      {:ok,
       %{
         ready: true,
         health_code: "",
         health_message: "",
         memory_budget: %{
           mode: "observe",
           budget_available: true,
           headroom_available: true,
           status_code: "ok",
           status_message: "",
           source: "mlx.core.device_info.max_recommended_working_set_size",
           max_recommended_working_set_size_bytes: 8_000_000_000,
           utilization: 0.5,
           target_working_set_bytes: 4_000_000_000,
           overhead_bytes: 128_000_000,
           resident_memory_bytes: 2_048_000,
           estimated_headroom_bytes: 3_870_000_000,
           kv_cache_bytes_per_token: 16_384,
           prefill_workspace_bytes_per_token: 2_048
         }
       }}
    end

    @impl true
    def load_model(%ModelRef{model_id: @blocked_model_id} = model_ref, _opts) do
      if pid = Process.whereis(:load_timeout_test_pid) do
        send(pid, {:short_circuit_blocking_load_started, self(), model_ref})
      end

      receive do
        :finish_load -> {:ok, %{model_ref: model_ref, generations: %{}}}
      after
        30_000 -> {:error, :load_timeout}
      end
    end

    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule InvalidMemoryBudgetRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def get_status(_adapter_state, _opts) do
      utilization =
        Application.fetch_env!(:orchard_node_agent, :runtime)
        |> Keyword.get(:test_invalid_memory_budget_utilization, 0.0)

      {:ok,
       %{
         ready: true,
         health_code: "",
         health_message: "",
         memory_budget: %{
           mode: "observe",
           budget_available: true,
           headroom_available: true,
           status_code: "ok",
           status_message: "",
           source: "mlx.core.device_info.max_recommended_working_set_size",
           max_recommended_working_set_size_bytes: -1,
           utilization: utilization,
           target_working_set_bytes: 18_446_744_073_709_551_616,
           overhead_bytes: "bad",
           resident_memory_bytes: true,
           estimated_headroom_bytes: 18_446_744_073_709_551_615,
           kv_cache_bytes_per_token: 16_384,
           prefill_workspace_bytes_per_token: 340_282_366_920_938_463_463_374_607_431_768_211_456
         }
       }}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule PrefixCacheMixedRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @malformed_prefix_model_id "prefix-cache/malformed"

    @impl true
    def get_status(adapter_state, _opts) do
      {:ok,
       %{
         ready: true,
         health_code: "",
         health_message: "",
         memory_budget: %{
           mode: "observe",
           budget_available: true,
           headroom_available: true,
           status_code: "ok",
           status_message: "",
           source: "mlx.core.device_info.max_recommended_working_set_size",
           max_recommended_working_set_size_bytes: 8_000_000_000,
           utilization: 0.5,
           target_working_set_bytes: 4_000_000_000,
           overhead_bytes: 128_000_000,
           resident_memory_bytes: 2_048_000,
           estimated_headroom_bytes: 3_870_000_000,
           kv_cache_bytes_per_token: 16_384,
           prefill_workspace_bytes_per_token: 2_048
         },
         prefix_cache_status: prefix_cache_status_for(adapter_state)
       }}
    end

    defp prefix_cache_status_for(%{model_ref: %ModelRef{model_id: @malformed_prefix_model_id}}) do
      %{
        implementation: "kv",
        enabled: true,
        entry_count: "invalid",
        total_bytes: 16_384,
        hits: 3,
        misses: 1,
        failures: 0,
        stores: 2,
        evictions: 0,
        configured_max_entries: 64,
        configured_max_bytes: 1_048_576,
        status_code: "ok",
        status_message: "",
        session_started_unix_ms: 1_713_726_400_000
      }
    end

    defp prefix_cache_status_for(_adapter_state) do
      %{
        implementation: "kv",
        enabled: true,
        entry_count: 2,
        total_bytes: 32_768,
        hits: 12,
        misses: 4,
        failures: 1,
        stores: 8,
        evictions: 3,
        configured_max_entries: 64,
        configured_max_bytes: 1_048_576,
        status_code: "ok",
        status_message: "",
        session_started_unix_ms: 1_713_726_400_000
      }
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule PrefixCacheFingerprintRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @malformed_fingerprint_model_id "prefix-cache/malformed-fingerprints"

    @impl true
    def get_status(adapter_state, _opts) do
      {:ok,
       %{
         ready: true,
         health_code: "",
         health_message: "",
         prefix_cache_status: prefix_cache_status_for(adapter_state)
       }}
    end

    defp prefix_cache_status_for(%{
           model_ref: %ModelRef{model_id: @malformed_fingerprint_model_id}
         }) do
      Map.put(base_prefix_cache_status(), :prefix_cache_fingerprints, "malformed")
    end

    defp prefix_cache_status_for(_adapter_state) do
      fingerprints =
        [
          fingerprint(0),
          fingerprint(1),
          fingerprint(0),
          "not-a-fingerprint",
          "hmac-sha256:" <> String.duplicate("g", 64)
        ] ++ Enum.map(2..70, &fingerprint/1)

      Map.put(base_prefix_cache_status(), :prefix_cache_fingerprints, fingerprints)
    end

    defp base_prefix_cache_status do
      %{
        implementation: "kv",
        enabled: true,
        entry_count: 2,
        total_bytes: 32_768,
        hits: 12,
        misses: 4,
        failures: 1,
        stores: 8,
        evictions: 3,
        configured_max_entries: 64,
        configured_max_bytes: 1_048_576,
        status_code: "ok",
        status_message: "",
        session_started_unix_ms: 1_713_726_400_000
      }
    end

    defp fingerprint(index) do
      "hmac-sha256:" <>
        (index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule LoadTimeoutCapturingAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef
    alias Orchard.InferenceEvent

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, opts) do
      if pid = Process.whereis(:load_timeout_test_pid) do
        send(pid, {:captured_load_timeout_ms, Keyword.get(opts, :load_timeout_ms)})
      end

      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule SlowLoadAdapter do
    @moduledoc false
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      # Block long enough for single-flight and cancel tests
      receive do
        :finish_load -> {:ok, %{model_ref: model_ref, generations: %{}}}
      after
        30_000 -> {:error, :load_timeout}
      end
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  defmodule ConfigurableScoreRuntimeAdapter do
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      {:ok, %{model_ref: model_ref, generations: %{}}}
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state

    def score_prefix_cache(_adapter_state, _request, _opts) do
      mode =
        Application.fetch_env!(:orchard_node_agent, :runtime)
        |> Keyword.get(:test_score_mode, :ok)

      case mode do
        :ok ->
          {:ok,
           %{
             status_code: "ok",
             status_message: "scored",
             resident_fingerprint_match: true,
             score_tier: "resident_fingerprint",
             session_started_unix_ms: 1_713_726_400_000
           }}

        :timeout ->
          {:error, :timeout}

        :contradictory_timeout ->
          {:ok,
           %{
             status_code: "timeout",
             status_message: "timed out",
             resident_fingerprint_match: true,
             score_tier: "resident_fingerprint",
             session_started_unix_ms: 1_713_726_400_000
           }}

        :sleep ->
          Process.sleep(200)
          {:ok, %{status_code: "ok", score_tier: "resident_fingerprint"}}

        :error ->
          {:error, :worker_unavailable}

        :malformed ->
          {:ok,
           %{
             status_code: "not_allowed",
             status_message: 123,
             resident_fingerprint_match: "yes",
             score_tier: "bad",
             session_started_unix_ms: -1
           }}
      end
    end
  end

  defmodule DeadlineTestAdapter do
    @moduledoc """
    Adapter that blocks in load_model until the test process sends a release
    message. Supports multiple attempts by tracking attempt count and notifying
    the test process of each load start.
    """
    @behaviour Orchard.Node.RuntimeAdapter

    alias Orchard.Cluster.V1.ExecuteInferenceRequest
    alias Orchard.Cluster.V1.ModelRef

    @impl true
    def get_status(_adapter_state, _opts) do
      {:ok, %{ready: true, health_code: "", health_message: ""}}
    end

    @impl true
    def load_model(%ModelRef{} = model_ref, _opts) do
      if pid = Process.whereis(:load_timeout_test_pid) do
        send(pid, {:load_attempt_started, self()})
      end

      receive do
        :finish_load -> {:ok, %{model_ref: model_ref, generations: %{}}}
        :fail_load -> {:error, :load_failed}
      after
        30_000 -> {:error, :load_timeout}
      end
    end

    @impl true
    def unload_model(_adapter_state, _opts), do: :ok

    @impl true
    def start_generation(_adapter_state, %ExecuteInferenceRequest{}, _opts),
      do: {:error, :not_implemented}

    @impl true
    def cancel_generation(adapter_state, _generation_ref, _opts), do: {:ok, adapter_state}

    @impl true
    def finish_generation(adapter_state, _generation_ref, _opts), do: adapter_state
  end

  setup do
    previous_sentry_enrichment = Application.get_env(:orchard_shared, :sentry_enrichment)
    clear_sentry_context()

    :ok = NodeStatus.reset()
    wait_until(fn -> worker_count() == 0 end)

    # Create a real test bundle at both the cache path and a source path.
    # The async ModelManager pipeline runs acquisition which checks cache hash.
    bundle = stage_test_bundle!()

    # Register the test process so adapters and ModelManager can send messages back.
    if Process.whereis(:load_timeout_test_pid), do: Process.unregister(:load_timeout_test_pid)
    Process.register(self(), :load_timeout_test_pid)

    on_exit(fn ->
      restore_sentry_enrichment(previous_sentry_enrichment)
      clear_sentry_context()
      File.rm_rf(bundle.cache_path)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
    end)

    %{bundle: bundle}
  end

  test "node agent version is derived from app metadata" do
    vsn = Application.spec(:orchard_node_agent, :vsn)
    expected = if is_list(vsn), do: List.to_string(vsn), else: to_string(vsn)
    assert Orchard.NodeAgent.version() == expected
  end

  describe "Sentry telemetry bridge" do
    test "maps only whitelisted lifecycle telemetry to breadcrumbs" do
      assert {:ok, breadcrumb} =
               SentryTelemetryBridge.breadcrumb_for_event(
                 [:orchard, :node, :model_manager, :load, :exception],
                 %{duration_ms: 12},
                 %{
                   model_id: @test_model_id,
                   version: @test_version,
                   reason: :worker_unavailable,
                   rpc_result: {:error, "/tmp/private/token-secret"},
                   source_url: "https://example.invalid/private",
                   path: "/tmp/private"
                 }
               )

      assert breadcrumb[:category] == "orchard.node.model_manager.load"
      assert breadcrumb[:message] == "model_manager.load.exception"
      assert breadcrumb[:level] == :warning
      assert breadcrumb[:data].duration_ms == 12
      assert breadcrumb[:data].model_id == @test_model_id
      assert breadcrumb[:data].reason == "worker_unavailable"
      assert breadcrumb[:data].rpc_result == "error"
      refute Map.has_key?(breadcrumb[:data], :source_url)
      refute Map.has_key?(breadcrumb[:data], :path)

      assert :ignore =
               SentryTelemetryBridge.breadcrumb_for_event(
                 [:orchard, :node, :model_acquisition, :progress],
                 %{},
                 %{path: "/tmp/private"}
               )
    end

    test "sanitizes non-allowlisted telemetry reasons" do
      assert {:ok, breadcrumb} =
               SentryTelemetryBridge.breadcrumb_for_event(
                 [:orchard, :node, :model_manager, :load, :exception],
                 %{duration_ms: 12},
                 %{
                   model_id: String.duplicate("a", 140),
                   version: @test_version,
                   reason: {:error, "/tmp/private?token=secret"},
                   rpc_result: "https://example.invalid/private?token=secret",
                   stop_result: {:error, "/tmp/private?token=secret"},
                   cancel_reason: "private-token-secret"
                 }
               )

      assert breadcrumb[:level] == :error
      assert breadcrumb[:data].reason == "unexpected_error"
      assert breadcrumb[:data].rpc_result == "[redacted]"
      assert breadcrumb[:data].stop_result == "error"
      assert breadcrumb[:data].cancel_reason == "unexpected_cancel"
      refute inspect(breadcrumb[:data]) =~ "/tmp/private"
      refute inspect(breadcrumb[:data]) =~ "example.invalid"
      assert String.ends_with?(breadcrumb[:data].model_id, "...")
      assert byte_size(breadcrumb[:data].model_id) < 140
    end

    test "handler records breadcrumbs only when node telemetry enrichment and request context are enabled" do
      Application.put_env(:orchard_shared, :sentry_enrichment,
        enabled?: true,
        node_agent_enabled?: true,
        telemetry_breadcrumbs_enabled?: true
      )

      Sentry.Context.set_extra_context(%{orchard_request_id: "req_node"})

      SentryTelemetryBridge.handle_event(
        [:orchard, :node, :worker_runtime, :load, :start],
        %{system_time: System.system_time()},
        %{model_id: @test_model_id, version: @test_version, backend: "stub"},
        nil
      )

      assert [%{message: "worker_runtime.load.start", data: data}] =
               Sentry.Context.get_all().breadcrumbs

      assert data.model_id == @test_model_id
      assert data.version == @test_version
      assert data.backend == "stub"
    end

    test "handler skips breadcrumbs when enrichment flags or request context are absent" do
      for config <- [
            [enabled?: false, node_agent_enabled?: true, telemetry_breadcrumbs_enabled?: true],
            [enabled?: true, node_agent_enabled?: false, telemetry_breadcrumbs_enabled?: true],
            [enabled?: true, node_agent_enabled?: true, telemetry_breadcrumbs_enabled?: false],
            [enabled?: true, node_agent_enabled?: true, telemetry_breadcrumbs_enabled?: true]
          ] do
        clear_sentry_context()
        Application.put_env(:orchard_shared, :sentry_enrichment, config)

        SentryTelemetryBridge.handle_event(
          [:orchard, :node, :worker_runtime, :load, :start],
          %{system_time: System.system_time()},
          %{model_id: @test_model_id, version: @test_version, backend: "stub"},
          nil
        )

        assert Sentry.Context.get_all().breadcrumbs == []
      end
    end

    test "handler drops manager telemetry without request-scoped context by design" do
      Application.put_env(:orchard_shared, :sentry_enrichment,
        enabled?: true,
        node_agent_enabled?: true,
        telemetry_breadcrumbs_enabled?: true
      )

      SentryTelemetryBridge.handle_event(
        [:orchard, :node, :model_manager, :load, :stop],
        %{duration_ms: 5},
        %{model_id: @test_model_id, version: @test_version, outcome: :ok},
        nil
      )

      assert Sentry.Context.get_all().breadcrumbs == []
    end
  end

  describe "runtime server Sentry context" do
    test "prepare_request failure reason code never exposes raw terms" do
      assert RuntimeServer.safe_failure_reason_code(:model_busy) == "model_busy"
      assert RuntimeServer.safe_failure_reason_code("worker-unavailable") == "worker_unavailable"
      assert RuntimeServer.safe_failure_reason_code(:not_allowlisted) == "runtime_error"

      assert RuntimeServer.safe_failure_reason_code({:error, "/tmp/private?token=secret"}) ==
               "runtime_error"
    end
  end

  test "node supervisor is already part of the started application tree" do
    pid = Process.whereis(NodeSupervisor)

    assert is_pid(pid)
    assert {:error, {:already_started, ^pid}} = NodeSupervisor.start_link([])
  end

  test "node supervisor boots all required children including gRPC client supervisor" do
    assert is_pid(Process.whereis(NodeSupervisor))
    assert is_pid(Process.whereis(ModelManager))
    assert is_pid(Process.whereis(WorkerSupervisor))
    assert is_pid(Process.whereis(Orchard.Node.ModelLoadTaskSupervisor))

    child_ids =
      Supervisor.which_children(NodeSupervisor)
      |> Enum.map(fn {id, _pid, _type, _modules} -> id end)

    assert NodeSupervisor.grpc_server_id() in child_ids
    assert ModelManager in child_ids
    assert WorkerSupervisor in child_ids
    assert Orchard.Node.ModelLoadTaskSupervisor in child_ids

    # Regression: GRPC.Client.Supervisor must be owned by NodeSupervisor,
    # not just globally registered (test_helper.exs pre-starts it as a
    # workaround, which can mask a missing child spec).
    assert GRPC.Client.Supervisor in child_ids
  end

  test "node agent application supervisor is running" do
    assert is_pid(Process.whereis(NodeAgentSupervisor))
  end

  test "node agent references the shared request, event, and manifest shapes" do
    request =
      CanonicalRequest.new(%{
        internal_id: "req_internal",
        public_id: "req_public",
        endpoint: :responses,
        tenant_id: "tenant_123",
        model_ref: %CanonicalModelRef{model_id: "mlx-community/phi-3", version: "main"}
      })

    event = OrchardInferenceEvent.progress("loading", "warming model")

    manifest =
      ModelManifest.new(%{
        model_id: "mlx-community/phi-3",
        version: "main",
        format: "mlx",
        artifact_layout: "directory",
        entrypoint: "weights/",
        sha256: "abc123",
        max_context_tokens: 32_768,
        capabilities: ["chat"],
        tokenizer: %Tokenizer{kind: "huggingface_tokenizer_json", path: "tokenizer.json"},
        runtime_requirements: %RuntimeRequirements{
          adapter: "mlx_lm",
          min_agent_capability: "mlx"
        }
      })

    assert request.endpoint == :responses
    assert SharedContract.request_model_ref(request).model_id == "mlx-community/phi-3"
    assert SharedContract.event_kind(event) == :progress
    assert %Orchard.Cluster.V1.ModelRef{} = SharedContract.manifest_proto_model_ref(manifest)
  end

  test "test environment config uses fake runtime and local worker paths" do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    assert runtime[:fake_runtime?]
    assert runtime[:listen_address] == [host: "127.0.0.1", port: 50_071]
    assert Path.type(runtime[:models_root]) == :absolute
    assert Path.type(runtime[:worker_socket_dir]) == :absolute
    assert Path.type(runtime[:worker_executable]) == :absolute
    assert String.ends_with?(runtime[:models_root], "/tmp/test/models")
    assert String.ends_with?(runtime[:worker_socket_dir], "/tmp/test/data/worker-sockets")

    assert String.ends_with?(
             runtime[:worker_executable],
             "/native/orchard_worker_mlx/bin/orchard-worker-mlx"
           )

    assert runtime[:worker_backend] == "stub"
    assert runtime[:hosted_tools] == []
    assert runtime[:worker_ready_timeout_ms] == 5_000
    assert runtime[:worker_load_timeout_ms] == 5_000
    assert runtime[:worker_shutdown_timeout_ms] == 1_000
    assert Path.type(runtime[:worker_log_dir]) == :absolute
    assert String.ends_with?(runtime[:worker_log_dir], "/tmp/test/logs/workers")
    assert runtime[:worker_generation_mode] == "stream"
    assert runtime[:worker_max_concurrent_requests_per_model] == 1
    assert runtime[:worker_auto_max_concurrent_requests_per_model] == 3
    assert runtime[:worker_memory_budget_mode] == "observe"
    assert runtime[:worker_memory_budget_utilization] == 0.90
    assert runtime[:worker_memory_budget_overhead_bytes] == 1_073_741_824

    assert Node.listen_host() == "127.0.0.1"
    assert Node.listen_port() == 50_071
    assert Node.fake_runtime?()
    assert Node.runtime_adapter_impl() == Orchard.Node.FakeRuntimeAdapter
    assert Node.worker_backend() == "stub"
    assert Node.worker_ready_timeout_ms() == 5_000
    assert Node.worker_load_timeout_ms() == 5_000
    assert Node.worker_shutdown_timeout_ms() == 1_000
    assert is_binary(Node.worker_log_dir())
    assert is_binary(Node.worker_log_path(@test_model_id, @test_version))
    assert Node.worker_generation_mode() == "stream"
    assert Node.worker_max_concurrent_requests_per_model() == 1
    assert Node.worker_auto_max_concurrent_requests_per_model() == 3
    assert Node.effective_worker_request_limit() == 1
    assert Node.worker_memory_budget_mode() == "observe"
    assert Node.worker_memory_budget_utilization() == 0.90
    assert Node.worker_memory_budget_overhead_bytes() == 1_073_741_824

    # Eviction: disabled by default (0 normalizes to nil)
    assert runtime[:max_loaded_models] == 0
    assert Node.max_loaded_models() == nil
  end

  test "ensure_model_loaded passes remaining deadline budget as load_timeout_ms to adapter", %{
    bundle: bundle
  } do
    with_runtime_adapter(LoadTimeoutCapturingAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert_receive {:captured_load_timeout_ms, timeout_ms}, 1_000
      # The remaining deadline budget is approximately 5000ms minus acquisition time.
      # Acquisition is a cache-hit (fast), so timeout should be close to 5000.
      assert is_integer(timeout_ms)
      assert timeout_ms > 0
      assert timeout_ms <= 5_000
    end)
  end

  test "get_status responds over gRPC" do
    with_channel(fn channel ->
      assert {:ok, %StatusResponse{} = response} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert response.worker_state == :WORKER_STATE_IDLE
      assert response.loaded_models == []
      assert response.active_request_count == 0
      assert response.hosted_tool_capabilities == []
      assert response.hosted_tool_readiness == []
    end)
  end

  test "get_status includes configured hosted tool capability and readiness" do
    with_runtime_config(
      [
        hosted_tools: [
          %{
            name: "lookup_docs",
            version: "2026-04-11",
            adapter_kind: "mcp",
            ready: false,
            readiness_code: "warming",
            readiness_message: "warming up"
          },
          %{name: "calculator", version: "2026-04-10", adapter_kind: "builtin"},
          %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "duplicate", ready: true}
        ]
      ],
      fn ->
        with_channel(fn channel ->
          assert {:ok, %StatusResponse{} = response} =
                   NodeRuntimeStub.get_status(channel, %StatusRequest{})

          assert response.hosted_tool_capabilities == [
                   %HostedToolCapability{
                     name: "calculator",
                     version: "2026-04-10",
                     adapter_kind: "builtin"
                   },
                   %HostedToolCapability{
                     name: "lookup_docs",
                     version: "2026-04-11",
                     adapter_kind: "mcp"
                   }
                 ]

          assert response.hosted_tool_readiness == [
                   %HostedToolReadiness{
                     name: "calculator",
                     version: "2026-04-10",
                     ready: true,
                     readiness_code: "",
                     readiness_message: ""
                   },
                   %HostedToolReadiness{
                     name: "lookup_docs",
                     version: "2026-04-11",
                     ready: false,
                     readiness_code: "warming",
                     readiness_message: "warming up"
                   }
                 ]
        end)
      end
    )
  end

  test "malformed hosted tool config does not break get_status" do
    with_runtime_config(
      [
        hosted_tools: [
          %{name: "bad tool", version: "2026-04-10", adapter_kind: "mcp"},
          %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp", ready: "yes"}
        ]
      ],
      fn ->
        with_channel(fn channel ->
          assert {:ok, %StatusResponse{} = response} =
                   NodeRuntimeStub.get_status(channel, %StatusRequest{})

          assert response.hosted_tool_capabilities == [
                   %HostedToolCapability{
                     name: "lookup_docs",
                     version: "2026-04-11",
                     adapter_kind: "mcp"
                   }
                 ]

          assert response.hosted_tool_readiness == [
                   %HostedToolReadiness{
                     name: "lookup_docs",
                     version: "2026-04-11",
                     ready: false,
                     readiness_code: "invalid_config",
                     readiness_message: "invalid hosted tool readiness configuration"
                   }
                 ]
        end)
      end
    )
  end

  test "get_status includes node metadata" do
    with_channel(fn channel ->
      assert {:ok, %StatusResponse{} = response} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert response.node_metadata != nil
      meta = response.node_metadata
      assert meta.node_id == "00000000-0000-4000-a000-000000000001"
      assert meta.display_name == "test-node"
      assert is_binary(meta.hostname) and meta.hostname != ""
      assert meta.agent_version == Orchard.NodeAgent.version()
      assert is_binary(meta.listen_host) and meta.listen_host != ""
      assert meta.listen_port > 0
      assert meta.worker_backend == "stub"
    end)
  end

  test "get_status reports healthy runtime when idle (no workers)" do
    with_channel(fn channel ->
      assert {:ok, %StatusResponse{} = response} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert response.runtime_health != nil
      health = response.runtime_health
      assert health.ready == true
      assert health.health_code == ""
      assert health.health_message == ""
      assert health.affected_model == nil
    end)
  end

  test "get_status reports healthy runtime with loaded model", %{bundle: bundle} do
    request = ensure_model_loaded_request(bundle)

    with_channel(fn channel ->
      assert {:ok, %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED}} =
               NodeRuntimeStub.ensure_model_loaded(channel, request)

      assert {:ok, %StatusResponse{} = response} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert response.runtime_health != nil
      assert response.runtime_health.ready == true
      assert response.runtime_health.health_code == ""
    end)
  end

  test "get_status advertises prompt token id support when loaded worker reports support", %{
    bundle: bundle
  } do
    with_runtime_adapter(PromptTokenIdsRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert %StatusResponse{} = response = NodeStatus.current()

      assert response.supports_prompt_token_ids == true
    end)
  end

  test "get_status defaults prompt token id support to false for legacy worker status" do
    legacy_bundle = stage_test_bundle!("prompt-token-ids/legacy", "v1")

    on_exit(fn ->
      File.rm_rf(legacy_bundle.cache_path)
      File.rm_rf(legacy_bundle.source_path)
    end)

    with_runtime_adapter(PromptTokenIdsRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(legacy_bundle))

      assert %StatusResponse{} = response = NodeStatus.current()

      assert response.supports_prompt_token_ids == false
    end)
  end

  test "get_status reports prompt token id support only when every loaded worker supports it", %{
    bundle: bundle
  } do
    legacy_bundle = stage_test_bundle!("prompt-token-ids/legacy", "v1")

    on_exit(fn ->
      File.rm_rf(legacy_bundle.cache_path)
      File.rm_rf(legacy_bundle.source_path)
    end)

    with_runtime_adapter(PromptTokenIdsRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(legacy_bundle))

      assert %StatusResponse{} = response = NodeStatus.current()

      assert response.supports_prompt_token_ids == false
    end)
  end

  test "get_status treats worker_status_error as not prompt token id capable", %{
    bundle: bundle
  } do
    status_error_bundle = stage_test_bundle!("prompt-token-ids/status-error", "v1")

    on_exit(fn ->
      File.rm_rf(status_error_bundle.cache_path)
      File.rm_rf(status_error_bundle.source_path)
    end)

    with_runtime_adapter(PromptTokenIdsRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(status_error_bundle))

      assert %StatusResponse{} = response = NodeStatus.current()

      assert response.supports_prompt_token_ids == false
    end)
  end

  test "ensure_model_loaded includes prompt token id support after fresh load", %{bundle: bundle} do
    with_runtime_adapter(PromptTokenIdsRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{
               already_loaded: false,
               placement_state: :PLACEMENT_STATE_LOADED,
               worker_supports_prompt_token_ids: true
             } = NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert_receive {:prompt_token_ids_status_probe, _worker_pid, model_ref}, 1_000
      assert model_ref.model_id == bundle.model_id
      assert model_ref.version == bundle.version
    end)
  end

  test "ensure_model_loaded includes prompt token id support for already-loaded worker", %{
    bundle: bundle
  } do
    with_runtime_adapter(PromptTokenIdsRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      flush_prompt_token_ids_status_probes()

      assert %EnsureModelLoadedResponse{
               already_loaded: true,
               placement_state: :PLACEMENT_STATE_LOADED,
               worker_supports_prompt_token_ids: true
             } = NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert_receive {:prompt_token_ids_status_probe, _worker_pid, model_ref}, 1_000
      assert model_ref.model_id == bundle.model_id
      assert model_ref.version == bundle.version
    end)
  end

  test "ensure_model_loaded already-loaded support probe honors expired deadline", %{
    bundle: bundle
  } do
    with_runtime_config(
      [
        runtime_adapter_impl: PromptTokenIdsRuntimeAdapter,
        test_prompt_token_ids_status_sleep_ms: 700
      ],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 5_000))

        flush_prompt_token_ids_status_probes()

        assert %EnsureModelLoadedResponse{
                 already_loaded: false,
                 placement_state: :PLACEMENT_STATE_FAILED,
                 failure_category: :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT,
                 failure_code: "deadline_exceeded",
                 worker_supports_prompt_token_ids: false
               } = NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 200))
      end
    )
  end

  test "ensure_model_loaded fresh support probe caps status wait to remaining deadline", %{
    bundle: bundle
  } do
    with_runtime_config(
      [
        runtime_adapter_impl: PromptTokenIdsRuntimeAdapter,
        test_prompt_token_ids_status_sleep_ms: 700
      ],
      fn ->
        started_at = System.monotonic_time(:millisecond)

        assert %EnsureModelLoadedResponse{
                 placement_state: :PLACEMENT_STATE_FAILED,
                 failure_category: :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT,
                 failure_code: "deadline_exceeded",
                 worker_supports_prompt_token_ids: false
               } = NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 200))

        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        assert elapsed_ms < 500
      end
    )
  end

  test "ensure_model_loaded honors deadlines that expire during fresh support probe", %{
    bundle: bundle
  } do
    with_runtime_config(
      [
        runtime_adapter_impl: PromptTokenIdsRuntimeAdapter,
        test_prompt_token_ids_status_sleep_ms: 900
      ],
      fn ->
        assert %EnsureModelLoadedResponse{
                 placement_state: :PLACEMENT_STATE_FAILED,
                 failure_category: :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT,
                 failure_code: "deadline_exceeded",
                 worker_supports_prompt_token_ids: false
               } = NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 700))
      end
    )
  end

  test "score_prefix_cache returns model_not_loaded when no matching worker exists" do
    with_channel(fn channel ->
      assert {:ok, %ScorePrefixCacheResponse{} = response} =
               NodeRuntimeStub.score_prefix_cache(
                 channel,
                 score_prefix_cache_request("missing-model", "v1")
               )

      assert response.status_code == "model_not_loaded"
      assert response.score_tier == "unknown"
      assert response.resident_fingerprint_match == false
    end)
  end

  test "score_prefix_cache returns unsupported_version when runtime adapter has no score hook", %{
    bundle: bundle
  } do
    with_runtime_adapter(Orchard.Node.FakeRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      with_channel(fn channel ->
        assert {:ok, %ScorePrefixCacheResponse{} = response} =
                 NodeRuntimeStub.score_prefix_cache(
                   channel,
                   score_prefix_cache_request(bundle.model_id, bundle.version)
                 )

        assert response.status_code == "unsupported_version"
      end)
    end)
  end

  test "score_prefix_cache broker normalizes adapter timeout and malformed responses", %{
    bundle: bundle
  } do
    with_runtime_config(
      [
        runtime_adapter_impl: ScorePrefixCacheRuntimeAdapter,
        test_score_prefix_cache_mode: :timeout
      ],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        with_channel(fn channel ->
          assert {:ok, %ScorePrefixCacheResponse{} = timeout_response} =
                   NodeRuntimeStub.score_prefix_cache(
                     channel,
                     score_prefix_cache_request(bundle.model_id, bundle.version)
                   )

          assert timeout_response.status_code == "timeout"

          runtime =
            Application.fetch_env!(:orchard_node_agent, :runtime)
            |> Keyword.put(:test_score_prefix_cache_mode, :contradictory_timeout)

          Application.put_env(:orchard_node_agent, :runtime, runtime)

          assert {:ok, %ScorePrefixCacheResponse{} = contradictory_response} =
                   NodeRuntimeStub.score_prefix_cache(
                     channel,
                     score_prefix_cache_request(bundle.model_id, bundle.version)
                   )

          assert contradictory_response.status_code == "timeout"
          assert contradictory_response.score_tier == "unknown"
          assert contradictory_response.resident_fingerprint_match == false

          runtime =
            Application.fetch_env!(:orchard_node_agent, :runtime)
            |> Keyword.put(:test_score_prefix_cache_mode, :malformed)

          Application.put_env(:orchard_node_agent, :runtime, runtime)

          assert {:ok, %ScorePrefixCacheResponse{} = malformed_response} =
                   NodeRuntimeStub.score_prefix_cache(
                     channel,
                     score_prefix_cache_request(bundle.model_id, bundle.version)
                   )

          assert malformed_response.status_code == "error"
          assert malformed_response.score_tier == "unknown"
        end)
      end
    )
  end

  test "get_status includes runtime memory budgets for loaded models", %{bundle: bundle} do
    request = ensure_model_loaded_request(bundle)

    with_runtime_adapter(MemoryBudgetRuntimeAdapter, fn ->
      with_channel(fn channel ->
        assert {:ok, %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED}} =
                 NodeRuntimeStub.ensure_model_loaded(channel, request)

        assert {:ok, %StatusResponse{} = response} =
                 NodeRuntimeStub.get_status(channel, %StatusRequest{})

        assert [%{model_ref: %RPCModelRef{} = model_ref} = budget] =
                 response.runtime_memory_budgets

        assert model_ref.model_id == bundle.model_id
        assert model_ref.version == bundle.version
        assert budget.mode == "observe"
        assert budget.budget_available == true
        assert budget.headroom_available == true
        assert budget.status_code == "ok"
        assert budget.target_working_set_bytes == 6_000_000_000
        assert budget.estimated_headroom_bytes == 5_731_516_544
      end)
    end)
  end

  test "get_status includes runtime prefix cache statuses for loaded models", %{bundle: bundle} do
    request = ensure_model_loaded_request(bundle)

    with_runtime_adapter(MemoryBudgetRuntimeAdapter, fn ->
      with_channel(fn channel ->
        assert {:ok, %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED}} =
                 NodeRuntimeStub.ensure_model_loaded(channel, request)

        assert {:ok, %StatusResponse{} = response} =
                 NodeRuntimeStub.get_status(channel, %StatusRequest{})

        assert [%{model_ref: %RPCModelRef{} = model_ref} = prefix_cache_status] =
                 response.runtime_prefix_cache_statuses

        assert model_ref.model_id == bundle.model_id
        assert model_ref.version == bundle.version
        assert prefix_cache_status.implementation == "kv"
        assert prefix_cache_status.enabled == true
        assert prefix_cache_status.entry_count == 2
        assert prefix_cache_status.total_bytes == 32_768
        assert prefix_cache_status.hits == 12
        assert prefix_cache_status.misses == 4
        assert prefix_cache_status.status_code == "ok"
        assert prefix_cache_status.session_started_unix_ms == 1_713_726_400_000
      end)
    end)
  end

  test "get_status sanitizes runtime prefix cache fingerprint sets", %{bundle: bundle} do
    malformed_bundle = stage_test_bundle!("prefix-cache/malformed-fingerprints", "v1")

    on_exit(fn ->
      File.rm_rf(malformed_bundle.cache_path)
      File.rm_rf(malformed_bundle.source_path)
    end)

    with_runtime_adapter(PrefixCacheFingerprintRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(malformed_bundle))

      assert %StatusResponse{} = response = NodeStatus.current()

      by_model =
        Map.new(response.runtime_prefix_cache_statuses, fn status ->
          {status.model_ref.model_id, status}
        end)

      fingerprints = by_model[bundle.model_id].prefix_cache_fingerprints

      assert fingerprints == Enum.map(0..63, &prefix_cache_fingerprint/1)
      assert MapSet.size(MapSet.new(fingerprints)) == 64
      refute "not-a-fingerprint" in fingerprints
      assert by_model[malformed_bundle.model_id].prefix_cache_fingerprints == []
    end)
  end

  test "get_status keeps other prefix cache entries when one worker reports malformed status", %{
    bundle: bundle
  } do
    malformed_bundle = stage_test_bundle!("prefix-cache/malformed", "v1")

    on_exit(fn ->
      File.rm_rf(malformed_bundle.cache_path)
      File.rm_rf(malformed_bundle.source_path)
    end)

    with_runtime_adapter(PrefixCacheMixedRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(malformed_bundle))

      assert %StatusResponse{} = response = NodeStatus.current()
      assert response.runtime_health.ready == true
      assert length(response.runtime_memory_budgets) == 2
      assert length(response.runtime_prefix_cache_statuses) == 2

      by_model =
        Map.new(response.runtime_prefix_cache_statuses, fn status ->
          {status.model_ref.model_id, status}
        end)

      assert by_model[bundle.model_id].status_code == "ok"
      assert by_model[bundle.model_id].entry_count == 2
      assert by_model[malformed_bundle.model_id].status_code == "invalid_status"

      assert by_model[malformed_bundle.model_id].status_message ==
               "prefix cache status contained invalid numeric fields"
    end)
  end

  test "score_prefix_cache returns model_not_loaded when no worker is loaded" do
    response = NodeStatus.score_prefix_cache(score_prefix_cache_request())

    assert %ScorePrefixCacheResponse{status_code: "model_not_loaded"} = response
    assert response.score_tier == "unknown"
    assert response.resident_fingerprint_match == false
  end

  test "score_prefix_cache over gRPC returns normalized selected-worker response", %{
    bundle: bundle
  } do
    with_runtime_config(
      [runtime_adapter_impl: ConfigurableScoreRuntimeAdapter, test_score_mode: :ok],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        with_channel(fn channel ->
          assert {:ok, %ScorePrefixCacheResponse{} = response} =
                   NodeRuntimeStub.score_prefix_cache(channel, score_prefix_cache_request())

          assert response.status_code == "ok"
          assert response.score_tier == "resident_fingerprint"
          assert response.resident_fingerprint_match == true
          assert response.session_started_unix_ms == 1_713_726_400_000
        end)
      end
    )
  end

  test "score_prefix_cache fail-open maps local score call timeout", %{bundle: bundle} do
    with_runtime_config(
      [runtime_adapter_impl: ConfigurableScoreRuntimeAdapter, test_score_mode: :sleep],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        request = %{
          score_prefix_cache_request()
          | deadline_unix_ms: System.system_time(:millisecond) + 10
        }

        response = NodeStatus.score_prefix_cache(request)
        assert response.status_code == "timeout"
        assert response.score_tier == "unknown"
        assert response.resident_fingerprint_match == false
      end
    )
  end

  test "score_prefix_cache fail-open maps timeout and malformed adapter responses", %{
    bundle: bundle
  } do
    with_runtime_config(
      [runtime_adapter_impl: ConfigurableScoreRuntimeAdapter, test_score_mode: :timeout],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        timeout_response = NodeStatus.score_prefix_cache(score_prefix_cache_request())
        assert timeout_response.status_code == "timeout"
        assert timeout_response.score_tier == "unknown"
        assert timeout_response.resident_fingerprint_match == false
      end
    )

    with_runtime_config(
      [runtime_adapter_impl: ConfigurableScoreRuntimeAdapter, test_score_mode: :malformed],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        malformed_response = NodeStatus.score_prefix_cache(score_prefix_cache_request())
        assert malformed_response.status_code == "error"
        assert malformed_response.score_tier == "unknown"
        assert malformed_response.resident_fingerprint_match == false
      end
    )

    with_runtime_config(
      [
        runtime_adapter_impl: ConfigurableScoreRuntimeAdapter,
        test_score_mode: :contradictory_timeout
      ],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        contradictory_response = NodeStatus.score_prefix_cache(score_prefix_cache_request())
        assert contradictory_response.status_code == "timeout"
        assert contradictory_response.score_tier == "unknown"
        assert contradictory_response.resident_fingerprint_match == false
      end
    )
  end

  test "score_prefix_cache returns unsupported_version when adapter lacks score RPC", %{
    bundle: bundle
  } do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      response = NodeStatus.score_prefix_cache(score_prefix_cache_request())
      assert response.status_code == "unsupported_version"
      assert response.score_tier == "unknown"
      assert response.resident_fingerprint_match == false
    end)
  end

  test "get_status reuses one worker status snapshot for health and memory budgets", %{
    bundle: bundle
  } do
    request = ensure_model_loaded_request(bundle)

    with_runtime_adapter(CountingStatusRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(request)

      flush_counting_status_probes()

      assert %StatusResponse{} = response = NodeStatus.current()
      assert response.runtime_health.ready == true
      assert [%{model_ref: %RPCModelRef{} = model_ref}] = response.runtime_memory_budgets

      assert [%{model_ref: %RPCModelRef{} = prefix_cache_model_ref}] =
               response.runtime_prefix_cache_statuses

      assert model_ref.model_id == bundle.model_id
      assert model_ref.version == bundle.version
      assert prefix_cache_model_ref.model_id == bundle.model_id
      assert prefix_cache_model_ref.version == bundle.version

      assert_receive {:counting_status_probe, _worker_pid}, 1_000
      refute_receive {:counting_status_probe, _worker_pid}, 100
    end)
  end

  test "get_status skips loaded-worker budget probes while load is inflight", %{bundle: bundle} do
    blocked_bundle = stage_test_bundle!("status-probe/blocked", "v1")

    on_exit(fn ->
      File.rm_rf(blocked_bundle.cache_path)
      File.rm_rf(blocked_bundle.source_path)
    end)

    with_runtime_adapter(StatusProbeShortCircuitAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      flush_short_circuit_status_probes()

      ensure_task =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(ensure_model_loaded_request(blocked_bundle, 10_000))
        end)

      assert_receive {:short_circuit_blocking_load_started, blocking_pid, blocked_model_ref},
                     1_000

      assert %StatusResponse{} = response = NodeStatus.current()
      assert response.runtime_health.ready == false
      assert response.runtime_health.health_code == "starting"
      assert response.runtime_health.health_message == "model load in progress"
      assert response.runtime_health.affected_model.model_id == blocked_bundle.model_id
      assert response.runtime_health.affected_model.version == blocked_bundle.version
      assert response.runtime_memory_budgets == []
      assert response.runtime_prefix_cache_statuses == []

      assert Enum.any?(
               response.loaded_models,
               &(&1.model_id == bundle.model_id and &1.version == bundle.version)
             )

      refute Enum.any?(
               response.loaded_models,
               &(&1.model_id == blocked_bundle.model_id and &1.version == blocked_bundle.version)
             )

      refute_receive {:short_circuit_status_probe, _pid, _model_ref}, 100

      send(blocking_pid, :finish_load)

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               Task.await(ensure_task, 5_000)

      assert blocked_model_ref.model_id == blocked_bundle.model_id
      assert blocked_model_ref.version == blocked_bundle.version
    end)
  end

  test "get_status downgrades invalid runtime memory budget values from runtime adapter", %{
    bundle: bundle
  } do
    assert_invalid_runtime_memory_budget_is_downgraded(bundle, huge_integer_utilization())
  end

  test "ensure_model_loaded is idempotent and does not create duplicate workers", %{
    bundle: bundle
  } do
    request = ensure_model_loaded_request(bundle)

    with_channel(fn channel ->
      assert {:ok,
              %EnsureModelLoadedResponse{
                already_loaded: false,
                placement_state: :PLACEMENT_STATE_LOADED
              }} = NodeRuntimeStub.ensure_model_loaded(channel, request)

      assert {:ok, %EnsureModelLoadedResponse{already_loaded: true}} =
               NodeRuntimeStub.ensure_model_loaded(channel, request)

      assert {:ok, %StatusResponse{loaded_models: [%RPCModelRef{} = loaded_model]}} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      assert loaded_model.model_id == @test_model_id
      assert loaded_model.version == @test_version
      assert worker_count() == 1
    end)
  end

  test "execute_inference streams accepted, deterministic deltas, and terminal completion", %{
    bundle: bundle
  } do
    request = execute_inference_request("req-r3-execute")

    with_channel(fn channel ->
      assert {:ok, _response} =
               NodeRuntimeStub.ensure_model_loaded(
                 channel,
                 ensure_model_loaded_request(bundle)
               )

      assert {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request)

      assert [
               {:ok,
                %RPCInferenceEvent{
                  event: {:accepted, %Accepted{accepted_at_unix_ms: accepted_at}}
                }},
               {:ok,
                %RPCInferenceEvent{
                  event: {:output_text_delta, %OutputTextDelta{delta: "orchard "}}
                }},
               {:ok,
                %RPCInferenceEvent{
                  event: {:output_text_delta, %OutputTextDelta{delta: "ready"}}
                }},
               {:ok,
                %RPCInferenceEvent{
                  event:
                    {:completed,
                     %Completed{
                       finish_reason: :FINISH_REASON_STOP,
                       usage: %TokenUsage{input_tokens: 2, output_tokens: 2, total_tokens: 4}
                     }}
                }}
             ] = Enum.to_list(event_stream)

      assert is_integer(accepted_at)
      assert accepted_at > 0

      assert {:ok, %StatusResponse{active_request_count: 0}} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      worker_state = :sys.get_state(worker_pid())
      assert worker_state.adapter_state.generations == %{}
    end)
  end

  test "real worker runtime adapter streams stub worker events and unload cleans up the socket",
       %{bundle: bundle} do
    with_real_worker_runtime(fn ->
      socket_path = real_worker_socket_path()

      refute File.exists?(socket_path)

      with_channel(fn channel ->
        assert {:ok,
                %EnsureModelLoadedResponse{
                  already_loaded: false,
                  placement_state: :PLACEMENT_STATE_LOADED
                }} =
                 NodeRuntimeStub.ensure_model_loaded(
                   channel,
                   ensure_model_loaded_request(bundle)
                 )

        wait_until(fn -> File.exists?(socket_path) end)

        request = execute_inference_request("req-r5-real-runtime")
        assert {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request)

        assert [
                 {:ok,
                  %RPCInferenceEvent{
                    event: {:accepted, %Accepted{accepted_at_unix_ms: accepted_at}}
                  }},
                 {:ok,
                  %RPCInferenceEvent{
                    event: {:output_text_delta, %OutputTextDelta{delta: "mlx "}}
                  }},
                 {:ok,
                  %RPCInferenceEvent{
                    event: {:output_text_delta, %OutputTextDelta{delta: "ready"}}
                  }},
                 {:ok,
                  %RPCInferenceEvent{
                    event:
                      {:completed,
                       %Completed{
                         finish_reason: :FINISH_REASON_STOP,
                         usage: %TokenUsage{input_tokens: 2, output_tokens: 2, total_tokens: 4}
                       }}
                  }}
               ] = Enum.to_list(event_stream)

        assert is_integer(accepted_at)
        assert accepted_at > 0

        assert {:ok, %{ok: true, message: "unload accepted"}} =
                 NodeRuntimeStub.unload_model(
                   channel,
                   %UnloadModelRequest{
                     model_id: @test_model_id,
                     version: @test_version,
                     force: false,
                     evict: false
                   }
                 )
      end)

      wait_until(fn -> worker_count() == 0 end)
      refute File.exists?(socket_path)
    end)
  end

  test "real worker runtime forwards Python lifecycle logs to Elixir Logger",
       %{bundle: bundle} do
    with_real_worker_runtime(fn ->
      # Temporarily lower Logger level — test.exs sets :warning, but we need :info.
      previous_level = Logger.level()
      Logger.configure(level: :info)

      try do
        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            with_channel(fn channel ->
              assert {:ok,
                      %EnsureModelLoadedResponse{
                        placement_state: :PLACEMENT_STATE_LOADED
                      }} =
                       NodeRuntimeStub.ensure_model_loaded(
                         channel,
                         ensure_model_loaded_request(bundle)
                       )

              # Give the GenServer a moment to process port data messages
              # that arrived during the gRPC call.
              Process.sleep(100)

              assert {:ok, %{ok: true}} =
                       NodeRuntimeStub.unload_model(
                         channel,
                         %UnloadModelRequest{
                           model_id: @test_model_id,
                           version: @test_version,
                           force: false,
                           evict: false
                         }
                       )
            end)

            wait_until(fn -> worker_count() == 0 end)
          end)

        # Assert on load_model logs emitted during the LoadModel RPC.
        # Bootstrap logs ("worker starting", "worker listening") may be consumed
        # by the adapter's readiness polling receive loop.
        assert log =~ "load_model start"
        assert log =~ "load_model ok"
      after
        Logger.configure(level: previous_level)
      end
    end)
  end

  test "real worker runtime creates deterministic log file under worker_log_dir",
       %{bundle: bundle} do
    with_real_worker_runtime(fn ->
      log_path = Node.worker_log_path(@test_model_id, @test_version)

      with_channel(fn channel ->
        assert {:ok,
                %EnsureModelLoadedResponse{
                  placement_state: :PLACEMENT_STATE_LOADED
                }} =
                 NodeRuntimeStub.ensure_model_loaded(
                   channel,
                   ensure_model_loaded_request(bundle)
                 )

        assert {:ok, %{ok: true}} =
                 NodeRuntimeStub.unload_model(
                   channel,
                   %UnloadModelRequest{
                     model_id: @test_model_id,
                     version: @test_version,
                     force: false,
                     evict: false
                   }
                 )
      end)

      wait_until(fn -> worker_count() == 0 end)

      assert File.exists?(log_path), "deterministic log file should exist at #{log_path}"
      content = File.read!(log_path)
      assert content =~ "load_model start"
      assert content =~ "load_model ok"
      assert content =~ "[INFO]"

      # Cleanup
      File.rm(log_path)
    end)
  end

  test "real worker runtime adapter worker death emits a terminal failure and clears runtime state",
       %{bundle: bundle} do
    with_real_worker_runtime(fn ->
      socket_path = real_worker_socket_path()

      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request =
        execute_inference_request("req-r5-worker-down")
        |> Map.put(:metadata_json, ~s({"worker_delay_ms":2000,"worker_chunks":["mlx ","worker"]}))

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      assert_receive {:node_runtime_event, "req-r5-worker-down",
                      %Orchard.InferenceEvent{event: %Orchard.InferenceEvent.OutputTextDelta{}}},
                     5_000

      os_pid = worker_os_pid()
      kill_process_tree(os_pid)

      assert_receive {:node_runtime_event, "req-r5-worker-down",
                      %Orchard.InferenceEvent{event: %{code: "worker_down"}}},
                     5_000

      wait_until(fn -> worker_count() == 0 end)
      refute File.exists?(socket_path)
      assert %StatusResponse{active_request_count: 0, loaded_models: []} = NodeStatus.current()
    end)
  end

  test "worker death during a running request emits a terminal failure and clears runtime state",
       %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request = execute_inference_request("req-r3-worker-down")

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      wait_until(fn -> NodeStatus.current().active_request_count == 1 end)
      Process.exit(worker_pid(), :kill)

      assert_receive {:node_runtime_event, "req-r3-worker-down",
                      %Orchard.InferenceEvent{event: %{code: "worker_down"}}},
                     1_000

      assert %StatusResponse{active_request_count: 0, loaded_models: []} = NodeStatus.current()
    end)
  end

  test "worker_unavailable runtime done clears the worker and active request state", %{
    bundle: bundle
  } do
    with_runtime_adapter(UnavailableDoneRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request = execute_inference_request("req-worker-unavailable")

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      assert_receive {:node_runtime_event, "req-worker-unavailable",
                      %Orchard.InferenceEvent{event: %{code: "worker_unavailable"}}},
                     1_000

      wait_until(fn -> worker_count() == 0 end)
      assert %StatusResponse{active_request_count: 0, loaded_models: []} = NodeStatus.current()
    end)
  end

  test "unload error does not leave stale loaded worker state", %{bundle: bundle} do
    with_runtime_adapter(FailingUnloadAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert %{ok: false, message: message} =
               NodeStatus.unload_model(%UnloadModelRequest{
                 model_id: @test_model_id,
                 version: @test_version,
                 force: false,
                 evict: false
               })

      assert message =~ "simulated_unload_failure"
      wait_until(fn -> worker_count() == 0 end)
      assert %StatusResponse{loaded_models: []} = NodeStatus.current()
    end)
  end

  test "force unload during a running request emits a terminal failure and clears runtime state",
       %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request = execute_inference_request("req-r3-force-unload")

      assert :ok = NodeStatus.prepare_request(request, self())
      assert :ok = NodeStatus.start_request(request)

      wait_until(fn -> NodeStatus.current().active_request_count == 1 end)

      assert %{ok: true, message: "unload accepted"} =
               NodeStatus.unload_model(%UnloadModelRequest{
                 model_id: @test_model_id,
                 version: @test_version,
                 force: true,
                 evict: false
               })

      assert_receive {:node_runtime_event, "req-r3-force-unload",
                      %Orchard.InferenceEvent{event: %{code: "worker_unloaded"}}},
                     1_000

      assert %StatusResponse{active_request_count: 0, loaded_models: []} = NodeStatus.current()
    end)
  end

  test "subscriber disconnect before start_request does not leave stale prepared runtime state",
       %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      subscriber =
        spawn(fn ->
          receive do
          end
        end)

      request = execute_inference_request("req-r3-prepared-disconnect")

      assert :ok = NodeStatus.prepare_request(request, subscriber)
      Process.exit(subscriber, :kill)

      wait_until(fn -> NodeStatus.current().active_request_count == 0 end)

      assert %StatusResponse{active_request_count: 0} = NodeStatus.current()

      assert %{ok: true, message: "unload accepted"} =
               NodeStatus.unload_model(%UnloadModelRequest{
                 model_id: @test_model_id,
                 version: @test_version,
                 force: false,
                 evict: false
               })
    end)
  end

  test "cancelling a prepared request prevents later start_request from launching it", %{
    bundle: bundle
  } do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request = execute_inference_request("req-r3-prepared-cancel")

      assert :ok = NodeStatus.prepare_request(request, self())

      assert %{ok: true, message: "cancel accepted"} =
               NodeStatus.cancel_request(request.request_id, request.controller_session_id)

      assert {:error, :request_not_prepared} = NodeStatus.start_request(request)
      assert %StatusResponse{active_request_count: 0} = NodeStatus.current()
      refute_receive {:node_runtime_event, "req-r3-prepared-cancel", _event}, 100
    end)
  end

  test "license denial at start_request cleans up prepared request state", %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      with_hard_mode_license(fn ->
        copy_license_fixture!("valid_bound_to_local")
        Gate.refresh()

        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        request = execute_inference_request("req-license-flip-start")

        assert :ok = NodeStatus.prepare_request(request, self())
        assert %StatusResponse{active_request_count: 1} = NodeStatus.current()

        replace_license_bundle_externally!("expired")
        Gate.refresh()

        assert {:error, :license_invalid} = NodeStatus.start_request(request)
        assert %StatusResponse{active_request_count: 0} = NodeStatus.current()
        refute_receive {:node_runtime_event, "req-license-flip-start", _event}, 100
      end)
    end)
  end

  test "cancel_inference is accepted over gRPC" do
    with_channel(fn channel ->
      request = %CancelInferenceRequest{
        request_id: "req-r2-cancel",
        controller_session_id: "controller-session-2"
      }

      assert {:ok, %{ok: true, message: "cancel accepted"}} =
               NodeRuntimeStub.cancel_inference(channel, request)
    end)
  end

  test "prepare_request rejects second request for same model with model_busy", %{
    bundle: bundle
  } do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      request1 = execute_inference_request("req-busy-first")
      request2 = execute_inference_request("req-busy-second")

      assert :ok = NodeStatus.prepare_request(request1, self())

      # Second request for same model should be rejected as model_busy.
      assert {:error, :model_busy} = NodeStatus.prepare_request(request2, self())

      # Clean up: cancel the first request so the model is released.
      assert %{ok: true} = NodeStatus.cancel_request(request1.request_id)
    end)
  end

  test "gRPC execute_inference streams model_busy failure without Accepted when model is busy",
       %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      # Start a blocking first request via direct API (not gRPC) to hold the model.
      request1 = execute_inference_request("req-grpc-busy-first")
      assert :ok = NodeStatus.prepare_request(request1, self())
      assert :ok = NodeStatus.start_request(request1)

      wait_until(fn -> NodeStatus.current().active_request_count == 1 end)

      # Second request via gRPC should get a failed event with model_busy, no Accepted.
      with_channel(fn channel ->
        request2 = execute_inference_request("req-grpc-busy-second")
        assert {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request2)
        events = Enum.to_list(event_stream)

        # Should have exactly one event: a failed with model_busy
        assert [{:ok, %RPCInferenceEvent{event: {:failed, failed}}}] = events
        assert failed.code == "model_busy"

        # No accepted event
        accepted_events =
          Enum.filter(events, fn
            {:ok, %RPCInferenceEvent{event: {:accepted, _}}} -> true
            _ -> false
          end)

        assert accepted_events == []
      end)

      # Release the blocking request.
      generation_ref = get_blocking_generation_ref()
      send_release(generation_ref)

      assert_receive {:node_runtime_event, "req-grpc-busy-first",
                      %OrchardInferenceEvent{event: %OrchardInferenceEvent.OutputTextDelta{}}},
                     1_000

      assert_receive {:node_runtime_event, "req-grpc-busy-first",
                      %OrchardInferenceEvent{event: %OrchardInferenceEvent.Completed{}}},
                     1_000
    end)
  end

  test "batch mode allows two active requests and rejects the third at prepare time",
       %{bundle: bundle} do
    with_runtime_config(
      [
        runtime_adapter_impl: BlockingRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 2,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      ],
      fn ->
        assert Node.effective_worker_request_limit() == 2

        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        request1 = execute_inference_request("req-batch-first")
        request2 = execute_inference_request("req-batch-second")
        request3 = execute_inference_request("req-batch-third")

        assert :ok = NodeStatus.prepare_request(request1, self())
        assert :ok = NodeStatus.start_request(request1)
        assert :ok = NodeStatus.prepare_request(request2, self())
        assert :ok = NodeStatus.start_request(request2)

        wait_until(fn -> NodeStatus.current().active_request_count == 2 end)

        assert {:error, :model_busy} = NodeStatus.prepare_request(request3, self())

        assert %{ok: true} = NodeStatus.cancel_request(request1.request_id)
        assert %{ok: true} = NodeStatus.cancel_request(request2.request_id)
        wait_until(fn -> NodeStatus.current().active_request_count == 0 end)
      end
    )
  end

  test "batch mode accepts two same-model gRPC streams and reports active placement capacity", %{
    bundle: bundle
  } do
    with_runtime_config(
      [
        runtime_adapter_impl: BlockingRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 2,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      ],
      fn ->
        request1 = execute_inference_request("req-batch-grpc-active-first")
        request2 = execute_inference_request("req-batch-grpc-active-second")
        request_id1 = request1.request_id
        request_id2 = request2.request_id

        with_channel(fn channel ->
          assert {:ok, %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED}} =
                   NodeRuntimeStub.ensure_model_loaded(
                     channel,
                     ensure_model_loaded_request(bundle)
                   )

          task1 = start_execute_inference_task(request1, self())
          task2 = start_execute_inference_task(request2, self())

          try do
            assert_execute_inference_accepted([request_id1, request_id2])

            refs = wait_for_generation_refs([request_id1, request_id2])

            status = grpc_status_snapshot()
            assert status.active_request_count == 2

            placement = runtime_model_placement!(status, @test_model_id, @test_version)
            assert placement.active_request_count == 2
            assert placement.max_concurrency == 2

            send_release(Map.fetch!(refs, request_id1))
            send_release(Map.fetch!(refs, request_id2))

            assert_blocking_stream_completed(Task.await(task1, 5_000))
            assert_blocking_stream_completed(Task.await(task2, 5_000))

            wait_until(fn ->
              grpc_status_snapshot().active_request_count == 0
            end)

            final_status = grpc_status_snapshot()

            final_placement =
              runtime_model_placement!(final_status, @test_model_id, @test_version)

            assert final_placement.active_request_count == 0
            assert final_placement.max_concurrency == 2
          after
            try do
              best_effort_release_generation_refs([request_id1, request_id2])
            after
              Task.shutdown(task1, :brutal_kill)
              Task.shutdown(task2, :brutal_kill)
            end
          end
        end)
      end
    )
  end

  test "current status reports loaded model placement capacity", %{bundle: bundle} do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
               NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

      assert %StatusResponse{
               runtime_model_placements: [
                 %{
                   model_ref: %{model_id: @test_model_id, version: @test_version},
                   active_request_count: 0,
                   max_concurrency: 1
                 }
               ]
             } = NodeStatus.current()
    end)
  end

  test "current status reports stream mode placement max concurrency as one", %{bundle: bundle} do
    with_runtime_config(
      [
        runtime_adapter_impl: BlockingRuntimeAdapter,
        worker_generation_mode: "stream",
        worker_max_concurrent_requests_per_model: 4,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      ],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        assert %StatusResponse{
                 runtime_model_placements: [
                   %{
                     model_ref: %{model_id: @test_model_id, version: @test_version},
                     active_request_count: 0,
                     max_concurrency: 1
                   }
                 ]
               } = NodeStatus.current()
      end
    )
  end

  test "current status reports batch placement active count and max concurrency", %{
    bundle: bundle
  } do
    with_runtime_config(
      [
        runtime_adapter_impl: BlockingRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 2,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      ],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        request = execute_inference_request("req-batch-status-first")
        assert :ok = NodeStatus.prepare_request(request, self())

        assert %StatusResponse{
                 runtime_model_placements: [
                   %{
                     model_ref: %{model_id: @test_model_id, version: @test_version},
                     active_request_count: 1,
                     max_concurrency: 2
                   }
                 ]
               } = NodeStatus.current()

        assert %{ok: true} = NodeStatus.cancel_request(request.request_id)
      end
    )
  end

  test "batch mode still maps third request to gRPC model_busy without Accepted", %{
    bundle: bundle
  } do
    with_runtime_config(
      [
        runtime_adapter_impl: BlockingRuntimeAdapter,
        worker_generation_mode: "batch",
        worker_max_concurrent_requests_per_model: 2,
        test_only_allow_batch_admission_for_non_worker_adapters?: true
      ],
      fn ->
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

        request1 = execute_inference_request("req-batch-grpc-first")
        request2 = execute_inference_request("req-batch-grpc-second")

        assert :ok = NodeStatus.prepare_request(request1, self())
        assert :ok = NodeStatus.start_request(request1)
        assert :ok = NodeStatus.prepare_request(request2, self())
        assert :ok = NodeStatus.start_request(request2)

        wait_until(fn -> NodeStatus.current().active_request_count == 2 end)

        with_channel(fn channel ->
          request3 = execute_inference_request("req-batch-grpc-third")
          assert {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request3)
          events = Enum.to_list(event_stream)

          assert [{:ok, %RPCInferenceEvent{event: {:failed, failed}}}] = events
          assert failed.code == "model_busy"

          accepted_events =
            Enum.filter(events, fn
              {:ok, %RPCInferenceEvent{event: {:accepted, _}}} -> true
              _ -> false
            end)

          assert accepted_events == []
        end)

        assert %{ok: true} = NodeStatus.cancel_request(request1.request_id)
        assert %{ok: true} = NodeStatus.cancel_request(request2.request_id)
        wait_until(fn -> NodeStatus.current().active_request_count == 0 end)
      end
    )
  end

  # -- Acquisition-specific tests ---------------------------------------------

  test "ensure_model_loaded with missing source and no cache returns FAILED", %{bundle: bundle} do
    # Remove the pre-staged cache so acquisition must fetch from source
    File.rm_rf!(bundle.cache_path)

    request = %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: @test_model_id,
      version: @test_version,
      artifact_sha256: bundle.hash,
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      artifact_source_uri: ""
    }

    result = NodeStatus.ensure_model_loaded(request)
    assert result.placement_state == :PLACEMENT_STATE_FAILED
    assert result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_ACQUISITION_FAILED
    assert result.failure_code == "missing_artifact_source_uri"
    assert result.failure_message != ""
  end

  test "ensure_model_loaded acquires from file:// source when cache is missing", %{
    bundle: bundle
  } do
    # Remove the pre-staged cache so acquisition must fetch from source
    File.rm_rf!(bundle.cache_path)

    assert %EnsureModelLoadedResponse{
             already_loaded: false,
             placement_state: :PLACEMENT_STATE_LOADED
           } = NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))

    # Cache should now exist
    assert File.dir?(bundle.cache_path)
    expected_hash = bundle.hash
    assert {:ok, ^expected_hash} = ArtifactBundle.tree_sha256(bundle.cache_path)
  end

  test "ensure_model_loaded hash mismatch returns FAILED", %{bundle: bundle} do
    # Remove cache and request with wrong hash
    File.rm_rf!(bundle.cache_path)

    request = %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: @test_model_id,
      version: @test_version,
      artifact_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      artifact_source_uri: bundle.source_uri
    }

    result = NodeStatus.ensure_model_loaded(request)
    assert result.placement_state == :PLACEMENT_STATE_FAILED
    assert result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_MODEL_INVALID
    assert result.failure_code == "artifact_hash_mismatch"
    assert result.failure_message != ""

    # Staging directory should be cleaned up
    staging_dir = Path.join([Node.models_root(), ".staging"])

    if File.exists?(staging_dir) do
      assert File.ls!(staging_dir) == []
    end
  end

  test "concurrent ensure_model_loaded calls single-flight to one acquisition task", %{
    bundle: bundle
  } do
    with_runtime_adapter(BlockingRuntimeAdapter, fn ->
      request = ensure_model_loaded_request(bundle)

      # Spawn two concurrent ensure calls
      task1 =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(request)
        end)

      task2 =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(request)
        end)

      # Both should succeed
      result1 = Task.await(task1, 10_000)
      result2 = Task.await(task2, 10_000)

      assert result1.placement_state == :PLACEMENT_STATE_LOADED
      assert result2.placement_state == :PLACEMENT_STATE_LOADED

      # Only one worker should exist
      assert worker_count() == 1
    end)
  end

  test "reset cancels inflight ensure_model_loaded and replies FAILED", %{bundle: bundle} do
    with_runtime_adapter(SlowLoadAdapter, fn ->
      # Start an ensure that will block in load_model
      ensure_task =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))
        end)

      # Wait until we see the inflight load in progress
      wait_until(fn -> NodeStatus.current().worker_state == :WORKER_STATE_STARTING end)

      # Reset should cancel the inflight load
      :ok = NodeStatus.reset()

      # The blocked caller should receive FAILED with cancellation category
      result = Task.await(ensure_task, 5_000)
      assert result.placement_state == :PLACEMENT_STATE_FAILED
      assert result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
      assert result.failure_code == "load_cancelled"

      # State should be clean
      assert %StatusResponse{worker_state: :WORKER_STATE_IDLE, loaded_models: []} =
               NodeStatus.current()
    end)
  end

  test "unload cancels inflight ensure_model_loaded for that model", %{bundle: bundle} do
    with_runtime_adapter(SlowLoadAdapter, fn ->
      # Start an ensure that will block in load_model
      ensure_task =
        Task.async(fn ->
          NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))
        end)

      # Wait until we see the inflight load in progress
      wait_until(fn -> NodeStatus.current().worker_state == :WORKER_STATE_STARTING end)

      # Unload should cancel the inflight load
      assert %{ok: true, message: "unload accepted"} =
               NodeStatus.unload_model(%UnloadModelRequest{
                 model_id: @test_model_id,
                 version: @test_version,
                 force: false,
                 evict: false
               })

      # The blocked caller should receive FAILED with cancellation category
      result = Task.await(ensure_task, 5_000)
      assert result.placement_state == :PLACEMENT_STATE_FAILED
      assert result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
      assert result.failure_code == "load_cancelled"
    end)
  end

  # -- Unhealthy worker fail-fast test -----------------------------------------

  test "unhealthy worker returns {:error, {:worker_unhealthy, ...}} and cleans up fast",
       %{bundle: bundle} do
    unhealthy_executable =
      Path.expand("support/unhealthy-worker", Path.dirname(__ENV__.file))

    # Guard: ensure the fixture actually exists so this test exercises the
    # unhealthy-worker code path, not :worker_executable_not_found.
    assert File.exists?(unhealthy_executable),
           "unhealthy-worker fixture not found at #{unhealthy_executable}"

    with_runtime_config(
      [
        runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter,
        fake_runtime?: false,
        worker_executable: unhealthy_executable
      ],
      fn ->
        start_time = System.monotonic_time(:millisecond)

        with_channel(fn channel ->
          result =
            NodeRuntimeStub.ensure_model_loaded(
              channel,
              ensure_model_loaded_request(bundle)
            )

          elapsed = System.monotonic_time(:millisecond) - start_time

          # Should fail — unhealthy worker detected during readiness polling.
          assert {:ok, %EnsureModelLoadedResponse{} = response} = result
          assert response.placement_state == :PLACEMENT_STATE_FAILED
          assert response.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
          assert response.failure_code == "mlx_backend_unavailable"

          # Should fail fast — well under the default ready timeout (5000ms).
          # The unhealthy worker should be detected on the first GetStatus call.
          assert elapsed < 4_000,
                 "Expected fail-fast but took #{elapsed}ms (near full ready timeout)"
        end)

        wait_until(fn -> worker_count() == 0 end)
      end
    )
  end

  # -- Worker lifecycle telemetry tests ----------------------------------------

  describe "worker lifecycle telemetry" do
    test "successful load emits manager and runtime start/stop telemetry", %{bundle: bundle} do
      with_real_worker_runtime(fn ->
        events =
          with_telemetry_collector(all_lifecycle_events(), fn ->
            with_channel(fn channel ->
              assert {:ok,
                      %EnsureModelLoadedResponse{
                        already_loaded: false,
                        placement_state: :PLACEMENT_STATE_LOADED
                      }} =
                       NodeRuntimeStub.ensure_model_loaded(
                         channel,
                         ensure_model_loaded_request(bundle)
                       )

              # Unload
              assert {:ok, %{ok: true}} =
                       NodeRuntimeStub.unload_model(
                         channel,
                         %UnloadModelRequest{
                           model_id: @test_model_id,
                           version: @test_version,
                           force: false,
                           evict: false
                         }
                       )
            end)

            wait_until(fn -> worker_count() == 0 end)
          end)

        # Manager load lifecycle
        assert_telemetry_event(events, [:orchard, :node, :model_manager, :load, :start], fn _m,
                                                                                            meta ->
          assert meta.model_id == @test_model_id
          assert meta.version == @test_version
          assert meta.backend == "stub"
          assert meta.source_scheme == "file"
          assert meta.preload == true
        end)

        assert_telemetry_event(events, [:orchard, :node, :model_manager, :load, :stop], fn m,
                                                                                           meta ->
          assert m.duration_ms >= 0
          assert meta.model_id == @test_model_id
          assert meta.version == @test_version
          assert meta.source_scheme == "file"
          assert meta.preload == true
          assert meta.outcome == :loaded
          assert meta.worker_started == true
          assert meta.waiter_count == 1
          assert meta.replied_waiter_count == 1
        end)

        # Runtime load lifecycle
        assert_telemetry_event(events, [:orchard, :node, :worker_runtime, :load, :start], fn _m,
                                                                                             meta ->
          assert meta.model_id == @test_model_id
          assert meta.version == @test_version
          assert meta.backend == "stub"
          assert meta.adapter == Orchard.Node.WorkerRuntimeAdapter
        end)

        assert_telemetry_event(events, [:orchard, :node, :worker_runtime, :load, :stop], fn m,
                                                                                            meta ->
          assert m.duration_ms >= 0
          assert meta.outcome == :loaded
        end)

        # Runtime unload lifecycle
        assert_telemetry_event(
          events,
          [:orchard, :node, :worker_runtime, :unload, :start],
          fn _m, meta ->
            assert meta.model_id == @test_model_id
            assert meta.skip_rpc == false
          end
        )

        assert_telemetry_event(
          events,
          [:orchard, :node, :worker_runtime, :unload, :stop],
          fn m, meta ->
            assert m.duration_ms >= 0
            assert meta.outcome == :unloaded
            assert meta.rpc_result == :ok
            assert meta.stop_result == :ok
            assert meta.skip_rpc == false
          end
        )
      end)
    end

    test "failed load emits manager and runtime exception telemetry", %{bundle: bundle} do
      with_runtime_config(
        [
          runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter,
          fake_runtime?: false,
          worker_executable: "/nonexistent/orchard-worker-mlx"
        ],
        fn ->
          events =
            with_telemetry_collector(all_lifecycle_events(), fn ->
              result = NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))
              assert result.placement_state == :PLACEMENT_STATE_FAILED
              assert result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_RUNTIME_UNAVAILABLE
              assert result.failure_code == "worker_executable_not_found"
            end)

          assert_telemetry_event(
            events,
            [:orchard, :node, :model_manager, :load, :start],
            fn _m, meta ->
              assert meta.model_id == @test_model_id
              assert meta.version == @test_version
              assert meta.source_scheme == "file"
              assert meta.preload == true
            end
          )

          assert_telemetry_event(
            events,
            [:orchard, :node, :model_manager, :load, :exception],
            fn m, meta ->
              assert m.duration_ms >= 0
              assert meta.model_id == @test_model_id
              assert meta.version == @test_version
              assert meta.reason == :worker_executable_not_found
              assert meta.worker_started == true
            end
          )

          assert_telemetry_event(
            events,
            [:orchard, :node, :worker_runtime, :load, :start],
            fn _m, meta ->
              assert meta.model_id == @test_model_id
              assert meta.backend == "stub"
              assert meta.adapter == Orchard.Node.WorkerRuntimeAdapter
            end
          )

          assert_telemetry_event(
            events,
            [:orchard, :node, :worker_runtime, :load, :exception],
            fn m, meta ->
              assert m.duration_ms >= 0
              assert meta.reason == :worker_executable_not_found
            end
          )

          # No stop events (failures only)
          refute_telemetry_event(events, [:orchard, :node, :model_manager, :load, :stop])
          refute_telemetry_event(events, [:orchard, :node, :worker_runtime, :load, :stop])
        end
      )
    end

    test "reset cancellation emits manager load stop with cancelled outcome", %{bundle: bundle} do
      with_runtime_adapter(SlowLoadAdapter, fn ->
        events =
          with_telemetry_collector(
            [
              [:orchard, :node, :model_manager, :load, :start],
              [:orchard, :node, :model_manager, :load, :stop],
              [:orchard, :node, :model_manager, :load, :exception]
            ],
            fn ->
              ensure_task =
                Task.async(fn ->
                  NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))
                end)

              wait_until(fn -> NodeStatus.current().worker_state == :WORKER_STATE_STARTING end)
              :ok = NodeStatus.reset()

              result = Task.await(ensure_task, 5_000)
              assert result.placement_state == :PLACEMENT_STATE_FAILED
              assert result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
              assert result.failure_code == "load_cancelled"
            end
          )

        assert_telemetry_event(events, [:orchard, :node, :model_manager, :load, :start], fn _m,
                                                                                            meta ->
          assert meta.model_id == @test_model_id
        end)

        assert_telemetry_event(events, [:orchard, :node, :model_manager, :load, :stop], fn m,
                                                                                           meta ->
          assert m.duration_ms >= 0
          assert meta.outcome == :cancelled
          assert meta.cancel_reason == :reset
          assert meta.waiter_count == 1
          assert meta.replied_waiter_count == 1
        end)

        # No exception (cancellation is stop, not exception)
        refute_telemetry_event(events, [:orchard, :node, :model_manager, :load, :exception])
      end)
    end

    test "unload cancellation emits manager load stop with unload_request reason", %{
      bundle: bundle
    } do
      with_runtime_adapter(SlowLoadAdapter, fn ->
        events =
          with_telemetry_collector(
            [
              [:orchard, :node, :model_manager, :load, :start],
              [:orchard, :node, :model_manager, :load, :stop],
              [:orchard, :node, :model_manager, :load, :exception]
            ],
            fn ->
              ensure_task =
                Task.async(fn ->
                  NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle))
                end)

              wait_until(fn -> NodeStatus.current().worker_state == :WORKER_STATE_STARTING end)

              assert %{ok: true} =
                       NodeStatus.unload_model(%UnloadModelRequest{
                         model_id: @test_model_id,
                         version: @test_version,
                         force: false,
                         evict: false
                       })

              result = Task.await(ensure_task, 5_000)
              assert result.placement_state == :PLACEMENT_STATE_FAILED
              assert result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_INTERNAL
              assert result.failure_code == "load_cancelled"
            end
          )

        assert_telemetry_event(events, [:orchard, :node, :model_manager, :load, :start], fn _m,
                                                                                            meta ->
          assert meta.model_id == @test_model_id
        end)

        assert_telemetry_event(events, [:orchard, :node, :model_manager, :load, :stop], fn m,
                                                                                           meta ->
          assert m.duration_ms >= 0
          assert meta.outcome == :cancelled
          assert meta.cancel_reason == :unload_request
          assert meta.waiter_count == 1
          assert meta.replied_waiter_count == 1
        end)

        refute_telemetry_event(events, [:orchard, :node, :model_manager, :load, :exception])
      end)
    end
  end

  # -- Single-flight deadline compatibility tests (Task 5) ---------------------

  describe "single-flight deadline compatibility" do
    test "short-deadline joiner fails by its own deadline without cancelling shared task", %{
      bundle: bundle
    } do
      with_runtime_adapter(DeadlineTestAdapter, fn ->
        # Long leader: 10s deadline
        leader_task =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 10_000))
          end)

        # Wait for the load attempt to start
        assert_receive {:load_attempt_started, worker_pid}, 5_000

        # Short follower: 200ms deadline
        follower_task =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 200))
          end)

        # Short follower should fail by its own deadline with TIMEOUT
        follower_result = Task.await(follower_task, 5_000)
        assert follower_result.placement_state == :PLACEMENT_STATE_FAILED
        assert follower_result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT
        assert follower_result.failure_code == "deadline_exceeded"

        # Leader's load should still be in progress (task not cancelled)
        assert NodeStatus.current().worker_state == :WORKER_STATE_STARTING

        # Release the worker load — leader should succeed
        send(worker_pid, :finish_load)

        leader_result = Task.await(leader_task, 5_000)
        assert leader_result.placement_state == :PLACEMENT_STATE_LOADED

        # One worker should be loaded
        assert worker_count() == 1
      end)
    end

    test "long-deadline joiner survives leader expiry and succeeds via restart", %{
      bundle: bundle
    } do
      with_runtime_adapter(DeadlineTestAdapter, fn ->
        # Short leader: 300ms deadline
        leader_task =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 300))
          end)

        # Wait for first load attempt
        assert_receive {:load_attempt_started, _worker_pid_1}, 5_000

        # Long follower: 10s deadline
        follower_task =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 10_000))
          end)

        # Give the follower time to join
        Process.sleep(50)

        # Leader should time out and receive deadline_exceeded
        leader_result = Task.await(leader_task, 5_000)
        assert leader_result.placement_state == :PLACEMENT_STATE_FAILED
        assert leader_result.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT
        assert leader_result.failure_code == "deadline_exceeded"

        # A second load attempt should start (restart with follower as new leader)
        assert_receive {:load_attempt_started, worker_pid_2}, 5_000

        # Release the second attempt
        send(worker_pid_2, :finish_load)

        # Long follower should succeed
        follower_result = Task.await(follower_task, 5_000)
        assert follower_result.placement_state == :PLACEMENT_STATE_LOADED

        # One worker loaded, no inflight
        assert worker_count() == 1
        assert NodeStatus.current().worker_state != :WORKER_STATE_STARTING
      end)
    end

    test "all-waiters-expire cleans up task and partial worker", %{bundle: bundle} do
      with_runtime_adapter(DeadlineTestAdapter, fn ->
        # Both callers have short deadlines: 300ms
        task1 =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 300))
          end)

        assert_receive {:load_attempt_started, _worker_pid}, 5_000

        task2 =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 300))
          end)

        # Both should fail with deadline_exceeded
        result1 = Task.await(task1, 5_000)
        result2 = Task.await(task2, 5_000)

        assert result1.placement_state == :PLACEMENT_STATE_FAILED
        assert result1.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT
        assert result1.failure_code == "deadline_exceeded"

        assert result2.placement_state == :PLACEMENT_STATE_FAILED
        assert result2.failure_category == :MODEL_LOAD_FAILURE_CATEGORY_TIMEOUT
        assert result2.failure_code == "deadline_exceeded"

        # Wait for cleanup
        wait_until(fn -> worker_count() == 0 end)
        assert NodeStatus.current().worker_state == :WORKER_STATE_IDLE
        assert NodeStatus.current().loaded_models == []
      end)
    end

    test "no timer leaks or stale timeout messages after restart", %{bundle: bundle} do
      with_runtime_adapter(DeadlineTestAdapter, fn ->
        # Short leader: 300ms, long follower: 10s
        leader_task =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 300))
          end)

        assert_receive {:load_attempt_started, _worker_pid_1}, 5_000

        follower_task =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 10_000))
          end)

        Process.sleep(50)

        # Leader times out, restart happens
        leader_result = Task.await(leader_task, 5_000)
        assert leader_result.placement_state == :PLACEMENT_STATE_FAILED

        # Second attempt starts
        assert_receive {:load_attempt_started, worker_pid_2}, 5_000

        # Release the second attempt
        send(worker_pid_2, :finish_load)

        follower_result = Task.await(follower_task, 5_000)
        assert follower_result.placement_state == :PLACEMENT_STATE_LOADED

        # Wait well past where the original leader's timer would have fired
        # (the leader had a 300ms deadline, already long past)
        Process.sleep(500)

        # Worker should still be loaded — no stale timer should have caused cleanup
        assert worker_count() == 1
        status = NodeStatus.current()
        assert status.worker_state != :WORKER_STATE_STARTING
        assert length(status.loaded_models) == 1
      end)
    end

    test "restart telemetry reports correct waiter counts per attempt", %{bundle: bundle} do
      with_runtime_adapter(DeadlineTestAdapter, fn ->
        events =
          with_telemetry_collector(all_lifecycle_events(), fn ->
            # Short leader: 300ms, long follower: 10s
            leader_task =
              Task.async(fn ->
                NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 300))
              end)

            assert_receive {:load_attempt_started, _worker_pid_1}, 5_000

            follower_task =
              Task.async(fn ->
                NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 10_000))
              end)

            Process.sleep(50)

            # Leader times out → abort + restart
            leader_result = Task.await(leader_task, 5_000)
            assert leader_result.placement_state == :PLACEMENT_STATE_FAILED

            # Second attempt starts
            assert_receive {:load_attempt_started, worker_pid_2}, 5_000
            send(worker_pid_2, :finish_load)

            follower_result = Task.await(follower_task, 5_000)
            assert follower_result.placement_state == :PLACEMENT_STATE_LOADED
          end)

        # Filter manager load stop events by outcome
        stop_events =
          Enum.filter(events, fn {name, _m, _meta} ->
            name == [:orchard, :node, :model_manager, :load, :stop]
          end)

        assert length(stop_events) == 2,
               "Expected 2 manager load stop events, got #{length(stop_events)}"

        # Aborted first attempt: 2 total waiters, 1 replied (leader expired before abort)
        {_, _m1, cancelled_meta} =
          Enum.find(stop_events, fn {_, _, meta} -> meta.outcome == :cancelled end)

        assert cancelled_meta.cancel_reason == :leader_deadline_exceeded
        assert cancelled_meta.waiter_count == 2
        assert cancelled_meta.replied_waiter_count == 1

        # Successful second attempt: 1 total waiter, 1 replied
        {_, _m2, loaded_meta} =
          Enum.find(stop_events, fn {_, _, meta} -> meta.outcome == :loaded end)

        assert loaded_meta.waiter_count == 1
        assert loaded_meta.replied_waiter_count == 1
      end)
    end

    test "restarted load attempt preserves original request fields", %{bundle: bundle} do
      with_runtime_adapter(DeadlineTestAdapter, fn ->
        # Short leader: 300ms, long follower: 10s
        leader_task =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 300))
          end)

        assert_receive {:load_attempt_started, _worker_pid_1}, 5_000

        follower_task =
          Task.async(fn ->
            NodeStatus.ensure_model_loaded(ensure_model_loaded_request(bundle, 10_000))
          end)

        Process.sleep(50)

        # Collect the request used for the first attempt
        assert_receive {:load_pipeline_request, _key, first_request}, 5_000

        # Leader times out → restart
        leader_result = Task.await(leader_task, 5_000)
        assert leader_result.placement_state == :PLACEMENT_STATE_FAILED

        # Collect the request used for the restarted attempt
        assert_receive {:load_pipeline_request, _key, restart_request}, 5_000

        # Core R4 assertion: artifact identity fields are preserved exactly
        assert restart_request.artifact_sha256 == first_request.artifact_sha256
        assert restart_request.artifact_source_uri == first_request.artifact_source_uri
        assert restart_request.model_id == first_request.model_id
        assert restart_request.version == first_request.version
        assert restart_request.node_id == first_request.node_id
        assert restart_request.preload == first_request.preload

        # Only deadline should differ (follower's longer deadline)
        assert restart_request.deadline_unix_ms > first_request.deadline_unix_ms

        # Release second attempt
        assert_receive {:load_attempt_started, worker_pid_2}, 5_000
        send(worker_pid_2, :finish_load)

        follower_result = Task.await(follower_task, 5_000)
        assert follower_result.placement_state == :PLACEMENT_STATE_LOADED
      end)
    end
  end

  # -- Opt-in MLX real generation smoke test ----------------------------------

  # Set ORCHARD_MLX_SMOKE_MODEL_PATH to a real Orchard bundle directory.
  @mlx_smoke_model_path System.get_env("ORCHARD_MLX_SMOKE_MODEL_PATH")

  if @mlx_smoke_model_path do
    @tag :mlx_smoke
    test "opt-in MLX real generation through full node-agent path" do
      mlx_bundle_path = unquote(@mlx_smoke_model_path)

      # Read manifest from the real bundle
      manifest_json = File.read!(Path.join(mlx_bundle_path, "manifest.json"))
      manifest_data = Jason.decode!(manifest_json)
      model_id = manifest_data["model_id"]
      version = manifest_data["version"]

      # Compute hash for the real bundle
      {:ok, hash} = ArtifactBundle.tree_sha256(mlx_bundle_path)

      source_uri = "file://#{mlx_bundle_path}"

      with_runtime_config(
        [
          runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter,
          fake_runtime?: false,
          worker_backend: "mlx",
          worker_load_timeout_ms: 120_000,
          worker_ready_timeout_ms: 30_000
        ],
        fn ->
          with_channel(fn channel ->
            # Ensure model loaded via file:// acquisition
            ensure_req = %EnsureModelLoadedRequest{
              node_id: "node-local",
              model_id: model_id,
              version: version,
              artifact_sha256: hash,
              preload: true,
              deadline_unix_ms: System.system_time(:millisecond) + 120_000,
              artifact_source_uri: source_uri
            }

            assert {:ok,
                    %EnsureModelLoadedResponse{
                      placement_state: :PLACEMENT_STATE_LOADED
                    }} =
                     NodeRuntimeStub.ensure_model_loaded(channel, ensure_req, timeout: 125_000)

            # Execute real generation
            gen_req = %ExecuteInferenceRequest{
              request_id: "req-mlx-smoke-gen",
              controller_session_id: "mlx-smoke-session",
              model_id: model_id,
              version: version,
              rendered_prompt_utf8: "The capital of France is",
              input_tokens: 6,
              params: %GenerationParams{max_output_tokens: 8, temperature: 0.0},
              deadline_unix_ms: System.system_time(:millisecond) + 60_000,
              metadata_json: ~s({"source":"mlx_smoke"})
            }

            assert {:ok, event_stream} =
                     NodeRuntimeStub.execute_inference(channel, gen_req)

            events = Enum.to_list(event_stream)
            assert length(events) >= 3, "Expected accepted + delta(s) + completed"

            # First event: Accepted from node (not worker)
            assert {:ok, %RPCInferenceEvent{event: {:accepted, %Accepted{}}}} =
                     hd(events)

            # At least one output_text_delta
            deltas =
              Enum.filter(events, fn
                {:ok, %RPCInferenceEvent{event: {:output_text_delta, _}}} -> true
                _ -> false
              end)

            refute deltas == [], "Expected at least one output_text_delta"

            {:ok, %RPCInferenceEvent{event: {:completed, %Completed{} = completed}}} =
              List.last(events)

            assert completed.finish_reason in [
                     :FINISH_REASON_STOP,
                     :FINISH_REASON_LENGTH
                   ]

            usage = completed.usage
            assert usage.input_tokens == 6
            assert usage.output_tokens > 0
            assert usage.total_tokens == usage.input_tokens + usage.output_tokens

            # Unload
            assert {:ok, %{ok: true}} =
                     NodeRuntimeStub.unload_model(channel, %UnloadModelRequest{
                       model_id: model_id,
                       version: version,
                       force: false,
                       evict: false
                     })
          end)
        end
      )
    end
  end

  # -- Eviction tests --------------------------------------------------------

  @eviction_model_id "eviction-test/model-b"
  @eviction_version "v1"

  describe "count-based model eviction" do
    setup %{bundle: bundle_a} do
      bundle_b = stage_test_bundle!(@eviction_model_id, @eviction_version)

      on_exit(fn ->
        File.rm_rf(bundle_b.cache_path)
        File.rm_rf(bundle_b.source_path)
      end)

      %{bundle_a: bundle_a, bundle_b: bundle_b}
    end

    test "with limit 1, loading model B evicts idle model A", %{
      bundle_a: bundle_a,
      bundle_b: bundle_b
    } do
      with_runtime_config([max_loaded_models: 1], fn ->
        # Load model A
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_a))

        assert worker_count() == 1

        # Load model B — should evict A
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_b))

        # Only B should remain
        assert worker_count() == 1

        status = ModelManager.current()
        assert length(status.loaded_models) == 1
        [loaded] = status.loaded_models
        assert loaded.model_id == @eviction_model_id
        assert loaded.version == @eviction_version
      end)
    end

    test "with limit 1, loading B while A has active request fails with capacity exhausted", %{
      bundle_a: bundle_a,
      bundle_b: bundle_b
    } do
      with_runtime_config(
        [max_loaded_models: 1, runtime_adapter_impl: BlockingRuntimeAdapter],
        fn ->
          # Load model A
          assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                   ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_a))

          # Start an active request on A
          inference_req = %ExecuteInferenceRequest{
            request_id: "evict-busy-req",
            controller_session_id: "ctrl-1",
            model_id: bundle_a.model_id,
            version: bundle_a.version,
            rendered_prompt_utf8: "hello",
            input_tokens: 2,
            params: %GenerationParams{max_output_tokens: 16},
            deadline_unix_ms: System.system_time(:millisecond) + 5_000
          }

          assert :ok = ModelManager.prepare_request(inference_req, self())
          assert :ok = ModelManager.start_request(inference_req)

          # Attempt to load B — should fail with capacity exhausted
          response = ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_b))

          assert %EnsureModelLoadedResponse{
                   placement_state: :PLACEMENT_STATE_FAILED,
                   failure_category: :MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED,
                   failure_code: "model_capacity_exhausted"
                 } = response

          # A should still be loaded
          assert worker_count() == 1
          status = ModelManager.current()
          [loaded] = status.loaded_models
          assert loaded.model_id == bundle_a.model_id
        end
      )
    end

    test "with limit disabled, both models remain loaded", %{
      bundle_a: bundle_a,
      bundle_b: bundle_b
    } do
      with_runtime_config([max_loaded_models: 0], fn ->
        # Load both models
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_a))

        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_b))

        # Both should be loaded
        assert worker_count() == 2

        status = ModelManager.current()
        assert length(status.loaded_models) == 2
      end)
    end

    test "eviction telemetry is emitted on successful eviction", %{
      bundle_a: bundle_a,
      bundle_b: bundle_b
    } do
      with_runtime_config([max_loaded_models: 1], fn ->
        # Load model A first (outside telemetry collection)
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_a))

        # Collect eviction telemetry while loading B
        events =
          with_telemetry_collector(all_eviction_events(), fn ->
            assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                     ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_b))
          end)

        # Verify eviction start
        assert_telemetry_event(
          events,
          [:orchard, :node, :eviction, :start],
          fn measurements, metadata ->
            assert is_integer(measurements.system_time)
            assert metadata.incoming_model_id == @eviction_model_id
            assert metadata.incoming_version == @eviction_version
            assert metadata.victim_model_id == nil
            assert metadata.victim_version == nil
            assert metadata.max_loaded_models == 1
            assert metadata.reserved_model_count_before == 1
          end
        )

        # Verify eviction stop
        assert_telemetry_event(
          events,
          [:orchard, :node, :eviction, :stop],
          fn measurements, metadata ->
            assert is_integer(measurements.duration_ms)
            assert metadata.incoming_model_id == @eviction_model_id
            assert metadata.incoming_version == @eviction_version
            assert metadata.victim_model_id == @test_model_id
            assert metadata.victim_version == @test_version
            assert metadata.outcome == :evicted
          end
        )

        # No exception event
        refute_telemetry_event(events, [:orchard, :node, :eviction, :exception])
      end)
    end

    test "eviction telemetry exception emitted when no idle victim exists", %{
      bundle_a: bundle_a,
      bundle_b: bundle_b
    } do
      with_runtime_config(
        [max_loaded_models: 1, runtime_adapter_impl: BlockingRuntimeAdapter],
        fn ->
          # Load A and start an active request
          assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                   ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_a))

          inference_req = %ExecuteInferenceRequest{
            request_id: "evict-telem-req",
            controller_session_id: "ctrl-1",
            model_id: bundle_a.model_id,
            version: bundle_a.version,
            rendered_prompt_utf8: "hello",
            input_tokens: 2,
            params: %GenerationParams{max_output_tokens: 16},
            deadline_unix_ms: System.system_time(:millisecond) + 5_000
          }

          assert :ok = ModelManager.prepare_request(inference_req, self())
          assert :ok = ModelManager.start_request(inference_req)

          # Collect eviction telemetry
          events =
            with_telemetry_collector(all_eviction_events(), fn ->
              _response =
                ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_b))
            end)

          # Verify eviction start
          assert_telemetry_event(
            events,
            [:orchard, :node, :eviction, :start],
            fn _measurements, metadata ->
              assert metadata.incoming_model_id == @eviction_model_id
              assert metadata.max_loaded_models == 1
            end
          )

          # Verify eviction exception
          assert_telemetry_event(
            events,
            [:orchard, :node, :eviction, :exception],
            fn measurements, metadata ->
              assert is_integer(measurements.duration_ms)
              assert metadata.reason == :model_capacity_exhausted
              assert metadata.victim_model_id == nil
              assert metadata.victim_version == nil
            end
          )

          # No stop event
          refute_telemetry_event(events, [:orchard, :node, :eviction, :stop])
        end
      )
    end

    test "evicts least recently used model when multiple are loaded", %{
      bundle_a: bundle_a,
      bundle_b: bundle_b
    } do
      with_runtime_config([max_loaded_models: 2], fn ->
        # Load A, then B
        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_a))

        assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                 ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_b))

        assert worker_count() == 2

        # Touch A via fast path to make B the LRU
        assert %EnsureModelLoadedResponse{already_loaded: true} =
                 ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_a))

        bundle_c = stage_test_bundle!("eviction-test/model-c", "v1")

        try do
          assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} =
                   ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_c))

          # B should have been evicted (LRU), A and C remain
          assert worker_count() == 2
          status = ModelManager.current()
          loaded_ids = Enum.map(status.loaded_models, & &1.model_id) |> Enum.sort()
          assert loaded_ids == [bundle_a.model_id, bundle_c.model_id] |> Enum.sort()
        after
          File.rm_rf(bundle_c.cache_path)
          File.rm_rf(bundle_c.source_path)
        end
      end)
    end

    test "inflight load for model A blocks model B from starting under capacity limit", %{
      bundle_a: bundle_a,
      bundle_b: bundle_b
    } do
      with_runtime_config(
        [max_loaded_models: 1, runtime_adapter_impl: DeadlineTestAdapter],
        fn ->
          # Start async load for model A — blocks in load_model
          task_a =
            Task.async(fn ->
              ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_a, 10_000))
            end)

          # Wait until A's load is actually in progress
          assert_receive {:load_attempt_started, worker_pid_a}, 2_000

          # Attempt to load B while A is still loading — should fail with capacity exhausted
          response = ModelManager.ensure_model_loaded(ensure_model_loaded_request(bundle_b))

          assert %EnsureModelLoadedResponse{
                   placement_state: :PLACEMENT_STATE_FAILED,
                   failure_category: :MODEL_LOAD_FAILURE_CATEGORY_RESOURCE_EXHAUSTED,
                   failure_code: "model_capacity_exhausted"
                 } = response

          # No load attempt should have started for B
          refute_receive {:load_attempt_started, _other_pid}, 200

          # Release A and confirm it loads successfully
          send(worker_pid_a, :finish_load)
          result_a = Task.await(task_a, 5_000)

          assert %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED} = result_a
          assert worker_count() == 1

          status = ModelManager.current()
          assert length(status.loaded_models) == 1
          [loaded] = status.loaded_models
          assert loaded.model_id == bundle_a.model_id
        end
      )
    end
  end

  # -- Private helpers -------------------------------------------------------

  defp start_execute_inference_task(request, test_pid) do
    Task.async(fn ->
      with_channel(&collect_execute_inference_events(&1, request, test_pid))
    end)
  end

  defp collect_execute_inference_events(channel, request, test_pid) do
    {:ok, event_stream} = NodeRuntimeStub.execute_inference(channel, request)

    event_stream
    |> Enum.reduce([], &collect_execute_inference_event(&1, &2, request, test_pid))
    |> Enum.reverse()
  end

  defp collect_execute_inference_event(event, events, request, test_pid) do
    notify_execute_inference_accepted(event, request.request_id, test_pid)
    [event | events]
  end

  defp notify_execute_inference_accepted(
         {:ok, %RPCInferenceEvent{event: {:accepted, %Accepted{}}}},
         request_id,
         test_pid
       ) do
    send(test_pid, {:execute_inference_accepted, request_id})
  end

  defp notify_execute_inference_accepted(_event, _request_id, _test_pid), do: :ok

  defp assert_execute_inference_accepted(request_ids) do
    expected = MapSet.new(request_ids)

    accepted =
      Enum.reduce_while(1..length(request_ids), MapSet.new(), fn _index, accepted ->
        receive do
          {:execute_inference_accepted, request_id} ->
            next = MapSet.put(accepted, request_id)

            if MapSet.equal?(next, expected) do
              {:halt, next}
            else
              {:cont, next}
            end
        after
          1_000 ->
            flunk(
              "missing accepted events for request ids: #{inspect(MapSet.difference(expected, accepted))}"
            )
        end
      end)

    assert MapSet.equal?(accepted, expected)
  end

  defp wait_for_generation_refs(request_ids, attempts \\ 80)

  defp wait_for_generation_refs(request_ids, attempts) when attempts > 0 do
    refs = generation_refs_for_request_ids(request_ids)

    if map_size(refs) == length(request_ids) do
      refs
    else
      Process.sleep(25)
      wait_for_generation_refs(request_ids, attempts - 1)
    end
  end

  defp wait_for_generation_refs(request_ids, 0) do
    flunk("generation refs not active for request ids: #{inspect(request_ids)}")
  end

  defp generation_refs_for_request_ids(request_ids) do
    case safe_worker_state() do
      {:ok, worker_state} ->
        generation_refs_for_worker_state(worker_state, MapSet.new(request_ids))

      :error ->
        %{}
    end
  end

  defp generation_refs_for_worker_state(worker_state, request_ids) do
    worker_state
    |> Map.fetch!(:requests)
    |> Enum.reduce(%{}, &put_generation_ref_if_requested(&1, &2, request_ids))
  end

  defp put_generation_ref_if_requested({request_id, request_state}, refs, request_ids) do
    if MapSet.member?(request_ids, request_id) do
      Map.put(refs, request_id, Map.fetch!(request_state, :generation_ref))
    else
      refs
    end
  end

  defp runtime_model_placement!(%StatusResponse{} = status, model_id, version) do
    Enum.find(status.runtime_model_placements, fn placement ->
      placement.model_ref.model_id == model_id and placement.model_ref.version == version
    end) || flunk("runtime model placement not found for #{model_id}@#{version}")
  end

  defp assert_blocking_stream_completed([
         {:ok,
          %RPCInferenceEvent{event: {:accepted, %Accepted{accepted_at_unix_ms: accepted_at}}}},
         {:ok,
          %RPCInferenceEvent{event: {:output_text_delta, %OutputTextDelta{delta: "released"}}}},
         {:ok, %RPCInferenceEvent{event: {:completed, %Completed{} = completed}}}
       ]) do
    assert is_integer(accepted_at)
    assert accepted_at > 0
    assert completed.finish_reason == :FINISH_REASON_STOP

    assert completed.usage == %TokenUsage{
             input_tokens: 2,
             output_tokens: 1,
             total_tokens: 3
           }
  end

  defp assert_blocking_stream_completed(events) do
    flunk("unexpected ExecuteInference stream events: #{inspect(events)}")
  end

  defp best_effort_release_generation_refs(request_ids) do
    request_ids
    |> release_messages_for_request_ids()
    |> Enum.each(fn {pid, generation_ref} -> send(pid, {:release, generation_ref}) end)
  end

  defp grpc_status_snapshot do
    with_channel(fn channel ->
      assert {:ok, %StatusResponse{} = status} =
               NodeRuntimeStub.get_status(channel, %StatusRequest{})

      status
    end)
  end

  defp release_messages_for_request_ids(request_ids) do
    case safe_worker_state() do
      {:ok, worker_state} ->
        release_messages_for_worker_state(worker_state, MapSet.new(request_ids))

      :error ->
        []
    end
  end

  defp release_messages_for_worker_state(worker_state, request_ids) do
    generations = get_in(worker_state, [:adapter_state, :generations]) || %{}
    requests = Map.get(worker_state, :requests, %{})

    requests
    |> Enum.flat_map(&release_message_for_request(&1, generations, request_ids))
  end

  defp release_message_for_request({request_id, request_state}, generations, request_ids) do
    if MapSet.member?(request_ids, request_id) do
      release_message_for_generation(request_state, generations)
    else
      []
    end
  end

  defp release_message_for_generation(request_state, generations) do
    case Map.get(request_state, :generation_ref) do
      nil -> []
      generation_ref -> release_message_for_ref(generation_ref, generations)
    end
  end

  defp release_message_for_ref(generation_ref, generations) do
    case Map.get(generations, generation_ref) do
      %{pid: pid} when is_pid(pid) -> [{pid, generation_ref}]
      _missing_or_malformed -> []
    end
  end

  defp safe_worker_state do
    worker_pid()
    |> fetch_worker_state_if_alive()
  catch
    :exit, _reason -> :error
  end

  defp fetch_worker_state_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: fetch_worker_state(pid), else: :error
  end

  defp fetch_worker_state_if_alive(_pid), do: :error

  defp fetch_worker_state(pid) do
    {:ok, :sys.get_state(pid)}
  catch
    :exit, _reason -> :error
  end

  defp get_blocking_generation_ref do
    pid = worker_pid()
    state = :sys.get_state(pid)

    state.requests
    |> Map.values()
    |> hd()
    |> Map.fetch!(:generation_ref)
  end

  defp send_release(generation_ref) do
    pid = worker_pid()
    state = :sys.get_state(pid)

    gen_state =
      Enum.find_value(state.adapter_state.generations, fn {ref, gen} ->
        if ref == generation_ref, do: gen
      end)

    send(gen_state.pid, {:release, generation_ref})
  end

  defp with_channel(fun) when is_function(fun, 1) do
    target = "#{Node.listen_host()}:#{Node.listen_port()}"

    {:ok, channel} = GRPC.Stub.connect(target)

    try do
      fun.(channel)
    after
      _ = GRPC.Stub.disconnect(channel)
    end
  end

  defp stage_test_bundle! do
    stage_test_bundle!(@test_model_id, @test_version)
  end

  defp stage_test_bundle!(model_id, version) do
    models_root = Node.models_root()
    cache_path = Path.join([models_root, model_id, version])
    source_path = Path.join([models_root, ".test-source", "#{model_id}-#{version}"])

    # Clean previous
    File.rm_rf(cache_path)
    File.rm_rf(source_path)

    # Create source bundle with dummy files
    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    # Compute hash
    {:ok, hash} = ArtifactBundle.tree_sha256(source_path)

    # Pre-stage at cache location (cache hit path)
    File.mkdir_p!(cache_path)
    :ok = ArtifactBundle.copy_directory(source_path, cache_path)

    source_uri = "file://#{source_path}"

    %{
      model_id: model_id,
      version: version,
      cache_path: cache_path,
      source_path: source_path,
      source_uri: source_uri,
      hash: hash
    }
  end

  defp ensure_model_loaded_request(bundle) do
    ensure_model_loaded_request(bundle, 5_000)
  end

  defp ensure_model_loaded_request(bundle, deadline_offset_ms) do
    %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: bundle.model_id,
      version: bundle.version,
      artifact_sha256: bundle.hash,
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + deadline_offset_ms,
      artifact_source_uri: bundle.source_uri
    }
  end

  defp execute_inference_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "controller-session-1",
      model_id: @test_model_id,
      version: @test_version,
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 2,
      params: %GenerationParams{max_output_tokens: 16},
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      metadata_json: ~s({"source":"test"})
    }
  end

  defp with_hard_mode_license(fun) when is_function(fun, 0) do
    previous_licensing = Application.get_env(:orchard_shared, :licensing, [])

    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "orchard-node-agent-license-test",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    bundle_path = Path.join([tmp_dir, "config", "licensing", "current.json"])
    node_identity_path = Path.join([tmp_dir, "data", "node-id"])

    Application.put_env(
      :orchard_shared,
      :licensing,
      Keyword.merge(previous_licensing,
        bundle_path: bundle_path,
        node_identity_path: node_identity_path,
        keygen_public_key: @licensing_public_key_hex,
        enforcement_mode: :hard,
        gate_cache_ttl_seconds: 1
      )
    )

    write_node_identity!(node_identity_path, @licensing_local_node_id)

    try do
      fun.()
    after
      Gate.refresh()
      Application.put_env(:orchard_shared, :licensing, previous_licensing)
      File.rm_rf!(tmp_dir)
    end
  end

  defp copy_license_fixture!(name) do
    licensing = Application.get_env(:orchard_shared, :licensing, [])
    bundle_path = Keyword.fetch!(licensing, :bundle_path)

    File.mkdir_p!(Path.dirname(bundle_path))
    File.cp!(license_fixture_path(name), bundle_path)
  end

  defp replace_license_bundle_externally!(fixture_name) do
    licensing = Application.get_env(:orchard_shared, :licensing, [])
    bundle_path = Keyword.fetch!(licensing, :bundle_path)

    assert :ok = LocalStore.write(bundle_path, load_license_fixture_bundle!(fixture_name))
  end

  defp load_license_fixture_bundle!(name) do
    name
    |> license_fixture_path()
    |> File.read!()
    |> Jason.decode!()
    |> then(fn %{
                 "license_certificate" => license_certificate,
                 "machine_certificate" => machine_certificate
               } ->
      %{license_certificate: license_certificate, machine_certificate: machine_certificate}
    end)
  end

  defp license_fixture_path(name), do: Path.join(@licensing_fixture_dir, "#{name}.json")

  defp write_node_identity!(node_identity_path, node_id) do
    File.mkdir_p!(Path.dirname(node_identity_path))
    File.write!(node_identity_path, node_id <> "\n")
  end

  defp score_prefix_cache_request do
    %ScorePrefixCacheRequest{
      request_id: "score-request-id",
      controller_session_id: "score-controller-session",
      model_ref: %RPCModelRef{model_id: @test_model_id, version: @test_version},
      cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("a", 64),
      deadline_unix_ms: System.system_time(:millisecond) + 1_000
    }
  end

  defp score_prefix_cache_request(model_id, version) do
    %ScorePrefixCacheRequest{
      request_id: "req-score-prefix-cache",
      controller_session_id: "controller-session-1",
      model_ref: %RPCModelRef{model_id: model_id, version: version},
      cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("a", 64),
      deadline_unix_ms: System.system_time(:millisecond) + 5_000
    }
  end

  defp worker_count do
    DynamicSupervisor.which_children(WorkerSupervisor)
    |> Enum.count(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
  end

  defp flush_prompt_token_ids_status_probes do
    receive do
      {:prompt_token_ids_status_probe, _worker_pid, _model_ref} ->
        flush_prompt_token_ids_status_probes()
    after
      0 -> :ok
    end
  end

  defp flush_counting_status_probes do
    receive do
      {:counting_status_probe, _worker_pid} ->
        flush_counting_status_probes()
    after
      0 -> :ok
    end
  end

  defp flush_short_circuit_status_probes do
    receive do
      {:short_circuit_status_probe, _worker_pid, _model_ref} ->
        flush_short_circuit_status_probes()
    after
      0 -> :ok
    end
  end

  defp worker_pid do
    DynamicSupervisor.which_children(WorkerSupervisor)
    |> Enum.find_value(fn {_id, pid, _type, _modules} -> if is_pid(pid), do: pid end)
  end

  defp assert_invalid_runtime_memory_budget_is_downgraded(bundle, utilization) do
    request = ensure_model_loaded_request(bundle)

    with_runtime_config(
      [
        runtime_adapter_impl: InvalidMemoryBudgetRuntimeAdapter,
        test_invalid_memory_budget_utilization: utilization
      ],
      fn ->
        with_channel(fn channel ->
          assert {:ok, %EnsureModelLoadedResponse{placement_state: :PLACEMENT_STATE_LOADED}} =
                   NodeRuntimeStub.ensure_model_loaded(channel, request)

          assert {:ok, %StatusResponse{} = response} =
                   NodeRuntimeStub.get_status(channel, %StatusRequest{})

          assert [%{model_ref: %RPCModelRef{} = model_ref} = budget] =
                   response.runtime_memory_budgets

          assert model_ref.model_id == bundle.model_id
          assert model_ref.version == bundle.version
          assert budget.mode == "observe"
          assert budget.budget_available == false
          assert budget.headroom_available == false
          assert budget.status_code == "invalid_status"
          assert budget.status_message == "memory budget status contained invalid numeric fields"
          assert budget.max_recommended_working_set_size_bytes == 0
          assert budget.utilization == 0.0
          assert budget.target_working_set_bytes == 0
          assert budget.overhead_bytes == 0
          assert budget.resident_memory_bytes == 0
          assert budget.estimated_headroom_bytes == 0
          assert budget.kv_cache_bytes_per_token == 0
          assert budget.prefill_workspace_bytes_per_token == 0
        end)
      end
    )
  end

  defp huge_integer_utilization do
    Integer.pow(2, 10_000)
  end

  defp prefix_cache_fingerprint(index) do
    "hmac-sha256:" <>
      (index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0"))
  end

  defp with_runtime_adapter(adapter, fun) when is_function(fun, 0) do
    with_runtime_config([runtime_adapter_impl: adapter], fun)
  end

  defp with_real_worker_runtime(fun) when is_function(fun, 0) do
    with_runtime_config(
      [runtime_adapter_impl: Orchard.Node.WorkerRuntimeAdapter, fake_runtime?: false],
      fun
    )
  end

  defp with_runtime_config(overrides, fun) when is_list(overrides) and is_function(fun, 0) do
    previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    updated_runtime = Keyword.merge(previous_runtime, overrides)

    Application.put_env(:orchard_node_agent, :runtime, updated_runtime)
    :ok = NodeStatus.reset()
    wait_until(fn -> worker_count() == 0 end)

    try do
      fun.()
    after
      :ok = NodeStatus.reset()
      wait_until(fn -> worker_count() == 0 end)
      Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
    end
  end

  defp real_worker_socket_path do
    Node.worker_socket_path(@test_model_id, @test_version)
  end

  defp worker_os_pid do
    %{adapter_state: %{os_pid: os_pid}} = :sys.get_state(worker_pid())
    os_pid
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not reached before timeout")

  defp kill_process_tree(os_pid) when is_integer(os_pid) do
    {children_output, _} =
      System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true)

    children_output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.each(fn child_pid_str ->
      case Integer.parse(child_pid_str) do
        {child_pid, _} -> kill_process_tree(child_pid)
        :error -> :ok
      end
    end)

    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
  end

  # -- Telemetry test helpers -------------------------------------------------

  defp all_lifecycle_events do
    [
      [:orchard, :node, :model_manager, :load, :start],
      [:orchard, :node, :model_manager, :load, :stop],
      [:orchard, :node, :model_manager, :load, :exception],
      [:orchard, :node, :worker_runtime, :load, :start],
      [:orchard, :node, :worker_runtime, :load, :stop],
      [:orchard, :node, :worker_runtime, :load, :exception],
      [:orchard, :node, :worker_runtime, :unload, :start],
      [:orchard, :node, :worker_runtime, :unload, :stop],
      [:orchard, :node, :worker_runtime, :unload, :exception]
    ] ++ all_eviction_events()
  end

  defp all_eviction_events do
    [
      [:orchard, :node, :eviction, :start],
      [:orchard, :node, :eviction, :stop],
      [:orchard, :node, :eviction, :exception]
    ]
  end

  defp with_telemetry_collector(event_names, fun) do
    test_pid = self()
    handler_id = "lifecycle-telemetry-#{System.unique_integer([:positive])}"
    ref = make_ref()

    :telemetry.attach_many(
      handler_id,
      event_names,
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, ref, event_name, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    collect_telemetry_events(ref)
  end

  defp collect_telemetry_events(ref) do
    receive do
      {:telemetry_event, ^ref, event_name, measurements, metadata} ->
        [{event_name, measurements, metadata} | collect_telemetry_events(ref)]
    after
      0 -> []
    end
    |> Enum.reverse()
  end

  defp assert_telemetry_event(events, event_name, assertion_fn) do
    matching = Enum.filter(events, fn {name, _m, _meta} -> name == event_name end)

    refute matching == [],
           "Expected at least one #{inspect(event_name)} event, got #{length(matching)}.\nAll events: #{inspect(Enum.map(events, &elem(&1, 0)))}"

    {^event_name, measurements, metadata} = hd(matching)
    assertion_fn.(measurements, metadata)
  end

  defp refute_telemetry_event(events, event_name) do
    matching = Enum.filter(events, fn {name, _m, _meta} -> name == event_name end)

    assert matching == [],
           "Expected no #{inspect(event_name)} events, got #{length(matching)}: #{inspect(matching)}"
  end

  defp clear_sentry_context do
    if Code.ensure_loaded?(Sentry.Context) do
      Sentry.Context.clear_all()
    end
  end

  defp restore_sentry_enrichment(nil),
    do: Application.delete_env(:orchard_shared, :sentry_enrichment)

  defp restore_sentry_enrichment(config),
    do: Application.put_env(:orchard_shared, :sentry_enrichment, config)
end
