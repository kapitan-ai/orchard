defmodule Orchard.ClusterManagement.MemoryBudgetPresenterTest do
  use ExUnit.Case, async: true

  alias Orchard.ClusterManagement.MemoryBudgetPresenter

  defmodule SharedHostnameStub do
    @moduledoc false

    def cluster_snapshot(_opts \\ []) do
      [
        snapshot("other-node-uuid", "other-model"),
        snapshot("inspected-node-uuid", "inspected-model")
      ]
    end

    defp snapshot(node_id, model_ref) do
      %{
        node_metadata: %{
          node_id: node_id,
          display_name: "shared-display",
          hostname: "shared-host.local"
        },
        runtime_memory_budgets: [
          %{
            display_state: :observed,
            model_ref: model_ref,
            mode: "observe",
            budget_available: true,
            headroom_available: true,
            status_code: "ok",
            status_message: "within budget"
          }
        ],
        runtime_memory_budgets_truncated_count: 0
      }
    end
  end

  describe "for_node/2 node matching" do
    test "matches on node_id even when hostname collides across snapshots" do
      node = %{
        id: "inspected-node-uuid",
        display_name: "shared-display",
        hostname: "shared-host.local"
      }

      assert %{runtime_memory_budgets: [%{model_ref: "inspected-model"}]} =
               MemoryBudgetPresenter.for_node(node, SharedHostnameStub)
    end
  end
end
