defmodule OrchardConsole.LocalNodeSummary do
  @moduledoc "Display-only projection of installed local identity and existing Node evidence."

  alias Orchard.RuntimeEndpoint.Target

  @type t :: %{
          state: :unknown | :healthy | :stale | :unavailable | :attention,
          node: map() | nil,
          runtime: map() | nil
        }

  @doc "Combines the current page evidence without probing, writing or guessing host identity."
  @spec build({:ok, Orchard.LocalNodeIdentity.t()} | {:error, atom()}, map(), map()) :: t()
  def build({:ok, identity}, %{status: :ok} = inventory, %{status: :ok} = cluster) do
    nodes = Enum.filter(inventory.rows, &(&1.id == identity.node_id))
    targets = Enum.filter(cluster.targets, &bound_target?(&1.target, identity))

    with [node] <- nodes,
         [target] <- targets,
         status when is_map(status) <-
           Enum.find(inventory.statuses, &(&1.resource.id == node.id)) do
      project(node, target, status.freshness.status)
    else
      _ -> unknown()
    end
  end

  def build(_identity, _inventory, _cluster), do: unknown()

  defp bound_target?(%Target{node_id: node_id, metadata: metadata}, identity) do
    node_id == identity.node_id and metadata[:source] == :trusted_node_inventory and
      metadata[:enrollment_id] == identity.enrollment_id and
      metadata[:certificate_identifier] == identity.certificate_identifier
  end

  defp bound_target?(_target, _identity), do: false

  defp project(node, %{status: status}, _freshness) when status != :ok,
    do: %{state: :unavailable, node: node, runtime: nil}

  defp project(node, %{node_metadata: %{node_id: id}} = target, freshness)
       when id == node.id do
    state = evidence_state(node, target, freshness)
    %{state: state, node: node, runtime: target}
  end

  defp project(_node, _target, _freshness), do: unknown()

  defp evidence_state(_node, _target, freshness) when freshness != "fresh", do: :stale

  defp evidence_state(%{health: :healthy}, %{runtime_health: %{ready: true} = health}, _freshness) do
    if health[:health_code] in [nil, ""] and health[:health_message] in [nil, ""],
      do: :healthy,
      else: :attention
  end

  defp evidence_state(_node, _target, _freshness), do: :attention

  defp unknown, do: %{state: :unknown, node: nil, runtime: nil}
end
