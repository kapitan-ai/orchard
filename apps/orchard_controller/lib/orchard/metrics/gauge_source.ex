defmodule Orchard.Metrics.GaugeSource do
  @moduledoc false

  import Ecto.Query

  alias Orchard.DispatchCapacity.AllocationAuthority
  alias Orchard.Governance
  alias Orchard.Inference.QueueManager
  alias Orchard.Nodes.{Node, NodeHeartbeat}
  alias Orchard.Repo
  alias Orchard.Requests.Request

  @query_timeout_ms 500
  @authority_timeout_ms 100
  @managed_node_limit 5

  @type entry :: %{labels: map(), value: number()}
  @type snapshots :: %{required(atom()) => [entry()]}

  @spec snapshots(DateTime.t()) :: snapshots()
  def snapshots(now \\ DateTime.utc_now()) do
    node_heartbeats = managed_node_heartbeats()

    %{
      node_heartbeat_lag: heartbeat_lag_entries(node_heartbeats, now),
      node_available_memory: memory_entries(node_heartbeats, now, :available_memory_bytes),
      node_swap_used: memory_entries(node_heartbeats, now, :swap_used_bytes),
      model_resident: placement_entries(node_heartbeats, :model_resident)
    }
    |> put_queue_depths()
    |> put_active_requests(node_heartbeats)
  end

  defp put_queue_depths(snapshots) do
    read = fn -> QueueManager.queue_depths(timeout: @authority_timeout_ms) end

    case read_authority(QueueManager, read) do
      {:ok, depths} ->
        tenants = Governance.list_tenants()
        Map.put(snapshots, :scheduler_queue_depth, queue_entries(tenants, depths))

      :unavailable ->
        snapshots
    end
  end

  defp put_active_requests(snapshots, node_heartbeats) do
    case read_authority(AllocationAuthority, &AllocationAuthority.live_claims/0) do
      {:ok, claims} ->
        Map.put(snapshots, :active_requests, active_request_entries(node_heartbeats, claims))

      :unavailable ->
        snapshots
    end
  end

  defp read_authority(server, read) do
    if is_pid(GenServer.whereis(server)), do: {:ok, read.()}, else: :unavailable
  catch
    :exit, _reason -> :unavailable
  end

  defp managed_node_heartbeats do
    Node
    |> where([node], node.state != :removed)
    |> order_by([node], asc: node.id)
    |> limit(@managed_node_limit)
    |> Repo.all(timeout: @query_timeout_ms)
    |> Enum.map(fn node -> {node, latest_heartbeat(node.id)} end)
  end

  defp latest_heartbeat(node_id) do
    NodeHeartbeat
    |> where([heartbeat], heartbeat.node_id == ^node_id)
    |> order_by([heartbeat], desc: heartbeat.observed_at, desc: heartbeat.id)
    |> limit(1)
    |> Repo.one(timeout: @query_timeout_ms)
  end

  defp queue_entries(tenants, depths) do
    Enum.map(tenants, fn tenant ->
      %{labels: %{tenant: tenant.id}, value: Map.get(depths, tenant.id, 0)}
    end)
  end

  defp heartbeat_lag_entries(node_heartbeats, now) do
    Enum.flat_map(node_heartbeats, fn
      {%Node{id: node_id}, %NodeHeartbeat{observed_at: %DateTime{} = observed_at}} ->
        lag = max(DateTime.diff(now, observed_at, :millisecond), 0) / 1_000
        [%{labels: %{node: node_id}, value: lag}]

      _missing ->
        []
    end)
  end

  defp memory_entries(node_heartbeats, now, field) do
    threshold_ms = Orchard.Inference.node_freshness_threshold_ms()

    Enum.flat_map(node_heartbeats, fn
      {%Node{id: node_id}, %NodeHeartbeat{observed_at: %DateTime{} = observed_at} = heartbeat} ->
        value = Map.fetch!(heartbeat, field)

        if fresh?(observed_at, now, threshold_ms) and is_integer(value) and value >= 0 do
          [%{labels: %{node: node_id}, value: value}]
        else
          []
        end

      _missing ->
        []
    end)
  end

  defp fresh?(observed_at, now, threshold_ms) do
    DateTime.compare(observed_at, DateTime.add(now, -threshold_ms, :millisecond)) in [:eq, :gt]
  end

  defp placement_entries(node_heartbeats, family) do
    node_heartbeats
    |> Enum.flat_map(fn
      {%Node{id: node_id}, %NodeHeartbeat{payload: %{"validity" => "valid"} = payload}} ->
        payload
        |> Map.get("placements", [])
        |> Enum.flat_map(&placement_entry(node_id, &1, family))

      _missing ->
        []
    end)
    |> merge_placement_entries(family)
  end

  defp active_request_entries(node_heartbeats, claims) do
    managed_node_ids =
      MapSet.new(node_heartbeats, fn {%Node{id: node_id}, _heartbeat} -> node_id end)

    authority_entries =
      claims
      |> Enum.filter(&MapSet.member?(managed_node_ids, &1.node_id))
      |> active_claim_entries()

    node_heartbeats
    |> placement_entries(:active_requests)
    |> Kernel.++(authority_entries)
    |> merge_placement_entries(:active_requests)
  end

  defp active_claim_entries([]), do: []

  defp active_claim_entries(claims) do
    request_ids = Enum.map(claims, & &1.request_id)

    models_by_request =
      Request
      |> where([request], request.public_id in ^request_ids)
      |> select([request], {request.public_id, request.requested_model})
      |> Repo.all(timeout: @query_timeout_ms)
      |> Map.new()

    Enum.flat_map(claims, fn claim ->
      case Map.get(models_by_request, claim.request_id) do
        model_id when is_binary(model_id) and model_id != "" ->
          [%{labels: %{node: claim.node_id, model: model_id}, value: 1}]

        _missing_request ->
          []
      end
    end)
  end

  defp placement_entry(
         node_id,
         %{"model_ref" => %{"model_id" => model_id}},
         :active_requests
       )
       when is_binary(model_id) and model_id != "" do
    [%{labels: %{node: node_id, model: model_id}, value: 0}]
  end

  defp placement_entry(
         node_id,
         %{"model_ref" => %{"model_id" => model_id}, "state" => state},
         :model_resident
       )
       when is_binary(model_id) and model_id != "" do
    [%{labels: %{node: node_id, model: model_id}, value: if(state == "loaded", do: 1, else: 0)}]
  end

  defp placement_entry(_node_id, _placement, _family), do: []

  defp merge_placement_entries(entries, family) do
    entries
    |> Enum.group_by(& &1.labels)
    |> Enum.map(fn {labels, grouped} ->
      values = Enum.map(grouped, & &1.value)
      value = if family == :model_resident, do: Enum.max(values), else: Enum.sum(values)
      %{labels: labels, value: value}
    end)
  end
end
