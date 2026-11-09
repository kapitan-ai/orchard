defmodule Orchard.ClusterManagement.Reads do
  @moduledoc """
  Controller-owned cluster and Node read payloads shared by Operator API and CLI.
  """

  alias Orchard.API.Admin.NodeAdmissionPresenter

  alias Orchard.ClusterManagement.{
    ControlPlaneStatus,
    MemoryBudgetPresenter,
    NodeStatus,
    StatusBuilder
  }

  alias Orchard.ControlPlane
  alias Orchard.Nodes
  alias Orchard.Nodes.Node

  @type node_options :: [latest_decision: :operator | :full]

  @doc "Returns the serving Controller's read-only cluster status."
  @spec cluster_status(ControlPlaneStatus.t()) :: map()
  def cluster_status(status \\ ControlPlane.read_only_status()) do
    %{
      object: "cluster_management.cluster_status",
      contract_version: "orchard.cluster_management.cluster_status.v1",
      summary: %{
        deployment_mode: status.deployment_mode,
        controller_role: status.controller_role,
        advisory_lock_status: status.advisory_lock_status
      },
      control_plane: ControlPlaneStatus.to_map(status)
    }
  end

  @doc "Returns registered Node statuses and the inventory summary."
  @spec nodes() :: map()
  def nodes do
    nodes = Nodes.list_nodes!()

    %{
      object: "cluster_management.node_status_list",
      contract_version: NodeStatus.contract_version(),
      data: StatusBuilder.node_status_maps(nodes),
      summary: %{
        total: length(nodes),
        by_state: Enum.frequencies_by(nodes, & &1.state) |> zero_fill(Node.states()),
        by_health: Enum.frequencies_by(nodes, & &1.health) |> zero_fill(Node.health_values())
      }
    }
  end

  @doc """
  Returns a Node with a non-observing runtime memory budget when available.

  Admission provenance defaults to the operator projection. Local admin callers
  may explicitly request `latest_decision: :full`.
  """
  @spec node(String.t(), node_options()) :: {:ok, map()} | {:error, :node_not_found}
  def node(node_id, opts \\ []) do
    with {:ok, node} <- Nodes.fetch_node(node_id) do
      payload =
        node
        |> NodeAdmissionPresenter.node()
        |> Map.update!(
          :latest_decision,
          &project_decision(&1, opts[:latest_decision] || :operator)
        )
        |> with_memory_budget()

      {:ok, payload}
    end
  end

  defp zero_fill(counts, values), do: Map.merge(Map.new(values, &{&1, 0}), counts)

  defp project_decision(nil, _projection), do: nil
  defp project_decision(decision, :full), do: decision

  defp project_decision(decision, :operator),
    do: Map.take(decision, [:object, :decision, :decided_at])

  defp with_memory_budget(node) do
    runtime_impl = Application.get_env(:orchard_controller, :console, [])[:runtime_impl]

    case MemoryBudgetPresenter.for_node(node, runtime_impl || OrchardConsole.Runtime,
           observe?: false
         ) do
      nil -> node
      memory_budget -> Map.put(node, :memory_budget, memory_budget)
    end
  end
end
