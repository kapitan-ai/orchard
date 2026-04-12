defmodule OrchardConsole.RuntimeTest do
  use ExUnit.Case, async: false

  alias OrchardConsole.Runtime
  import Orchard.TestSupport.RepoHelpers

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      previous
      |> Keyword.put(:runtime_client_impl, __MODULE__.StubClient)
      |> Keyword.put(:nodes_impl, __MODULE__.StubNodes)
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)
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
          target_key = {Keyword.get(target, :host), Keyword.get(target, :port)}

          case Map.get(responses, target_key) do
            nil -> Keyword.fetch!(stubs, key)
            target_stubs -> Keyword.fetch!(target_stubs, key)
          end

        _ ->
          Keyword.fetch!(stubs, key)
      end
    end

    defp get_stub_pid do
      [{pid, _stubs}] = Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs)
      pid
    end
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
end
