defmodule Orchard.Nodes.LifecycleTest.FailingAuditLog do
  @moduledoc false

  import Ecto.Changeset

  alias Orchard.Governance.AuditLog

  @spec changeset(AuditLog.t(), map()) :: Ecto.Changeset.t()
  def changeset(%AuditLog{} = audit_log, _attrs) do
    audit_log
    |> change()
    |> add_error(:action, "forced lifecycle audit failure")
  end
end

defmodule Orchard.Nodes.LifecycleTest.RecordingQueueManager do
  @moduledoc false

  def clear_capacity_sources(sources, opts) do
    send(
      Process.get(:lifecycle_queue_observer),
      {:queue_sources_cleared, sources, opts, Orchard.Repo.in_transaction?()}
    )

    :ok
  end
end

defmodule Orchard.Nodes.LifecycleTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes.Lifecycle
  alias Orchard.Nodes.Node
  alias Orchard.Repo

  @queue_manager Orchard.Nodes.LifecycleTest.RecordingQueueManager

  setup do
    Process.put(:lifecycle_queue_observer, self())
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "SPEC.md §4.3 lifecycle actions transition nodes and write cluster audit" do
    cases = [
      {:cordon, :active, :cordoned, "node_lifecycle.cordoned"},
      {:uncordon, :cordoned, :active, "node_lifecycle.uncordoned"},
      {:drain, :cordoned, :draining, "node_lifecycle.drain_started"},
      {:cancel_drain, :draining, :cordoned, "node_lifecycle.drain_cancelled"},
      {:resume, :maintenance, :active, "node_lifecycle.resumed"},
      {:decommission, :admitted, :decommissioning, "node_lifecycle.decommission_started"},
      {:decommission, :draining, :decommissioning, "node_lifecycle.decommission_started"}
    ]

    for {action, from_state, to_state, audit_action} <- cases do
      node = insert_node!(state: from_state, display_name: "lifecycle-#{action}-#{from_state}")

      assert {:ok, %{node: updated, audit_log: audit_log}} =
               Lifecycle.execute(
                 action,
                 node.id,
                 %{reason: "operator requested"},
                 queue_manager: @queue_manager
               )

      assert_receive {:queue_sources_cleared, sources, opts, false}

      assert Enum.sort(sources) ==
               Enum.sort([
                 {:node, node.id},
                 {:node, node.id, :placement},
                 {:node, node.id, :cold}
               ])

      assert opts[:promote?]
      assert updated.state == to_state
      assert Repo.get!(Node, node.id).state == to_state
      assert audit_log.scope == "cluster"
      assert audit_log.action == audit_action
      assert audit_log.target_type == "node"
      assert audit_log.target_id == node.id
      assert audit_log.payload["from_state"] == Atom.to_string(from_state)
      assert audit_log.payload["to_state"] == Atom.to_string(to_state)
      assert audit_log.payload["reason"] == "operator requested"
    end
  end

  test "SPEC.md §7.3 execution revalidates lifecycle state at mutation time" do
    node = insert_node!(state: :active)

    node
    |> Ecto.Changeset.change(state: :cordoned)
    |> Repo.update!()

    assert {:error, :node_not_active} =
             Lifecycle.execute(:cordon, node.id, %{}, queue_manager: @queue_manager)

    refute_receive {:queue_sources_cleared, _sources, _opts, _in_transaction?}
    assert Repo.get!(Node, node.id).state == :cordoned
  end

  test "SPEC.md §4.3 disallowed lifecycle transitions do not mutate" do
    cases = [
      {:cordon, :registered, :node_not_admitted},
      {:drain, :draining, :drain_already_running},
      {:maintenance, :active, :maintenance_requires_drain},
      {:maintenance, :draining, :drain_completion_unverified}
    ]

    for {action, state, reason} <- cases do
      node = insert_node!(state: state, display_name: "blocked-#{action}-from-#{state}")

      assert {:error, ^reason} = Lifecycle.execute(action, node.id)
      assert Repo.get!(Node, node.id).state == state
    end
  end

  test "OpenSpec cancel drain scenario reports drain_not_running outside draining" do
    for state <- [:active, :cordoned, :maintenance] do
      node = insert_node!(state: state, display_name: "cancel-drain-not-running-#{state}")

      assert Lifecycle.blocker_codes(:cancel_drain, node) == [:drain_not_running]
      assert {:error, :drain_not_running} = Lifecycle.execute(:cancel_drain, node.id)
      assert Repo.get!(Node, node.id).state == state
    end
  end

  test "OpenSpec drain completes between preview and execution revalidates cancel drain" do
    node = insert_node!(state: :draining)

    assert Lifecycle.blocker_codes(:cancel_drain, node) == []

    node
    |> Ecto.Changeset.change(state: :cordoned)
    |> Repo.update!()

    assert {:error, :drain_not_running} = Lifecycle.execute(:cancel_drain, node.id)
    assert Repo.get!(Node, node.id).state == :cordoned
  end

  test "SPEC.md §4.4 resume blocks unhealthy and unreachable nodes" do
    unreachable = insert_node!(state: :maintenance, health: :unreachable)
    unhealthy = insert_node!(state: :maintenance, health: :unhealthy)

    assert {:error, :node_unreachable} = Lifecycle.execute(:resume, unreachable.id)
    assert {:error, :node_unhealthy} = Lifecycle.execute(:resume, unhealthy.id)
    assert Repo.get!(Node, unreachable.id).state == :maintenance
    assert Repo.get!(Node, unhealthy.id).state == :maintenance
  end

  test "audit persistence failure rolls back lifecycle state" do
    node = insert_node!(state: :active)

    Application.put_env(
      :orchard_controller,
      :governance_audit_log_impl,
      Orchard.Nodes.LifecycleTest.FailingAuditLog
    )

    on_exit(fn -> Application.delete_env(:orchard_controller, :governance_audit_log_impl) end)

    assert {:error, %Ecto.Changeset{}} =
             Lifecycle.execute(:cordon, node.id, %{}, queue_manager: @queue_manager)

    refute_receive {:queue_sources_cleared, _sources, _opts, _in_transaction?}
    assert Repo.get!(Node, node.id).state == :active

    assert 0 =
             AuditLog
             |> where([audit_log], audit_log.target_id == ^node.id)
             |> Repo.aggregate(:count)
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
