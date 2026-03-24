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

    def status(_channel, _opts \\ []) do
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
