defmodule Orchard.TestSupport.WorkerRecoveryFixtures do
  @moduledoc false

  alias Orchard.RuntimeEndpoint.Observation

  @epoch "scheduler-fixture-epoch"
  @node_id "00000000-0000-4000-a000-000000000379"

  def epoch, do: @epoch
  def node_id, do: @node_id

  def inspect(target, ref) do
    with {:ok, node_id} <- Ecto.UUID.cast(target.node_id),
         true <-
           is_binary(ref.model_id) and ref.model_id != "" and
             is_binary(ref.version) and ref.version != "" do
      {:ok, evidence(node_id, ref)}
    else
      _invalid -> {:error, :invalid_recovery_identity}
    end
  end

  @request_orchestrator_fixture_model_ids [
    "request-orchestrator-single-target-explanation",
    "request-orchestrator-worker-loss-cancel",
    "request-orchestrator-missing-terminal-detector",
    "request-orchestrator-load-timeout",
    "request-orchestrator-breaker-ordering",
    "request-orchestrator-worker-loss-breaker",
    "request-orchestrator-worker-loss-no-retry"
  ]

  def inspect_manager(_target, ref) do
    manager = Module.concat([Orchard, Node, ModelManager])
    manager.inspect_worker_recovery(ref.model_id, ref.version)
  end

  def inspect_lifecycle(target, ref) do
    manager = Module.concat([Orchard, Node, ModelManager])

    with {:ok, node_id} <- Ecto.UUID.cast(target.node_id),
         true <-
           is_binary(ref.model_id) and ref.model_id != "" and
             is_binary(ref.version) and ref.version != "",
         %{worker_recovery_epoch: epoch} when is_binary(epoch) and epoch != "" <-
           manager.current() do
      projection = evidence(node_id, ref)
      {:ok, %{projection | epoch: epoch, owner_epoch: epoch}}
    else
      _invalid -> {:error, :invalid_recovery_identity}
    end
  end

  def inspect_request_orchestrator(target, %{model_id: model_id} = ref) do
    cond do
      model_id in [
        "request-orchestrator-terminal-persist-success-failure",
        "request-orchestrator-success-persistence-failure",
        "request-orchestrator-success-persistence-exception",
        "request-orchestrator-success-persistence-exit",
        "request-orchestrator-success-persistence-throw"
      ] ->
        inspect_lifecycle(target, ref)

      model_id in @request_orchestrator_fixture_model_ids ->
        __MODULE__.inspect(target, ref)

      true ->
        inspect_manager(target, ref)
    end
  end

  def evidence(node_id, ref) do
    %{
      key: %{node_id: node_id, model_id: ref.model_id, version: ref.version},
      epoch: @epoch,
      owner_epoch: @epoch,
      revision: 1,
      state: "armed",
      hydrated: true,
      eligible: true,
      reason: nil
    }
  end

  def placements(placements, node_id) do
    Enum.map(placements, fn placement ->
      if Map.get(placement, :worker_recovery) do
        placement
      else
        Map.put(placement, :worker_recovery, evidence(node_id, placement.model_ref))
      end
    end)
  end

  def status(%Observation{} = observation) do
    node_id = Map.get(observation.metadata, :node_id)

    %{
      observation
      | worker_recovery_epoch: observation.worker_recovery_epoch || @epoch,
        placements: placements(observation.placements, node_id)
    }
  end

  def status(status) when is_map(status) do
    node_id = status |> Map.get(:node_metadata, %{}) |> metadata_node_id()

    records =
      Enum.map(Map.get(status, :runtime_model_placements, []), &placement_record(&1, node_id))

    present = MapSet.new(records, &identity(Map.get(&1, :model_ref)))

    retained =
      status
      |> Map.get(:loaded_models, [])
      |> Enum.reject(&MapSet.member?(present, identity(&1)))
      |> Enum.map(&placement_record(%{model_ref: &1}, node_id))

    status
    |> Map.update(:worker_recovery_epoch, @epoch, fn
      epoch when epoch in [nil, ""] -> @epoch
      epoch -> epoch
    end)
    |> Map.put(:runtime_model_placements, records ++ retained)
  end

  def status(nil), do: nil

  defp placement_record(%{model_ref: %{model_id: _, version: _} = ref} = record, node_id) do
    Map.put_new(record, :worker_recovery_json, Jason.encode!(evidence(node_id, ref)))
  end

  defp placement_record(record, _node_id), do: record

  defp identity(%{model_id: model_id, version: version}), do: {model_id, version}
  defp identity(_missing), do: nil

  defp metadata_node_id(metadata) when is_map(metadata), do: Map.get(metadata, :node_id)
  defp metadata_node_id(_metadata), do: nil
end

defmodule Orchard.TestSupport.WorkerRecoveryCheckpointClient do
  @moduledoc false

  def read(_key), do: {:ok, :absent}

  def commit(_key, _epoch, revision, transition_id, record) do
    {:ok,
     %{
       epoch: record["epoch"],
       revision: revision + 1,
       transition_id: transition_id,
       record: record
     }}
  end
end
