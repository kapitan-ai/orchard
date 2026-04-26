defmodule Orchard.Dispatch.ProbeCompatibilityTest.StubClient do
  @moduledoc false
  @registry __MODULE__.Registry

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    ExecuteInferenceRequest
  }

  alias Orchard.InferenceEvent

  @doc false
  def registry_name, do: @registry

  def connect(_target), do: config().connect

  def status(_channel, _opts \\ []) do
    config().status
  end

  def ensure_model_loaded(_channel, %EnsureModelLoadedRequest{} = request, _opts \\ []) do
    config = config()

    if config.capture_pid do
      send(config.capture_pid, {:ensure_model_loaded_called, request})
    end

    case config.ensure_model_loaded do
      {:ok, %EnsureModelLoadedResponse{} = response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute_inference(_channel, %ExecuteInferenceRequest{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    spawn(fn ->
      accepted = InferenceEvent.accepted(System.system_time(:millisecond))
      completed = InferenceEvent.completed(:finish_reason_stop, nil)

      case config().execute do
        :success ->
          send(owner, {:dispatch_event, ref, request.request_id, accepted})
          send(owner, {:dispatch_event, ref, request.request_id, completed})
          send(owner, {:dispatch_done, ref, :ok})

        {:error, reason} ->
          send(owner, {:dispatch_done, ref, {:error, reason}})

        {:accepted_then_error, reason} ->
          send(owner, {:dispatch_event, ref, request.request_id, accepted})
          send(owner, {:dispatch_done, ref, {:error, reason}})
      end
    end)

    {:ok, ref}
  end

  def cancel_inference(_channel, _request_id), do: :ok
  def disconnect(_channel), do: :ok

  defp config do
    [{_pid, config}] = Registry.lookup(@registry, :config)
    config
  end
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

  import Orchard.TestSupport.SentryContextHelpers

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    ExecuteInferenceRequest
  }

  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.Nodes.Node

  @valid_uuid "550e8400-e29b-41d4-a716-446655440000"
  @other_uuid "660f9511-f30c-52e5-b827-557766551111"
  @stub_client Orchard.Dispatch.ProbeCompatibilityTest.StubClient

  setup :setup_sentry_context

  setup do
    start_supervised!({Registry, keys: :duplicate, name: @stub_client.registry_name()})

    %{
      schedule: %{
        strategy: :single_node,
        request_id: "req-probe-test",
        runtime_client_target: [host: "127.0.0.1", port: 59_999],
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

  defp configure_stub(overrides) do
    Registry.register(
      @stub_client.registry_name(),
      :config,
      Map.merge(default_stub_config(), overrides)
    )
  end

  defp default_stub_config do
    %{
      connect: {:ok, :stub_channel},
      status: {:ok, old_agent_status()},
      ensure_model_loaded:
        {:ok,
         %EnsureModelLoadedResponse{
           already_loaded: false,
           placement_state: :PLACEMENT_STATE_LOADED
         }},
      execute: :success,
      capture_pid: self()
    }
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
    }
  end

  defp insert_target_node!(target, opts \\ []) do
    now = DateTime.utc_now()
    host = Keyword.fetch!(target, :host)
    port = Keyword.fetch!(target, :port)

    attrs = %{
      id: Keyword.get(opts, :id, Ecto.UUID.generate()),
      hostname: Keyword.get(opts, :hostname, "target.local"),
      display_name:
        Keyword.get(opts, :display_name, "target-node-#{System.unique_integer([:positive])}"),
      advertise_addr: Keyword.get(opts, :advertise_addr, host),
      rpc_port: Keyword.get(opts, :rpc_port, port),
      connect_host: Keyword.get(opts, :connect_host),
      connect_port: Keyword.get(opts, :connect_port),
      state: Keyword.get(opts, :state, :active),
      health: Keyword.get(opts, :health, :healthy),
      capabilities: %{},
      last_heartbeat_at: Keyword.get(opts, :last_heartbeat_at, now)
    }

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  describe "missing metadata from old node-agent" do
    test "dispatch succeeds and keeps original node_id", ctx do
      configure_stub(%{status: {:ok, old_agent_status()}})

      assert {:ok, _events} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == "original-node-id"
    end

    test "on_node_resolved callback is not invoked", ctx do
      configure_stub(%{status: {:ok, old_agent_status()}})
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
      configure_stub(%{status: {:ok, full_status("not-a-uuid")}})

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
      configure_stub(%{status: {:ok, full_status(@valid_uuid)}})

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == @valid_uuid
    end

    test "Sentry controller enrichment records node resolution and ensure-load breadcrumbs",
         ctx do
      enable_controller_sentry()
      configure_stub(%{status: {:ok, full_status(@valid_uuid)}})

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      context = sentry_context()

      assert "node.resolved" in breadcrumb_messages()
      assert "ensure_model_load.started" in breadcrumb_messages()
      assert "ensure_model_load.completed" in breadcrumb_messages()
      assert context.extra.orchard_node_hash == Orchard.SentryContext.hash_id(@valid_uuid)
      assert context.extra.orchard_target_host_sanitized == "[redacted]"
      refute inspect(context) =~ @valid_uuid
      refute inspect(context) =~ "127.0.0.1"
    end

    test "on_node_resolved callback receives discovered UUID", ctx do
      configure_stub(%{status: {:ok, full_status(@other_uuid)}})
      callback = fn node_id -> send(self(), {:node_resolved, node_id}) end

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client,
                 on_node_resolved: callback
               )

      assert_received {:node_resolved, @other_uuid}
    end

    test "hosted tool fields remain additive to pre-dispatch probe compatibility", ctx do
      configure_stub(%{
        status:
          {:ok,
           Map.merge(full_status(@valid_uuid), %{
             hosted_tool_capabilities: [
               %{name: "lookup_docs", version: "2026-04-11", adapter_kind: "mcp"}
             ],
             hosted_tool_readiness: [
               %{name: "lookup_docs", version: "2026-04-11", ready: true}
             ]
           })}
      })

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == @valid_uuid
    end
  end

  describe "probe transport failure" do
    test "dispatch succeeds, keeps original node_id, and marks fresh node degraded", ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{status: {:error, :node_timeout}})

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == "original-node-id"

      marked =
        Repo.get_by!(Node,
          advertise_addr: Keyword.fetch!(ctx.schedule.runtime_client_target, :host),
          rpc_port: Keyword.fetch!(ctx.schedule.runtime_client_target, :port)
        )

      assert marked.health == :degraded
    end

    test "marks stale node unreachable when transport failure crosses threshold", ctx do
      stale_hb = DateTime.add(DateTime.utc_now(), -20, :second)
      insert_target_node!(ctx.schedule.runtime_client_target, last_heartbeat_at: stale_hb)
      configure_stub(%{status: {:error, :node_timeout}})

      assert {:ok, _} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      marked =
        Repo.get_by!(Node,
          advertise_addr: Keyword.fetch!(ctx.schedule.runtime_client_target, :host),
          rpc_port: Keyword.fetch!(ctx.schedule.runtime_client_target, :port)
        )

      assert marked.health == :unreachable
    end
  end

  describe "Sentry cancellation enrichment" do
    test "handler cancellation records cancel and synthesized terminal breadcrumbs", ctx do
      enable_controller_sentry()
      configure_stub(%{execute: {:accepted_then_error, :client_closed}})

      handler = fn _request_id, event ->
        if Orchard.InferenceEvent.kind(event) == :accepted, do: :cancel, else: :ok
      end

      assert {:ok, events} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client,
                 event_handler: handler
               )

      assert List.last(events) |> Orchard.InferenceEvent.terminal?()
      assert "cancel.sent" in breadcrumb_messages()
      assert "terminal.synthesized" in breadcrumb_messages()

      cancel = sentry_context().breadcrumbs |> Enum.find(&(&1.message == "cancel.sent"))
      assert cancel.level == :warning
      assert cancel.data.reason == :client_disconnect
    end
  end

  describe "connect and dispatch transport failures" do
    test "connect failure marks target degraded and returns sanitized failure", ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{connect: {:error, {:connect_failed, :econnrefused}}})

      assert {:error, {:model_load_failed, failure}} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert failure.code == "node_unavailable"

      marked =
        Repo.get_by!(Node,
          advertise_addr: Keyword.fetch!(ctx.schedule.runtime_client_target, :host),
          rpc_port: Keyword.fetch!(ctx.schedule.runtime_client_target, :port)
        )

      assert marked.health == :degraded
    end

    test "connect failure marks bind-all advertised node by actual connect target", ctx do
      target = ctx.schedule.runtime_client_target

      node =
        insert_target_node!(target,
          advertise_addr: "0.0.0.0",
          connect_host: Keyword.fetch!(target, :host),
          connect_port: Keyword.fetch!(target, :port)
        )

      configure_stub(%{connect: {:error, {:connect_failed, :econnrefused}}})

      assert {:error, {:model_load_failed, failure}} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert failure.code == "node_unavailable"

      marked = Repo.get!(Node, node.id)
      assert marked.advertise_addr == "0.0.0.0"
      assert marked.health == :degraded
    end

    test "ensure_model_loaded transport failure marks target degraded", ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{ensure_model_loaded: {:error, :node_unavailable}})

      assert {:error, {:model_load_failed, failure}} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert failure.code == "node_unavailable"

      marked =
        Repo.get_by!(Node,
          advertise_addr: Keyword.fetch!(ctx.schedule.runtime_client_target, :host),
          rpc_port: Keyword.fetch!(ctx.schedule.runtime_client_target, :port)
        )

      assert marked.health == :degraded
    end

    test "stream execution transport failure marks target degraded", ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{execute: {:error, :node_timeout}})

      assert {:error, {:dispatch_failed, :node_timeout}} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      marked =
        Repo.get_by!(Node,
          advertise_addr: Keyword.fetch!(ctx.schedule.runtime_client_target, :host),
          rpc_port: Keyword.fetch!(ctx.schedule.runtime_client_target, :port)
        )

      assert marked.health == :degraded
    end
  end

  describe "repo-off during probe observation" do
    test "dispatch succeeds with discovered UUID even when persistence fails", ctx do
      configure_stub(%{status: {:ok, full_status(@valid_uuid)}})

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
