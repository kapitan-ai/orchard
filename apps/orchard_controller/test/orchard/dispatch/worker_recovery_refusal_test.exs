defmodule Orchard.Dispatch.WorkerRecoveryRefusalTest do
  use Orchard.DataCase, async: false

  alias Orchard.CircuitBreakers
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest}
  alias Orchard.Dispatch.RequestDispatcher
  alias Orchard.InferenceEvent
  alias Orchard.RuntimeEndpoint.{Observation, Operation, Target}
  alias Orchard.TestSupport.DispatchCapacityFixtures

  defmodule Client do
    def connect(target), do: {:ok, target}
    def disconnect(_channel), do: :ok

    def status(target, _opts),
      do: {:ok, Observation.new(%{target: target, metadata: %{node_id: target.node_id}})}

    def ensure_model_loaded(_channel, _request, _opts) do
      case Process.get(:recovery_test_phase) do
        :ensure ->
          {:error, Process.get(:recovery_test_reason)}

        :load_failure ->
          {:ok,
           %Operation.EnsureModelLoadedResult{
             placement_state: :failed,
             failure_code: "model_invalid"
           }}

        _ ->
          {:ok,
           %Operation.EnsureModelLoadedResult{placement_state: :loaded, already_loaded: true}}
      end
    end

    def execute_inference(_channel, request, opts) do
      reason = Process.get(:recovery_test_reason)

      case Process.get(:recovery_test_phase) do
        :execute ->
          {:error, reason}

        phase when phase in [:stream, :accepted] ->
          ref = make_ref()
          owner = Keyword.fetch!(opts, :owner)

          if phase == :accepted do
            send(
              owner,
              {:runtime_endpoint_event, ref, request.request_id, InferenceEvent.accepted(0)}
            )
          end

          send(owner, {:runtime_endpoint_done, ref, {:error, reason}})
          {:ok, ref}

        :worker_loss ->
          ref = make_ref()
          owner = Keyword.fetch!(opts, :owner)

          send(
            owner,
            {:runtime_endpoint_event, ref, request.request_id, InferenceEvent.accepted(0)}
          )

          send(
            owner,
            {:runtime_endpoint_event, ref, request.request_id,
             InferenceEvent.failed("worker_down", "worker lost", true)}
          )

          send(owner, {:runtime_endpoint_done, ref, :ok})
          {:ok, ref}
      end
    end
  end

  setup do
    node =
      Repo.insert!(%Orchard.Nodes.Node{
        id: Ecto.UUID.generate(),
        hostname: "recovery-test.local",
        display_name: "recovery-test",
        advertise_addr: "127.0.0.1",
        rpc_port: 54_321,
        state: :active,
        health: :healthy,
        capabilities: %{},
        tool_readiness: %{}
      })

    model =
      Repo.insert!(%Orchard.Models.Model{
        model_id: "recovery-test",
        version: "v1",
        state: :active,
        format: "mlx",
        capabilities: ["text"],
        tokenizer: %{},
        artifact_sha256: String.duplicate("a", 64),
        artifact_uri: "file:///tmp/recovery-test",
        artifact_size_bytes: 1,
        resident_memory_bytes: 1,
        kv_cache_bytes_per_token: 1,
        prefill_workspace_bytes_per_token: 1,
        runtime_requirements: %{}
      })

    %{node: node, model: model}
  end

  test "SPEC §12.2 four pre-execution refusals have nil load category and zero §5.10 events",
       context do
    before_count = Repo.aggregate(Orchard.CircuitBreakers.Failure, :count)

    for phase <- [:ensure, :execute, :stream], reason <- refusal_reasons() do
      outcome = dispatch(context, phase, {:worker_recovery_refused, reason})
      assert outcome.failure["failure_class"] == "capacity_rejection"
      assert outcome.failure["failure_code"] == "model_busy"
      assert outcome.model_load_category == nil
      refute outcome.accepted
      refute outcome.output_committed
      assert outcome.execution_resolution in [:not_started, :terminated]
      assert outcome.capacity_release_outcome in [:released, :not_applicable]
      assert {:ok, :not_eligible} = record(outcome, context)
    end

    assert Repo.aggregate(Orchard.CircuitBreakers.Failure, :count) == before_count
  end

  test "SPEC §12.2 refusal after acceptance is not rewritten as capacity", context do
    outcome = dispatch(context, :accepted, {:worker_recovery_refused, :worker_restart_backoff})
    assert outcome.accepted
    refute outcome.failure["failure_class"] == "capacity_rejection"
  end

  test "SPEC §12.2 identity and occupancy uncertainty retain precedence", context do
    for {reason, expected_class} <- [
          dispatch_capacity_node_identity_mismatch: "identity_unresolved",
          dispatch_capacity_quarantine_store_unavailable: "occupancy_unresolved"
        ] do
      outcome = dispatch(context, :execute, reason)
      assert outcome.failure["failure_class"] == expected_class
      assert {:ok, :not_eligible} = record(outcome, context)
    end
  end

  test "SPEC §12.2 unknown refusal strings are not proven admission refusals", context do
    outcome = dispatch(context, :ensure, {:worker_recovery_refused, :unknown})
    assert outcome.failure["failure_class"] == "model_load_failure"
    refute outcome.model_load_category == nil
  end

  test "SPEC §12.2 actual eligible worker loss retains Node breaker attribution", context do
    outcome = dispatch(context, :worker_loss, nil)
    assert outcome.failure["failure_class"] == "worker_or_node_loss"
    assert {:ok, %{kind: :node, contribution_count: 1}} = record(outcome, context)
  end

  test "SPEC §12.2 actual eligible load failure retains placement breaker attribution", context do
    outcome = dispatch(context, :load_failure, nil)
    assert outcome.failure["failure_class"] == "model_load_failure"
    assert {:ok, %{kind: :placement, contribution_count: 1}} = record(outcome, context)
  end

  defp dispatch(context, phase, reason) do
    Process.put(:recovery_test_phase, phase)
    Process.put(:recovery_test_reason, reason)
    request_id = Ecto.UUID.generate()

    target =
      Orchard.Inference.runtime_client_target()
      |> Target.normalize()
      |> Map.put(:node_id, context.node.id)

    schedule =
      %{
        strategy: :single_node,
        request_id: request_id,
        node_id: context.node.id,
        runtime_endpoint_target: target,
        request_timeout_ms: 5_000,
        model_load_timeout_ms: 1_000
      }
      |> DispatchCapacityFixtures.authorize_unmanaged_schedule()

    execute = %ExecuteInferenceRequest{
      request_id: request_id,
      controller_session_id: Ecto.UUID.generate(),
      model_id: context.model.model_id,
      version: "v1",
      rendered_prompt_utf8: "test",
      input_tokens: 1
    }

    load = %EnsureModelLoadedRequest{
      node_id: context.node.id,
      model_id: context.model.model_id,
      version: "v1"
    }

    RequestDispatcher.dispatch(schedule, execute, load, client_impl: Client)
  end

  defp record(outcome, context) do
    CircuitBreakers.record_failure(%{
      failure_id: Ecto.UUID.generate(),
      node_id: context.node.id,
      model_id:
        if(outcome.failure["failure_class"] == "model_load_failure", do: context.model.id),
      failure_class: outcome.failure["failure_class"],
      occurred_at: DateTime.utc_now()
    })
  end

  defp refusal_reasons,
    do: [
      :worker_restart_backoff,
      :worker_restart_in_progress,
      :placement_crash_breaker_open,
      :placement_recovery_required
    ]
end
