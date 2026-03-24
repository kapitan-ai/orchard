defmodule OrchardConsole.RuntimeTest do
  use ExUnit.Case, async: false

  alias OrchardConsole.Runtime

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
               listen_port: 50071,
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
               listen_port: 50071,
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
    def connect(_target) do
      get_stub(:connect)
    end

    def status(_channel, opts \\ []) do
      if opts != [], do: send(get_stub_pid(), {:status_called_with_opts, opts})
      get_stub(:status)
    end

    def disconnect(channel) do
      send(get_stub_pid(), {:disconnect_called, channel})
      :ok
    end

    defp get_stub(key) do
      [{_pid, stubs}] = Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs)
      Keyword.fetch!(stubs, key)
    end

    defp get_stub_pid do
      [{pid, _stubs}] = Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs)
      pid
    end
  end

  defmodule StubNodes do
    def observe_status(_target, _response, _observed_at) do
      pid = stub_pid()
      if pid, do: send(pid, {:observe_status_called, _target, _response, _observed_at})
      :noop
    end

    defp stub_pid do
      case Registry.lookup(OrchardConsole.RuntimeTest.StubRegistry, :stubs) do
        [{pid, _}] -> pid
        _ -> nil
      end
    end
  end

  defp stub_client(stubs) do
    start_supervised!({Registry, keys: :duplicate, name: __MODULE__.StubRegistry})
    Registry.register(__MODULE__.StubRegistry, :stubs, stubs)
  end
end
