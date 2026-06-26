defmodule OrchardConsole.RuntimeTest do
  use ExUnit.Case, async: false

  alias Orchard.Runtime.PrefixCacheStatus
  alias Orchard.RuntimeEndpoint.{Observation, Target}
  alias OrchardConsole.Runtime
  import Orchard.TestSupport.RepoHelpers

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :console,
      previous
      |> Keyword.put(:runtime_client_impl, __MODULE__.StubClient)
      |> Keyword.put(:nodes_impl, __MODULE__.StubNodes)
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      Application.put_env(:orchard_controller, :inference, previous_inference)
    end)

    :ok
  end

  describe "snapshot/0" do
    test "success path normalizes worker state, sorts models, preserves count" do
      stub_client(
        connect: {:ok, :test_channel},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [
               %{model_id: "z-model", version: "v1"},
               %{model_id: "a-model", version: "v2"}
             ],
             active_request_count: 3
           }},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()

      assert snapshot.worker_state == :idle
      assert snapshot.active_request_count == 3

      # Models sorted by {model_id, version}
      assert [%{model_id: "a-model"}, %{model_id: "z-model"}] = snapshot.loaded_models
    end

    test "normalizes integer worker state values" do
      stub_client(
        connect: {:ok, :ch},
        status: {:ok, %{worker_state: 2, loaded_models: [], active_request_count: 0}},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.worker_state == :idle
    end

    test "maps unknown worker state to :unknown" do
      stub_client(
        connect: {:ok, :ch},
        status: {:ok, %{worker_state: 999, loaded_models: [], active_request_count: 0}},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.worker_state == :unknown
    end

    test "status error still disconnects and returns error snapshot" do
      stub_client(
        connect: {:ok, :ch},
        status: {:error, :node_timeout},
        disconnect: :ok
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.status == :timeout
      assert error.code == "node_timeout"
      assert error.worker_state == :unknown
      assert error.loaded_models == []

      # Verify disconnect was called
      assert_received {:disconnect_called, :ch}
    end

    test "connect error returns unavailable snapshot without disconnect" do
      stub_client(
        connect: {:error, {:connect_failed, :econnrefused}},
        status: nil,
        disconnect: nil
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.status == :unavailable
      assert error.code == "node_unavailable"

      refute_received {:disconnect_called, _}
    end

    test "success with metadata and health normalizes both maps" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: %{
               node_id: "550e8400-e29b-41d4-a716-446655440000",
               display_name: "mawarduri",
               hostname: "mawarduri.local",
               listen_host: "127.0.0.1",
               listen_port: 50_071,
               agent_version: "0.1.0",
               worker_backend: "mlx"
             },
             runtime_health: %{
               ready: true,
               health_code: nil,
               health_message: nil,
               affected_model: nil
             }
           }},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()

      assert snapshot.node_metadata == %{
               node_id: "550e8400-e29b-41d4-a716-446655440000",
               display_name: "mawarduri",
               hostname: "mawarduri.local",
               listen_host: "127.0.0.1",
               listen_port: 50_071,
               agent_version: "0.1.0",
               worker_backend: "mlx"
             }

      assert snapshot.runtime_health == %{
               ready: true,
               health_code: nil,
               health_message: nil,
               affected_model: nil
             }
    end

    test "absent node_metadata and runtime_health return nil" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: nil,
             runtime_health: nil
           }},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.node_metadata == nil
      assert snapshot.runtime_health == nil
    end

    test "absent submessage fields (no keys at all) return nil" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0
           }},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.node_metadata == nil
      assert snapshot.runtime_health == nil
    end

    test "normalizes prompt-token-id capability when status advertises support" do
      stub_client(
        connect: {:ok, :ch},
        status: {:ok, status_response(%{supports_prompt_token_ids: true})},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.supports_prompt_token_ids == true
    end

    test "defaults prompt-token-id capability to false when status omits support" do
      stub_client(
        connect: {:ok, :ch},
        status: {:ok, status_response()},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.supports_prompt_token_ids == false
    end

    test "keeps prompt-token-id capability false when status reports legacy support" do
      stub_client(
        connect: {:ok, :ch},
        status: {:ok, status_response(%{supports_prompt_token_ids: false})},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.supports_prompt_token_ids == false
    end

    test "error snapshots include nil node_metadata and runtime_health" do
      stub_client(
        connect: {:error, {:connect_failed, :econnrefused}},
        status: nil,
        disconnect: nil
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.node_metadata == nil
      assert error.runtime_health == nil
    end

    test "error snapshots default prompt-token-id capability to false" do
      stub_client(
        connect: {:error, {:connect_failed, :econnrefused}},
        status: nil,
        disconnect: nil
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.supports_prompt_token_ids == false
    end

    test "normalizes affected_model from ModelRef to display string" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: nil,
             runtime_health: %{
               ready: false,
               health_code: "memory_pressure",
               health_message: "GPU memory exhausted",
               affected_model: %{model_id: "test-model", version: "v1"}
             }
           }},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.runtime_health.affected_model == "test-model@v1"
      assert snapshot.runtime_health.health_code == "memory_pressure"
      assert snapshot.runtime_health.ready == false
    end

    test "normalizes affected_model with model_id only" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: nil,
             runtime_health: %{
               ready: false,
               health_code: nil,
               health_message: nil,
               affected_model: %{model_id: "test-model", version: ""}
             }
           }},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.runtime_health.affected_model == "test-model"
    end

    test "normalizes blank metadata strings to nil" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: %{
               node_id: "",
               display_name: "",
               hostname: "",
               listen_host: "",
               listen_port: 0,
               agent_version: "",
               worker_backend: ""
             },
             runtime_health: %{
               ready: false,
               health_code: "",
               health_message: "",
               affected_model: ""
             }
           }},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()

      meta = snapshot.node_metadata
      assert meta.node_id == nil
      assert meta.display_name == nil
      assert meta.listen_port == nil

      health = snapshot.runtime_health
      assert health.ready == false
      assert health.health_code == nil
      assert health.health_message == nil
    end

    test "successful status triggers observe_status call" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: %{node_id: "test-uuid"},
             runtime_health: nil
           }},
        disconnect: :ok
      )

      assert {:ok, _snapshot} = Runtime.snapshot()
      assert_received {:observe_status_called, _target, _response, _observed_at}
    end

    test "hosted tool capability fields stay additive to runtime snapshot behavior" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: %{node_id: "test-uuid"},
             runtime_health: %{ready: true},
             hosted_tool_capabilities: [
               %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
             ],
             hosted_tool_readiness: [
               %{name: "lookup_docs", version: "2026-04-11", ready: true}
             ]
           }},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.worker_state == :idle
      assert snapshot.node_metadata.node_id == "test-uuid"
      assert snapshot.node_metadata.display_name == nil

      assert snapshot.runtime_health == %{
               ready: true,
               health_code: nil,
               health_message: nil,
               affected_model: nil
             }

      assert_received {:observe_status_called, _target, response, _observed_at}

      assert response.hosted_tool_capabilities == [
               %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
             ]

      assert response.hosted_tool_readiness == [
               %{name: "lookup_docs", version: "2026-04-11", ready: true}
             ]
    end

    test "SPEC 7.5.3 normalizes present runtime memory budgets with approved fields only" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           status_response(%{
             runtime_memory_budgets: [
               %{
                 model_ref: %{model_id: "mlx-community/phi-3", version: "main"},
                 mode: "observe",
                 budget_available: true,
                 headroom_available: false,
                 status_code: "resident_memory_unavailable",
                 status_message: "resident memory metadata missing",
                 source: "worker",
                 max_recommended_working_set_size_bytes: 50_000,
                 utilization: 0.9,
                 target_working_set_bytes: 45_000,
                 overhead_bytes: 1_024,
                 resident_memory_bytes: 0,
                 estimated_headroom_bytes: 0,
                 kv_cache_bytes_per_token: 16,
                 prefill_workspace_bytes_per_token: 8
               }
             ]
           })},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()

      assert [
               %{
                 display_state: :observed,
                 model_ref: "mlx-community/phi-3@main",
                 mode: "observe",
                 budget_available: true,
                 headroom_available: false,
                 status_code: "resident_memory_unavailable",
                 status_message: "resident memory metadata missing",
                 target_working_set_bytes: 45_000,
                 resident_memory_bytes: 0,
                 kv_cache_bytes_per_token: 16,
                 prefill_workspace_bytes_per_token: 8
               } = budget
             ] = snapshot.runtime_memory_budgets

      refute Map.has_key?(budget, :source)
      refute Map.has_key?(budget, :estimated_headroom_bytes)
      refute Map.has_key?(budget, :overhead_bytes)
      assert snapshot.runtime_memory_budgets_truncated_count == 0
    end

    test "SPEC 7.5.3 preserves empty runtime memory budgets for absent telemetry" do
      stub_client(
        connect: {:ok, :ch},
        status: {:ok, status_response()},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.runtime_memory_budgets == []
      assert snapshot.runtime_memory_budgets_truncated_count == 0
    end

    test "SPEC 7.5.3 normalizes malformed non-list memory budgets to empty telemetry" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           status_response(%{
             runtime_memory_budgets: %{unexpected: "shape"}
           })},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.runtime_memory_budgets == []
      assert snapshot.runtime_memory_budgets_truncated_count == 0
    end

    test "SPEC 7.5.3 tolerates partial memory budget payloads without failing" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           status_response(%{
             runtime_memory_budgets: [
               %{model_ref: %{model_id: "partial-model"}, status_code: "ok"}
             ]
           })},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()

      assert [
               %{
                 display_state: :observed,
                 model_ref: "partial-model",
                 mode: "unknown",
                 budget_available: nil,
                 headroom_available: nil,
                 status_code: "ok",
                 status_message: nil,
                 target_working_set_bytes: nil
               }
             ] = snapshot.runtime_memory_budgets
    end

    test "SPEC 7.5.3 safely normalizes malformed memory budget field values" do
      long_status = String.duplicate("x", 120)
      long_model_ref = String.duplicate("m", 200)
      long_mode = String.duplicate("o", 60)
      long_status_message = String.duplicate("s", 300)

      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           status_response(%{
             runtime_memory_budgets: [
               %{
                 model_ref: long_model_ref,
                 mode: long_mode,
                 budget_available: "true",
                 headroom_available: 1,
                 status_code: long_status,
                 status_message: long_status_message,
                 target_working_set_bytes: "45000",
                 resident_memory_bytes: -1,
                 kv_cache_bytes_per_token: nil,
                 prefill_workspace_bytes_per_token: :unknown
               },
               "not a budget map"
             ]
           })},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()

      assert [
               %{
                 display_state: :observed,
                 model_ref: bounded_model_ref,
                 mode: bounded_mode,
                 budget_available: nil,
                 headroom_available: nil,
                 status_code: bounded_status,
                 status_message: bounded_status_message,
                 target_working_set_bytes: nil,
                 resident_memory_bytes: nil,
                 kv_cache_bytes_per_token: nil,
                 prefill_workspace_bytes_per_token: nil
               },
               %{
                 display_state: :invalid,
                 model_ref: "unknown model",
                 status_code: "invalid_status"
               }
             ] = snapshot.runtime_memory_budgets

      assert String.length(bounded_model_ref) == 160
      assert String.length(bounded_mode) == 40
      assert String.length(bounded_status) == 80
      assert String.length(bounded_status_message) == 240
    end

    test "SPEC 7.5.3 caps oversized runtime memory budget lists deterministically" do
      budgets =
        Enum.map(1..22, fn index ->
          %{
            model_ref: %{model_id: "model-#{index}", version: "main"},
            mode: "observe",
            budget_available: true,
            headroom_available: false,
            status_code: "ok",
            status_message: "",
            target_working_set_bytes: index,
            resident_memory_bytes: 0,
            kv_cache_bytes_per_token: 0,
            prefill_workspace_bytes_per_token: 0
          }
        end)

      stub_client(
        connect: {:ok, :ch},
        status: {:ok, status_response(%{runtime_memory_budgets: budgets})},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert length(snapshot.runtime_memory_budgets) == 20
      assert hd(snapshot.runtime_memory_budgets).model_ref == "model-1@main"
      assert List.last(snapshot.runtime_memory_budgets).model_ref == "model-20@main"
      assert snapshot.runtime_memory_budgets_truncated_count == 2
    end

    test "SPEC 7.5.3 normalizes prefix-cache statuses with approved fields only" do
      fingerprint = "hmac-sha256:" <> String.duplicate("a", 64)

      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           status_response(%{
             runtime_prefix_cache_statuses: [
               %{
                 model_ref: %{model_id: "mlx-community/phi-3", version: "main"},
                 implementation: "kv",
                 enabled: true,
                 entry_count: 2,
                 total_bytes: 32_768,
                 hits: 12,
                 misses: 4,
                 failures: 1,
                 stores: 8,
                 evictions: 0,
                 configured_max_entries: 8,
                 configured_max_bytes: 0,
                 status_code: "ok",
                 status_message: "active",
                 session_started_unix_ms: 1_713_726_400_000,
                 prefix_cache_fingerprints: [fingerprint, "not-a-fingerprint"],
                 prompt_fingerprint: "must-not-leak"
               }
             ]
           })},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()

      assert [status] = snapshot.runtime_prefix_cache_statuses
      assert status.model_ref == "mlx-community/phi-3@main"
      assert status.implementation == "kv"
      assert status.enabled == true
      assert status.entry_count == 2
      assert status.total_bytes == 32_768
      assert status.hits == 12
      assert status.misses == 4
      assert status.failures == 1
      assert status.stores == 8
      assert status.evictions == 0
      assert status.configured_max_entries == 8
      assert status.configured_max_bytes == 0
      assert status.status_code == "ok"
      assert status.status_message == "active"
      assert status.session_started_unix_ms == 1_713_726_400_000
      assert status.prefix_cache_fingerprint_count == 1
      assert status.prefix_cache_warmth_indicator == true
      refute Map.has_key?(status, :prefix_cache_fingerprints)
      refute Map.has_key?(status, :prompt_fingerprint)
    end

    test "SPEC 7.5.3 keeps raw prefix-cache fingerprints scheduler-internal only" do
      fingerprints =
        Enum.map(0..70, fn value ->
          digest = value |> Integer.to_string(16) |> String.downcase()
          "hmac-sha256:" <> String.pad_leading(digest, 64, "0")
        end)

      status = %{
        model_ref: %{model_id: "mlx-community/phi-3", version: "main"},
        implementation: "kv",
        enabled: true,
        entry_count: 2,
        total_bytes: 32_768,
        status_code: "ok",
        prefix_cache_fingerprints: fingerprints ++ [hd(fingerprints), "not-a-fingerprint"]
      }

      scheduler_status = PrefixCacheStatus.normalize_for_scheduler(status)
      telemetry_status = PrefixCacheStatus.normalize(status)

      assert length(scheduler_status.prefix_cache_fingerprints) == 64
      assert hd(scheduler_status.prefix_cache_fingerprints) == hd(fingerprints)
      refute "not-a-fingerprint" in scheduler_status.prefix_cache_fingerprints
      refute Map.has_key?(telemetry_status, :prefix_cache_fingerprints)
      assert telemetry_status.prefix_cache_fingerprint_count == 64
      assert telemetry_status.prefix_cache_warmth_indicator == true
    end

    test "SPEC 7.5.3 tolerates absent and malformed prefix-cache telemetry" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           status_response(%{
             runtime_prefix_cache_statuses: [
               %{model_ref: %{model_id: "bad-model"}, status_code: "ok", total_bytes: "bad"},
               "not a status map"
             ]
           })},
        disconnect: :ok
      )

      assert {:ok, snapshot} = Runtime.snapshot()

      assert [malformed_numeric, malformed_shape] = snapshot.runtime_prefix_cache_statuses
      assert malformed_numeric.status_code == "invalid_status"
      assert malformed_numeric.total_bytes == nil
      assert malformed_shape.status_code == "invalid_status"
      assert malformed_shape.status_message == "prefix-cache telemetry payload was malformed"
    end

    test "SPEC 7.5.3 selected prefix-cache fields suppress non-ok counters" do
      assert PrefixCacheStatus.selected_fields(%{
               status_code: "unavailable",
               enabled: true,
               entry_count: 10,
               total_bytes: 20,
               session_started_unix_ms: 1_713_726_400_000
             }) == %{
               selected_prefix_cache_status_code: "unavailable",
               selected_prefix_cache_enabled: true
             }
    end

    test "SPEC 7.5.3 preserves empty memory budgets on unreachable snapshots" do
      stub_client(
        connect: {:error, {:connect_failed, :econnrefused}},
        status: nil,
        disconnect: nil
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.runtime_memory_budgets == []
      assert error.runtime_memory_budgets_truncated_count == 0
    end

    test "status error does not trigger observe_status" do
      stub_client(
        connect: {:ok, :ch},
        status: {:error, :node_timeout},
        disconnect: :ok
      )

      assert {:error, _} = Runtime.snapshot()
      refute_received {:observe_status_called, _, _, _}
    end

    test "connect error does not trigger observe_status" do
      stub_client(
        connect: {:error, {:connect_failed, :econnrefused}},
        status: nil,
        disconnect: nil
      )

      assert {:error, _} = Runtime.snapshot()
      refute_received {:observe_status_called, _, _, _}
    end

    test "timeout option is forwarded to status call" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: nil,
             runtime_health: nil
           }},
        disconnect: :ok
      )

      assert {:ok, _snapshot} = Runtime.snapshot(timeout: 1_000)
      assert_received {:status_called_with_opts, [timeout: 1_000]}
    end

    test "rpc error is sanitized and does not leak backend message" do
      stub_client(
        connect: {:ok, :ch},
        status: {:error, {:rpc_error, :internal, "sensitive backend text"}},
        disconnect: :ok
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.code == "rpc_internal"
      assert error.message == "node status request failed"
      refute error.message =~ "sensitive"
    end
  end

  # ---------------------------------------------------------------------------
  # Stub client
  # ---------------------------------------------------------------------------

  defmodule StubClient do
    def connect(target) do
      send(get_stub_pid(), {:connect_called, target})

      case dispatch_stub(:connect, target) do
        {:ok, channel} ->
          # Wrap channel with target info so status/disconnect can route per-target
          {:ok, {:stub_channel, target, channel}}

        error ->
          error
      end
    end

    def status({:stub_channel, target, _channel}, opts) do
      if opts != [], do: send(get_stub_pid(), {:status_called_with_opts, opts})
      dispatch_stub(:status, target)
    end

    def status(channel, opts) do
      if opts != [], do: send(get_stub_pid(), {:status_called_with_opts, opts})
      # Fallback for non-wrapped channels (legacy single-target tests)
      _ = channel
      dispatch_stub(:status)
    end

    def disconnect({:stub_channel, _target, channel}) do
      send(get_stub_pid(), {:disconnect_called, channel})
      dispatch_stub(:disconnect)
    end

    def disconnect(channel) do
      send(get_stub_pid(), {:disconnect_called, channel})
      dispatch_stub(:disconnect)
    end

    # Sentinel dispatch: interprets {:raise, exception} and {:exit, reason}
    # to simulate transport crashes in addition to normal return values.
    defp dispatch_stub(key, target \\ nil) do
      value = get_stub(key, target)

      case value do
        {:raise, exception} -> raise exception
        {:exit, reason} -> exit(reason)
        other -> other
      end
    end

    defp get_stub(key, target) do
      [{_pid, stubs}] = Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs)

      # Support per-target scripted responses via :target_responses map
      case Keyword.get(stubs, :target_responses) do
        responses when is_map(responses) and target != nil ->
          target_key = target_response_key(target)

          case Map.get(responses, target_key) do
            nil -> Keyword.fetch!(stubs, key)
            target_stubs -> Keyword.fetch!(target_stubs, key)
          end

        _ ->
          Keyword.fetch!(stubs, key)
      end
    end

    defp target_response_key(%Orchard.RuntimeEndpoint.Target{
           transport: :grpc_compat,
           address: address
         }) do
      target_response_key(address)
    end

    defp target_response_key(%Orchard.RuntimeEndpoint.Target{transport: :beam, address: address}) do
      {:beam, address}
    end

    defp target_response_key(target) when is_list(target) do
      {Keyword.get(target, :host), Keyword.get(target, :port)}
    end

    defp get_stub_pid do
      [{pid, _stubs}] = Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs)
      pid
    end
  end

  defmodule LegacyPoisonClient do
    def connect(target) do
      [{pid, _stubs}] = Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs)
      send(pid, {:legacy_client_called, target})
      {:error, :legacy_client_used}
    end

    def status(_channel, _opts \\ []), do: {:error, :legacy_client_used}
    def disconnect(_channel), do: :ok
  end

  defmodule StubNodes do
    def observe_status(target, response, observed_at) do
      pid = stub_pid()
      if pid, do: send(pid, {:observe_status_called, target, response, observed_at})

      # Support configurable observe_status behavior for crash testing
      case get_observe_behavior() do
        {:exit, reason} -> exit(reason)
        {:raise, exception} -> raise exception
        _ -> :noop
      end
    end

    defp get_observe_behavior do
      case Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs) do
        [{_pid, stubs}] -> Keyword.get(stubs, :observe_behavior)
        _ -> nil
      end
    end

    defp stub_pid do
      case Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs) do
        [{pid, _}] -> pid
        _ -> nil
      end
    end
  end

  describe "cluster_snapshot/0,1" do
    test "defaults to explicit Runtime Endpoint targets instead of legacy gRPC targets" do
      node_id = "550e8400-e29b-41d4-a716-446655440000"
      beam_target = Target.beam(node_id, address: :orchard_node_agent_smoke@localhost)
      legacy_target = [host: "10.0.0.1", port: 50_061]

      put_inference(
        runtime_endpoint_client_impl: __MODULE__.StubClient,
        runtime_endpoint_targets: [beam_target],
        runtime_client_targets: [legacy_target]
      )

      stub_client(
        target_responses: %{
          {:beam, :orchard_node_agent_smoke@localhost} => [
            connect: {:ok, :beam_ch},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [],
                 active_request_count: 0,
                 node_metadata: %{
                   node_id: node_id,
                   display_name: "beam-node",
                   hostname: "beam.local",
                   listen_host: "127.0.0.1",
                   listen_port: 50_071,
                   agent_version: "0.1.0",
                   worker_backend: "stub"
                 },
                 runtime_health: %{ready: true}
               }},
            disconnect: :ok
          ]
        }
      )

      assert [
               %{target: ^beam_target, status: :ok, node_metadata: %{display_name: "beam-node"}}
             ] = Runtime.cluster_snapshot()

      assert_received {:connect_called, ^beam_target}
      refute_received {:connect_called, ^legacy_target}
    end

    test "BEAM Runtime Endpoint targets ignore stale legacy Console runtime client override" do
      node_id = "550e8400-e29b-41d4-a716-446655440000"
      beam_target = Target.beam(node_id, address: :orchard_node_agent_smoke@localhost)

      put_console(runtime_client_impl: __MODULE__.LegacyPoisonClient)

      put_inference(
        runtime_endpoint_client_impl: __MODULE__.StubClient,
        runtime_endpoint_targets: [beam_target]
      )

      stub_client(
        target_responses: %{
          {:beam, :orchard_node_agent_smoke@localhost} => [
            connect: {:ok, :beam_ch},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [],
                 active_request_count: 0,
                 node_metadata: %{node_id: node_id, display_name: "beam-node"},
                 runtime_health: %{ready: true}
               }},
            disconnect: :ok
          ]
        }
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.node_metadata.display_name == "beam-node"
      assert_received {:connect_called, ^beam_target}
      refute_received {:legacy_client_called, ^beam_target}
    end

    test "normalizes Runtime Endpoint observations returned by the configured client" do
      node_id = "550e8400-e29b-41d4-a716-446655440000"
      target = Target.beam(node_id, address: :orchard_node_agent_smoke@localhost)

      put_inference(runtime_endpoint_client_impl: __MODULE__.StubClient)

      observation =
        Observation.new(%{
          endpoint_id: "beam:#{node_id}",
          target: target,
          availability: :available,
          worker_state: :idle,
          aggregate_active_request_count: 2,
          metadata: %{
            node_id: node_id,
            display_name: "beam-observed",
            hostname: "beam.local",
            listen_host: "127.0.0.1",
            listen_port: 50_071,
            agent_version: "0.2.0",
            worker_backend: "stub"
          },
          health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil},
          placements: [
            %{
              model_ref: %{model_id: "mlx-community/phi-3", version: "main"},
              state: :loaded
            }
          ],
          supports_prompt_token_ids: true
        })

      stub_client(
        target_responses: %{
          {:beam, :orchard_node_agent_smoke@localhost} => [
            connect: {:ok, :beam_ch},
            status: {:ok, observation},
            disconnect: :ok
          ]
        }
      )

      assert {:ok, snapshot} = Runtime.snapshot(target: target)

      assert snapshot.worker_state == :idle
      assert snapshot.active_request_count == 2
      assert snapshot.node_metadata.display_name == "beam-observed"
      assert snapshot.runtime_health.ready == true
      assert snapshot.supports_prompt_token_ids == true
      assert snapshot.loaded_models == [%{model_id: "mlx-community/phi-3", version: "main"}]

      assert_received {:observe_status_called, ^target, ^observation, _observed_at}
    end

    test "probes all targets in config order" do
      target_a = [host: "127.0.0.1", port: 50_071]
      target_b = [host: "10.0.0.2", port: 50_061]

      stub_client(
        target_responses: %{
          {"127.0.0.1", 50_071} => [
            connect: {:ok, :ch_a},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [%{model_id: "model-a", version: "v1"}],
                 active_request_count: 1,
                 node_metadata: %{
                   node_id: "aaaa-0001",
                   display_name: "node-a",
                   hostname: "host-a.local"
                 },
                 runtime_health: %{ready: true}
               }},
            disconnect: :ok
          ],
          {"10.0.0.2", 50_061} => [
            connect: {:ok, :ch_b},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_BUSY,
                 loaded_models: [],
                 active_request_count: 3,
                 node_metadata: %{
                   node_id: "bbbb-0002",
                   display_name: "node-b",
                   hostname: "host-b.local"
                 },
                 runtime_health: %{ready: true}
               }},
            disconnect: :ok
          ]
        }
      )

      results = Runtime.cluster_snapshot(targets: [target_a, target_b])

      assert length(results) == 2

      [first, second] = results
      assert first.target == target_a
      assert first.status == :ok
      assert first.worker_state == :idle
      assert first.node_metadata.display_name == "node-a"

      assert second.target == target_b
      assert second.status == :ok
      assert second.worker_state == :busy
      assert second.node_metadata.display_name == "node-b"
    end

    test "mixed success and error entries in one result" do
      target_ok = [host: "127.0.0.1", port: 50_071]
      target_fail = [host: "10.0.0.99", port: 50_061]

      stub_client(
        target_responses: %{
          {"127.0.0.1", 50_071} => [
            connect: {:ok, :ch},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [],
                 active_request_count: 0,
                 node_metadata: %{node_id: "ok-node"},
                 runtime_health: %{ready: true}
               }},
            disconnect: :ok
          ],
          {"10.0.0.99", 50_061} => [
            connect: {:error, {:connect_failed, :econnrefused}},
            status: nil,
            disconnect: nil
          ]
        }
      )

      results = Runtime.cluster_snapshot(targets: [target_ok, target_fail])

      assert length(results) == 2

      [ok_entry, fail_entry] = results
      assert ok_entry.status == :ok
      assert ok_entry.worker_state == :idle

      assert fail_entry.status == :unavailable
      assert fail_entry.message == "node runtime is unavailable"
      assert fail_entry.worker_state == :unknown
    end

    test "cluster_snapshot carries prompt-token-id capability per successful target" do
      target_capable = [host: "127.0.0.1", port: 50_071]
      target_legacy = [host: "10.0.0.2", port: 50_061]
      target_fail = [host: "10.0.0.99", port: 50_061]

      stub_client(
        target_responses: %{
          {"127.0.0.1", 50_071} => [
            connect: {:ok, :ch_a},
            status: {:ok, status_response(%{supports_prompt_token_ids: true})},
            disconnect: :ok
          ],
          {"10.0.0.2", 50_061} => [
            connect: {:ok, :ch_b},
            status: {:ok, status_response(%{supports_prompt_token_ids: false})},
            disconnect: :ok
          ],
          {"10.0.0.99", 50_061} => [
            connect: {:error, {:connect_failed, :econnrefused}},
            status: nil,
            disconnect: nil
          ]
        }
      )

      [capable, legacy, failed] =
        Runtime.cluster_snapshot(targets: [target_capable, target_legacy, target_fail])

      assert capable.supports_prompt_token_ids == true
      assert legacy.supports_prompt_token_ids == false
      assert failed.supports_prompt_token_ids == false
    end

    test "successful entries trigger observe_status, failed entries do not" do
      target_ok = [host: "127.0.0.1", port: 50_071]
      target_fail = [host: "10.0.0.99", port: 50_061]

      stub_client(
        target_responses: %{
          {"127.0.0.1", 50_071} => [
            connect: {:ok, :ch},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [],
                 active_request_count: 0,
                 node_metadata: %{node_id: "observe-me"},
                 runtime_health: nil
               }},
            disconnect: :ok
          ],
          {"10.0.0.99", 50_061} => [
            connect: {:error, {:connect_failed, :econnrefused}},
            status: nil,
            disconnect: nil
          ]
        }
      )

      _results = Runtime.cluster_snapshot(targets: [target_ok, target_fail])

      # Exactly one observe_status call for the successful target
      assert_received {:observe_status_called, ^target_ok, _response, _observed_at}
      refute_received {:observe_status_called, ^target_fail, _, _}
    end

    test "shared observed_at is passed through to all probes" do
      observed_at = ~U[2026-03-24 12:00:00Z]
      target = [host: "127.0.0.1", port: 50_071]

      stub_client(
        target_responses: %{
          {"127.0.0.1", 50_071} => [
            connect: {:ok, :ch},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [],
                 active_request_count: 0,
                 node_metadata: %{node_id: "ts-test"},
                 runtime_health: nil
               }},
            disconnect: :ok
          ]
        }
      )

      _results = Runtime.cluster_snapshot(targets: [target], observed_at: observed_at)

      assert_received {:observe_status_called, ^target, _response, ^observed_at}
    end

    test "timeout option is forwarded to each snapshot call" do
      target = [host: "127.0.0.1", port: 50_071]

      stub_client(
        target_responses: %{
          {"127.0.0.1", 50_071} => [
            connect: {:ok, :ch},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [],
                 active_request_count: 0,
                 node_metadata: nil,
                 runtime_health: nil
               }},
            disconnect: :ok
          ]
        }
      )

      _results = Runtime.cluster_snapshot(targets: [target], timeout: 2_000)

      assert_received {:status_called_with_opts, [timeout: 2_000]}
    end

    test "empty target list returns empty list" do
      stub_client(connect: nil, status: nil, disconnect: nil)

      assert Runtime.cluster_snapshot(targets: []) == []
    end

    test "single target returns single-element list" do
      target = [host: "127.0.0.1", port: 50_071]

      stub_client(
        target_responses: %{
          {"127.0.0.1", 50_071} => [
            connect: {:ok, :ch},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [],
                 active_request_count: 0
               }},
            disconnect: :ok
          ]
        }
      )

      results = Runtime.cluster_snapshot(targets: [target])
      assert length(results) == 1
      assert hd(results).target == target
      assert hd(results).status == :ok
    end
  end

  describe "transport crash resilience" do
    test "connect exit returns unavailable snapshot" do
      stub_client(
        connect: {:exit, :econnrefused},
        status: nil,
        disconnect: nil
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.status == :unavailable
      assert error.code == "node_unavailable"
      refute_received {:disconnect_called, _}
    end

    test "connect raise returns unavailable snapshot" do
      stub_client(
        connect: {:raise, RuntimeError.exception("boom")},
        status: nil,
        disconnect: nil
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.status == :unavailable
      assert error.code == "node_unavailable"
    end

    test "status exit after successful connect returns unavailable snapshot" do
      stub_client(
        connect: {:ok, :ch},
        status: {:exit, {:shutdown, :timeout}},
        disconnect: :ok
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.status == :unavailable
      assert error.code == "node_unavailable"
      # disconnect still called via after block
      assert_received {:disconnect_called, :ch}
    end

    test "status raise after successful connect returns error snapshot" do
      stub_client(
        connect: {:ok, :ch},
        status: {:raise, RuntimeError.exception("status boom")},
        disconnect: :ok
      )

      assert {:error, error} = Runtime.snapshot()
      assert error.status == :unavailable
      assert error.code == "node_unavailable"
      assert_received {:disconnect_called, :ch}
    end

    test "disconnect exit does not override successful snapshot" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0
           }},
        disconnect: {:exit, :noproc}
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.worker_state == :idle
    end

    test "disconnect raise does not override successful snapshot" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0
           }},
        disconnect: {:raise, RuntimeError.exception("disconnect boom")}
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.worker_state == :idle
    end

    test "cluster_snapshot continues after one target exits" do
      target_exit = [host: "10.0.0.1", port: 50_071]
      target_ok = [host: "10.0.0.2", port: 50_071]

      stub_client(
        target_responses: %{
          {"10.0.0.1", 50_071} => [
            connect: {:exit, :econnrefused},
            status: nil,
            disconnect: nil
          ],
          {"10.0.0.2", 50_071} => [
            connect: {:ok, :ch_b},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_IDLE,
                 loaded_models: [],
                 active_request_count: 0,
                 node_metadata: %{node_id: "ok-node"},
                 runtime_health: %{ready: true}
               }},
            disconnect: :ok
          ]
        }
      )

      results = Runtime.cluster_snapshot(targets: [target_exit, target_ok])

      assert length(results) == 2
      [fail_entry, ok_entry] = results

      # First target failed — shows as error/unavailable
      assert fail_entry.target == target_exit
      assert fail_entry.status in [:error, :unavailable]
      assert fail_entry.worker_state == :unknown

      # Second target unaffected
      assert ok_entry.target == target_ok
      assert ok_entry.status == :ok
      assert ok_entry.worker_state == :idle
    end

    test "cluster_snapshot continues after one target raises" do
      target_raise = [host: "10.0.0.1", port: 50_071]
      target_ok = [host: "10.0.0.2", port: 50_071]

      stub_client(
        target_responses: %{
          {"10.0.0.1", 50_071} => [
            connect: {:raise, RuntimeError.exception("connect boom")},
            status: nil,
            disconnect: nil
          ],
          {"10.0.0.2", 50_071} => [
            connect: {:ok, :ch_b},
            status:
              {:ok,
               %{
                 worker_state: :WORKER_STATE_BUSY,
                 loaded_models: [],
                 active_request_count: 2
               }},
            disconnect: :ok
          ]
        }
      )

      results = Runtime.cluster_snapshot(targets: [target_raise, target_ok])

      assert length(results) == 2
      [fail_entry, ok_entry] = results

      assert fail_entry.target == target_raise
      assert fail_entry.status in [:error, :unavailable]

      assert ok_entry.target == target_ok
      assert ok_entry.status == :ok
      assert ok_entry.worker_state == :busy
    end

    test "observe_status exit does not turn successful snapshot into error" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: %{node_id: "observe-exit-test"},
             runtime_health: %{ready: true}
           }},
        disconnect: :ok,
        observe_behavior: {:exit, :noproc}
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.worker_state == :idle
      assert snapshot.node_metadata.node_id == "observe-exit-test"
    end

    test "observe_status raise does not turn successful snapshot into error" do
      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: %{node_id: "observe-raise-test"},
             runtime_health: nil
           }},
        disconnect: :ok,
        observe_behavior: {:raise, RuntimeError.exception("repo crashed")}
      )

      assert {:ok, snapshot} = Runtime.snapshot()
      assert snapshot.worker_state == :idle
    end
  end

  describe "repo-off fallback" do
    test "snapshot succeeds when Repo is unavailable during observe_status" do
      # Use real Orchard.Nodes instead of StubNodes so observe_status hits the DB path
      Application.put_env(
        :orchard_controller,
        :console,
        Application.get_env(:orchard_controller, :console, [])
        |> Keyword.put(:nodes_impl, Orchard.Nodes)
      )

      stub_client(
        connect: {:ok, :ch},
        status:
          {:ok,
           %{
             worker_state: :WORKER_STATE_IDLE,
             loaded_models: [],
             active_request_count: 0,
             node_metadata: %{
               node_id: Ecto.UUID.generate(),
               display_name: "repo-off-test",
               hostname: "test.local",
               listen_host: "127.0.0.1",
               listen_port: 50_071,
               agent_version: "0.1.0",
               worker_backend: "mlx"
             },
             runtime_health: %{
               ready: true,
               health_code: nil,
               health_message: nil,
               affected_model: nil
             }
           }},
        disconnect: :ok
      )

      with_repo_unregistered(fn ->
        assert {:ok, snapshot} = Runtime.snapshot()
        assert snapshot.worker_state == :idle
        assert snapshot.node_metadata != nil
        assert snapshot.runtime_health != nil
      end)
    end
  end

  defp stub_client(stubs) do
    start_supervised!({Registry, keys: :duplicate, name: __MODULE__.StubRegistry})
    Registry.register(__MODULE__.StubRegistry, :stubs, stubs)
  end

  defp status_response(attrs \\ %{}) do
    Map.merge(
      %{
        worker_state: :WORKER_STATE_IDLE,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil
      },
      attrs
    )
  end

  defp put_inference(opts) do
    previous = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.merge(previous, opts))
  end

  defp put_console(opts) do
    previous = Application.fetch_env!(:orchard_controller, :console)
    Application.put_env(:orchard_controller, :console, Keyword.merge(previous, opts))
  end
end
