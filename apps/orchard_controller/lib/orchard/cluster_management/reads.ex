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
    nodes = Nodes.list_nodes()

    %{
      object: "cluster_management.node_status_list",
      contract_version: NodeStatus.contract_version(),
      data: StatusBuilder.node_status_maps(nodes),
      summary: Nodes.summary()
    }
  end

  @doc "Returns a sanitized Node with its runtime memory budget when available."
  @spec node(String.t()) :: {:ok, map()} | {:error, :node_not_found}
  def node(node_id) do
    with {:ok, node} <- Nodes.fetch_node(node_id) do
      {:ok, node |> NodeAdmissionPresenter.node() |> with_memory_budget()}
    end
  end

  defp with_memory_budget(node) do
    runtime_impl = Application.get_env(:orchard_controller, :console, [])[:runtime_impl]

    case MemoryBudgetPresenter.for_node(node, runtime_impl || OrchardConsole.Runtime) do
      nil -> node
      memory_budget -> Map.put(node, :memory_budget, memory_budget)
    end
  end
end
