defmodule OrchardConsole.NodesPageData do
  @moduledoc """
  Builds Console nodes page data from shared cluster-management status structures.
  """

  alias Orchard.ClusterManagement.StatusBuilder
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, Node}

  @pending_admission_categories [:pending_observed, :pending_provisioned, :pending_registered]
  @pending_admission_category_strings Enum.map(@pending_admission_categories, &Atom.to_string/1)

  @spec inventory([struct()], map()) :: map()
  def inventory(rows, summary) when is_list(rows) and is_map(summary) do
    %{
      status: :ok,
      rows: rows,
      summary: summary,
      statuses: StatusBuilder.node_status_maps(rows),
      message: nil
    }
  end

  @spec pending_admissions([AdmissionCandidate.t()], [Node.t()]) :: map()
  def pending_admissions(candidates, nodes) when is_list(candidates) and is_list(nodes) do
    candidate_decisions =
      candidates
      |> Enum.map(& &1.id)
      |> Nodes.latest_admission_decisions_for_candidates()

    node_decisions =
      nodes
      |> Enum.map(& &1.id)
      |> Nodes.latest_admission_decisions_for_nodes()

    candidate_node_ids =
      candidates
      |> Enum.map(& &1.node_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    rows =
      candidates
      |> Enum.map(&candidate_row(&1, Map.get(candidate_decisions, &1.id)))
      |> Kernel.++(
        nodes
        |> Enum.filter(&pending_node?/1)
        |> Enum.reject(&MapSet.member?(candidate_node_ids, &1.id))
        |> Enum.map(&node_row(&1, Map.get(node_decisions, &1.id)))
      )
      |> Enum.sort_by(&row_sort_key/1)

    %{
      status: :ok,
      rows: rows,
      count: length(rows),
      pending_count: Enum.count(rows, &pending_admission_row?/1),
      rejected_count: Enum.count(rows, &rejected_admission_row?/1),
      message: nil
    }
  end

  defp candidate_row(%AdmissionCandidate{} = candidate, latest_decision) do
    status = StatusBuilder.candidate_status_map(candidate, latest_decision: latest_decision)

    %{
      kind: :candidate,
      id: candidate.id,
      node_id: candidate.node_id,
      display_label: candidate_display_label(candidate),
      source: candidate.source,
      admission_category: candidate.admission_category,
      target_ref: candidate.target_ref || candidate.endpoint_target,
      observed_at: candidate.last_observed_at,
      status: status
    }
  end

  defp node_row(%Node{} = node, latest_decision) do
    status = StatusBuilder.node_status_map(node, latest_decision: latest_decision)

    %{
      kind: :node,
      id: node.id,
      node_id: node.id,
      display_label: node.display_name || node.hostname || node.id,
      source: :registered_node,
      admission_category: get_in(status, [:admission, :category]),
      target_ref: format_host_port(node.advertise_addr, node.rpc_port),
      observed_at: node.last_heartbeat_at,
      status: status
    }
  end

  defp pending_node?(%Node{state: state}), do: state in [:provisioned, :registered]

  defp pending_admission_row?(%{admission_category: category}),
    do:
      category in @pending_admission_categories or category in @pending_admission_category_strings

  defp rejected_admission_row?(%{admission_category: category}),
    do: category in [:rejected, "rejected"]

  defp candidate_display_label(%AdmissionCandidate{observed_identity: identity} = candidate) do
    [
      map_get(identity, "display_name"),
      map_get(identity, "hostname"),
      map_get(identity, "claimed_node_id"),
      candidate.target_ref,
      candidate.endpoint_target,
      candidate.id
    ]
    |> Enum.find(&present?/1)
  end

  defp row_sort_key(%{observed_at: %DateTime{} = observed_at, display_label: label}) do
    {-DateTime.to_unix(observed_at, :microsecond), to_string(label)}
  end

  defp row_sort_key(%{display_label: label}), do: {0, to_string(label)}

  defp map_get(map, "display_name") when is_map(map),
    do: Map.get(map, "display_name") || Map.get(map, :display_name)

  defp map_get(map, "hostname") when is_map(map),
    do: Map.get(map, "hostname") || Map.get(map, :hostname)

  defp map_get(map, "claimed_node_id") when is_map(map),
    do: Map.get(map, "claimed_node_id") || Map.get(map, :claimed_node_id)

  defp map_get(_map, _key), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp format_host_port(host, port) when is_binary(host) and is_integer(port) do
    if String.contains?(host, ":"),
      do: "[#{host}]:#{port}",
      else: "#{host}:#{port}"
  end

  defp format_host_port(_host, _port), do: nil
end
