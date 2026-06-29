defmodule Orchard.API.Admin.NodeAdmissionControllerTest do
  use Orchard.ConnCase, async: false

  import Ecto.Query

  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}
  alias Orchard.Repo

  describe "Admin API node admission" do
    @describetag :db

    test "SPEC.md §7.4 lists and shows admission candidates with latest decision metadata" do
      token = admin_token!("admin-node-admission-list")
      candidate = insert_candidate!(target_ref: "10.0.0.44:50071")

      assert {:ok, _result} =
               Nodes.reject_admission_candidate(candidate.id, %{reason: "review later"})

      list_conn = admin_json(:get, "/admin/v1/node-admission/candidates", token)
      assert list_conn.status == 200

      assert %{"object" => "list", "data" => [listed]} = Jason.decode!(list_conn.resp_body)
      assert listed["id"] == candidate.id
      assert listed["object"] == "node_admission_candidate"
      assert listed["latest_decision"]["decision"] == "rejected"

      show_conn =
        admin_json(:get, "/admin/v1/node-admission/candidates/#{candidate.id}", token)

      assert show_conn.status == 200
      assert Jason.decode!(show_conn.resp_body)["id"] == candidate.id
    end

    test "candidate show returns 404 for unknown candidates" do
      token = admin_token!("admin-node-admission-show-missing")

      conn =
        admin_json(
          :get,
          "/admin/v1/node-admission/candidates/#{Ecto.UUID.generate()}",
          token
        )

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "candidate_not_found"
    end

    test "reject requires a nonblank reason" do
      token = admin_token!("admin-node-admission-reason")
      candidate = insert_candidate!()

      conn =
        admin_json(
          :post,
          "/admin/v1/node-admission/candidates/#{candidate.id}/reject",
          token,
          %{"reason" => "  "}
        )

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "reason_required"
    end

    test "reject and clear append decisions and cluster audit logs" do
      token = admin_token!("admin-node-admission-reject-clear")
      candidate = insert_candidate!(target_ref: "10.0.0.45:50071")

      reject_conn =
        admin_json(
          :post,
          "/admin/v1/node-admission/candidates/#{candidate.id}/reject",
          token,
          %{"reason" => "identity mismatch"}
        )

      assert reject_conn.status == 200
      rejected = Jason.decode!(reject_conn.resp_body)
      assert rejected["action"] == "node_admission.rejected"
      assert rejected["candidate"]["admission_category"] == "rejected"
      assert rejected["decision"]["reason"] == "identity mismatch"
      assert rejected["audit_log"]["scope"] == "cluster"

      clear_conn =
        admin_json(
          :post,
          "/admin/v1/node-admission/candidates/#{candidate.id}/clear-rejection",
          token,
          %{"surface" => "admin-api-test"}
        )

      assert clear_conn.status == 200
      cleared = Jason.decode!(clear_conn.resp_body)
      assert cleared["action"] == "node_admission.rejection_cleared"
      assert cleared["candidate"]["admission_category"] == "pending_observed"
      assert cleared["decision"]["metadata"] == %{"surface" => "admin-api-test"}
      refute Map.has_key?(cleared["decision"]["metadata"], "candidate_id")

      decisions =
        AdmissionDecision
        |> where([decision], decision.candidate_id == ^candidate.id)
        |> order_by([decision], asc: decision.inserted_at)
        |> Repo.all()
        |> Enum.map(& &1.decision)

      assert decisions == [:rejected, :rejection_cleared]

      assert Repo.aggregate(
               from(audit_log in AuditLog,
                 where:
                   audit_log.scope == "cluster" and
                     audit_log.target_type == "node_admission_candidate" and
                     audit_log.target_id == ^candidate.id
               ),
               :count,
               :id
             ) == 2
    end

    test "candidate reject route does not fall back to a node with the same UUID" do
      token = admin_token!("admin-node-admission-no-fallback")

      node =
        insert_node!(%{
          state: :registered,
          display_name: "same-id-node",
          hostname: "same-id-node.local"
        })

      conn =
        admin_json(
          :post,
          "/admin/v1/node-admission/candidates/#{node.id}/reject",
          token,
          %{"reason" => "must not affect node"}
        )

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "candidate_not_found"

      assert [] =
               Repo.all(from(decision in AdmissionDecision, where: decision.node_id == ^node.id))
    end

    test "candidate clear route does not fall back to a node with the same UUID" do
      token = admin_token!("admin-node-admission-clear-no-fallback")

      node =
        insert_node!(%{
          state: :registered,
          display_name: "same-id-clear-node",
          hostname: "same-id-clear-node.local"
        })

      conn =
        admin_json(
          :post,
          "/admin/v1/node-admission/candidates/#{node.id}/clear-rejection",
          token,
          %{}
        )

      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "candidate_not_found"

      assert [] =
               Repo.all(from(decision in AdmissionDecision, where: decision.node_id == ^node.id))
    end

    test "admit rejects observed-only candidates and provisioned nodes" do
      token = admin_token!("admin-node-admission-blockers")
      candidate = insert_candidate!()

      observed_conn =
        admin_json(:post, "/admin/v1/nodes/#{candidate.id}/admit", token, admission_attrs())

      assert observed_conn.status == 404
      assert Jason.decode!(observed_conn.resp_body)["error"]["code"] == "node_not_found"

      node =
        insert_node!(%{
          state: :provisioned,
          display_name: "provisioned-node",
          hostname: "provisioned-node.local"
        })

      provisioned_conn =
        admin_json(:post, "/admin/v1/nodes/#{node.id}/admit", token, admission_attrs())

      assert provisioned_conn.status == 409
      assert Jason.decode!(provisioned_conn.resp_body)["error"]["code"] == "node_not_registered"
    end

    test "admit enforces rejection clear, inventory, trust, pool, and policy blockers" do
      token = admin_token!("admin-node-admission-input-blockers")

      rejected_node =
        insert_node!(%{
          state: :registered,
          display_name: "rejected-node",
          hostname: "rejected-node.local"
        })

      assert {:ok, _rejected} =
               Nodes.reject_admission(rejected_node.id, %{reason: "hold admission"})

      rejected_conn =
        admin_json(:post, "/admin/v1/nodes/#{rejected_node.id}/admit", token, admission_attrs())

      assert rejected_conn.status == 409
      assert Jason.decode!(rejected_conn.resp_body)["error"]["code"] == "admission_rejected"

      missing_inventory =
        insert_node!(%{
          state: :registered,
          advertise_addr: "0.0.0.0",
          display_name: "missing-inventory-node",
          hostname: "missing-inventory-node.local"
        })

      inventory_conn =
        admin_json(
          :post,
          "/admin/v1/nodes/#{missing_inventory.id}/admit",
          token,
          admission_attrs()
        )

      assert inventory_conn.status == 409
      assert Jason.decode!(inventory_conn.resp_body)["error"]["code"] == "inventory_missing"

      registered =
        insert_node!(%{
          state: :registered,
          display_name: "registered-blocker-node",
          hostname: "registered-blocker-node.local"
        })

      trust_conn = admin_json(:post, "/admin/v1/nodes/#{registered.id}/admit", token, %{})
      assert trust_conn.status == 409
      assert Jason.decode!(trust_conn.resp_body)["error"]["code"] == "trust_not_established"

      pool_conn =
        admin_json(
          :post,
          "/admin/v1/nodes/#{registered.id}/admit",
          token,
          %{"trust_evidence_ref" => "registration-audit:test"}
        )

      assert pool_conn.status == 409
      assert Jason.decode!(pool_conn.resp_body)["error"]["code"] == "pool_required"

      policy_conn =
        admin_json(
          :post,
          "/admin/v1/nodes/#{registered.id}/admit",
          token,
          %{
            "trust_evidence_ref" => "registration-audit:test",
            "pool_id" => Ecto.UUID.generate()
          }
        )

      assert policy_conn.status == 409
      assert Jason.decode!(policy_conn.resp_body)["error"]["code"] == "policy_required"
    end

    test "admit transitions a registered trusted node to admitted and writes cluster audit" do
      token = admin_token!("admin-node-admission-admit")

      node =
        insert_node!(%{
          state: :registered,
          display_name: "registered-admit-node",
          hostname: "registered-admit-node.local"
        })

      conn = admin_json(:post, "/admin/v1/nodes/#{node.id}/admit", token, admission_attrs())

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["action"] == "node_admission.admitted"
      assert body["node"]["state"] == "admitted"
      assert body["decision"]["decision"] == "admitted"
      assert body["decision"]["metadata"]["trust_evidence_ref"] == "registration-audit:test"
      refute Map.has_key?(body["decision"]["metadata"], "node_id")
      assert body["audit_log"]["scope"] == "cluster"
      assert Repo.get!(Node, node.id).state == :admitted
    end

    test "stored snapshot truncation markers are preserved in candidate responses" do
      token = admin_token!("admin-node-admission-truncation")

      marker = %{
        "truncated" => true,
        "reason" => "entry_limit",
        "kind" => "map",
        "entry_limit" => 40,
        "original_count" => 41
      }

      candidate =
        insert_candidate!(
          inventory: %{
            "__orchard_snapshot_truncation__" => marker,
            "retained" => "value"
          }
        )

      conn = admin_json(:get, "/admin/v1/node-admission/candidates/#{candidate.id}", token)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["inventory"]["__orchard_snapshot_truncation__"] == marker
    end

    test "controller standby fails closed before mutation or audit writes" do
      token = admin_token!("admin-node-admission-standby")
      candidate = insert_candidate!()
      previous = Application.get_env(:orchard_controller, :control_plane)

      Application.put_env(:orchard_controller, :control_plane, role: :standby)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:orchard_controller, :control_plane)
        else
          Application.put_env(:orchard_controller, :control_plane, previous)
        end
      end)

      conn =
        admin_json(
          :post,
          "/admin/v1/node-admission/candidates/#{candidate.id}/reject",
          token,
          %{"reason" => "standby should not mutate"}
        )

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "controller_standby"
      assert Repo.get!(AdmissionCandidate, candidate.id).admission_category == :pending_observed

      assert Repo.aggregate(
               from(audit_log in AuditLog,
                 where:
                   audit_log.target_type == "node_admission_candidate" and
                     audit_log.target_id == ^candidate.id
               ),
               :count,
               :id
             ) == 0
    end
  end

  defp admin_json(method, path, token, params \\ %{}) do
    method
    |> build_conn(path)
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Map.put(:params, params)
    |> Map.put(:body_params, params)
    |> Router.call(Router.init([]))
  end

  defp admin_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{slug}-client",
        owner_contact: "owner@example.com"
      })

    {:ok, _role_binding} = Governance.ensure_cluster_admin_access(api_client)
    {:ok, %{token: token}} = Governance.create_api_client_api_token(api_client, %{name: "admin"})
    token
  end

  defp insert_candidate!(overrides \\ []) do
    unique = System.unique_integer([:positive])

    attrs =
      %{
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
      |> Map.merge(Map.new(overrides))

    %AdmissionCandidate{}
    |> AdmissionCandidate.changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_node!(overrides) do
    unique = System.unique_integer([:positive])

    attrs =
      %{
        id: Ecto.UUID.generate(),
        hostname: "node-#{unique}.local",
        display_name: "node-#{unique}",
        advertise_addr: "10.20.#{rem(unique, 200)}.#{rem(unique, 250) + 1}",
        rpc_port: 50_071,
        state: :active,
        health: :healthy,
        capabilities: %{},
        tool_readiness: %{}
      }
      |> Map.merge(overrides)

    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert!()
  end

  defp admission_attrs do
    %{
      "trust_evidence_ref" => "registration-audit:test",
      "pool_id" => Ecto.UUID.generate(),
      "routing_policy_id" => Ecto.UUID.generate()
    }
  end
end
