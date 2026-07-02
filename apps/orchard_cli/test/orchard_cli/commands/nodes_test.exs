defmodule OrchardCLI.Commands.NodesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.ClusterManagement.StatusBuilder
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}
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
      assert msg =~ "inspect"
      assert msg =~ "pending"
      assert msg =~ "admit"
      assert msg =~ "reject"
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
      assert output =~ "-"
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

  describe "inspect" do
    test "json output renders one node with shared status categories" do
      node =
        insert_node!(
          display_name: "inspect-node",
          state: :registered,
          health: :healthy,
          last_heartbeat_at: DateTime.utc_now()
        )

      assert {:ok, output} = NodesCmd.run(["inspect", node.id, "--json"])
      decoded = Jason.decode!(output)

      assert decoded["object"] == "node"
      assert decoded["id"] == node.id
      assert decoded["status"]["object"] == "cluster_management.node_status"
      assert decoded["status"]["admission"]["category"] == "pending_registered"
      assert decoded["status"]["scheduling"]["reason_codes"] == ["node_not_admitted"]
    end

    test "missing node reports not found" do
      assert {:error, message, 1} = NodesCmd.run(["inspect", Ecto.UUID.generate(), "--json"])
      assert message =~ "node not found"
    end
  end

  describe "pending" do
    test "json output renders admission review candidates with shared status" do
      candidate = insert_candidate!(target_ref: "10.0.0.44:50071")

      assert {:ok, output} = NodesCmd.run(["pending", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["object"] == "cluster_management.node_admission_review"
      assert decoded["contract_version"] == "orchard.cluster_management.status.v1"
      assert [listed] = decoded["data"]
      assert listed["id"] == candidate.id
      assert listed["status"]["resource"]["type"] == "admission_candidate"

      assert listed["status"]["scheduling"]["reason_codes"] == [
               "node_not_registered",
               "trust_not_established"
             ]
    end

    test "human output shows empty admission review" do
      assert {:ok, output} = NodesCmd.run(["pending"])
      assert output =~ "No admission candidates pending review."
    end
  end

  describe "admit" do
    test "dry-run json reports blocker and confirmation requirement without mutation" do
      node = insert_node!(state: :registered, display_name: "admit-preview-node")

      assert {:ok, output} = NodesCmd.run(["admit", node.id, "--dry-run", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["object"] == "cluster_management.action_preview"
      assert decoded["action"] == "node_admission.admit"
      assert decoded["target"] == %{"type" => "node", "id" => node.id}
      assert decoded["confirmation_requirements"] == ["requires_yes_flag"]

      assert Enum.map(decoded["blockers"], & &1["code"]) == [
               "trust_not_established",
               "pool_required",
               "policy_required"
             ]

      assert Repo.get!(Node, node.id).state == :registered
    end

    test "json execution without yes returns preview instead of mutating" do
      node = insert_node!(state: :registered, display_name: "admit-needs-yes-node")

      assert {:error, output, 2} =
               NodesCmd.run([
                 "admit",
                 node.id,
                 "--json",
                 "--trust-evidence-ref",
                 "registration-audit:test",
                 "--pool-id",
                 Ecto.UUID.generate(),
                 "--routing-policy-id",
                 Ecto.UUID.generate()
               ])

      decoded = Jason.decode!(output)
      assert decoded["confirmation_requirements"] == ["requires_yes_flag"]
      assert decoded["blockers"] == []
      assert Repo.get!(Node, node.id).state == :registered
    end

    test "yes execution admits a registered node and emits action result json" do
      node = insert_node!(state: :registered, display_name: "admit-execute-node")

      assert {:ok, output} =
               NodesCmd.run([
                 "admit",
                 node.id,
                 "--yes",
                 "--json",
                 "--trust-evidence-ref",
                 "registration-audit:test",
                 "--pool-id",
                 Ecto.UUID.generate(),
                 "--routing-policy-id",
                 Ecto.UUID.generate()
               ])

      decoded = Jason.decode!(output)
      assert decoded["action"] == "node_admission.admitted"
      assert decoded["node"]["id"] == node.id
      assert decoded["node"]["state"] == "admitted"
      assert decoded["audit_log"]["scope"] == "cluster"
      assert Repo.get!(Node, node.id).state == :admitted
    end
  end

  describe "reject" do
    test "dry-run json reports reason and yes confirmation requirements" do
      candidate = insert_candidate!()

      assert {:ok, output} = NodesCmd.run(["reject", candidate.id, "--dry-run", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["action"] == "node_admission.reject"
      assert decoded["target"] == %{"type" => "admission_candidate", "id" => candidate.id}
      assert decoded["confirmation_requirements"] == ["requires_yes_flag", "requires_reason"]
      assert decoded["blockers"] == []
      assert Repo.get!(AdmissionCandidate, candidate.id).admission_category == :pending_observed
    end

    test "json execution without yes returns preview and preserves candidate" do
      candidate = insert_candidate!()

      assert {:error, output, 2} =
               NodesCmd.run(["reject", candidate.id, "--json", "--reason", "identity mismatch"])

      decoded = Jason.decode!(output)
      assert decoded["confirmation_requirements"] == ["requires_yes_flag"]
      assert decoded["blockers"] == []
      assert Repo.get!(AdmissionCandidate, candidate.id).admission_category == :pending_observed
    end

    test "yes execution rejects candidate and records a decision" do
      candidate = insert_candidate!()

      assert {:ok, output} =
               NodesCmd.run([
                 "reject",
                 candidate.id,
                 "--yes",
                 "--json",
                 "--reason",
                 "identity mismatch"
               ])

      decoded = Jason.decode!(output)
      assert decoded["action"] == "node_admission.rejected"
      assert decoded["candidate"]["id"] == candidate.id
      assert decoded["candidate"]["admission_category"] == "rejected"
      assert decoded["decision"]["reason"] == "identity mismatch"
      assert decoded["audit_log"]["scope"] == "cluster"
      assert Repo.get!(AdmissionCandidate, candidate.id).admission_category == :rejected

      assert %AdmissionDecision{decision: :rejected} =
               Repo.get_by(AdmissionDecision, candidate_id: candidate.id)
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

  defp insert_candidate!(attrs \\ []) do
    unique = System.unique_integer([:positive])

    defaults = %{
      source: :runtime_endpoint_observation,
      admission_category: :pending_observed,
      observed_identity: %{
        "claimed_node_id" => Ecto.UUID.generate(),
        "display_name" => "candidate-#{unique}",
        "hostname" => "candidate-#{unique}.local"
      },
      target_ref: "10.0.0.#{rem(unique, 200) + 1}:50071",
      endpoint_transport: :grpc,
      endpoint_target: "10.0.0.#{rem(unique, 200) + 1}:50071",
      inventory: %{"capabilities" => %{}},
      compatibility_evidence: %{"health" => "healthy"},
      last_observed_at: DateTime.utc_now()
    }

    %AdmissionCandidate{}
    |> AdmissionCandidate.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end
end
