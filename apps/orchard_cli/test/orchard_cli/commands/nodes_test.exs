defmodule OrchardCLI.Commands.NodesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.ClusterManagement.StatusBuilder
  alias Orchard.Nodes.Node
  alias Orchard.Repo
  alias OrchardCLI.Commands.Nodes, as: NodesCmd

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Help and usage
  # ---------------------------------------------------------------------------

  describe "help and usage" do
    test "group usage on missing subcommand" do
      assert {:error, msg, 1} = NodesCmd.run([])
      assert msg =~ "orchardctl nodes"
      assert msg =~ "list"
    end

    test "--help returns group usage" do
      assert {:ok, msg} = NodesCmd.run(["--help"])
      assert msg =~ "orchardctl nodes"
    end

    test "help returns group usage" do
      assert {:ok, msg} = NodesCmd.run(["help"])
      assert msg =~ "orchardctl nodes"
    end

    test "list --help returns list usage" do
      assert {:ok, msg} = NodesCmd.run(["list", "--help"])
      assert msg =~ "orchardctl nodes list"
    end

    test "unknown subcommand returns usage" do
      assert {:error, msg, 1} = NodesCmd.run(["unknown"])
      assert msg =~ "orchardctl nodes"
    end
  end

  # ---------------------------------------------------------------------------
  # List command
  # ---------------------------------------------------------------------------

  describe "list" do
    test "empty output shows zero summary and empty message" do
      assert {:ok, output} = NodesCmd.run(["list"])

      assert output =~ "Summary: total=0 healthy=0 degraded=0 unhealthy=0 unreachable=0"
      assert output =~ "No nodes registered."
    end

    test "populated table renders inserted node fields" do
      now = DateTime.utc_now()

      insert_node!(
        display_name: "test-node-alpha",
        hostname: "alpha.local",
        state: :active,
        health: :healthy,
        agent_version: "0.2.0",
        last_heartbeat_at: now
      )

      assert {:ok, output} = NodesCmd.run(["list"])

      assert output =~ "Summary: total=1 healthy=1"
      assert output =~ "NODE ID"
      assert output =~ "DISPLAY NAME"
      assert output =~ "test-node-alpha"
      assert output =~ "alpha.local"
      assert output =~ "active"
      assert output =~ "healthy"
      assert output =~ "0.2.0"
      assert output =~ DateTime.to_iso8601(now)
    end

    test "nil last_heartbeat_at and agent_version render dash" do
      insert_node!(
        display_name: "no-heartbeat-node",
        last_heartbeat_at: nil,
        agent_version: nil
      )

      assert {:ok, output} = NodesCmd.run(["list"])

      assert output =~ "no-heartbeat-node"
      # Two dashes: one for last_seen, one for agent_version
      assert output =~ "\u2014"
    end

    test "multiple nodes render in table" do
      insert_node!(display_name: "node-a", health: :healthy)
      insert_node!(display_name: "node-b", health: :degraded)
      insert_node!(display_name: "node-c", health: :unhealthy)

      assert {:ok, output} = NodesCmd.run(["list"])

      assert output =~ "Summary: total=3 healthy=1 degraded=1 unhealthy=1"
      assert output =~ "node-a"
      assert output =~ "node-b"
      assert output =~ "node-c"
    end

    test "unreachable node appears in summary and table" do
      insert_node!(display_name: "ghost-node", health: :unreachable)

      assert {:ok, output} = NodesCmd.run(["list"])

      assert output =~ "Summary: total=1 healthy=0 degraded=0 unhealthy=0 unreachable=1"
      assert output =~ "ghost-node"
      assert output =~ "unreachable"
    end

    test "json output derives status data from shared cluster management structures" do
      node =
        insert_node!(
          display_name: "json-node",
          state: :registered,
          health: :healthy,
          last_heartbeat_at: DateTime.utc_now()
        )

      assert {:ok, output} = NodesCmd.run(["list", "--json"])
      decoded = Jason.decode!(output)
      expected_status = StatusBuilder.node_status_map(node) |> Jason.encode!() |> Jason.decode!()

      assert decoded["object"] == "cluster_management.node_status_list"
      assert decoded["contract_version"] == "orchard.cluster_management.status.v1"
      assert decoded["data"] == [expected_status]

      assert get_in(decoded, ["data", Access.at(0), "scheduling", "reason_codes"]) == [
               "node_not_admitted"
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

    merged = Map.merge(defaults, Map.new(attrs))

    %Node{}
    |> Node.changeset(merged)
    |> Repo.insert!()
  end
end
