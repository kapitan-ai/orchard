defmodule Orchard.Dispatch.DispatchTest.DisconnectRaisingClient do
  @moduledoc false

  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  def connect(_target), do: {:ok, :disconnect_raising_channel}

  def status(_channel, _opts \\ []), do: {:ok, %StatusResponse{}}

  def disconnect(_channel) do
    raise FunctionClauseError, module: __MODULE__, function: :disconnect, arity: 1
  end

  def ensure_model_loaded(
        _channel,
        %Operation.EnsureModelLoadedRequest{},
        _opts \\ []
      ) do
    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    send(owner, {:runtime_endpoint_event, ref, request.request_id, InferenceEvent.accepted(0)})

    send(
      owner,
      {:runtime_endpoint_event, ref, request.request_id,
       InferenceEvent.completed(:finish_reason_stop, nil)}
    )

    send(owner, {:runtime_endpoint_done, ref, :ok})

    {:ok, ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok
end

defmodule Orchard.Dispatch.DispatchTest.TerminalContractClient do
  @moduledoc false

  alias Orchard.Dispatch.DispatchTest.DisconnectRaisingClient
  alias Orchard.InferenceEvent
  alias Orchard.InferenceEvent.Usage
  alias Orchard.RuntimeEndpoint.Operation

  def connect(_target), do: {:ok, :terminal_contract_channel}

  defdelegate status(channel, opts), to: DisconnectRaisingClient
  defdelegate ensure_model_loaded(channel, request, opts), to: DisconnectRaisingClient

  def disconnect(_channel), do: {:ok, :disconnected}

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    request.request_id
    |> events_for()
    |> Enum.each(fn event ->
      send(owner, {:runtime_endpoint_event, ref, request.request_id, event})
    end)

    send(owner, {:runtime_endpoint_done, ref, done_result(request.request_id)})

    {:ok, ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok

  defp events_for("req-dispatch-duplicate-terminal") do
    [
      InferenceEvent.accepted(0),
      InferenceEvent.completed(:finish_reason_stop, nil),
      InferenceEvent.failed("late_terminal", "late terminal", false)
    ]
  end

  defp events_for(request_id)
       when request_id in [
              "req-dispatch-tool",
              "req-dispatch-handler-commit-failure",
              "req-dispatch-handler-post-commit-failure"
            ] do
    [
      InferenceEvent.accepted(0),
      InferenceEvent.tool_call_delta("call-stable", ""),
      InferenceEvent.output_text_delta("later text"),
      InferenceEvent.completed(:finish_reason_tool_calls, nil)
    ]
  end

  defp events_for(request_id)
       when request_id in ["req-dispatch-uncommitted", "req-dispatch-final-flush-failure"] do
    [
      InferenceEvent.accepted(0),
      InferenceEvent.progress("prefill", "working"),
      InferenceEvent.usage_update(%Usage{input_tokens: 1, output_tokens: 0, total_tokens: 1}),
      InferenceEvent.output_text_delta(""),
      InferenceEvent.completed(:finish_reason_stop, nil)
    ]
  end

  defp events_for("req-dispatch-runtime-retryable") do
    [
      InferenceEvent.accepted(0),
      InferenceEvent.failed("runtime_unavailable", "runtime unavailable", true)
    ]
  end

  defp events_for("req-dispatch-post-terminal-error") do
    [
      InferenceEvent.accepted(0),
      InferenceEvent.completed(:finish_reason_stop, nil),
      InferenceEvent.output_text_delta("late")
    ]
  end

  defp events_for("req-dispatch-post-terminal-" <> event_kind) do
    [
      InferenceEvent.accepted(0),
      InferenceEvent.completed(:finish_reason_stop, nil),
      post_terminal_event(event_kind)
    ]
  end

  defp events_for(_request_id), do: [InferenceEvent.accepted(0)]

  defp done_result("req-dispatch-post-terminal-error"), do: {:error, :stream_failed}
  defp done_result(_request_id), do: :ok

  defp post_terminal_event("accepted"), do: InferenceEvent.accepted(1)
  defp post_terminal_event("output-text-delta"), do: InferenceEvent.output_text_delta("late")
  defp post_terminal_event("tool-call-delta"), do: InferenceEvent.tool_call_delta("call-1", "{}")

  defp post_terminal_event("usage") do
    InferenceEvent.usage_update(%Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2})
  end

  defp post_terminal_event("progress"), do: InferenceEvent.progress("late", "late progress")
end

defmodule Orchard.Dispatch.DispatchTest.NoConnectClient do
  @moduledoc false

  def connect(_target), do: raise("activation target must not receive dispatch operations")
end

defmodule Orchard.Dispatch.DispatchTest.NeverAcceptClient do
  @moduledoc false

  alias Orchard.RuntimeEndpoint.GrpcCompatibilityClient, as: Client
  alias Orchard.RuntimeEndpoint.Operation

  defdelegate connect(target), to: Client
  defdelegate status(channel, opts), to: Client
  defdelegate ensure_model_loaded(channel, request, opts), to: Client
  defdelegate disconnect(channel), to: Client

  def execute_inference(_channel, %Operation.ExecuteRequest{}, _opts),
    do: {:ok, make_ref()}

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts), do: :ok
end

defmodule Orchard.Dispatch.DispatchTest.HoldAfterAcceptClient do
  @moduledoc false

  alias Orchard.Dispatch.DispatchTest.DisconnectRaisingClient
  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  defdelegate connect(target), to: DisconnectRaisingClient
  defdelegate status(channel, opts), to: DisconnectRaisingClient
  defdelegate ensure_model_loaded(channel, request, opts), to: DisconnectRaisingClient

  def disconnect(_channel), do: {:ok, :disconnected}

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()
    send(owner, {:runtime_endpoint_event, ref, request.request_id, InferenceEvent.accepted(0)})
    {:ok, ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok
end

defmodule Orchard.Dispatch.DispatchTest.DeadlineCapturingClient do
  @moduledoc false

  alias Orchard.Cluster.V1.StatusResponse
  alias Orchard.RuntimeEndpoint.Operation

  def connect(_target), do: {:ok, :deadline_channel}

  def status(_channel, _opts), do: {:ok, %StatusResponse{}}

  def disconnect(_channel), do: :ok

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{} = request, opts) do
    Process.put({__MODULE__, :captured}, %{
      deadline_unix_ms: request.deadline_unix_ms,
      timeout: Keyword.get(opts, :timeout)
    })

    {:error, :node_timeout}
  end

  def execute_inference(_channel, _request, _opts), do: raise("should not be called")

  def cancel_inference(_channel, _request, _opts), do: :ok
end

defmodule Orchard.Dispatch.DispatchTest do
  @moduledoc """
  Tests for R6: single-node dispatch and cancellation.

  These tests run against the live node-agent gRPC server (on port 50071
  in test config, backed by FakeRuntimeAdapter) to prove end-to-end
  dispatch through the controller → node-agent boundary.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Orchard.TestSupport.SentryContextHelpers

  alias Orchard.ArtifactBundle

  alias Orchard.Cluster.V1.{
    EnsureModelLoadedRequest,
    ExecuteInferenceRequest,
    ModelRef,
    ScorePrefixCacheRequest,
    StatusResponse
  }

  alias Orchard.Dispatch.{AttemptOutcome, RequestDispatcher}
  alias Orchard.Dispatch.DispatchTest.DeadlineCapturingClient
  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: Client
  alias Orchard.DispatchCapacity.{AllocationAuthority, ConformanceFixture, Evaluator}
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.Inference

  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.ModelManager
  alias Orchard.RuntimeEndpoint.Target

  @model_id "mlx-community/phi-3"
  @version "main"

  setup :setup_sentry_context

  setup do
    # Reset node-agent state between tests to avoid model-already-loaded
    ModelManager.reset()
    bundle = stage_test_bundle!()
    authority = start_supervised!({AllocationAuthority, name: nil})
    Process.put({__MODULE__, :capacity_authority}, authority)

    on_exit(fn ->
      File.rm_rf(bundle.cache_path)
      File.rm_rf(bundle.source_path)
      File.rm_rf(Path.join(Node.models_root(), ".staging"))
      Process.delete({__MODULE__, :capacity_authority})
    end)

    %{bundle: bundle}
  end

  describe "GrpcNodeRuntimeClient" do
    test "connects to the node-agent and retrieves status" do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      assert {:ok, %StatusResponse{} = response} = Client.status(channel)
      assert response.worker_state == :WORKER_STATE_IDLE
      assert response.loaded_models == []

      Client.disconnect(channel)
    end

    test "ensure_model_loaded loads a model via gRPC", %{bundle: bundle} do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      request = model_load_request(bundle)
      assert {:ok, response} = Client.ensure_model_loaded(channel, request)
      refute response.already_loaded
      assert response.placement_state == :PLACEMENT_STATE_LOADED

      # Idempotent
      assert {:ok, response2} = Client.ensure_model_loaded(channel, request)
      assert response2.already_loaded

      Client.disconnect(channel)
    end

    test "execute_inference streams events to the caller", %{bundle: bundle} do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      # Load model first
      {:ok, _} = Client.ensure_model_loaded(channel, model_load_request(bundle))

      # Execute inference
      request = execute_request("req-dispatch-stream")
      {:ok, task_ref} = Client.execute_inference(channel, request)

      events = collect_dispatch_events(task_ref, "req-dispatch-stream")

      # FakeRuntimeAdapter emits: accepted, "orchard ", "ready", completed
      assert length(events) >= 3
      assert InferenceEvent.kind(hd(events)) == :accepted
      assert List.last(events) |> InferenceEvent.terminal?()

      Client.disconnect(channel)
    end

    test "cancel_inference sends cancellation to node-agent", %{bundle: bundle} do
      target = Inference.runtime_client_target()
      {:ok, channel} = Client.connect(target)

      {:ok, _} = Client.ensure_model_loaded(channel, model_load_request(bundle))

      assert :ok = Client.cancel_inference(channel, "req-nonexistent")

      Client.disconnect(channel)
    end

    test "score_prefix_cache canonicalizes worker status_message for model_not_loaded" do
      target = Inference.runtime_client_target()

      assert {:ok, response} =
               Client.score_prefix_cache(
                 target,
                 score_prefix_cache_request("missing-model", "req-score-model-not-loaded")
               )

      assert response.status_code == "model_not_loaded"
      assert response.status_message == "model not loaded"
      refute response.status_message == "model is not loaded"
      assert response.score_tier == "unknown"
    end

    test "score_prefix_cache canonicalizes transport failures to default error message" do
      target = [host: "127.0.0.1", port: 1]

      assert {:ok, response} =
               Client.score_prefix_cache(
                 target,
                 score_prefix_cache_request("missing-model", "req-score-transport-error")
               )

      assert response.status_code == "error"
      assert response.status_message == "prefix cache scoring error"
      assert response.score_tier == "unknown"
      assert response.resident_fingerprint_match == false
      assert response.session_started_unix_ms == 0
    end
  end

  describe "RequestDispatcher" do
    test "rejects an admitted activation-probe target before transport connection", %{
      bundle: bundle
    } do
      target =
        Target.grpc_compat(
          host: "127.0.0.1",
          port: 50_071,
          node_id: Ecto.UUID.generate(),
          metadata: %{authorization: :activation_probe, source: :trusted_node_inventory}
        )

      schedule =
        "req-admitted-dispatch-rejected"
        |> build_schedule()
        |> Map.put(:runtime_endpoint_target, target)
        |> Map.put(:node_id, target.node_id)
        |> put_capacity_input(ConformanceFixture.input())

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "internal_error",
                 "raw_source_code" => "node_not_active"
               }
             } =
               RequestDispatcher.dispatch(
                 schedule,
                 execute_request("req-admitted-dispatch-rejected"),
                 model_load_request(bundle),
                 client_impl: Orchard.Dispatch.DispatchTest.NoConnectClient
               )
    end

    test "dispatches a request and returns all events including terminal", %{bundle: bundle} do
      schedule = build_schedule("req-dispatch-e2e")
      execute = execute_request("req-dispatch-e2e")
      model_load = model_load_request(bundle)

      assert %AttemptOutcome{
               attempt_outcome: :completed,
               accepted: true,
               runtime_retryable: nil,
               events: events
             } = RequestDispatcher.dispatch(schedule, execute, model_load)

      assert length(events) >= 3
      assert InferenceEvent.kind(hd(events)) == :accepted
      assert List.last(events) |> InferenceEvent.terminal?()

      # Verify delta content from fake adapter
      deltas =
        events
        |> Enum.filter(&(InferenceEvent.kind(&1) == :output_text_delta))
        |> Enum.map(& &1.event.delta)

      assert deltas == ["orchard ", "ready"]
    end

    test "SPEC.md §5.8 copies runtime retryability into unsuccessful attempt evidence", %{
      bundle: bundle
    } do
      request_id = "req-dispatch-runtime-retryable"

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: true,
               runtime_retryable: true,
               failure: %{
                 "failure_class" => "runtime_failure",
                 "failure_code" => "runtime_unavailable"
               }
             } =
               RequestDispatcher.dispatch(
                 build_schedule(request_id),
                 execute_request(request_id),
                 model_load_request(bundle),
                 client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient
               )
    end

    test "SPEC 7.5.5: accepted stream without a terminal becomes one failed terminal", %{
      bundle: bundle
    } do
      request_id = "req-dispatch-missing-terminal"

      handler = fn received_request_id, event ->
        send(self(), {:handler_event, received_request_id, event})
        :ok
      end

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: true,
               events: [accepted, failed],
               failure: %{
                 "failure_class" => "terminal_conformance",
                 "failure_code" => "orchestration_error",
                 "raw_source_code" => "runtime_endpoint_missing_terminal"
               }
             } =
               outcome =
               RequestDispatcher.dispatch(
                 build_schedule(request_id),
                 execute_request(request_id),
                 model_load_request(bundle),
                 client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient,
                 event_handler: handler
               )

      assert InferenceEvent.kind(accepted) == :accepted
      assert %InferenceEvent{event: %InferenceEvent.Failed{code: code}} = failed
      assert code == "runtime_endpoint_missing_terminal"
      assert outcome.delivery_state == :pending
      refute_received {:handler_event, ^request_id, _event}
      selected = AttemptOutcome.select(outcome, request_id, handler)
      assert selected.delivery_state == :selected
      assert_received {:handler_event, ^request_id, ^accepted}
      assert_received {:handler_event, ^request_id, ^failed}
      refute_received {:handler_event, ^request_id, _event}
    end

    test "SPEC 7.5.5: duplicate terminal becomes one conformance failure", %{
      bundle: bundle
    } do
      request_id = "req-dispatch-duplicate-terminal"

      handler = fn received_request_id, event ->
        send(self(), {:handler_event, received_request_id, event})
        :ok
      end

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: true,
               events: [accepted, failed],
               failure: %{
                 "failure_class" => "terminal_conformance",
                 "failure_code" => "orchestration_error",
                 "raw_source_code" => "runtime_endpoint_duplicate_terminal"
               }
             } =
               outcome =
               RequestDispatcher.dispatch(
                 build_schedule(request_id),
                 execute_request(request_id),
                 model_load_request(bundle),
                 client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient,
                 event_handler: handler
               )

      assert InferenceEvent.kind(accepted) == :accepted
      assert %InferenceEvent{event: %InferenceEvent.Failed{code: code}} = failed
      assert code == "runtime_endpoint_duplicate_terminal"
      assert outcome.delivery_state == :pending
      refute_received {:handler_event, ^request_id, _event}
      selected = AttemptOutcome.select(outcome, request_id, handler)
      assert selected.delivery_state == :selected
      assert_received {:handler_event, ^request_id, ^accepted}
      assert_received {:handler_event, ^request_id, ^failed}
      refute_received {:handler_event, ^request_id, _event}
    end

    test "SPEC 7.5.5: every nonterminal event after terminal becomes one failure", %{
      bundle: bundle
    } do
      for event_kind <- ["accepted", "output-text-delta", "tool-call-delta", "usage", "progress"] do
        request_id = "req-dispatch-post-terminal-#{event_kind}"

        handler = fn received_request_id, event ->
          send(self(), {:handler_event, received_request_id, event})
          :ok
        end

        assert %AttemptOutcome{
                 attempt_outcome: :failed,
                 accepted: true,
                 events: [accepted, failed],
                 failure: %{
                   "failure_class" => "terminal_conformance",
                   "failure_code" => "orchestration_error",
                   "raw_source_code" => "runtime_endpoint_post_terminal_event"
                 }
               } =
                 outcome =
                 RequestDispatcher.dispatch(
                   build_schedule(request_id),
                   execute_request(request_id),
                   model_load_request(bundle),
                   client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient,
                   event_handler: handler
                 )

        assert InferenceEvent.kind(accepted) == :accepted
        assert %InferenceEvent{event: %InferenceEvent.Failed{code: code}} = failed
        assert code == "runtime_endpoint_post_terminal_event"
        assert outcome.delivery_state == :pending
        refute_received {:handler_event, ^request_id, _event}
        selected = AttemptOutcome.select(outcome, request_id, handler)
        assert selected.delivery_state == :selected
        assert_received {:handler_event, ^request_id, ^accepted}
        assert_received {:handler_event, ^request_id, ^failed}
        refute_received {:handler_event, ^request_id, _event}
      end
    end

    test "SPEC 7.5.5: observed post-terminal defect survives a later stream error", %{
      bundle: bundle
    } do
      request_id = "req-dispatch-post-terminal-error"

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: true,
               events: [accepted, failed],
               failure: %{
                 "failure_class" => "terminal_conformance",
                 "failure_code" => "orchestration_error",
                 "raw_source_code" => "runtime_endpoint_post_terminal_event"
               }
             } =
               RequestDispatcher.dispatch(
                 build_schedule(request_id),
                 execute_request(request_id),
                 model_load_request(bundle),
                 client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient
               )

      assert InferenceEvent.kind(accepted) == :accepted
      assert %InferenceEvent{event: %InferenceEvent.Failed{code: code}} = failed
      assert code == "runtime_endpoint_post_terminal_event"
    end

    test "terminal conformance metrics distinguish each protocol defect", %{bundle: bundle} do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)
      enable_controller_sentry()

      defects = [
        {"req-dispatch-missing-terminal", "missing_terminal"},
        {"req-dispatch-duplicate-terminal", "duplicate_terminal"},
        {"req-dispatch-post-terminal-output-text-delta", "post_terminal"}
      ]

      for {request_id, defect} <- defects do
        log =
          capture_log([level: :info], fn ->
            assert %AttemptOutcome{
                     attempt_outcome: :failed,
                     accepted: true,
                     events: [_accepted, %InferenceEvent{event: %InferenceEvent.Failed{}}],
                     failure: %{
                       "failure_class" => "terminal_conformance",
                       "failure_code" => "orchestration_error"
                     }
                   } =
                     RequestDispatcher.dispatch(
                       build_schedule(request_id),
                       execute_request(request_id),
                       model_load_request(bundle),
                       client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient
                     )
          end)

        assert log =~ "conformance_defect=#{defect}"
        assert log =~ "outcome=conformance_failed"

        context = sentry_context()
        assert context.tags.failure_category == "conformance_failed"
        assert context.extra.orchard_conformance_defect == String.to_existing_atom(defect)
      end
    end

    test "returns streamed events when disconnect cleanup raises", %{bundle: bundle} do
      schedule = build_schedule("req-dispatch-cleanup-raises")
      execute = execute_request("req-dispatch-cleanup-raises")
      model_load = model_load_request(bundle)

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true, events: events} =
               RequestDispatcher.dispatch(schedule, execute, model_load,
                 client_impl: Orchard.Dispatch.DispatchTest.DisconnectRaisingClient
               )

      assert Enum.map(events, &InferenceEvent.kind/1) == [:accepted, :completed]
      assert List.last(events) |> InferenceEvent.terminal?()
    end

    test "Sentry controller enrichment records sparse dispatch context", %{bundle: bundle} do
      enable_controller_sentry()
      schedule = build_schedule("req-dispatch-sentry")
      execute = execute_request("req-dispatch-sentry")
      model_load = model_load_request(bundle)

      assert %AttemptOutcome{attempt_outcome: :completed, accepted: true, events: events} =
               RequestDispatcher.dispatch(schedule, execute, model_load)

      assert Enum.any?(events, &InferenceEvent.terminal?/1)

      context = sentry_context()
      messages = breadcrumb_messages()

      assert context.tags.orchard_app == "controller"
      assert context.tags.orchard_surface == "api"
      assert context.tags.scheduler_strategy == "single_node"
      assert context.tags.failure_category == "ok"
      assert context.tags.terminal_source == "stream"

      assert context.extra.orchard_scheduler_strategy == :single_node
      assert context.extra.orchard_target_host_sanitized == "[redacted]"
      assert is_integer(context.extra.orchard_ensure_model_loaded_ms)
      assert is_integer(context.extra.orchard_accepted_to_first_delta_ms)
      assert is_integer(context.extra.orchard_accepted_to_terminal_ms)
      assert context.extra.orchard_event_count == length(events)

      assert "node.resolved" in messages
      assert "ensure_model_load.started" in messages
      assert "ensure_model_load.completed" in messages
      assert Enum.count(messages, &(&1 == "first_delta.received")) == 1
      refute inspect(context) =~ "127.0.0.1"
    end

    test "SPEC 5.8 coordinates uncommitted, tool, and handler-failed dispatch delivery", %{
      bundle: bundle
    } do
      owner = self()

      handler = fn request_id, event ->
        send(owner, {:handler_event, request_id, event})
        :ok
      end

      uncommitted =
        RequestDispatcher.dispatch(
          build_schedule("req-dispatch-uncommitted"),
          execute_request("req-dispatch-uncommitted"),
          model_load_request(bundle),
          client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient,
          event_handler: handler,
          on_accepted: fn request_id, _event ->
            send(owner, {:accepted, request_id})
            :ok
          end
        )

      assert_received {:accepted, "req-dispatch-uncommitted"}
      refute uncommitted.output_committed
      assert uncommitted.delivery_state == :pending
      assert uncommitted.first_token_at == nil
      refute_received {:handler_event, "req-dispatch-uncommitted", _event}

      selected = AttemptOutcome.select(uncommitted, "req-dispatch-uncommitted", handler)
      assert selected.delivery_state == :selected
      assert selected.delivered_event_count == length(selected.events)

      tool =
        RequestDispatcher.dispatch(
          build_schedule("req-dispatch-tool"),
          execute_request("req-dispatch-tool"),
          model_load_request(bundle),
          client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient,
          event_handler: handler
        )

      assert tool.output_committed
      assert tool.output_commitment_kind == :tool_call
      assert %DateTime{} = tool.first_token_at
      assert tool.delivery_state == :selected

      commit_failure_handler = fn _request_id, event ->
        if InferenceEvent.kind(event) == :accepted, do: raise("flush failed"), else: :ok
      end

      commit_failure =
        RequestDispatcher.dispatch(
          build_schedule("req-dispatch-handler-commit-failure"),
          execute_request("req-dispatch-handler-commit-failure"),
          model_load_request(bundle),
          client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient,
          event_handler: commit_failure_handler
        )

      assert commit_failure.attempt_outcome == :failed
      assert commit_failure.output_committed
      assert commit_failure.delivery_state == :failed
      assert commit_failure.delivered_event_count == 0
      assert commit_failure.failure["failure_class"] == "controller_failure"

      post_commit_handler = fn _request_id, event ->
        if InferenceEvent.kind(event) == :output_text_delta,
          do: {:error, :serializer_failed},
          else: :ok
      end

      post_commit_failure =
        RequestDispatcher.dispatch(
          build_schedule("req-dispatch-handler-post-commit-failure"),
          execute_request("req-dispatch-handler-post-commit-failure"),
          model_load_request(bundle),
          client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient,
          event_handler: post_commit_handler
        )

      assert post_commit_failure.attempt_outcome == :failed
      assert post_commit_failure.output_commitment_kind == :tool_call
      assert post_commit_failure.delivery_state == :failed
      assert post_commit_failure.delivered_event_count == 2

      pending_flush =
        RequestDispatcher.dispatch(
          build_schedule("req-dispatch-final-flush-failure"),
          execute_request("req-dispatch-final-flush-failure"),
          model_load_request(bundle),
          client_impl: Orchard.Dispatch.DispatchTest.TerminalContractClient
        )

      final_flush_handler = fn _request_id, event ->
        if InferenceEvent.terminal?(event), do: {:error, :serializer_failed}, else: :ok
      end

      final_flush_failure =
        AttemptOutcome.select(
          pending_flush,
          "req-dispatch-final-flush-failure",
          final_flush_handler
        )

      refute final_flush_failure.output_committed
      assert final_flush_failure.attempt_outcome == :failed
      assert final_flush_failure.delivery_state == :failed
      assert final_flush_failure.delivered_event_count == 4
    end

    test "dispatches with event_handler callback", %{bundle: bundle} do
      schedule = build_schedule("req-dispatch-handler")
      execute = execute_request("req-dispatch-handler")
      model_load = model_load_request(bundle)

      test_pid = self()

      handler = fn request_id, event ->
        send(test_pid, {:handler_event, request_id, event})
        :ok
      end

      assert %AttemptOutcome{
               attempt_outcome: :completed,
               accepted: true,
               events: events,
               output_committed: true,
               output_commitment_kind: :text,
               delivery_state: :selected,
               delivered_event_count: delivered_event_count
             } = RequestDispatcher.dispatch(schedule, execute, model_load, event_handler: handler)

      assert length(events) >= 3
      assert delivered_event_count == length(events)

      # Verify handler received all events
      Enum.each(events, fn event ->
        assert_received {:handler_event, "req-dispatch-handler", ^event}
      end)
    end

    test "timeout fails closed and keeps the timeout classification", %{
      bundle: bundle
    } do
      # Leave enough budget to begin execution, then time out before acceptance.
      schedule = build_schedule("req-dispatch-timeout", request_timeout_ms: 100)
      execute = execute_request("req-dispatch-timeout")
      model_load = model_load_request(bundle)

      assert %AttemptOutcome{
               attempt_outcome: :timed_out,
               accepted: false,
               events: [],
               failure: %{
                 "failure_class" => "deadline",
                 "failure_code" => "request_timeout"
               }
             } =
               RequestDispatcher.dispatch(schedule, execute, model_load,
                 client_impl: Orchard.Dispatch.DispatchTest.NeverAcceptClient
               )
    end

    test "SPEC.md §7.2.7 caller disconnect after acceptance produces cancellation evidence", %{
      bundle: bundle
    } do
      schedule = build_schedule("req-dispatch-disconnect")
      execute = execute_request("req-dispatch-disconnect")
      model_load = model_load_request(bundle)

      test_pid = self()

      caller =
        spawn(fn ->
          receive do
            :stay_alive -> :ok
          end
        end)

      dispatch_pid =
        spawn(fn ->
          on_accepted = fn _request_id, _event ->
            send(test_pid, :dispatch_accepted)
            :ok
          end

          result =
            RequestDispatcher.dispatch(schedule, execute, model_load,
              caller: caller,
              on_accepted: on_accepted,
              client_impl: Orchard.Dispatch.DispatchTest.HoldAfterAcceptClient
            )

          send(test_pid, {:dispatch_result, result})
        end)

      assert_receive :dispatch_accepted, 10_000
      Process.exit(caller, :kill)

      assert_receive {:dispatch_result,
                      %AttemptOutcome{
                        attempt_outcome: :cancelled,
                        runtime_retryable: false,
                        failure: %{
                          "failure_class" => "cancellation",
                          "failure_code" => "request_caller_disconnect"
                        },
                        events: events
                      }},
                     10_000

      assert events != []
      terminal = List.last(events)
      assert InferenceEvent.terminal?(terminal)

      terminal_count = Enum.count(events, &InferenceEvent.terminal?/1)
      assert terminal_count == 1, "expected exactly 1 terminal, got #{terminal_count}"

      if Process.alive?(dispatch_pid), do: Process.exit(dispatch_pid, :kill)
    end

    test "SPEC.md §7.2.7 dispatch-capacity caller-down is cancellation", %{bundle: bundle} do
      caller = spawn(fn -> Process.sleep(:infinity) end)
      Process.exit(caller, :kill)
      refute Process.alive?(caller)

      request_id = "req-dispatch-capacity-caller-down"

      assert %AttemptOutcome{
               attempt_outcome: :cancelled,
               failure: %{
                 "failure_class" => "cancellation",
                 "failure_code" => "request_caller_disconnect"
               }
             } =
               RequestDispatcher.dispatch(
                 build_schedule(request_id),
                 execute_request(request_id),
                 model_load_request(bundle),
                 caller: caller
               )
    end

    test "dispatch returns sanitized error when node connection fails" do
      # Use a target that will fail to connect — port 1 is privileged and won't have a gRPC server
      inference = Application.fetch_env!(:orchard_controller, :inference)

      Application.put_env(
        :orchard_controller,
        :inference,
        Keyword.merge(inference,
          runtime_client_target: [host: "127.0.0.1", port: 1],
          runtime_client_targets: []
        )
      )

      on_exit(fn -> Application.put_env(:orchard_controller, :inference, inference) end)

      schedule =
        "req-connect-fail"
        |> build_schedule()
        |> Map.put(:runtime_client_target, host: "127.0.0.1", port: 1)

      execute = execute_request("req-connect-fail")

      model_load =
        %EnsureModelLoadedRequest{
          node_id: "local",
          model_id: "test/model",
          version: "v1"
        }

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               output_committed: false,
               output_commitment_kind: nil,
               delivery_state: :pending,
               delivered_event_count: 0,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "runtime_unavailable",
                 "raw_source_code" => "node_unavailable"
               }
             } =
               RequestDispatcher.dispatch(schedule, execute, model_load)
    end

    test "dispatch returns error when ensure-load placement state is not LOADED" do
      schedule = build_schedule("req-dispatch-fail-load")

      execute =
        %ExecuteInferenceRequest{
          request_id: "req-dispatch-fail-load",
          controller_session_id: "controller-session-dispatch",
          model_id: "fail-load/test-model",
          version: "v1",
          rendered_prompt_utf8: "hello",
          input_tokens: 1
        }

      model_load =
        %EnsureModelLoadedRequest{
          node_id: "local",
          model_id: "fail-load/test-model",
          version: "v1"
        }

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               accepted: false,
               output_committed: false,
               output_commitment_kind: nil,
               delivery_state: :pending,
               delivered_event_count: 0,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "model_invalid",
                 "raw_source_code" => "missing_artifact_sha256"
               }
             } =
               RequestDispatcher.dispatch(schedule, execute, model_load)
    end

    test "issue #222 caps EnsureModelLoadedRequest deadline to the stage budget", %{
      bundle: bundle
    } do
      schedule =
        build_schedule("req-deadline-cap",
          request_timeout_ms: 5_000,
          model_load_timeout_ms: 500
        )

      execute = execute_request("req-dispatch-deadline-cap")

      model_load = %EnsureModelLoadedRequest{
        node_id: "local",
        model_id: @model_id,
        version: @version,
        artifact_sha256: bundle.hash,
        artifact_source_uri: bundle.source_uri,
        deadline_unix_ms: 0
      }

      assert %AttemptOutcome{
               attempt_outcome: :failed,
               failure: %{
                 "failure_class" => "model_load_failure",
                 "failure_code" => "load_timeout"
               }
             } =
               RequestDispatcher.dispatch(schedule, execute, model_load,
                 client_impl: DeadlineCapturingClient
               )

      captured = Process.get({DeadlineCapturingClient, :captured})
      assert captured.timeout == 500

      deadline_ms = captured.deadline_unix_ms
      now_ms = System.system_time(:millisecond)
      timeout_at_ms = DateTime.to_unix(schedule.timeout_at, :millisecond)

      # The load deadline must be bounded by the stage cap, not the request deadline.
      assert deadline_ms <= now_ms + 600
      assert deadline_ms <= timeout_at_ms
    end
  end

  # -- Helpers ---------------------------------------------------------------

  defp model_load_request(bundle) do
    %EnsureModelLoadedRequest{
      node_id: "local",
      model_id: @model_id,
      version: @version,
      artifact_sha256: bundle.hash,
      artifact_source_uri: bundle.source_uri,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000
    }
  end

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "controller-session-dispatch",
      model_id: @model_id,
      version: @version,
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 2
    }
  end

  defp build_schedule(request_id, opts \\ []) do
    timeout_ms = Keyword.get(opts, :request_timeout_ms, 5_000)

    %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: timeout_ms,
      timeout_at: DateTime.add(DateTime.utc_now(), timeout_ms, :millisecond),
      model_load_timeout_ms: Keyword.get(opts, :model_load_timeout_ms, 5_000),
      dispatch_capacity_authority: Process.get({__MODULE__, :capacity_authority})
    }
    |> put_capacity_input(unmanaged_capacity_input())
  end

  defp put_capacity_input(schedule, input) do
    Map.merge(schedule, %{
      dispatch_capacity_input: input,
      dispatch_capacity_evaluation: Evaluator.evaluate(input),
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> input end
    })
  end

  defp unmanaged_capacity_input do
    %Input{
      authority_phase: :invalid,
      policy_presence: :missing,
      policy_state: :missing,
      management_classification: {:ok, :unmanaged_source_development},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: DateTime.utc_now(),
      runtime_concurrency_limit: {:valid, 1},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: :missing,
      controller_accounted_allocation: 0,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end

  defp score_prefix_cache_request(model_id, request_id) do
    %ScorePrefixCacheRequest{
      request_id: request_id,
      controller_session_id: "controller-session-dispatch",
      model_ref: %ModelRef{model_id: model_id, version: @version},
      cache_affinity_fingerprint: "hmac-sha256:" <> String.duplicate("0", 64),
      deadline_unix_ms: System.system_time(:millisecond) + 500
    }
  end

  defp collect_dispatch_events(task_ref, request_id, events \\ []) do
    receive do
      {:dispatch_event, ^task_ref, ^request_id, %InferenceEvent{} = event} ->
        events = [event | events]

        if InferenceEvent.terminal?(event) do
          Enum.reverse(events)
        else
          collect_dispatch_events(task_ref, request_id, events)
        end

      {:dispatch_done, ^task_ref, _result} ->
        Enum.reverse(events)
    after
      5_000 ->
        flunk("timed out waiting for dispatch events")
    end
  end

  defp stage_test_bundle! do
    models_root = Node.models_root()
    cache_path = Path.join([models_root, @model_id, @version])
    source_path = Path.join([models_root, ".test-source", "bundle"])

    File.rm_rf(cache_path)
    File.rm_rf(source_path)

    File.mkdir_p!(source_path)
    File.write!(Path.join(source_path, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source_path, "tokenizer.json"), ~s({"version":"1.0"}))
    weights_dir = Path.join(source_path, "weights")
    File.mkdir_p!(weights_dir)
    File.write!(Path.join(weights_dir, "model.safetensors"), "fake-weights-data")

    {:ok, hash} = ArtifactBundle.tree_sha256(source_path)

    File.mkdir_p!(cache_path)
    :ok = ArtifactBundle.copy_directory(source_path, cache_path)

    source_uri = "file://#{source_path}"

    %{cache_path: cache_path, source_path: source_path, source_uri: source_uri, hash: hash}
  end
end
