defmodule Orchard.Dispatch.ProbeCompatibilityTest.StubClient do
  @moduledoc false

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    ExecuteInferenceRequest
  }

  alias Orchard.InferenceEvent

  def connect(_target), do: {:ok, :stub_channel}

  def status(_channel, _opts \\ []) do
    Process.get(:probe_stub_config).status
  end

  def ensure_model_loaded(_channel, %EnsureModelLoadedRequest{} = request, _opts \\ []) do
    config = Process.get(:probe_stub_config)

    if config.capture_pid do
      send(config.capture_pid, {:ensure_model_loaded_called, request})
    end

    {:ok,
     %EnsureModelLoadedResponse{already_loaded: false, placement_state: :PLACEMENT_STATE_LOADED}}
  end

  def execute_inference(_channel, %ExecuteInferenceRequest{} = request, _opts \\ []) do
    caller = self()
    ref = make_ref()

    spawn(fn ->
      accepted = InferenceEvent.accepted(System.system_time(:millisecond))
      completed = InferenceEvent.completed(:finish_reason_stop, nil)

      send(caller, {:dispatch_event, ref, request.request_id, accepted})
      send(caller, {:dispatch_event, ref, request.request_id, completed})
      send(caller, {:dispatch_done, ref, :ok})
    end)

    {:ok, ref}
  end

  def cancel_inference(_channel, _request_id), do: :ok
  def disconnect(_channel), do: :ok
end

defmodule Orchard.Dispatch.ProbeCompatibilityTest do
  @moduledoc """
  Tests for the pre-dispatch status probe in RequestDispatcher.

  Uses a stub client to verify behavior without a live gRPC server:
  - Missing metadata from old node-agent
  - Invalid UUID in metadata
  - Valid UUID discovery overrides scheduled UUID
  - Probe transport failure is non-fatal
  - Repo-off during probe observation is non-fatal
  """

  use Orchard.DataCase, async: false

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    ExecuteInferenceRequest
  }

  alias Orchard.Dispatch.RequestDispatcher

  @valid_uuid "550e8400-e29b-41d4-a716-446655440000"
  @other_uuid "660f9511-f30c-52e5-b827-557766551111"
  @stub_client Orchard.Dispatch.ProbeCompatibilityTest.StubClient

  setup do
    %{
      schedule: %{
        strategy: :single_node,
        request_id: "req-probe-test",
        runtime_client_target: [host: "127.0.0.1", port: 99999],
        request_timeout_ms: 5_000,
        model_load_timeout_ms: 5_000
      },
      execute: %ExecuteInferenceRequest{
        request_id: "req-probe-test",
        controller_session_id: "probe-test-session",
        model_id: "test/model",
        version: "v1",
        rendered_prompt_utf8: "hello",
        input_tokens: 1
      },
      model_load: %EnsureModelLoadedRequest{
        node_id: "original-node-id",
        model_id: "test/model",
        version: "v1"
      }
    }
  end

  defp configure_stub(status_response) do
    Process.put(:probe_stub_config, %{
      status: status_response,
      capture_pid: self()
    })
  end

  defp old_agent_status do
    %{worker_state: :WORKER_STATE_IDLE, loaded_models: [], active_request_count: 0}
  end

  defp full_status(node_id) do
    %{
      worker_state: :WORKER_STATE_IDLE,
      loaded_models: [],
      active_request_count: 0,
      node_metadata: %{
        node_id: node_id,
        display_name: "test-node",
        hostname: "test.local",
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
    }
  end

  describe "missing metadata from old node-agent" do
    test "dispatch succeeds and keeps original node_id", ctx do
      configure_stub({:ok, old_agent_status()})

      assert {:ok, _events} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == "original-node-id"
    end

    test "on_node_resolved callback is not invoked", ctx do
      configure_stub({:ok, old_agent_status()})
      callback = fn node_id -> send(self(), {:node_resolved, node_id}) end

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client,
                 on_node_resolved: callback
               )

      refute_received {:node_resolved, _}
    end
  end

  describe "invalid UUID in metadata" do
    test "dispatch succeeds and keeps original node_id", ctx do
      configure_stub({:ok, full_status("not-a-uuid")})

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == "original-node-id"
    end
  end

  describe "valid UUID overrides scheduled node_id" do
    test "model_load receives discovered UUID", ctx do
      configure_stub({:ok, full_status(@valid_uuid)})

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == @valid_uuid
    end

    test "on_node_resolved callback receives discovered UUID", ctx do
      configure_stub({:ok, full_status(@other_uuid)})
      callback = fn node_id -> send(self(), {:node_resolved, node_id}) end

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client,
                 on_node_resolved: callback
               )

      assert_received {:node_resolved, @other_uuid}
    end
  end

  describe "probe transport failure" do
    test "dispatch succeeds and keeps original node_id", ctx do
      configure_stub({:error, :node_timeout})

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == "original-node-id"
    end
  end

  describe "repo-off during probe observation" do
    test "dispatch succeeds with discovered UUID even when persistence fails", ctx do
      configure_stub({:ok, full_status(@valid_uuid)})

      repo_pid = Process.whereis(Orchard.Repo)
      assert is_pid(repo_pid)
      Process.unregister(Orchard.Repo)

      try do
        assert {:ok, _} =
                 RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                   client_impl: @stub_client
                 )

        assert_received {:ensure_model_loaded_called, req}
        assert req.node_id == @valid_uuid
      after
        Process.register(repo_pid, Orchard.Repo)
      end
    end
  end
end
