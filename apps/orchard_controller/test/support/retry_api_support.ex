defmodule Orchard.TestSupport.RetryAPI.Scheduler do
  @moduledoc false

  @behaviour Orchard.Scheduler.SingleNode

  alias Orchard.CanonicalRequest
  alias Orchard.DispatchCapacity.AllocationAuthority
  alias Orchard.DispatchCapacity.{ConformanceFixture, Evaluator}
  alias Orchard.Inference
  alias Orchard.TestSupport.RetryAPI

  def schedule(%CanonicalRequest{} = request), do: schedule(request, [])

  @impl true
  def schedule(%CanonicalRequest{} = request, opts) do
    excluded_node_ids = Keyword.get(opts, :exclude_node_ids, [])

    case excluded_node_ids do
      [excluded_node_id] ->
        send(
          self(),
          {:retry_api_claim_count_before_alternate,
           AllocationAuthority.claim_count(excluded_node_id)}
        )

      [] ->
        :ok
    end

    case RetryAPI.select_node(excluded_node_ids) do
      {:ok, node} ->
        send(self(), {:retry_api_schedule, excluded_node_ids, node.node_id})
        {:ok, schedule_for(request, node)}

      :error ->
        {:error, :cluster_busy,
         %{
           strategy: :multi_node,
           request_id: request.public_id,
           candidate_count: 0,
           selected_tier: nil
         }}
    end
  end

  defp schedule_for(request, node) do
    capacity_input = ConformanceFixture.input()

    %{
      strategy: :multi_node,
      request_id: request.public_id,
      runtime_client_target: node.target,
      request_timeout_ms: Inference.request_timeout_ms(),
      model_load_timeout_ms: Inference.model_load_timeout_ms(),
      node_id: node.node_id,
      candidate_count: RetryAPI.node_count(),
      selected_tier: :loaded,
      dispatch_capacity_input: capacity_input,
      dispatch_capacity_evaluation: Evaluator.evaluate(capacity_input),
      dispatch_capacity_acquisition_input_provider: fn -> capacity_input end,
      dispatch_capacity_input_provider: fn -> capacity_input end
    }
  end
end

defmodule Orchard.TestSupport.RetryAPI.RuntimeClient do
  @moduledoc false

  alias Orchard.RuntimeEndpoint.{Operation, PlacementCapacity}
  alias Orchard.TestSupport.DispatchCapacityFixtures
  alias Orchard.TestSupport.RetryAPI

  def connect(target), do: {:ok, target}

  def status(target, _opts) do
    case RetryAPI.runtime_status(target) do
      nil ->
        {:error, :unavailable}

      response ->
        DispatchCapacityFixtures.record_authenticated_probe_evidence(response)
        {:ok, response}
    end
  end

  def ensure_model_loaded(_channel, %Operation.EnsureModelLoadedRequest{} = request, _opts) do
    model = %{model_id: request.model_ref.model_id, version: request.model_ref.version}

    {:ok,
     %Operation.EnsureModelLoadedResult{
       already_loaded: true,
       placement_state: :loaded,
       worker_supports_prompt_token_ids: true,
       placement_capacity:
         PlacementCapacity.new(%{
           model_ref: model,
           active_request_count: 0,
           max_concurrency: 4,
           source: :ensure_model_loaded_result
         }),
       placement_capacity_evidence_state: :valid
     }}
  end

  def unload_model(_channel, %Operation.UnloadModelRequest{}, _opts),
    do: {:ok, %Operation.Ack{ok: true}}

  def execute_inference(channel, %Operation.ExecuteRequest{} = request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    stream_ref = make_ref()

    send(self(), {:retry_api_execute, request.request_id, channel})

    Enum.each(RetryAPI.next_attempt_events(), fn event ->
      send(owner, {:runtime_endpoint_event, stream_ref, request.request_id, event})
    end)

    send(owner, {:runtime_endpoint_done, stream_ref, :ok})
    {:ok, stream_ref}
  end

  def cancel_inference(_channel, %Operation.CancelRequest{}, _opts), do: :ok
  def disconnect(_channel), do: :ok

  def score_prefix_cache(_target, _request, _opts),
    do: {:ok, %{status_code: "unavailable", score_tier: "unknown"}}
end

defmodule Orchard.TestSupport.RetryAPI do
  @moduledoc false

  import ExUnit.Assertions

  alias Orchard.CircuitBreakers.Failure
  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.AllocationAuthority
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.InferenceEvent
  alias Orchard.Nodes.AdmissionDecision
  alias Orchard.Nodes.Node, as: InventoryNode
  alias Orchard.Repo
  alias Orchard.Requests
  alias Orchard.TestSupport.RetryAPI.{RuntimeClient, Scheduler}

  @state_key {__MODULE__, :state}

  def successful_retry_events do
    [
      [
        InferenceEvent.progress("prefill", "attempt-one-only"),
        InferenceEvent.output_text_delta(""),
        InferenceEvent.failed("worker_down", "attempt one failed", true)
      ],
      [
        InferenceEvent.output_text_delta("attempt-two-only"),
        InferenceEvent.completed(
          :finish_reason_stop,
          %InferenceEvent.Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}
        )
      ]
    ]
  end

  def exhausted_retry_events do
    [
      [InferenceEvent.failed("worker_down", "attempt one failed", true)],
      [
        InferenceEvent.failed(
          "runtime_unavailable",
          "attempt two failed",
          true
        )
      ]
    ]
  end

  def commitment_cases do
    [
      {"text", InferenceEvent.output_text_delta("committed")},
      {"tool_call",
       InferenceEvent.tool_call_delta(
         "call-stable",
         Jason.encode!(%{
           index: 0,
           type: "function",
           function: %{name: "lookup_weather", arguments_delta: "{}"}
         })
       )}
    ]
  end

  def alternate_refusal_cases do
    [
      {"no-alternative", :no_alternative, "no_alternative_node"},
      {"same-node", :same_node, "identity_unresolved"}
    ]
  end

  def configure_retry_nodes!(attempt_event_lists, opts \\ [])
      when is_list(attempt_event_lists) and is_list(opts) do
    node_count = Keyword.get(opts, :node_count, 2)
    assert node_count in [1, 2]

    target_suffix = rem(System.unique_integer([:positive]), 10_000)
    first_target = [host: "10.13.1.1", port: 42_000 + target_suffix]
    second_target = [host: "10.13.1.2", port: 53_000 + target_suffix]
    first_node = insert_runtime_node!(first_target)
    second_node = if node_count == 2, do: insert_runtime_node!(second_target)

    nodes =
      [%{node_id: first_node.id, target: first_target, inventory: first_node}]
      |> maybe_append_second_node(second_node, second_target)

    statuses =
      Map.new(nodes, fn node ->
        {target_key(node.target), runtime_status_payload(node.inventory, node.target)}
      end)

    Process.put(@state_key, %{
      nodes: nodes,
      statuses: statuses,
      event_lists: attempt_event_lists,
      accepted?: Keyword.get(opts, :accepted?, true),
      selection_mode: Keyword.get(opts, :selection_mode, :different_node)
    })

    inference =
      Application.fetch_env!(:orchard_controller, :inference)
      |> Keyword.merge(
        runtime_client_targets: Enum.map(nodes, & &1.target),
        runtime_endpoint_targets: [],
        runtime_endpoint_client_impl: RuntimeClient,
        scheduler_impl: Scheduler
      )

    Application.put_env(:orchard_controller, :inference, inference)
    %{first: first_node, second: second_node}
  end

  def clear do
    Process.delete(@state_key)
    Process.delete(:orchard_retry_started_probe)
  end

  def select_node(excluded_node_ids) do
    state = fetch_state!(@state_key)

    case {state.selection_mode, excluded_node_ids} do
      {:no_alternative, [_excluded_node_id]} ->
        :error

      {:same_node, [_excluded_node_id]} ->
        {:ok, hd(state.nodes)}

      {_mode, excluded_node_ids} ->
        state.nodes
        |> Enum.find(fn node -> node.node_id not in excluded_node_ids end)
        |> case do
          nil -> :error
          node -> {:ok, node}
        end
    end
  end

  def runtime_status(target) do
    @state_key
    |> fetch_state!()
    |> Map.fetch!(:statuses)
    |> Map.get(target_key(target))
  end

  def node_count do
    @state_key
    |> fetch_state!()
    |> Map.fetch!(:nodes)
    |> length()
  end

  def next_attempt_events do
    state = fetch_state!(@state_key)

    case state.event_lists do
      [{:pre_acceptance, events} | rest] ->
        Process.put(@state_key, %{state | event_lists: rest})
        events

      [events | rest] ->
        Process.put(@state_key, %{state | event_lists: rest})
        if state.accepted?, do: [InferenceEvent.accepted(0) | events], else: events

      [] ->
        flunk("retry API fixture observed an unexpected third inference attempt")
    end
  end

  def assert_successful_retry!(request, nodes) do
    step_events = Requests.list_request_step_events(request)

    assert Enum.map(step_events, &{&1.event_type, &1.attempt}) == [
             {"request_step.started", 1},
             {"request_step.failed", 1},
             {"request_step.started", 2},
             {"request_step.completed", 2}
           ]

    [_, attempt_one, _, attempt_two] = Enum.map(step_events, & &1.result)
    assert attempt_one["node_id"] == nodes.first.id
    assert attempt_one["output_committed"] == false
    assert attempt_one["capacity_release_outcome"] == "released"
    assert attempt_one["retry_decision"] == "retried"
    assert attempt_two["node_id"] == nodes.second.id
    assert attempt_two["output_committed"] == true
    refute Map.has_key?(attempt_two, "retry_decision")
    assert request.node_id == nodes.second.id

    assert_receive {:retry_api_schedule, [], first_node_id}
    assert first_node_id == nodes.first.id
    assert_receive {:retry_api_claim_count_before_alternate, 0}
    assert_receive {:retry_api_schedule, [excluded_node_id], second_node_id}
    assert excluded_node_id == nodes.first.id
    assert second_node_id == nodes.second.id

    assert_receive {:retry_api_execute, public_id, _target}
    assert public_id == request.public_id
    assert_receive {:retry_api_execute, ^public_id, _target}
    refute_receive {:retry_api_execute, ^public_id, _target}, 0
  end

  def assert_failed_retry!(request, nodes) do
    step_events = Requests.list_request_step_events(request)

    assert Enum.map(step_events, &{&1.event_type, &1.attempt}) == [
             {"request_step.started", 1},
             {"request_step.failed", 1},
             {"request_step.started", 2},
             {"request_step.failed", 2}
           ]

    [_, attempt_one, _, attempt_two] = Enum.map(step_events, & &1.result)
    assert attempt_one["node_id"] == nodes.first.id
    assert attempt_one["retry_decision"] == "retried"
    assert attempt_two["node_id"] == nodes.second.id
    assert attempt_two["retry_decision"] == "retry_exhausted"
    assert request.node_id == nodes.second.id

    assert_two_executions!(request, nodes)
  end

  def assert_declined_retry!(
        request,
        nodes,
        expected_decision,
        expected_failure_class,
        expected_commitment_kind \\ nil
      ) do
    step_events = Requests.list_request_step_events(request)

    assert Enum.map(step_events, &{&1.event_type, &1.attempt}) == [
             {"request_step.started", 1},
             {"request_step.failed", 1}
           ]

    terminal = List.last(step_events).result
    assert terminal["retry_decision"] == expected_decision
    assert terminal["failure_class"] == expected_failure_class

    if expected_commitment_kind do
      assert terminal["output_committed"]
      assert terminal["output_commitment_kind"] == expected_commitment_kind
    else
      refute terminal["output_committed"]
    end

    assert_receive {:retry_api_schedule, [], first_node_id}
    assert first_node_id == nodes.first.id

    assert_receive {:retry_api_execute, public_id, _target}
    assert public_id == request.public_id

    case expected_decision do
      "no_alternative_node" ->
        assert_receive {:retry_api_claim_count_before_alternate, 0}
        refute_receive {:retry_api_schedule, [_excluded_node_id], _node_id}, 0

      "identity_unresolved" ->
        assert_receive {:retry_api_claim_count_before_alternate, 0}
        assert_receive {:retry_api_schedule, [excluded_node_id], same_node_id}
        assert excluded_node_id == nodes.first.id
        assert same_node_id == nodes.first.id

      _other ->
        refute_receive {:retry_api_claim_count_before_alternate, _count}, 0
    end

    refute_receive {:retry_api_execute, ^public_id, _target}, 0
  end

  def assert_logical_identity!(request, idempotency_key, capture_mode) do
    assert request.idempotency_key == idempotency_key
    assert request.payload_capture_mode == capture_mode

    matching_requests =
      Requests.Request
      |> Repo.all()
      |> Enum.filter(&(&1.idempotency_key == idempotency_key))

    assert [%{id: request_id}] = matching_requests
    assert request_id == request.id
  end

  def assert_preacceptance_capacity_refusal!(request, nodes) do
    assert_declined_retry!(request, nodes, "not_retryable", "capacity_rejection")
    assert request.state == :failed
    assert request.http_status == 503
    assert request.error_code == "model_busy"
    assert request.reserved_output_tokens == 0
    assert request.first_token_at == nil

    terminal =
      request |> Requests.list_request_step_events() |> List.last() |> Map.fetch!(:result)

    assert terminal["accepted"] == false
    assert terminal["failure_code"] == "model_busy"
    assert terminal["capacity_release_outcome"] == "released"
    assert terminal["execution_resolution"] == "terminated"

    states = request |> Requests.list_request_events() |> Enum.map(& &1.state)
    assert Enum.count(states, &(&1 in [:completed, :failed, :cancelled, :timed_out])) == 1
    refute Enum.any?(states, &(&1 in [:queued, :running, :streaming]))

    refute Enum.any?(Repo.all(Failure), &(&1.node_id == nodes.first.id))
    assert AllocationAuthority.claim_count(nodes.first.id) == 0

    assert {:ok, lease} =
             AllocationAuthority.try_acquire_acceptance_gate(
               AllocationAuthority,
               nodes.first.id,
               100
             )

    AllocationAuthority.release_acceptance_gate(lease)
  end

  def latest_request!(requested_model, stream?) do
    Orchard.Requests.Request
    |> Repo.all()
    |> Enum.filter(&(&1.requested_model == requested_model and &1.stream == stream?))
    |> Enum.max_by(& &1.inserted_at)
  end

  defp assert_two_executions!(request, nodes) do
    assert_receive {:retry_api_schedule, [], first_node_id}
    assert first_node_id == nodes.first.id
    assert_receive {:retry_api_execute, public_id, _target}
    assert public_id == request.public_id
    assert_receive {:retry_api_claim_count_before_alternate, 0}
    assert_receive {:retry_api_schedule, [excluded_node_id], second_node_id}
    assert excluded_node_id == nodes.first.id
    assert second_node_id == nodes.second.id
    assert_receive {:retry_api_execute, ^public_id, _target}
    refute_receive {:retry_api_execute, ^public_id, _target}, 0
  end

  defp insert_runtime_node!(target) do
    unique = System.unique_integer([:positive])
    observed_at = DateTime.utc_now()

    node =
      %InventoryNode{}
      |> InventoryNode.changeset(%{
        id: Ecto.UUID.generate(),
        hostname: "retry-api-#{unique}.local",
        display_name: "retry-api-#{unique}",
        advertise_addr: Keyword.fetch!(target, :host),
        rpc_port: Keyword.fetch!(target, :port),
        state: :active,
        health: :healthy,
        capabilities: %{},
        last_heartbeat_at: observed_at
      })
      |> Repo.insert!()

    decision =
      %AdmissionDecision{}
      |> AdmissionDecision.changeset(%{
        node_id: node.id,
        decision: :admitted,
        actor_type: "system",
        actor_id: "retry-api-test",
        observed_identity: %{},
        metadata: %{},
        decided_at: observed_at
      })
      |> Repo.insert!()

    %Policy{}
    |> Policy.approved_explicit_changeset(%{
      node_id: node.id,
      admission_decision_id: decision.id,
      controller_dispatch_ceiling: 4,
      approved_by_actor_type: "system",
      approved_by_actor_id: "retry-api-test",
      approved_at: observed_at,
      approval_reason: "bounded retry public API fixture"
    })
    |> Repo.insert!()

    assert {:ok, _evidence} =
             DispatchCapacity.record_capacity_evidence(node.id, %{
               active_request_count: 0,
               observed_at: observed_at,
               runtime_concurrency_limit: 4,
               validity: :valid
             })

    node
  end

  defp runtime_status_payload(node, target) do
    %{
      node_metadata: %{
        node_id: node.id,
        display_name: node.display_name,
        hostname: node.hostname,
        agent_version: "0.1.0",
        listen_host: Keyword.fetch!(target, :host),
        listen_port: Keyword.fetch!(target, :port),
        worker_backend: "mlx"
      },
      runtime_health: %{ready: true, health_code: "ok", health_message: "ready"},
      loaded_models: [],
      active_request_count: 0,
      max_concurrency: 4,
      runtime_memory_budgets: [],
      runtime_prefix_cache_statuses: [],
      runtime_model_placements: [],
      supports_prompt_token_ids: false
    }
  end

  defp maybe_append_second_node(nodes, nil, _target), do: nodes

  defp maybe_append_second_node(nodes, second_node, target) do
    nodes ++ [%{node_id: second_node.id, target: target, inventory: second_node}]
  end

  defp target_key(%{address: address}), do: target_key(address)

  defp target_key(target),
    do: {Keyword.fetch!(target, :host), Keyword.fetch!(target, :port)}

  defp fetch_state!(key) do
    Process.get(key) || raise "retry API fixture is not configured"
  end
end
