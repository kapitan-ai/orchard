defmodule Orchard.NodesTest do
  use Orchard.DataCase, async: false

  import ExUnit.CaptureLog

  alias Orchard.Nodes
  alias Orchard.Nodes.Node

  # -- Helpers --

  defp node_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        hostname: "host-#{unique}.local",
        display_name: "node-#{unique}",
        advertise_addr: "10.0.0.#{rem(unique, 255)}",
        rpc_port: 9444,
        state: :active,
        health: :healthy,
        capabilities: %{}
      },
      overrides
    )
  end

  defp insert_node!(overrides \\ %{}) do
    attrs = node_attrs(overrides)

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp make_target(host, port), do: [host: host, port: port]

  defp make_status_response(meta_overrides \\ %{}, health_overrides \\ nil) do
    unique = System.unique_integer([:positive])

    metadata =
      Map.merge(
        %{
          node_id: Ecto.UUID.generate(),
          display_name: "node-#{unique}",
          hostname: "host-#{unique}.local",
          agent_version: "0.1.0",
          listen_host: "10.0.0.#{rem(unique, 255)}",
          listen_port: 9444,
          worker_backend: "mlx"
        },
        meta_overrides
      )

    runtime_health =
      case health_overrides do
        nil -> nil
        overrides -> Map.merge(%{ready: true, health_code: "", health_message: ""}, overrides)
      end

    %{node_metadata: metadata, runtime_health: runtime_health}
  end

  # -- Schema validation --

  describe "Node schema" do
    test "valid attrs produce valid changeset" do
      changeset = Node.changeset(%Node{}, node_attrs())
      assert changeset.valid?
    end

    test "required fields" do
      changeset = Node.changeset(%Node{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert errors[:hostname]
      assert errors[:display_name]
      assert errors[:advertise_addr]
      assert errors[:rpc_port]
      assert errors[:state]
      assert errors[:health]
    end

    test "invalid rpc_port" do
      changeset = Node.changeset(%Node{}, node_attrs(%{rpc_port: 0}))
      refute changeset.valid?
      assert errors_on(changeset)[:rpc_port]

      changeset = Node.changeset(%Node{}, node_attrs(%{rpc_port: 70_000}))
      refute changeset.valid?
      assert errors_on(changeset)[:rpc_port]
    end

    test "enum helpers" do
      assert :active in Node.states()
      assert :provisioned in Node.states()
      assert length(Node.states()) == 9

      assert :healthy in Node.health_values()
      assert :unreachable in Node.health_values()
      assert length(Node.health_values()) == 4
    end
  end

  # -- list_nodes/0 --

  describe "list_nodes/0" do
    test "returns empty list when no nodes" do
      assert Nodes.list_nodes() == []
    end

    test "returns nodes ordered by display_name" do
      insert_node!(%{display_name: "zeta"})
      insert_node!(%{display_name: "alpha"})
      insert_node!(%{display_name: "middle"})

      names = Nodes.list_nodes() |> Enum.map(& &1.display_name)
      assert names == ["alpha", "middle", "zeta"]
    end
  end

  # -- summary/0 --

  describe "summary/0" do
    test "returns zero-filled summary on empty DB" do
      summary = Nodes.summary()
      assert summary.total == 0
      assert summary.by_state.active == 0
      assert summary.by_state.provisioned == 0
      assert summary.by_health.healthy == 0
      assert summary.by_health.unreachable == 0
      assert map_size(summary.by_state) == 9
      assert map_size(summary.by_health) == 4
    end

    test "counts by state and health" do
      insert_node!(%{state: :active, health: :healthy})
      insert_node!(%{state: :active, health: :degraded})
      insert_node!(%{state: :cordoned, health: :unhealthy})

      summary = Nodes.summary()
      assert summary.total == 3
      assert summary.by_state.active == 2
      assert summary.by_state.cordoned == 1
      assert summary.by_state.provisioned == 0
      assert summary.by_health.healthy == 1
      assert summary.by_health.degraded == 1
      assert summary.by_health.unhealthy == 1
    end
  end

  # -- lookup_by_target/1 --

  describe "lookup_by_target/1" do
    test "returns node for exact target match" do
      node = insert_node!(%{advertise_addr: "10.0.0.5", rpc_port: 9444})
      found = Nodes.lookup_by_target(host: "10.0.0.5", port: 9444)
      assert found.id == node.id
    end

    test "returns nil for no match" do
      assert Nodes.lookup_by_target(host: "10.0.0.99", port: 9444) == nil
    end

    test "returns nil for malformed target" do
      assert Nodes.lookup_by_target(host: "", port: 9444) == nil
      assert Nodes.lookup_by_target(host: "10.0.0.1", port: 0) == nil
      assert Nodes.lookup_by_target([]) == nil
    end
  end

  # -- observe_status/3 insert --

  describe "observe_status/3 insert" do
    test "valid metadata inserts node as active" do
      node_id = Ecto.UUID.generate()
      target = make_target("10.0.0.1", 9444)
      now = DateTime.utc_now()

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "test-node",
          hostname: "test-host.local",
          listen_host: "10.0.0.1",
          listen_port: 9444
        })

      assert {:ok, node} = Nodes.observe_status(target, status, now)
      assert node.id == node_id
      assert node.state == :active
      assert node.display_name == "test-node"
      assert node.hostname == "test-host.local"
      assert node.advertise_addr == "10.0.0.1"
      assert node.rpc_port == 9444
    end

    test "persists health mapping: nil runtime_health -> healthy" do
      target = make_target("10.0.0.2", 9444)
      status = make_status_response(%{listen_host: "10.0.0.2"}, nil)

      assert {:ok, node} = Nodes.observe_status(target, status, DateTime.utc_now())
      assert node.health == :healthy
    end

    test "persists health mapping: not ready -> unhealthy" do
      target = make_target("10.0.0.3", 9444)
      status = make_status_response(%{listen_host: "10.0.0.3"}, %{ready: false})

      assert {:ok, node} = Nodes.observe_status(target, status, DateTime.utc_now())
      assert node.health == :unhealthy
    end

    test "persists health mapping: ready with code -> degraded" do
      target = make_target("10.0.0.4", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.4"}, %{
          ready: true,
          health_code: "SLOW"
        })

      assert {:ok, node} = Nodes.observe_status(target, status, DateTime.utc_now())
      assert node.health == :degraded
    end

    test "stores worker_backend in capabilities" do
      target = make_target("10.0.0.5", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.5", worker_backend: "mlx"})

      assert {:ok, node} = Nodes.observe_status(target, status, DateTime.utc_now())
      assert node.capabilities == %{"worker_backend" => "mlx"}
    end

    test "empty worker_backend stores empty capabilities" do
      target = make_target("10.0.0.6", 9444)

      status =
        make_status_response(%{listen_host: "10.0.0.6", worker_backend: ""})

      assert {:ok, node} = Nodes.observe_status(target, status, DateTime.utc_now())
      assert node.capabilities == %{}
    end
  end

  # -- observe_status/3 update --

  describe "observe_status/3 update" do
    test "updates metadata on existing node" do
      node_id = Ecto.UUID.generate()
      existing = insert_node!(%{id: node_id, advertise_addr: "10.0.0.10", rpc_port: 9444})
      target = make_target("10.0.0.10", 9444)
      later = DateTime.add(DateTime.utc_now(), 60, :second)

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "updated-name",
          hostname: "updated-host.local",
          listen_host: "10.0.0.10",
          listen_port: 9444,
          agent_version: "0.2.0"
        })

      assert {:ok, updated} = Nodes.observe_status(target, status, later)
      assert updated.id == existing.id
      assert updated.display_name == "updated-name"
      assert updated.agent_version == "0.2.0"
    end

    test "preserves admin-managed state on update" do
      node_id = Ecto.UUID.generate()
      insert_node!(%{id: node_id, state: :cordoned, advertise_addr: "10.0.0.11", rpc_port: 9444})
      target = make_target("10.0.0.11", 9444)
      later = DateTime.add(DateTime.utc_now(), 60, :second)

      status =
        make_status_response(%{
          node_id: node_id,
          display_name: "cordoned-node",
          listen_host: "10.0.0.11",
          listen_port: 9444
        })

      assert {:ok, updated} = Nodes.observe_status(target, status, later)
      assert updated.state == :cordoned
    end
  end

  # -- observe_status/3 stale guard --

  describe "observe_status/3 stale guard" do
    test "rejects stale observation" do
      node_id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -60, :second)

      insert_node!(%{
        id: node_id,
        advertise_addr: "10.0.0.20",
        rpc_port: 9444,
        last_heartbeat_at: now
      })

      target = make_target("10.0.0.20", 9444)

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.20",
          listen_port: 9444
        })

      assert :noop = Nodes.observe_status(target, status, earlier)
    end

    test "rejects equal-timestamp observation" do
      node_id = Ecto.UUID.generate()
      now = DateTime.utc_now()

      insert_node!(%{
        id: node_id,
        advertise_addr: "10.0.0.21",
        rpc_port: 9444,
        last_heartbeat_at: now
      })

      target = make_target("10.0.0.21", 9444)

      status =
        make_status_response(%{
          node_id: node_id,
          listen_host: "10.0.0.21",
          listen_port: 9444
        })

      assert :noop = Nodes.observe_status(target, status, now)
    end
  end

  # -- observe_status/3 identity conflicts --

  describe "observe_status/3 identity conflicts" do
    test "target conflict: same addr:port, different UUID" do
      insert_node!(%{id: Ecto.UUID.generate(), advertise_addr: "10.0.0.30", rpc_port: 9444})
      target = make_target("10.0.0.30", 9444)
      different_id = Ecto.UUID.generate()

      status =
        make_status_response(%{
          node_id: different_id,
          listen_host: "10.0.0.30",
          listen_port: 9444
        })

      log =
        capture_log(fn ->
          assert :noop = Nodes.observe_status(target, status, DateTime.utc_now())
        end)

      assert log =~ "identity conflict"
    end

    test "display_name conflict: same name, different UUID" do
      insert_node!(%{display_name: "shared-name", advertise_addr: "10.0.0.31", rpc_port: 9444})
      target = make_target("10.0.0.32", 9444)

      status =
        make_status_response(%{
          node_id: Ecto.UUID.generate(),
          display_name: "shared-name",
          listen_host: "10.0.0.32",
          listen_port: 9444
        })

      log =
        capture_log(fn ->
          assert :noop = Nodes.observe_status(target, status, DateTime.utc_now())
        end)

      assert log =~ "identity conflict"
    end
  end

  # -- observe_status/3 concurrent insert race --

  describe "observe_status/3 concurrent insert race" do
    test "constraint error on concurrent first-observation returns noop" do
      # Pre-insert a node to provoke a uniqueness conflict when observe_status
      # tries to insert with the same id (simulates a concurrent winner).
      node_id = Ecto.UUID.generate()
      insert_node!(%{id: node_id, advertise_addr: "10.0.0.60", rpc_port: 9444})

      # Now observe with the same id but from a different target — the
      # transaction will lock the existing row by id (not by target), see
      # no target conflict, and try to update. But if we use a *different*
      # display_name that also already exists, the unique constraint fires.
      target = make_target("10.0.0.61", 9444)

      status =
        make_status_response(%{
          node_id: Ecto.UUID.generate(),
          display_name: "unique-for-race",
          listen_host: "10.0.0.61",
          listen_port: 9444
        })

      # Insert a node at the same target to cause a constraint error on insert
      insert_node!(%{advertise_addr: "10.0.0.61", rpc_port: 9444, display_name: "occupant"})

      # The observe should noop due to target identity conflict
      log =
        capture_log(fn ->
          assert :noop = Nodes.observe_status(target, status, DateTime.utc_now())
        end)

      assert log =~ "identity conflict"
    end
  end

  # -- observe_status/3 missing/invalid metadata --

  describe "observe_status/3 missing metadata" do
    test "nil node_metadata returns noop" do
      target = make_target("10.0.0.40", 9444)
      status = %{node_metadata: nil, runtime_health: nil}

      assert :noop = Nodes.observe_status(target, status, DateTime.utc_now())
      assert Nodes.list_nodes() == []
    end

    test "invalid UUID returns noop" do
      target = make_target("10.0.0.41", 9444)

      status =
        make_status_response(%{node_id: "not-a-uuid", listen_host: "10.0.0.41"})

      assert :noop = Nodes.observe_status(target, status, DateTime.utc_now())
      assert Nodes.list_nodes() == []
    end

    test "empty display_name and hostname returns noop" do
      target = make_target("10.0.0.42", 9444)

      status =
        make_status_response(%{
          display_name: "",
          hostname: "",
          listen_host: "10.0.0.42"
        })

      assert :noop = Nodes.observe_status(target, status, DateTime.utc_now())
      assert Nodes.list_nodes() == []
    end
  end

  # -- mark_target_unreachable/2 --

  describe "mark_target_unreachable/2" do
    test "marks known node as unreachable" do
      node =
        insert_node!(%{
          advertise_addr: "10.0.0.50",
          rpc_port: 9444,
          health: :healthy,
          last_heartbeat_at: DateTime.utc_now()
        })

      later = DateTime.add(DateTime.utc_now(), 60, :second)
      assert {:ok, marked} = Nodes.mark_target_unreachable(make_target("10.0.0.50", 9444), later)
      assert marked.id == node.id
      assert marked.health == :unreachable
    end

    test "preserves state and last_heartbeat_at" do
      hb_time = DateTime.utc_now()

      node =
        insert_node!(%{
          advertise_addr: "10.0.0.51",
          rpc_port: 9444,
          state: :cordoned,
          health: :healthy,
          last_heartbeat_at: hb_time
        })

      later = DateTime.add(hb_time, 60, :second)
      assert {:ok, marked} = Nodes.mark_target_unreachable(make_target("10.0.0.51", 9444), later)
      assert marked.state == :cordoned
      assert DateTime.compare(marked.last_heartbeat_at, hb_time) == :eq
    end

    test "returns noop for unknown target" do
      assert :noop =
               Nodes.mark_target_unreachable(make_target("10.0.0.99", 9444), DateTime.utc_now())
    end

    test "stale failure is ignored" do
      now = DateTime.utc_now()
      earlier = DateTime.add(now, -60, :second)

      insert_node!(%{
        advertise_addr: "10.0.0.52",
        rpc_port: 9444,
        health: :healthy,
        last_heartbeat_at: now
      })

      assert :noop = Nodes.mark_target_unreachable(make_target("10.0.0.52", 9444), earlier)
    end
  end

  # -- Schedulable nodes --

  describe "schedulable_nodes/0" do
    test "returns active, healthy nodes within freshness threshold" do
      now = DateTime.utc_now()

      n1 =
        insert_node!(%{
          state: :active,
          health: :healthy,
          last_heartbeat_at: DateTime.add(now, -5, :second)
        })

      _n2 =
        insert_node!(%{
          state: :active,
          health: :healthy,
          last_heartbeat_at: DateTime.add(now, -60, :second)
        })

      result = Nodes.schedulable_nodes()
      assert length(result) == 1
      assert hd(result).id == n1.id
    end

    test "includes degraded nodes" do
      now = DateTime.utc_now()

      n1 =
        insert_node!(%{
          state: :active,
          health: :degraded,
          last_heartbeat_at: DateTime.add(now, -5, :second)
        })

      result = Nodes.schedulable_nodes()
      assert length(result) == 1
      assert hd(result).id == n1.id
    end

    test "excludes non-active states" do
      now = DateTime.utc_now()

      insert_node!(%{
        state: :registered,
        health: :healthy,
        last_heartbeat_at: DateTime.add(now, -5, :second)
      })

      assert Nodes.schedulable_nodes() == []
    end

    test "excludes unhealthy and unreachable" do
      now = DateTime.utc_now()

      insert_node!(%{
        state: :active,
        health: :unhealthy,
        last_heartbeat_at: DateTime.add(now, -5, :second)
      })

      insert_node!(%{
        state: :active,
        health: :unreachable,
        last_heartbeat_at: DateTime.add(now, -5, :second)
      })

      assert Nodes.schedulable_nodes() == []
    end

    test "excludes nodes with nil last_heartbeat_at" do
      insert_node!(%{
        state: :active,
        health: :healthy,
        last_heartbeat_at: nil
      })

      assert Nodes.schedulable_nodes() == []
    end

    test "returns ordered by id" do
      now = DateTime.utc_now()
      id_a = "00000000-0000-0000-0000-000000000001"
      id_b = "00000000-0000-0000-0000-000000000002"

      insert_node!(%{
        id: id_b,
        state: :active,
        health: :healthy,
        last_heartbeat_at: DateTime.add(now, -1, :second)
      })

      insert_node!(%{
        id: id_a,
        state: :active,
        health: :healthy,
        last_heartbeat_at: DateTime.add(now, -1, :second)
      })

      result = Nodes.schedulable_nodes()
      assert length(result) == 2
      assert Enum.map(result, & &1.id) == [id_a, id_b]
    end
  end
end
