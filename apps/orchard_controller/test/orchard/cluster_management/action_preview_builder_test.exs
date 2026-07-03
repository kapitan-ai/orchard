defmodule Orchard.ClusterManagement.ActionPreviewBuilderTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.ClusterManagement.{ActionPreview, ActionPreviewBuilder}
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes.Node
  alias Orchard.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    on_exit(fn -> Application.delete_env(:orchard_controller, :control_plane) end)

    :ok
  end

  test "SPEC.md §7.3 lifecycle previews are side-effect-free and use shared ActionPreview" do
    node = insert_node!(state: :active)

    preview = ActionPreviewBuilder.node_lifecycle(:drain, node.id)
    map = ActionPreview.to_map(preview)

    assert map.object == "cluster_management.action_preview"
    assert map.action == "node_lifecycle.drain"
    assert map.target == %{type: "node", id: node.id}
    assert map.active_request_count == nil
    assert map.consequence_codes == ["existing_requests_continue_until_deadline"]

    assert map.confirmation_requirements == [
             "requires_yes_flag",
             "requires_drain_consequence_acknowledgement"
           ]

    assert map.expected_transition == %{from: "active", to: "draining"}
    assert Repo.get!(Node, node.id).state == :active

    assert 0 =
             AuditLog
             |> where([audit_log], audit_log.target_id == ^node.id)
             |> Repo.aggregate(:count)
  end

  test "decommission preview includes destructive confirmation requirements and consequences" do
    node = insert_node!(state: :active)

    preview = ActionPreviewBuilder.node_lifecycle(:decommission, node.id)
    map = ActionPreview.to_map(preview)

    assert map.action == "node_lifecycle.decommission"

    assert map.consequence_codes == [
             "future_scheduling_revoked",
             "no_rejoin_with_same_node_id"
           ]

    assert map.confirmation_requirements == [
             "requires_yes_flag",
             "requires_typed_node_id",
             "requires_decommission_consequence_acknowledgement"
           ]

    assert map.expected_transition == %{from: "active", to: "decommissioning"}
  end

  test "SPEC.md §4.4 maintenance preview blocks draining nodes until drain completion is verified" do
    node = insert_node!(state: :draining)

    preview = ActionPreviewBuilder.node_lifecycle(:maintenance, node.id)
    map = ActionPreview.to_map(preview)

    assert map.action == "node_lifecycle.maintenance"
    assert Enum.map(map.blockers, & &1.code) == ["drain_completion_unverified"]
    assert map.expected_transition == %{from: "draining", to: "maintenance"}
    assert Repo.get!(Node, node.id).state == :draining
  end

  test "missing lifecycle target returns a node_not_found preview" do
    node_id = Ecto.UUID.generate()

    preview = ActionPreviewBuilder.node_lifecycle(:cordon, node_id)
    map = ActionPreview.to_map(preview)

    assert map.action == "node_lifecycle.cordon"
    assert map.target == %{type: "node", id: node_id}
    assert Enum.map(map.blockers, & &1.code) == ["node_not_found"]
  end

  test "standby control plane adds a write-path blocker" do
    Application.put_env(:orchard_controller, :control_plane, role: :standby)
    node = insert_node!(state: :active)

    preview = ActionPreviewBuilder.node_lifecycle(:cordon, node.id)

    assert "ha_standby_write_blocked" in Enum.map(preview.blockers, & &1.code)
    assert Repo.get!(Node, node.id).state == :active
  end

  defp insert_node!(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      id: Ecto.UUID.generate(),
      hostname: "host-#{unique}.local",
      display_name: "node-#{unique}",
      advertise_addr: "127.0.0.#{rem(unique, 255)}",
      rpc_port: 50_000 + rem(unique, 15_000),
      state: :active,
      health: :healthy,
      capabilities: %{},
      agent_version: "0.1.0",
      last_heartbeat_at: DateTime.utc_now()
    }

    %Node{}
    |> Node.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end
end
