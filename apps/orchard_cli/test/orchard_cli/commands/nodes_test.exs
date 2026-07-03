defmodule OrchardCLI.Commands.NodesTest.FailingAuditLog do
  @moduledoc false

  import Ecto.Changeset

  alias Orchard.Governance.AuditLog

  @spec changeset(AuditLog.t(), map()) :: Ecto.Changeset.t()
  def changeset(%AuditLog{} = audit_log, _attrs) do
    audit_log
    |> change()
    |> add_error(:action, "forced audit persistence failure")
  end
end

defmodule OrchardCLI.Commands.NodesTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.ClusterManagement.StatusBuilder
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}
  alias Orchard.Repo
  alias OrchardCLI.Commands.Nodes, as: NodesCmd
  alias OrchardCLI.Commands.NodesTest.FailingAuditLog

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
      assert msg =~ "cordon"
      assert msg =~ "uncordon"
      assert msg =~ "drain"
      assert msg =~ "maintenance"
      assert msg =~ "resume"
      assert msg =~ "decommission"
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

  describe "help flag on parsed commands" do
    test "inspect --help with a node id prints usage to stdout with success" do
      assert {:ok, msg} = NodesCmd.run(["inspect", Ecto.UUID.generate(), "--help"])
      assert msg =~ "orchardctl nodes inspect"
    end

    test "pending --json --help prints usage to stdout with success" do
      assert {:ok, msg} = NodesCmd.run(["pending", "--json", "--help"])
      assert msg =~ "orchardctl nodes pending"
    end

    test "admit --help with a node id prints usage to stdout with success" do
      assert {:ok, msg} = NodesCmd.run(["admit", Ecto.UUID.generate(), "--help"])
      assert msg =~ "orchardctl nodes admit"
    end

    test "reject --help with a target id prints usage to stdout with success" do
      assert {:ok, msg} = NodesCmd.run(["reject", Ecto.UUID.generate(), "--help"])
      assert msg =~ "orchardctl nodes reject"
    end

    test "lifecycle --help with a node id prints usage to stdout with success" do
      for command <- ~w(cordon uncordon drain maintenance resume decommission) do
        assert {:ok, msg} = NodesCmd.run([command, Ecto.UUID.generate(), "--help"])
        assert msg =~ "orchardctl nodes #{command}"
      end
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

    test "unknown option reports the flag without doubled dashes" do
      assert {:error, message, 2} =
               NodesCmd.run(["inspect", Ecto.UUID.generate(), "--bogus"])

      assert message == "Unknown option: --bogus"
      refute message =~ "----"
    end

    test "degrades to not found when the controller repo is unavailable" do
      node = insert_node!(display_name: "inspect-repo-off-node")

      with_repo_unavailable(fn ->
        assert {:error, message, 1} = NodesCmd.run(["inspect", node.id, "--json"])
        assert message =~ "node not found"
      end)
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

    test "json output lists pending and rejected candidates but omits admitted" do
      pending = insert_candidate!(admission_category: :pending_observed)
      rejected = insert_candidate!(admission_category: :rejected)
      admitted = insert_candidate!(admission_category: :admitted)

      assert {:ok, output} = NodesCmd.run(["pending", "--json"])
      decoded = Jason.decode!(output)
      ids = Enum.map(decoded["data"], & &1["id"])

      assert pending.id in ids
      assert rejected.id in ids
      refute admitted.id in ids
      refute Enum.any?(decoded["data"], &(&1["admission_category"] == "admitted"))
    end

    test "human output omits admitted candidates from review scope" do
      pending = insert_candidate!(admission_category: :pending_observed)
      admitted = insert_candidate!(admission_category: :admitted)

      assert {:ok, output} = NodesCmd.run(["pending"])

      assert output =~ pending.id
      refute output =~ admitted.id
      refute output =~ "admitted"
    end

    test "degrades to empty review when the controller repo is unavailable" do
      insert_candidate!()

      with_repo_unavailable(fn ->
        assert {:ok, output} = NodesCmd.run(["pending"])
        assert output =~ "No admission candidates pending review."

        assert {:ok, json} = NodesCmd.run(["pending", "--json"])
        assert Jason.decode!(json)["data"] == []
      end)
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

    test "dry-run degrades to a not-found preview when the controller repo is unavailable" do
      node = insert_node!(state: :registered, display_name: "admit-dry-run-repo-off")

      with_repo_unavailable(fn ->
        assert {:ok, output} = NodesCmd.run(["admit", node.id, "--dry-run", "--json"])
        decoded = Jason.decode!(output)

        assert decoded["action"] == "node_admission.admit"
        assert decoded["target"] == %{"type" => "node", "id" => node.id}
        assert Enum.map(decoded["blockers"], & &1["code"]) == ["node_not_found"]
      end)

      assert Repo.get!(Node, node.id).state == :registered
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

    test "yes without reason reports the missing reason rather than a missing --yes" do
      candidate = insert_candidate!()

      assert {:error, output, 2} = NodesCmd.run(["reject", candidate.id, "--yes"])

      assert output =~ "requires a nonblank --reason before execution"
      refute output =~ "requires --yes before execution"
      assert output =~ "requires_reason"
      assert Repo.get!(AdmissionCandidate, candidate.id).admission_category == :pending_observed
    end

    test "dry-run degrades to a not-found preview when the controller repo is unavailable" do
      candidate = insert_candidate!()

      with_repo_unavailable(fn ->
        assert {:ok, output} = NodesCmd.run(["reject", candidate.id, "--dry-run", "--json"])
        decoded = Jason.decode!(output)

        assert decoded["action"] == "node_admission.reject"
        assert decoded["target"] == %{"type" => "node", "id" => candidate.id}
        assert Enum.map(decoded["blockers"], & &1["code"]) == ["node_not_found"]
      end)

      assert Repo.get!(AdmissionCandidate, candidate.id).admission_category == :pending_observed
    end
  end

  describe "lifecycle commands" do
    test "dry-run json returns shared preview and does not mutate" do
      node = insert_node!(state: :active, display_name: "cordon-preview-node")

      assert {:ok, output} = NodesCmd.run(["cordon", node.id, "--dry-run", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["object"] == "cluster_management.action_preview"
      assert decoded["action"] == "node_lifecycle.cordon"
      assert decoded["target"] == %{"type" => "node", "id" => node.id}
      assert decoded["confirmation_requirements"] == ["requires_yes_flag"]
      assert decoded["expected_transition"] == %{"from" => "active", "to" => "cordoned"}
      assert Repo.get!(Node, node.id).state == :active
    end

    test "json execution without yes returns preview instead of mutating" do
      node = insert_node!(state: :active, display_name: "cordon-needs-yes-node")

      assert {:error, output, 2} = NodesCmd.run(["cordon", node.id, "--json"])
      decoded = Jason.decode!(output)

      assert decoded["action"] == "node_lifecycle.cordon"
      assert decoded["blockers"] == []
      assert decoded["confirmation_requirements"] == ["requires_yes_flag"]
      assert Repo.get!(Node, node.id).state == :active
    end

    test "drain and decommission enforce consequence acknowledgement gates" do
      drain_node = insert_node!(state: :active, display_name: "drain-needs-ack")
      decommission_node = insert_node!(state: :active, display_name: "decommission-needs-ack")

      assert {:error, drain_output, 2} =
               NodesCmd.run(["drain", drain_node.id, "--yes"])

      assert drain_output =~ "requires --acknowledge"
      assert drain_output =~ "requires_drain_consequence_acknowledgement"
      assert Repo.get!(Node, drain_node.id).state == :active

      assert {:error, decommission_output, 2} =
               NodesCmd.run([
                 "decommission",
                 decommission_node.id,
                 "--yes",
                 "--typed-node-id",
                 decommission_node.id
               ])

      assert decommission_output =~ "requires --acknowledge"
      assert decommission_output =~ "requires_decommission_consequence_acknowledgement"
      assert Repo.get!(Node, decommission_node.id).state == :active
    end

    test "decommission requires typed node id before execution" do
      node = insert_node!(state: :active, display_name: "decommission-needs-typed-id")

      assert {:error, output, 2} =
               NodesCmd.run(["decommission", node.id, "--yes", "--acknowledge"])

      assert output =~ "requires --typed-node-id"
      assert output =~ "requires_typed_node_id"
      assert Repo.get!(Node, node.id).state == :active
    end

    test "yes execution mutates lifecycle state and emits action result json" do
      cases = [
        {"cordon", :active, "node_lifecycle.cordoned", "cordoned", []},
        {"uncordon", :cordoned, "node_lifecycle.uncordoned", "active", []},
        {"drain", :cordoned, "node_lifecycle.drain_started", "draining", ["--acknowledge"]},
        {"resume", :maintenance, "node_lifecycle.resumed", "active", []},
        {"decommission", :active, "node_lifecycle.decommission_started", "decommissioning",
         :typed},
        {"decommission", :draining, "node_lifecycle.decommission_started", "decommissioning",
         :typed}
      ]

      for {command, from_state, action, to_state, extra_args} <- cases do
        node = insert_node!(state: from_state, display_name: "execute-#{command}-#{from_state}")

        extra_args =
          if extra_args == :typed,
            do: ["--acknowledge", "--typed-node-id", node.id],
            else: extra_args

        assert {:ok, output} =
                 NodesCmd.run([
                   command,
                   node.id,
                   "--yes",
                   "--json",
                   "--reason",
                   "operator requested"
                   | extra_args
                 ])

        decoded = Jason.decode!(output)
        assert decoded["object"] == "node_lifecycle_action_result"
        assert decoded["action"] == action
        assert decoded["node"]["id"] == node.id
        assert decoded["node"]["state"] == to_state
        assert decoded["audit_log"]["scope"] == "cluster"
        assert Repo.get!(Node, node.id).state == String.to_existing_atom(to_state)

        audit_log = Repo.get!(AuditLog, decoded["audit_log"]["id"])
        assert audit_log.payload["reason"] == "operator requested"
      end
    end

    test "blocked lifecycle execution returns preview and preserves node" do
      node = insert_node!(state: :registered, display_name: "cordon-blocked-node")

      assert {:error, output, 2} =
               NodesCmd.run(["cordon", node.id, "--yes", "--json"])

      decoded = Jason.decode!(output)
      assert Enum.map(decoded["blockers"], & &1["code"]) == ["node_not_admitted"]
      assert Repo.get!(Node, node.id).state == :registered
    end

    test "SPEC.md §4.4 maintenance execution stays blocked while drain completion is unverified" do
      node = insert_node!(state: :draining, display_name: "maintenance-blocked-node")

      assert {:error, output, 2} =
               NodesCmd.run(["maintenance", node.id, "--yes", "--json"])

      decoded = Jason.decode!(output)
      assert Enum.map(decoded["blockers"], & &1["code"]) == ["drain_completion_unverified"]
      assert Repo.get!(Node, node.id).state == :draining
    end

    test "SPEC.md §4.4 maintenance dry-run still previews the blocked transition" do
      node = insert_node!(state: :draining, display_name: "maintenance-dry-run-node")

      assert {:ok, output} = NodesCmd.run(["maintenance", node.id, "--dry-run", "--json"])
      decoded = Jason.decode!(output)

      assert decoded["object"] == "cluster_management.action_preview"
      assert decoded["action"] == "node_lifecycle.maintenance"
      assert Enum.map(decoded["blockers"], & &1["code"]) == ["drain_completion_unverified"]
      assert decoded["expected_transition"] == %{"from" => "draining", "to" => "maintenance"}
      assert Repo.get!(Node, node.id).state == :draining
    end

    test "dry-run degrades to a not-found preview when the controller repo is unavailable" do
      node = insert_node!(state: :active, display_name: "cordon-dry-run-repo-off")

      with_repo_unavailable(fn ->
        assert {:ok, output} = NodesCmd.run(["cordon", node.id, "--dry-run", "--json"])
        decoded = Jason.decode!(output)

        assert decoded["action"] == "node_lifecycle.cordon"
        assert decoded["target"] == %{"type" => "node", "id" => node.id}
        assert Enum.map(decoded["blockers"], & &1["code"]) == ["node_not_found"]
      end)

      assert Repo.get!(Node, node.id).state == :active
    end
  end

  describe "action persistence failures" do
    setup do
      Application.put_env(:orchard_controller, :governance_audit_log_impl, FailingAuditLog)
      on_exit(fn -> Application.delete_env(:orchard_controller, :governance_audit_log_impl) end)
      :ok
    end

    test "admit json surfaces a clean error when audit persistence fails" do
      node = insert_node!(state: :registered, display_name: "admit-audit-fail-node")

      assert {:error, output, 1} =
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
      assert decoded["object"] == "error"
      assert decoded["code"] == "action_failed"
      assert Repo.get!(Node, node.id).state == :registered
    end

    test "reject human output surfaces a clean error when audit persistence fails" do
      candidate = insert_candidate!()

      assert {:error, output, 1} =
               NodesCmd.run(["reject", candidate.id, "--yes", "--reason", "identity mismatch"])

      assert output =~ "the admission action could not be completed."
      assert Repo.get!(AdmissionCandidate, candidate.id).admission_category == :pending_observed
    end

    test "lifecycle json surfaces a clean error when audit persistence fails" do
      node = insert_node!(state: :active, display_name: "cordon-audit-fail-node")

      assert {:error, output, 1} =
               NodesCmd.run(["cordon", node.id, "--yes", "--json"])

      decoded = Jason.decode!(output)
      assert decoded["object"] == "error"
      assert decoded["code"] == "action_failed"
      assert Repo.get!(Node, node.id).state == :active
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp with_repo_unavailable(fun) do
    repo_pid = Process.whereis(Repo)
    Process.unregister(Repo)

    try do
      fun.()
    after
      Process.register(repo_pid, Repo)
    end
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
