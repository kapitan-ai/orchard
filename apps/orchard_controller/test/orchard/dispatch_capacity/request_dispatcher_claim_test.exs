defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.Client do
  @moduledoc false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation
  alias Orchard.TestSupport.DispatchCapacityFixtures

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)
  def clear, do: :persistent_term.erase({__MODULE__, :test_pid})

  def connect(_target), do: {:ok, :capacity_test_channel}
  def disconnect(_channel), do: :ok
  def status(_channel, _opts \\ []), do: {:ok, DispatchCapacityFixtures.probe_status_response()}

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts \\ []) do
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    send(test_pid, {:model_load_started, self()})

    receive do
      :continue_model_load ->
        {:ok,
         %Operation.EnsureModelLoadedResult{
           already_loaded: false,
           placement_state: :loaded,
           worker_supports_prompt_token_ids: true
         }}
    end
  end

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()

    emitter =
      spawn(fn ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id, InferenceEvent.accepted(0)}
        )

        send(test_pid, {:node_accepted, self()})

        receive do
          :finish ->
            send(
              owner,
              {:runtime_endpoint_event, task_ref, request.request_id,
               InferenceEvent.completed(:finish_reason_stop, nil)}
            )

            send(owner, {:runtime_endpoint_done, task_ref, :ok})
        end
      end)

    send(test_pid, {:stream_emitter, emitter})
    {:ok, task_ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient do
  @moduledoc false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation
  alias Orchard.TestSupport.DispatchCapacityFixtures

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)
  def clear, do: :persistent_term.erase({__MODULE__, :test_pid})

  def connect(_target), do: {:ok, :capacity_gate_channel}
  def disconnect(_channel), do: :ok
  def status(_channel, _opts \\ []), do: {:ok, DispatchCapacityFixtures.probe_status_response()}

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts \\ []) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :model_loaded)

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end

  def execute_inference(_channel, %Operation.ExecuteRequest{} = request, opts \\ []) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()
    send(test_pid, :execute_called)

    send(
      owner,
      {:runtime_endpoint_event, task_ref, request.request_id, InferenceEvent.accepted(0)}
    )

    send(
      owner,
      {:runtime_endpoint_event, task_ref, request.request_id,
       InferenceEvent.completed(:finish_reason_stop, nil)}
    )

    send(owner, {:runtime_endpoint_done, task_ref, :ok})
    {:ok, task_ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts \\ []), do: :ok
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.ExecuteErrorClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, _request, _opts), do: {:error, :execution_refused}
  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.DoneBeforeAcceptedClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, _request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()
    send(owner, {:runtime_endpoint_done, task_ref, :ok})
    {:ok, task_ref}
  end

  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.TerminalBeforeAcceptedClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient

  def configure(event), do: :persistent_term.put({__MODULE__, :event}, event)
  def clear, do: :persistent_term.erase({__MODULE__, :event})

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()
    event = :persistent_term.get({__MODULE__, :event})
    send(owner, {:runtime_endpoint_event, task_ref, request.request_id, event})
    send(owner, {:runtime_endpoint_done, task_ref, :ok})
    {:ok, task_ref}
  end

  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.NonterminalThenErrorClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()

    send(
      owner,
      {:runtime_endpoint_event, task_ref, request.request_id,
       InferenceEvent.output_text_delta("before acceptance")}
    )

    send(owner, {:runtime_endpoint_done, task_ref, {:error, :stream_failed}})
    {:ok, task_ref}
  end

  defdelegate cancel_inference(channel, request, opts), to: GateClient
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.CancellableStreamClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)

  def clear do
    :persistent_term.erase({__MODULE__, :test_pid})
    :persistent_term.erase({__MODULE__, :emitter})
  end

  defdelegate connect(target), to: GateClient
  defdelegate disconnect(channel), to: GateClient
  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()

    emitter =
      spawn(fn ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id, InferenceEvent.accepted(0)}
        )

        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id,
           InferenceEvent.output_text_delta("streaming")}
        )

        receive do
          :cancel ->
            send(test_pid, {:cancel_received, self()})

            receive do
              :finish_cancel ->
                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.failed("cancelled", "cancelled", false)}
                )

                send(owner, {:runtime_endpoint_done, task_ref, :ok})
            end
        end
      end)

    :persistent_term.put({__MODULE__, :emitter}, emitter)
    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts) do
    send(:persistent_term.get({__MODULE__, :emitter}), :cancel)
    :ok
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.PreAcceptanceCancelClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  def configure(test_pid, opts \\ []) do
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)
    :persistent_term.put({__MODULE__, :cancel_failure}, Keyword.get(opts, :cancel_failure))
  end

  def clear do
    :persistent_term.erase({__MODULE__, :test_pid})
    :persistent_term.erase({__MODULE__, :emitter})
    :persistent_term.erase({__MODULE__, :cancel_failure})
  end

  defdelegate connect(target), to: GateClient

  def disconnect(channel) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :pre_acceptance_disconnected)
    GateClient.disconnect(channel)
  end

  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()

    emitter =
      spawn(fn ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id,
           InferenceEvent.output_text_delta("before acceptance")}
        )

        send(test_pid, :pre_acceptance_stream_started)

        receive do
          :cancel ->
            send(test_pid, {:pre_acceptance_cancel_received, self()})

            receive do
              :finish_cancel ->
                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.failed("cancelled", "cancelled", false)}
                )

                send(owner, {:runtime_endpoint_done, task_ref, :ok})

              :finish_cancel_after_acceptance ->
                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.accepted(0)}
                )

                send(
                  owner,
                  {:runtime_endpoint_event, task_ref, request.request_id,
                   InferenceEvent.failed("cancelled", "cancelled", false)}
                )

                send(owner, {:runtime_endpoint_done, task_ref, :ok})
            end
        end
      end)

    :persistent_term.put({__MODULE__, :emitter}, emitter)
    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts) do
    send(:persistent_term.get({__MODULE__, :emitter}), :cancel)

    case :persistent_term.get({__MODULE__, :cancel_failure}) do
      nil -> :ok
      :raise -> raise "cancel failed"
      :exit -> exit(:cancel_failed)
    end
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.NoisyCancelClient do
  @moduledoc false

  alias Orchard.DispatchCapacity.RequestDispatcherClaimTest.GateClient
  alias Orchard.InferenceEvent

  def configure(test_pid), do: :persistent_term.put({__MODULE__, :test_pid}, test_pid)

  def clear do
    case :persistent_term.get({__MODULE__, :emitter}, nil) do
      emitter when is_pid(emitter) -> send(emitter, :disconnect)
      _missing -> :ok
    end

    :persistent_term.erase({__MODULE__, :test_pid})
    :persistent_term.erase({__MODULE__, :emitter})
  end

  defdelegate connect(target), to: GateClient

  def disconnect(channel) do
    case :persistent_term.get({__MODULE__, :emitter}, nil) do
      emitter when is_pid(emitter) -> send(emitter, :disconnect)
      _missing -> :ok
    end

    send(:persistent_term.get({__MODULE__, :test_pid}), :noisy_cancel_disconnected)
    GateClient.disconnect(channel)
  end

  defdelegate status(channel, opts), to: GateClient
  defdelegate ensure_model_loaded(channel, request, opts), to: GateClient

  def execute_inference(_channel, request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    test_pid = :persistent_term.get({__MODULE__, :test_pid})
    task_ref = make_ref()

    emitter =
      spawn(fn ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request.request_id,
           InferenceEvent.output_text_delta("before acceptance")}
        )

        receive do
          :cancel ->
            send(test_pid, :noisy_cancel_received)
            emit_until_disconnected(owner, task_ref, request.request_id)
        end
      end)

    :persistent_term.put({__MODULE__, :emitter}, emitter)
    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts) do
    send(:persistent_term.get({__MODULE__, :emitter}), :cancel)
    :ok
  end

  defp emit_until_disconnected(owner, task_ref, request_id) do
    receive do
      :disconnect ->
        :ok
    after
      1 ->
        send(
          owner,
          {:runtime_endpoint_event, task_ref, request_id,
           InferenceEvent.output_text_delta("still cancelling")}
        )

        emit_until_disconnected(owner, task_ref, request_id)
    end
  end
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest.ProductionFreshStatusClient do
  @moduledoc false

  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.Operation

  def configure(test_pid, initial_status, post_load_status) do
    :persistent_term.put({__MODULE__, :test_pid}, test_pid)
    :persistent_term.put({__MODULE__, :status}, initial_status)
    :persistent_term.put({__MODULE__, :post_load_status}, post_load_status)
  end

  def clear do
    for key <- [:test_pid, :status, :post_load_status] do
      :persistent_term.erase({__MODULE__, key})
    end
  end

  def connect(target), do: {:ok, target}
  def disconnect(_channel), do: :ok

  def status(target, _opts) do
    status = :persistent_term.get({__MODULE__, :status})
    metadata = Map.fetch!(status, :node_metadata)
    observed_at = DateTime.utc_now()

    {:ok, _evidence} =
      Orchard.DispatchCapacity.record_capacity_evidence(metadata.node_id, %{
        active_request_count: Map.fetch!(status, :active_request_count),
        observed_at: observed_at,
        runtime_concurrency_limit: Map.fetch!(status, :max_concurrency),
        validity: :valid
      })

    {:ok, _node} = Orchard.Nodes.observe_status(target, status, observed_at)

    {:ok, status}
  end

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{}, _opts) do
    :persistent_term.put(
      {__MODULE__, :status},
      :persistent_term.get({__MODULE__, :post_load_status})
    )

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: false,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true
     }}
  end

  def execute_inference(_channel, request, opts) do
    send(:persistent_term.get({__MODULE__, :test_pid}), :production_execute_called)
    owner = Keyword.fetch!(opts, :owner)
    task_ref = make_ref()

    send(owner, {
      :runtime_endpoint_event,
      task_ref,
      request.request_id,
      InferenceEvent.accepted(0)
    })

    send(owner, {
      :runtime_endpoint_event,
      task_ref,
      request.request_id,
      InferenceEvent.completed(:finish_reason_stop, nil)
    })

    send(owner, {:runtime_endpoint_done, task_ref, :ok})

    {:ok, task_ref}
  end

  def cancel_inference(_channel, _request, _opts), do: :ok
end

defmodule Orchard.DispatchCapacity.RequestDispatcherClaimTest do
  use Orchard.DataCase, async: false

  alias Orchard.CanonicalRequest
  alias Orchard.CanonicalRequest.ModelRef
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest}
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.DispatchCapacity.AllocationAuthority
  alias Orchard.DispatchCapacity.Evaluator
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.Inference
  alias Orchard.Inference.QueueManager
  alias Orchard.InferenceEvent
  alias Orchard.Nodes.{AdmissionDecision, Node}
  alias Orchard.Scheduler.{MultiNode, SingleNode}
  alias Orchard.TestSupport.DispatchCapacityFixtures

  alias __MODULE__.{
    CancellableStreamClient,
    Client,
    DoneBeforeAcceptedClient,
    ExecuteErrorClient,
    GateClient,
    NoisyCancelClient,
    NonterminalThenErrorClient,
    PreAcceptanceCancelClient,
    ProductionFreshStatusClient,
    TerminalBeforeAcceptedClient
  }

  @client Client
  @gate_client GateClient
  @execute_error_client ExecuteErrorClient
  @done_before_accepted_client DoneBeforeAcceptedClient
  @terminal_before_accepted_client TerminalBeforeAcceptedClient
  @nonterminal_then_error_client NonterminalThenErrorClient
  @cancellable_stream_client CancellableStreamClient
  @noisy_cancel_client NoisyCancelClient
  @pre_acceptance_cancel_client PreAcceptanceCancelClient
  @production_fresh_status_client ProductionFreshStatusClient

  # The request timeout now bounds connect, model load, and acceptance-gate
  # waiting as well as streaming, so it must outlast dispatch setup or the
  # request expires as `:dispatch_capacity_acceptance_gate_busy` before the
  # stream-phase cancellation path under test can run.
  @expiring_request_timeout_ms 250

  setup do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)
    @client.configure(self())
    @gate_client.configure(self())
    @cancellable_stream_client.configure(self())
    @noisy_cancel_client.configure(self())
    @pre_acceptance_cancel_client.configure(self())

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, previous_inference)
      @client.clear()
      @gate_client.clear()
      @terminal_before_accepted_client.clear()
      @cancellable_stream_client.clear()
      @noisy_cancel_client.clear()
      @pre_acceptance_cancel_client.clear()
      @production_fresh_status_client.clear()
      DispatchCapacityFixtures.clear_probe_node_id()
    end)

    :ok
  end

  test "SPEC 5.9 dispatch retains one claim through loading, acceptance, and completion" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    input = enforcing_input()
    request_id = "request-claim-lifetime"

    schedule = %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000,
      node_id: node_id,
      dispatch_capacity_input: input,
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> input end,
      dispatch_capacity_authority: authority
    }

    dispatch_task =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          schedule,
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @client
        )
      end)

    assert_receive {:model_load_started, dispatcher_pid}
    assert AllocationAuthority.claim_count(authority, node_id) == 1

    assert {:error, :dispatch_capacity_unavailable, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "competitor-during-load",
               input,
               authority: authority
             )

    send(dispatcher_pid, :continue_model_load)
    assert_receive {:stream_emitter, emitter}
    assert_receive {:node_accepted, ^emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1

    send(emitter, :finish)
    assert {:ok, _events} = Task.await(dispatch_task)
    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:ok, final_claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-completion",
               input,
               authority: authority
             )

    assert :ok = QueueManager.release_dispatch_capacity(final_claim, authority: authority)
  end

  test "SPEC 4.6.2 dispatch owner death releases its claim exactly once" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-owner-death"
    input = enforcing_input()

    schedule = %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000,
      node_id: node_id,
      dispatch_capacity_input: input,
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> input end,
      dispatch_capacity_authority: authority
    }

    {dispatcher_pid, monitor_ref} =
      spawn_monitor(fn ->
        RequestDispatcher.dispatch(
          schedule,
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @client
        )
      end)

    assert_receive {:model_load_started, ^dispatcher_pid}
    assert AllocationAuthority.claim_count(authority, node_id) == 1

    Process.exit(dispatcher_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^dispatcher_pid, :killed}
    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-owner-death",
               enforcing_input(),
               authority: authority
             )

    assert :ok = QueueManager.release_dispatch_capacity(claim, authority: authority)
    assert :ok = QueueManager.release_dispatch_capacity(claim, authority: authority)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 policy mutation linearizes before final dispatch revalidation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-final-revalidation"
    parent = self()
    input_state = start_supervised!({Agent, fn -> enforcing_input() end})

    mutation =
      Task.async(fn ->
        Orchard.DispatchCapacity.with_policy_mutation_gate(
          node_id,
          fn ->
            send(parent, {:mutation_gate_held, self()})

            receive do
              :commit_mutation ->
                Agent.update(input_state, fn input ->
                  %{input | controller_dispatch_ceiling: {:valid, 0}}
                end)
            end
          end,
          authority: authority
        )
      end)

    assert_receive {:mutation_gate_held, mutation_pid}

    schedule = %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000,
      node_id: node_id,
      dispatch_capacity_input: enforcing_input(),
      dispatch_capacity_acquisition_input_provider: fn -> Agent.get(input_state, & &1) end,
      dispatch_capacity_input_provider: fn -> Agent.get(input_state, & &1) end,
      dispatch_capacity_authority: authority
    }

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          schedule,
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @gate_client
        )
      end)

    assert_receive :model_loaded
    send(mutation_pid, :commit_mutation)
    assert :ok = Task.await(mutation)

    assert {:error, {:dispatch_failed, :dispatch_capacity_revalidation_failed}} =
             Task.await(dispatch)

    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 4.5 synchronous execute failure releases the claim for retry" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-execute-error"

    assert {:error, {:dispatch_failed, :execution_refused}} =
             RequestDispatcher.dispatch(
               capacity_schedule(authority, node_id, request_id),
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @execute_error_client
             )

    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-retry",
               enforcing_input(),
               authority: authority
             )

    assert :ok = QueueManager.release_dispatch_capacity(claim, authority: authority)
  end

  test "SPEC 4.6 runtime completion before Accepted is a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-missing-acceptance"

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} =
             RequestDispatcher.dispatch(
               capacity_schedule(authority, node_id, request_id),
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @done_before_accepted_client
             )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 managed dispatch rejects cached capacity without fresh providers" do
    node_id = claim_node_id()
    request_id = "request-cached-capacity-authorization"

    schedule =
      capacity_schedule(
        start_supervised!({AllocationAuthority, name: nil}),
        node_id,
        request_id
      )
      |> Map.drop([
        :dispatch_capacity_acquisition_input_provider,
        :dispatch_capacity_input_provider
      ])

    assert {:error, {:dispatch_failed, :dispatch_capacity_facts_unavailable}} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @gate_client
             )

    refute_receive :execute_called
  end

  test "SPEC 5.9 initial claim acquisition reloads current capacity facts" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-fresh-acquisition-capacity"

    unavailable_input = %{
      enforcing_input()
      | controller_dispatch_ceiling: {:valid, 0}
    }

    schedule =
      authority
      |> capacity_schedule(node_id, request_id)
      |> Map.put(:dispatch_capacity_acquisition_input_provider, fn -> unavailable_input end)

    assert {:error, {:dispatch_failed, :dispatch_capacity_unavailable}} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @gate_client
             )

    refute_receive :model_loaded
    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 unmanaged dispatch revalidates fresh post-load placement capacity" do
    request_id = "request-unmanaged-post-load-revalidation"
    input = unmanaged_input()
    unavailable_input = %{input | placement_capacity: :unknown}

    schedule = %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000,
      dispatch_capacity_input: input,
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> unavailable_input end,
      dispatch_capacity_evaluation: Evaluator.evaluate(input)
    }

    assert {:error, {:dispatch_failed, :dispatch_capacity_revalidation_failed}} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request(request_id),
               model_load_request(Ecto.UUID.generate()),
               client_impl: @gate_client
             )

    assert_receive :model_loaded
    refute_receive :execute_called
  end

  test "SPEC 5.9 Completed before Accepted is a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-completed-before-accepted"

    @terminal_before_accepted_client.configure(
      Orchard.InferenceEvent.completed(:finish_reason_stop, nil)
    )

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} =
             RequestDispatcher.dispatch(
               capacity_schedule(authority, node_id, request_id),
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @terminal_before_accepted_client
             )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 Failed before Accepted is a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-failed-before-accepted"

    @terminal_before_accepted_client.configure(
      Orchard.InferenceEvent.failed("runtime_failed", "runtime failed before acceptance", false)
    )

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} =
             RequestDispatcher.dispatch(
               capacity_schedule(authority, node_id, request_id),
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @terminal_before_accepted_client
             )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 stream error after a pre-Accepted delta fails with the transport reason" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-delta-before-acceptance-error"

    assert {:error, {:dispatch_failed, :stream_failed}} =
             RequestDispatcher.dispatch(
               capacity_schedule(authority, node_id, request_id),
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @nonterminal_then_error_client
             )

    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 4.5 Accepted handler exception retains the claim through cancellation terminal" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-accepted-handler-exception"

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client,
          event_handler: fn
            _request_id, %InferenceEvent{event: %InferenceEvent.Accepted{}} ->
              raise "accepted handler failed"

            _request_id, _event ->
              :ok
          end
        )
      end)

    assert_receive {:cancel_received, emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel)

    assert {:error, {:dispatch_failed, :event_handler_failed}} = Task.await(dispatch)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 4.5 delta handler exception retains the claim through cancellation terminal" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-delta-handler-exception"

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client,
          event_handler: fn
            _request_id, %InferenceEvent{event: %InferenceEvent.OutputTextDelta{}} ->
              raise "delta handler failed"

            _request_id, _event ->
              :ok
          end
        )
      end)

    assert_receive {:cancel_received, emitter}
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel)

    assert {:error, {:dispatch_failed, :event_handler_failed}} = Task.await(dispatch)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 timeout before Accepted remains a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-timeout-before-accepted"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms
    }

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          schedule,
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, emitter}, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel_after_acceptance)

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} = Task.await(dispatch)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 handler exception before Accepted remains failed after late Accepted" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-handler-failure-before-late-acceptance"

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          event_handler: fn _request_id, _event -> raise "handler failed before acceptance" end
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, emitter}, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel_after_acceptance)

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} = Task.await(dispatch)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  for cancel_failure <- [:raise, :exit] do
    test "SPEC 4.5 cancel #{cancel_failure} still drains before releasing the claim" do
      @pre_acceptance_cancel_client.configure(self(), cancel_failure: unquote(cancel_failure))
      authority = start_supervised!({AllocationAuthority, name: nil})
      node_id = claim_node_id()
      request_id = "request-cancel-#{unquote(cancel_failure)}"

      schedule = %{
        capacity_schedule(authority, node_id, request_id)
        | request_timeout_ms: @expiring_request_timeout_ms
      }

      dispatch =
        Task.async(fn ->
          RequestDispatcher.dispatch(
            schedule,
            execute_request(request_id),
            model_load_request(node_id),
            client_impl: @pre_acceptance_cancel_client
          )
        end)

      assert_receive {:pre_acceptance_cancel_received, emitter}, 1_000
      assert AllocationAuthority.claim_count(authority, node_id) == 1
      send(emitter, :finish_cancel)

      assert {:error, {:dispatch_failed, :node_acceptance_missing}} = Task.await(dispatch)
      assert AllocationAuthority.claim_count(authority, node_id) == 0
    end
  end

  test "SPEC 4.5 an unresponsive cancellation reconciles fail closed before release" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-cancel-drain-timeout"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms
    }

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          schedule,
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, _emitter}, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    assert_receive :pre_acceptance_disconnected, 1_000

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} = Task.await(dispatch)
    assert AllocationAuthority.claim_count(authority, node_id) == 0

    assert {:error, :dispatch_capacity_unavailable, quarantined} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-cancel-timeout",
               enforcing_input(),
               authority: authority
             )

    assert :node_health_unhealthy in quarantined.reason_codes
  end

  test "SPEC 4.5 cancellation drain deadline is not extended by nonterminal events" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-noisy-cancel-drain"

    schedule = %{
      capacity_schedule(authority, node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms
    }

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          schedule,
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @noisy_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive :noisy_cancel_received, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    assert_receive :noisy_cancel_disconnected, 250

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} = Task.await(dispatch)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 4.5 reconciliation quarantines the claimed Node when inventory resolves another" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = Inference.runtime_client_target()
    inventory_node = insert_admitted_node!(target, DateTime.utc_now())
    claimed_node_id = claim_node_id()
    request_id = "request-mismatched-reconciliation-node"

    schedule = %{
      capacity_schedule(authority, claimed_node_id, request_id)
      | request_timeout_ms: @expiring_request_timeout_ms
    }

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          schedule,
          execute_request(request_id),
          model_load_request(claimed_node_id),
          client_impl: @pre_acceptance_cancel_client,
          cancel_drain_timeout_ms: 20
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, _emitter}, 1_000
    assert {:error, {:dispatch_failed, :node_acceptance_missing}} = Task.await(dispatch)
    assert Repo.get!(Node, inventory_node.id).health == :degraded

    assert {:error, :dispatch_capacity_unavailable, quarantined} =
             QueueManager.acquire_dispatch_capacity(
               claimed_node_id,
               "request-after-mismatched-reconciliation",
               enforcing_input(),
               authority: authority
             )

    assert :node_health_unhealthy in quarantined.reason_codes
  end

  test "SPEC 5.9 handler cancellation before Accepted remains a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-handler-cancel-before-accepted"

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          event_handler: fn _request_id, _event -> :cancel end
        )
      end)

    assert_receive {:pre_acceptance_cancel_received, emitter}, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel_after_acceptance)

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} = Task.await(dispatch)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 caller death before Accepted remains a pre-acceptance failure" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-caller-death-before-accepted"
    caller = spawn(fn -> Process.sleep(:infinity) end)

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @pre_acceptance_cancel_client,
          caller: caller
        )
      end)

    assert_receive :pre_acceptance_stream_started, 1_000
    Process.exit(caller, :kill)
    assert_receive {:pre_acceptance_cancel_received, emitter}, 1_000
    assert AllocationAuthority.claim_count(authority, node_id) == 1
    send(emitter, :finish_cancel_after_acceptance)

    assert {:error, {:dispatch_failed, :node_acceptance_missing}} = Task.await(dispatch)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 admitted SingleNode dispatch rejects missing post-load placement evidence" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    now = DateTime.utc_now()
    node = insert_admitted_node!(target, now)
    initial_status = production_status(node, target, [])

    post_load_status =
      production_status(node, target, [%{model_id: "test/model", version: "v1"}])

    @production_fresh_status_client.configure(self(), initial_status, post_load_status)

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(),
               target,
               status_client: @production_fresh_status_client,
               dispatch_capacity_authority: authority
             )

    assert {:error, {:dispatch_failed, :dispatch_capacity_revalidation_failed}} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request(schedule.request_id),
               model_load_request(node.id),
               client_impl: @production_fresh_status_client
             )

    refute_receive :production_execute_called
    assert AllocationAuthority.claim_count(authority, node.id) == 0
  end

  test "SPEC 5.9 SingleNode target remap cannot move a queued claim to another Node" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    now = DateTime.utc_now()
    scheduled_node = insert_admitted_node!(target, now)

    remapped_target =
      target
      |> Keyword.put(:host, "127.0.0.2")
      |> Keyword.update!(:port, &(&1 + 1))

    remapped_node = insert_admitted_node!(remapped_target, now)
    resolver = start_supervised!({Agent, fn -> scheduled_node end})
    initial_status = production_status(scheduled_node, target, [])

    @production_fresh_status_client.configure(self(), initial_status, initial_status)

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(),
               target,
               status_client: @production_fresh_status_client,
               dispatch_capacity_authority: authority,
               node_resolver: fn _target -> {:ok, Agent.get(resolver, & &1)} end
             )

    assert schedule.node_id == scheduled_node.id

    remapped_status = production_status(remapped_node, target, [])

    remapped_post_load_status =
      remapped_node
      |> production_status(target, [%{model_id: "test/model", version: "v1"}])
      |> Map.put(:runtime_model_placements, [
        %{
          model_ref: %{model_id: "test/model", version: "v1"},
          active_request_count: 0,
          max_concurrency: 2
        }
      ])

    scheduled_node
    |> Ecto.Changeset.change(
      advertise_addr: "127.0.0.3",
      rpc_port: Keyword.fetch!(target, :port) + 2,
      connect_host: "127.0.0.3",
      connect_port: Keyword.fetch!(target, :port) + 2
    )
    |> Repo.update!()

    remapped_node
    |> Ecto.Changeset.change(
      advertise_addr: Keyword.fetch!(target, :host),
      rpc_port: Keyword.fetch!(target, :port),
      connect_host: Keyword.fetch!(target, :host),
      connect_port: Keyword.fetch!(target, :port)
    )
    |> Repo.update!()

    assert {:ok, %Node{id: remapped_node_id}} = Orchard.Nodes.lookup_by_target_result(target)
    assert remapped_node_id == remapped_node.id

    Agent.update(resolver, fn _scheduled_node -> remapped_node end)

    @production_fresh_status_client.configure(
      self(),
      remapped_status,
      remapped_post_load_status
    )

    assert {:error, {:dispatch_failed, :dispatch_capacity_facts_unavailable}} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request(schedule.request_id),
               model_load_request(scheduled_node.id),
               client_impl: @production_fresh_status_client
             )

    refute_receive :model_loaded
    refute_receive :production_execute_called
    assert AllocationAuthority.claim_count(authority, scheduled_node.id) == 0
    assert AllocationAuthority.claim_count(authority, remapped_node.id) == 0
  end

  test "SPEC 5.9 dispatch probe cannot move execution away from the claimed Node" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    runtime_node = insert_admitted_node!(target, DateTime.utc_now())
    claimed_node_id = claim_node_id()
    request_id = "request-probe-identity-remap"
    status = production_status(runtime_node, target, [])

    @production_fresh_status_client.configure(self(), status, status)

    assert {:error, {:dispatch_failed, :dispatch_capacity_node_identity_mismatch}} =
             RequestDispatcher.dispatch(
               capacity_schedule(authority, claimed_node_id, request_id),
               execute_request(request_id),
               model_load_request(claimed_node_id),
               client_impl: @production_fresh_status_client
             )

    refute_receive :production_execute_called
    assert AllocationAuthority.claim_count(authority, claimed_node_id) == 0
    assert AllocationAuthority.claim_count(authority, runtime_node.id) == 0
  end

  test "SPEC 5.9 a claimed Node whose dispatch probe reports no identity fails closed" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    DispatchCapacityFixtures.clear_probe_node_id()
    node_id = Ecto.UUID.generate()
    request_id = "request-probe-identity-missing"

    assert {:error, {:dispatch_failed, :dispatch_capacity_node_identity_mismatch}} =
             RequestDispatcher.dispatch(
               capacity_schedule(authority, node_id, request_id),
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @gate_client
             )

    refute_receive :execute_called
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 admitted MultiNode dispatch rejects nonmatching post-load placement evidence" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    target = SingleNode.target()
    put_inference(runtime_client_targets: [target])
    now = DateTime.utc_now()
    node = insert_admitted_node!(target, now)
    initial_status = production_status(node, target, [])

    post_load_status =
      node
      |> production_status(target, [%{model_id: "test/model", version: "v1"}])
      |> Map.put(:runtime_model_placements, [
        %{
          model_ref: %{model_id: "different/model", version: "v1"},
          active_request_count: 0,
          max_concurrency: 2
        }
      ])

    @production_fresh_status_client.configure(self(), initial_status, post_load_status)

    assert {:ok, schedule} =
             MultiNode.schedule(
               canonical_request(),
               status_client: @production_fresh_status_client,
               dispatch_capacity_authority: authority
             )

    assert schedule.strategy == :multi_node

    assert {:error, {:dispatch_failed, :dispatch_capacity_revalidation_failed}} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request(schedule.request_id),
               model_load_request(node.id),
               client_impl: @production_fresh_status_client
             )

    refute_receive :production_execute_called
    assert AllocationAuthority.claim_count(authority, node.id) == 0
  end

  test "SPEC 5.9 an unprobed unmanaged schedule stays dispatchable end to end" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    request_id = "request-unprobed-unmanaged"

    assert {:ok, schedule} =
             SingleNode.default_schedule(
               canonical_request(),
               Inference.runtime_client_target(),
               probe_status?: false,
               dispatch_capacity_authority: authority
             )

    assert is_nil(schedule.node_id)
    assert %Input{} = schedule.dispatch_capacity_input
    assert %Evaluator.Result{eligible?: true} = schedule.dispatch_capacity_evaluation

    assert {:ok, _events} =
             RequestDispatcher.dispatch(
               Map.put(schedule, :request_id, request_id),
               execute_request(request_id),
               model_load_request("unmanaged"),
               client_impl: @gate_client
             )
  end

  test "SPEC 5.9 a held acceptance gate fails dispatch bounded instead of blocking" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-acceptance-gate-busy"

    {:ok, lease} = QueueManager.acquire_acceptance_gate(node_id, authority: authority)

    schedule = %{capacity_schedule(authority, node_id, request_id) | request_timeout_ms: 60}

    assert {:error, {:dispatch_failed, :dispatch_capacity_acceptance_gate_busy}} =
             RequestDispatcher.dispatch(
               schedule,
               execute_request(request_id),
               model_load_request(node_id),
               client_impl: @gate_client
             )

    refute_receive :execute_called, 50
    assert :ok = QueueManager.release_acceptance_gate(lease, authority: authority)
    assert AllocationAuthority.claim_count(authority, node_id) == 0
  end

  test "SPEC 5.9 caller death while waiting for acceptance prevents execution" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-caller-death-during-acceptance-wait"
    caller = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, held_lease} = QueueManager.acquire_acceptance_gate(node_id, authority: authority)

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          capacity_schedule(authority, node_id, request_id),
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @gate_client,
          caller: caller
        )
      end)

    try do
      assert_receive :model_loaded
      Process.exit(caller, :kill)
      assert :ok = QueueManager.release_acceptance_gate(held_lease, authority: authority)

      assert {:ok, {:error, {:dispatch_failed, :caller_disconnect}}} =
               Task.yield(dispatch, 250)

      refute_receive :execute_called
      assert AllocationAuthority.claim_count(authority, node_id) == 0
    after
      Task.shutdown(dispatch, :brutal_kill)
      QueueManager.release_acceptance_gate(held_lease, authority: authority)
    end

    assert {:ok, next_lease} =
             QueueManager.acquire_acceptance_gate(node_id,
               authority: authority,
               gate_timeout_ms: 100
             )

    assert :ok = QueueManager.release_acceptance_gate(next_lease, authority: authority)
  end

  test "SPEC 5.9 acceptance waiting and streaming share one request timeout" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = claim_node_id()
    request_id = "request-shared-acceptance-deadline"
    schedule = %{capacity_schedule(authority, node_id, request_id) | request_timeout_ms: 1_000}

    {:ok, held_lease} = QueueManager.acquire_acceptance_gate(node_id, authority: authority)
    started_at = System.monotonic_time(:millisecond)

    dispatch =
      Task.async(fn ->
        RequestDispatcher.dispatch(
          schedule,
          execute_request(request_id),
          model_load_request(node_id),
          client_impl: @cancellable_stream_client
        )
      end)

    try do
      assert_receive :model_loaded
      Process.sleep(600)
      assert :ok = QueueManager.release_acceptance_gate(held_lease, authority: authority)

      # A deadline that excluded the 600ms gate wait would cancel no earlier
      # than 1_600ms after dispatch started, so the upper bound still proves
      # acceptance waiting and streaming share one request timeout.
      assert_receive {:cancel_received, emitter}, 700
      assert System.monotonic_time(:millisecond) - started_at < 1_400

      send(emitter, :finish_cancel)
      assert {:ok, _events} = Task.await(dispatch)
      assert AllocationAuthority.claim_count(authority, node_id) == 0
    after
      Task.shutdown(dispatch, :brutal_kill)
      QueueManager.release_acceptance_gate(held_lease, authority: authority)

      case :persistent_term.get({CancellableStreamClient, :emitter}, nil) do
        emitter when is_pid(emitter) -> Process.exit(emitter, :kill)
        nil -> :ok
      end
    end
  end

  defp claim_node_id do
    node_id = Ecto.UUID.generate()
    DispatchCapacityFixtures.put_probe_node_id(node_id)
    node_id
  end

  defp execute_request(request_id) do
    %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: "controller-session-capacity",
      model_id: "test/model",
      version: "v1",
      rendered_prompt_utf8: "hello orchard",
      input_tokens: 2
    }
  end

  defp model_load_request(node_id) do
    %EnsureModelLoadedRequest{
      node_id: node_id,
      model_id: "test/model",
      version: "v1"
    }
  end

  defp capacity_schedule(authority, node_id, request_id) do
    input = enforcing_input()

    %{
      strategy: :single_node,
      request_id: request_id,
      runtime_client_target: Inference.runtime_client_target(),
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000,
      node_id: node_id,
      dispatch_capacity_input: input,
      dispatch_capacity_acquisition_input_provider: fn -> input end,
      dispatch_capacity_input_provider: fn -> input end,
      dispatch_capacity_authority: authority
    }
  end

  defp canonical_request do
    CanonicalRequest.new(%{
      internal_id: "int-production-post-load",
      public_id: "pub-production-post-load",
      endpoint: :chat_completions,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %ModelRef{model_id: "test/model", version: "v1"},
      rendered_prompt: "hello orchard"
    })
  end

  defp put_inference(overrides) do
    config = Application.fetch_env!(:orchard_controller, :inference)
    Application.put_env(:orchard_controller, :inference, Keyword.merge(config, overrides))
  end

  defp insert_admitted_node!(target, now) do
    host = Keyword.fetch!(target, :host)
    port = Keyword.fetch!(target, :port)
    unique = System.unique_integer([:positive])

    {:ok, node} =
      Repo.transaction(fn ->
        node =
          %Node{}
          |> Node.changeset(%{
            id: Ecto.UUID.generate(),
            hostname: "dispatch-#{unique}.local",
            display_name: "dispatch-#{unique}",
            advertise_addr: host,
            rpc_port: port,
            state: :active,
            health: :healthy,
            capabilities: %{},
            last_heartbeat_at: now
          })
          |> Repo.insert!()

        decision =
          %AdmissionDecision{}
          |> AdmissionDecision.changeset(%{
            node_id: node.id,
            decision: :admitted,
            actor_type: "system",
            actor_id: "request-dispatcher-test",
            observed_identity: %{},
            metadata: %{},
            decided_at: now
          })
          |> Repo.insert!()

        %Policy{}
        |> Policy.approved_explicit_changeset(%{
          node_id: node.id,
          admission_decision_id: decision.id,
          controller_dispatch_ceiling: 2,
          approved_by_actor_type: "system",
          approved_by_actor_id: "request-dispatcher-test",
          approved_at: now,
          approval_reason: "request dispatcher test fixture",
          version: 1
        })
        |> Repo.insert!()

        node
      end)

    node
  end

  defp production_status(node, target, loaded_models) do
    %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        agent_version: "test",
        listen_host: Keyword.fetch!(target, :host),
        listen_port: Keyword.fetch!(target, :port),
        worker_backend: "mlx"
      },
      runtime_health: %{ready: true},
      loaded_models: loaded_models,
      active_request_count: 0,
      max_concurrency: 2,
      runtime_model_placements: []
    }
  end

  defp enforcing_input do
    %Input{
      authority_phase: :enforcing,
      policy_presence: :present,
      policy_state: :enforcing,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 1},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: {:valid, 1},
      controller_accounted_allocation: 0,
      placement_capacity: {:valid, 0, 1},
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end

  defp unmanaged_input do
    %Input{
      authority_phase: :invalid,
      policy_presence: :missing,
      policy_state: :missing,
      management_classification: {:ok, :unmanaged_compatibility},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
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
end
