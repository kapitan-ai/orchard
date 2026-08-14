defmodule Orchard.Dispatch.ProbeCompatibilityTest.StubClient do
  @moduledoc false
  @registry __MODULE__.Registry

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest
  }

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  @doc false
  def registry_name, do: @registry

  def connect(target) do
    config = config()

    if config.capture_pid do
      send(config.capture_pid, {:connect_called, target})
    end

    config.connect
  end

  def status(_channel, _opts \\ []) do
    config().status
  end

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{} = request, _opts \\ []) do
    config = config()

    if config.capture_pid do
      send(config.capture_pid, {:ensure_model_loaded_called, request})
    end

    case config.ensure_model_loaded do
      {:ok, %Operation.EnsureModelLoadedResult{} = response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()
    execute = config().execute
    parent = self()

    spawn(fn ->
      accepted = InferenceEvent.accepted(System.system_time(:millisecond))
      completed = InferenceEvent.completed(:finish_reason_stop, nil)

      case execute do
        :success ->
          send(owner, {:runtime_endpoint_event, ref, request.request_id, accepted})
          send(owner, {:runtime_endpoint_event, ref, request.request_id, completed})
          send(owner, {:runtime_endpoint_done, ref, :ok})

        {:error, reason} ->
          send(owner, {:runtime_endpoint_done, ref, {:error, reason}})

        {:accepted_then_error, reason} ->
          send(owner, {:runtime_endpoint_event, ref, request.request_id, accepted})
          send(owner, {:runtime_endpoint_done, ref, {:error, reason}})

        mode when mode in [:accepted_until_cancel, :text_until_cancel] ->
          Registry.register(@registry, {:stream, request.request_id}, {owner, ref})
          send(parent, {:stream_registered, ref})
          send(owner, {:runtime_endpoint_event, ref, request.request_id, accepted})

          maybe_emit_committed_text(mode, owner, ref, request.request_id)

          receive do
            :finish_after_cancel ->
              send(owner, {:runtime_endpoint_done, ref, :ok})
          after
            1_000 ->
              :ok
          end
      end
    end)

    if execute in [:accepted_until_cancel, :text_until_cancel] do
      receive do
        {:stream_registered, ^ref} -> :ok
      after
        100 -> :ok
      end
    end

    {:ok, ref}
  end

  defp maybe_emit_committed_text(:text_until_cancel, owner, ref, request_id) do
    send(
      owner,
      {:runtime_endpoint_event, ref, request_id, InferenceEvent.output_text_delta("committed")}
    )
  end

  defp maybe_emit_committed_text(_mode, _owner, _ref, _request_id), do: :ok

  def cancel_inference(_channel, %Operation.CancelRequest{} = request, opts) do
    send(config().capture_pid, {:cancel_inference_called, request, opts})

    @registry
    |> Registry.lookup({:stream, request.request_id})
    |> Enum.each(fn {pid, _value} -> send(pid, :finish_after_cancel) end)

    :ok
  end

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
    ExecuteInferenceRequest
  }

  alias Orchard.Dispatch.{AttemptOutcome, RequestDispatcher}
  alias Orchard.DispatchCapacity.{ConformanceFixture, Policy}
  alias Orchard.Inference
  alias Orchard.Inference.QueueManager
  alias Orchard.Nodes.{AdmissionDecision, Node}
  alias Orchard.RuntimeEndpoint.{Operation, Target}
  alias Orchard.TestSupport.DispatchCapacityFixtures

  @valid_uuid "550e8400-e29b-41d4-a716-446655440000"
  @other_uuid "660f9511-f30c-52e5-b827-557766551111"
  @stub_client Orchard.Dispatch.ProbeCompatibilityTest.StubClient

  setup :setup_sentry_context

  setup do
    start_supervised!({Registry, keys: :duplicate, name: @stub_client.registry_name()})
    runtime_client_target = Inference.runtime_client_target()
    configure_static_compatibility_targets(runtime_client_target)

    %{
      schedule:
        DispatchCapacityFixtures.authorize_unmanaged_schedule(%{
          strategy: :single_node,
          request_id: "req-probe-test",
          runtime_client_target: runtime_client_target,
          request_timeout_ms: 5_000,
          model_load_timeout_ms: 5_000
        }),
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

  defp configure_static_compatibility_targets(runtime_client_target) do
    previous = Application.fetch_env!(:orchard_controller, :inference)

    targets = [
      Target.grpc_compat(runtime_client_target),
      Target.beam(@valid_uuid, address: :"orchard_node_agent@127.0.0.1"),
      Target.beam(@valid_uuid,
        id: "beam:#{@valid_uuid}:localhost",
        address: :orchard_node_agent@localhost
      )
    ]

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(previous, :runtime_endpoint_targets, targets)
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :inference, previous) end)
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
         %Operation.EnsureModelLoadedResult{
           already_loaded: false,
           placement_state: :loaded
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

    node =
      %Node{}
      |> Node.changeset(attrs)
      |> Repo.insert!()

    decision =
      %AdmissionDecision{}
      |> AdmissionDecision.changeset(%{
        node_id: node.id,
        decision: :admitted,
        actor_type: "system",
        actor_id: "probe-compatibility-test",
        observed_identity: %{},
        metadata: %{},
        decided_at: now
      })
      |> Repo.insert!()

    %Policy{}
    |> Policy.approved_explicit_changeset(%{
      node_id: node.id,
      admission_decision_id: decision.id,
      controller_dispatch_ceiling: 4,
      approved_by_actor_type: "system",
      approved_by_actor_id: "probe-compatibility-test",
      approved_at: now,
      approval_reason: "probe compatibility capacity fixture"
    })
    |> Repo.insert!()

    node
  end

  defp queue_admission_request(public_id, model_id) do
    %{
      request_id: Ecto.UUID.generate(),
      public_id: public_id,
      tenant_id: Ecto.UUID.generate(),
      model_id: model_id,
      version: "v1",
      caller_pid: self()
    }
  end

  defp queue_config(overrides) do
    Keyword.merge(
      [
        enabled: true,
        capacity: 1,
        max_queued_per_tenant: 32,
        max_wait_ms: 1_000
      ],
      overrides
    )
  end

  defp start_holding_awaiter(ticket, tag) do
    parent = self()

    spawn(fn ->
      result = QueueManager.await(ticket)
      send(parent, {tag, result})

      receive do
        :stop -> :ok
      after
        5_000 -> :ok
      end
    end)
  end

  describe "missing metadata from old node-agent" do
    test "SPEC.md §9.1 warm already-loaded checks do not emit model load duration", ctx do
      ref = attach_model_load_metric()

      configure_stub(%{
        status: {:ok, old_agent_status()},
        ensure_model_loaded:
          {:ok,
           %Operation.EnsureModelLoadedResult{
             already_loaded: true,
             placement_state: :loaded
           }}
      })

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      refute_receive {^ref, _measurements, _metadata}
    end

    test "dispatch succeeds and keeps original node_id", ctx do
      configure_stub(%{status: {:ok, old_agent_status()}})

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == "original-node-id"
    end

    test "on_node_resolved callback is not invoked", ctx do
      configure_stub(%{status: {:ok, old_agent_status()}})
      callback = fn node_id -> send(self(), {:node_resolved, node_id}) end

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
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

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
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

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
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

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
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

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client,
                 on_node_resolved: callback
               )

      assert_received {:node_resolved, @other_uuid}
    end

    test "on_node_resolved callback exit does not abort dispatch or observation", ctx do
      configure_stub(%{status: {:ok, full_status(@other_uuid)}})

      insert_target_node!(ctx.schedule.runtime_client_target,
        id: @other_uuid,
        display_name: "test-node",
        hostname: "test.local",
        rpc_port: 50_071
      )

      callback = fn _node_id ->
        exit({:noproc, {GenServer, :call, [:queue_manager, :mark, 5_000]}})
      end

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client,
                 on_node_resolved: callback
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == @other_uuid
      assert Repo.get_by!(Node, display_name: "test-node").id == @other_uuid
    end

    test "callback release cannot promote stale source before fresh observation", ctx do
      QueueManager.reset()

      target = ctx.schedule.runtime_client_target
      model_id = "probe-stale-source-model"

      assert {:queued, first_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-probe-stale-source-a", model_id),
                 config: queue_config(capacity: 0)
               )

      assert {:queued, second_ticket} =
               QueueManager.acquire(
                 queue_admission_request("req-probe-stale-source-b", model_id),
                 config: queue_config(capacity: 0)
               )

      first_awaiter = start_holding_awaiter(first_ticket, :first_probe_stale_source_result)
      second_awaiter = Task.async(fn -> QueueManager.await(second_ticket) end)

      healthy_status =
        @valid_uuid
        |> full_status()
        |> Map.put(:max_concurrency, 1)
        |> Map.put(:runtime_model_placements, [])

      insert_target_node!(target,
        id: @valid_uuid,
        display_name: "test-node",
        hostname: "test.local",
        rpc_port: 50_071
      )

      assert {:ok, _node} =
               Orchard.Nodes.observe_status(target, healthy_status, DateTime.utc_now(),
                 dispatch_capacity_input: ConformanceFixture.input()
               )

      assert_receive {:first_probe_stale_source_result, {:ok, first_grant}}, 2_000
      refute Task.yield(second_awaiter, 50)

      unhealthy_status =
        healthy_status
        |> Map.put(:active_request_count, 1)
        |> Map.put(:runtime_health, %{
          ready: false,
          health_code: "busy",
          health_message: "node busy",
          affected_model: nil
        })

      configure_stub(%{status: {:ok, unhealthy_status}})

      callback = fn @valid_uuid ->
        node = Repo.get!(Node, @valid_uuid)
        send(self(), {:callback_node_health, node.health})
        assert :ok = QueueManager.release(first_grant)
      end

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client,
                 on_node_resolved: callback
               )

      assert_received {:callback_node_health, :unhealthy}
      refute Task.yield(second_awaiter, 100)

      assert {:ok, _node} =
               Orchard.Nodes.observe_status(
                 target,
                 healthy_status,
                 DateTime.add(DateTime.utc_now(), 1, :second),
                 dispatch_capacity_input: ConformanceFixture.input()
               )

      assert {:ok, second_grant} = Task.await(second_awaiter, 2_000)
      assert second_grant.queue_result == :queued
      assert :ok = QueueManager.release(second_grant)
      send(first_awaiter, :stop)
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

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:ensure_model_loaded_called, req}
      assert req.node_id == @valid_uuid
    end
  end

  describe "BEAM Runtime Endpoint dispatch" do
    test "uses the explicit BEAM target and never falls back to the legacy gRPC target", ctx do
      beam_target = Target.beam(@valid_uuid, address: :"orchard_node_agent@127.0.0.1")
      legacy_target = [host: "127.0.0.1", port: 59_999]

      schedule =
        ctx.schedule
        |> Map.put(:runtime_endpoint_target, beam_target)
        |> Map.put(:runtime_client_target, legacy_target)

      configure_stub(%{connect: {:error, {:rpc_exit, :nodedown}}})

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "runtime_unavailable",
                 "raw_source_code" => "node_unavailable"
               }
             } =
               RequestDispatcher.dispatch(schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:connect_called, ^beam_target}
      refute_received {:connect_called, ^legacy_target}
      refute_received {:ensure_model_loaded_called, _request}
    end

    test "returns BEAM RPC failures without retrying the legacy gRPC target", ctx do
      beam_target = Target.beam(@valid_uuid, address: :"orchard_node_agent@127.0.0.1")
      legacy_target = [host: "127.0.0.1", port: 59_999]

      schedule =
        ctx.schedule
        |> Map.put(:runtime_endpoint_target, beam_target)
        |> Map.put(:runtime_client_target, legacy_target)

      configure_stub(%{
        status: {:ok, full_status(@valid_uuid)},
        ensure_model_loaded: {:error, :node_unavailable}
      })

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "runtime_unavailable",
                 "raw_source_code" => "node_unavailable"
               }
             } =
               RequestDispatcher.dispatch(schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:connect_called, ^beam_target}
      refute_received {:connect_called, ^legacy_target}
      assert_received {:ensure_model_loaded_called, _request}
    end

    test "returns BEAM stream failures without retrying the legacy gRPC target", ctx do
      beam_target = Target.beam(@valid_uuid, address: :"orchard_node_agent@127.0.0.1")
      legacy_target = [host: "127.0.0.1", port: 59_999]

      schedule =
        ctx.schedule
        |> Map.put(:runtime_endpoint_target, beam_target)
        |> Map.put(:runtime_client_target, legacy_target)

      configure_stub(%{
        status: {:ok, full_status(@valid_uuid)},
        execute: {:error, :node_timeout}
      })

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "node_timeout"
               }
             } =
               RequestDispatcher.dispatch(schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_received {:connect_called, ^beam_target}
      refute_received {:connect_called, ^legacy_target}
      assert_received {:ensure_model_loaded_called, _request}
    end

    test "dispatch fails closed before observe or ensure when live metadata disagrees", ctx do
      target = Target.beam(@valid_uuid, address: :orchard_node_agent@localhost)

      schedule =
        ctx.schedule
        |> Map.put(:runtime_endpoint_target, target)
        |> Map.delete(:runtime_client_target)

      configure_stub(%{status: {:ok, full_status(@other_uuid)}})

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "internal_error",
                 "raw_source_code" => "beam_node_identity_mismatch"
               }
             } =
               RequestDispatcher.dispatch(schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      refute_received {:ensure_model_loaded_called, _request}
      assert Repo.get(Node, @other_uuid) == nil
    end
  end

  describe "probe transport failure" do
    test "dispatch succeeds, keeps original node_id, and marks fresh node degraded", ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{status: {:error, :node_timeout}})

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
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

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
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

  describe "authenticated observation rejection" do
    test "aborts dispatch without recording a transport failure", ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{status: {:error, :authenticated_observation_rejected}})

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "internal_error",
                 "raw_source_code" => "authenticated_observation_rejected"
               }
             } =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      refute_received {:ensure_model_loaded_called, _request}

      unchanged =
        Repo.get_by!(Node,
          advertise_addr: Keyword.fetch!(ctx.schedule.runtime_client_target, :host),
          rpc_port: Keyword.fetch!(ctx.schedule.runtime_client_target, :port)
        )

      assert unchanged.health == :healthy
    end
  end

  describe "Sentry cancellation enrichment" do
    test "cancellation calls runtime endpoint cancel with opts", ctx do
      configure_stub(%{execute: :accepted_until_cancel})
      schedule = %{ctx.schedule | request_timeout_ms: 100}

      assert %AttemptOutcome{
               attempt_outcome: :timed_out,
               accepted: true,
               events: events,
               failure: %{
                 "failure_class" => "deadline",
                 "failure_code" => "request_timeout"
               }
             } =
               RequestDispatcher.dispatch(schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      assert_receive {:cancel_inference_called,
                      %Operation.CancelRequest{
                        request_id: "req-probe-test",
                        controller_session_id: "probe-test-session"
                      }, []}

      assert Enum.any?(events, &Orchard.InferenceEvent.terminal?/1)
    end

    test "handler cancellation records cancel and synthesized terminal breadcrumbs", ctx do
      enable_controller_sentry()
      configure_stub(%{execute: :text_until_cancel})

      handler = fn _request_id, event ->
        if Orchard.InferenceEvent.kind(event) == :output_text_delta, do: :cancel, else: :ok
      end

      assert %AttemptOutcome{
               attempt_outcome: :cancelled,
               accepted: true,
               events: events,
               failure: %{
                 "failure_class" => "cancellation",
                 "failure_code" => "request_caller_disconnect"
               }
             } =
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

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "runtime_unavailable",
                 "raw_source_code" => "node_unavailable"
               }
             } =
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

    test "runtime endpoint connect error marks target degraded and returns sanitized failure",
         ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{connect: {:error, :node_unavailable}})

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "runtime_unavailable",
                 "raw_source_code" => "node_unavailable"
               }
             } =
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

    test "connect failure marks bind-all advertised node by actual connect target", ctx do
      target = ctx.schedule.runtime_client_target

      node =
        insert_target_node!(target,
          advertise_addr: "0.0.0.0",
          connect_host: Keyword.fetch!(target, :host),
          connect_port: Keyword.fetch!(target, :port)
        )

      configure_stub(%{connect: {:error, {:connect_failed, :econnrefused}}})

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "runtime_unavailable",
                 "raw_source_code" => "node_unavailable"
               }
             } =
               RequestDispatcher.dispatch(ctx.schedule, ctx.execute, ctx.model_load,
                 client_impl: @stub_client
               )

      marked = Repo.get!(Node, node.id)
      assert marked.advertise_addr == "0.0.0.0"
      assert marked.health == :degraded
    end

    test "ensure_model_loaded transport failure marks target degraded", ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{ensure_model_loaded: {:error, :node_unavailable}})

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "runtime_unavailable",
                 "raw_source_code" => "node_unavailable"
               }
             } =
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

    test "stream execution transport failure marks target degraded", ctx do
      insert_target_node!(ctx.schedule.runtime_client_target)
      configure_stub(%{execute: {:error, :node_timeout}})

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "node_timeout"
               }
             } =
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

  defp attach_model_load_metric do
    if Process.whereis(Orchard.Metrics.Supervisor) == nil do
      start_supervised!(Orchard.Metrics.Supervisor)
    end

    owner = self()
    ref = make_ref()
    handler_id = {__MODULE__, ref}

    :ok =
      :telemetry.attach(
        handler_id,
        [:orchard, :metrics, :model_load_duration],
        fn _event, measurements, metadata, _config ->
          send(owner, {ref, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  describe "repo-off during probe observation" do
    test "dispatch succeeds with discovered UUID even when persistence fails", ctx do
      configure_stub(%{status: {:ok, full_status(@valid_uuid)}})

      repo_pid = Process.whereis(Orchard.Repo)
      assert is_pid(repo_pid)
      Process.unregister(Orchard.Repo)

      try do
        assert %AttemptOutcome{attempt_outcome: :completed, accepted: true} =
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
