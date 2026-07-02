defmodule OrchardConsole.NodesPageData do
  @moduledoc """
  Builds Console nodes page data from shared cluster-management status structures.
  """

  alias Orchard.ClusterManagement.StatusBuilder

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
end
