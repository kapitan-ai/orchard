defmodule Orchard.API.Ops.CircuitBreakersControllerTest do
  use Orchard.ConnCase, async: false

  import Ecto.Query

  alias Orchard.API.Router
  alias Orchard.CircuitBreakers
  alias Orchard.Governance
  alias Orchard.Governance.AuditLog
  alias Orchard.Governance.RoleBinding
  alias Orchard.Models.Model
  alias Orchard.Nodes.Node
  alias Orchard.Repo

  describe "GET /ops/v1/circuit-breakers/nodes/:node_id" do
    @describetag :db

    test "SPEC.md section 7.3 denies missing and tenant-direct credentials without state" do
      node = insert_node!()
      path = "/ops/v1/circuit-breakers/nodes/#{node.id}"

      missing = operator_json(:get, path, nil)
      assert missing.status == 401
      assert get_resp_header(missing, "cache-control") == ["no-store"]
      assert Jason.decode!(missing.resp_body)["error"]["code"] == "invalid_api_key"

      tenant_token = tenant_token!("ops-breaker-tenant-denied")
      tenant = operator_json(:get, path, tenant_token)
      assert tenant.status == 403
      assert get_resp_header(tenant, "cache-control") == ["no-store"]
      assert Jason.decode!(tenant.resp_body)["error"]["code"] == "operator_required"
    end

    test "SPEC.md section 5.10 lets a cluster operator inspect a closed Node breaker" do
      node = insert_node!()
      token = operator_token!("ops-breaker-node-inspect")

      conn = operator_json(:get, "/ops/v1/circuit-breakers/nodes/#{node.id}", token)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert Jason.decode!(conn.resp_body) == %{
               "object" => "circuit_breaker",
               "kind" => "node",
               "node_id" => node.id,
               "model_id" => nil,
               "state" => "closed",
               "contribution_count" => 0,
               "opened_at" => nil,
               "suppressed_until" => nil,
               "last_cleared_at" => nil,
               "generation" => 0
             }
    end

    test "SPEC.md section 5.10 rejects inspection on a standby Controller without exposing state" do
      node = insert_node!()
      token = operator_token!("ops-breaker-node-standby-inspection")
      configure_control_plane(role: :standby)

      conn = operator_json(:get, "/ops/v1/circuit-breakers/nodes/#{node.id}", token)

      assert conn.status == 503
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "code" => "controller_standby",
                 "message" => "This controller is in standby mode."
               }
             }
    end

    test "SPEC.md section 5.10 fails inspection closed when Controller leadership is unproven" do
      node = insert_node!()
      token = operator_token!("ops-breaker-node-unproven-inspection")
      configure_control_plane(role: :leader, this_controller_identity: "controller-a")

      conn = operator_json(:get, "/ops/v1/circuit-breakers/nodes/#{node.id}", token)

      assert conn.status == 503

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "code" => "controller_leadership_unproven",
                 "message" => "This controller has not proven local leadership."
               }
             }
    end

    test "returns stable invalid and missing canonical identity errors" do
      token = operator_token!("ops-breaker-node-errors")

      invalid = operator_json(:get, "/ops/v1/circuit-breakers/nodes/not-a-uuid", token)
      assert invalid.status == 422
      assert Jason.decode!(invalid.resp_body)["error"]["code"] == "invalid_circuit_breaker_target"

      missing =
        operator_json(
          :get,
          "/ops/v1/circuit-breakers/nodes/#{Ecto.UUID.generate()}",
          token
        )

      assert missing.status == 404
      assert Jason.decode!(missing.resp_body)["error"]["code"] == "node_not_found"
    end
  end

  describe "GET /ops/v1/circuit-breakers/placements/:node_id/:model_id" do
    @describetag :db

    test "lets a cluster admin inspect an open placement breaker" do
      node = insert_node!()
      model = insert_model!()
      token = admin_token!("ops-breaker-placement-admin")
      open_placement!(node.id, model.id)

      conn =
        operator_json(
          :get,
          "/ops/v1/circuit-breakers/placements/#{node.id}/#{model.id}",
          token
        )

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert %{
               "kind" => "placement",
               "node_id" => node_id,
               "model_id" => model_id,
               "state" => "open",
               "contribution_count" => 3,
               "opened_at" => opened_at,
               "suppressed_until" => suppressed_until
             } = Jason.decode!(conn.resp_body)

      assert node_id == node.id
      assert model_id == model.id
      assert is_binary(opened_at)
      assert is_binary(suppressed_until)
    end

    test "rejects an unknown Model but preserves retained placement history after deletion" do
      node = insert_node!()
      model = insert_model!()
      token = operator_token!("ops-breaker-placement-identity")

      unknown =
        operator_json(
          :get,
          "/ops/v1/circuit-breakers/placements/#{node.id}/#{Ecto.UUID.generate()}",
          token
        )

      assert unknown.status == 404
      assert Jason.decode!(unknown.resp_body)["error"]["code"] == "model_not_found"

      open_placement!(node.id, model.id)
      Repo.delete!(model)

      retained =
        operator_json(
          :get,
          "/ops/v1/circuit-breakers/placements/#{node.id}/#{model.id}",
          token
        )

      assert retained.status == 200

      assert %{"state" => "open", "model_id" => model_id} =
               Jason.decode!(retained.resp_body)

      assert model_id == model.id
    end
  end

  describe "POST /ops/v1/circuit-breakers/placements/:node_id/:model_id/clear" do
    @describetag :db

    test "SPEC.md section 5.10 clears an open placement and audits a repeated no-op clear" do
      node = insert_node!()
      model = insert_model!()
      token = operator_token!("ops-breaker-placement-clear")
      open_placement!(node.id, model.id)

      path = "/ops/v1/circuit-breakers/placements/#{node.id}/#{model.id}/clear"
      first = operator_json(:post, path, token, %{"reason" => "load failures investigated"})

      assert first.status == 200
      assert get_resp_header(first, "cache-control") == ["no-store"]

      assert %{
               "result" => "cleared",
               "changed" => true,
               "breaker" => %{
                 "kind" => "placement",
                 "node_id" => node_id,
                 "model_id" => model_id,
                 "state" => "closed",
                 "generation" => generation
               }
             } = Jason.decode!(first.resp_body)

      assert node_id == node.id
      assert model_id == model.id

      second = operator_json(:post, path, token, %{"reason" => "confirm suppression clear"})

      assert second.status == 200

      assert %{
               "result" => "already_cleared",
               "changed" => false,
               "breaker" => %{"generation" => ^generation}
             } = Jason.decode!(second.resp_body)

      audits =
        AuditLog
        |> where([audit], audit.action == "circuit_breaker.placement.cleared")
        |> where([audit], audit.target_id == ^"#{node.id}:#{model.id}")
        |> order_by([audit], asc: audit.occurred_at)
        |> Repo.all()

      assert Enum.map(audits, & &1.payload["changed"]) == [true, false]

      assert Enum.map(audits, & &1.payload["reason"]) == [
               "load failures investigated",
               "confirm suppression clear"
             ]

      assert Enum.all?(audits, &(&1.scope == "cluster"))
      assert Enum.all?(audits, &(&1.actor_type == "service_account"))
      assert Enum.all?(audits, &is_binary(&1.actor_id))
      assert Enum.all?(audits, &is_nil(&1.api_key_id))

      assert [effective_audit, repeated_audit] = audits
      assert DateTime.compare(repeated_audit.occurred_at, effective_audit.occurred_at) == :gt
    end

    test "requires a nonblank reason before attempting the clear" do
      node = insert_node!()
      model = insert_model!()
      token = operator_token!("ops-breaker-placement-reason")

      conn =
        operator_json(
          :post,
          "/ops/v1/circuit-breakers/placements/#{node.id}/#{model.id}/clear",
          token,
          %{"reason" => "  "}
        )

      assert conn.status == 422

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "code" => "circuit_breaker_clear_reason_required",
                 "message" => "A nonblank circuit-breaker clear reason is required."
               }
             }
    end

    test "clearing a closed breaker with contributions audits an idempotent no-op" do
      node = insert_node!()
      model = insert_model!()
      token = operator_token!("ops-breaker-placement-closed-clear")
      record_placement_failures!(node.id, model.id, 1)

      conn =
        operator_json(
          :post,
          "/ops/v1/circuit-breakers/placements/#{node.id}/#{model.id}/clear",
          token,
          %{"reason" => "discard isolated load failure"}
        )

      assert conn.status == 200

      assert %{
               "result" => "already_cleared",
               "changed" => false,
               "breaker" => %{"state" => "closed", "generation" => 0}
             } = Jason.decode!(conn.resp_body)

      audit =
        Repo.get_by!(AuditLog,
          action: "circuit_breaker.placement.cleared",
          target_id: "#{node.id}:#{model.id}"
        )

      assert audit.payload["previous_state"] == "closed"
      assert audit.payload["changed"] == false
      assert audit.payload["resulting_generation"] == 0
    end
  end

  describe "POST /ops/v1/circuit-breakers/nodes/:node_id/clear" do
    @describetag :db

    test "fails closed on a standby controller without appending audit evidence" do
      node = insert_node!()
      token = operator_token!("ops-breaker-node-standby")
      previous = Application.get_env(:orchard_controller, :control_plane)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:orchard_controller, :control_plane, previous),
          else: Application.delete_env(:orchard_controller, :control_plane)
      end)

      Application.put_env(:orchard_controller, :control_plane, role: :standby)

      conn =
        operator_json(
          :post,
          "/ops/v1/circuit-breakers/nodes/#{node.id}/clear",
          token,
          %{"reason" => "operator investigation complete"}
        )

      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "controller_standby"

      assert Repo.aggregate(
               from(audit in AuditLog,
                 where:
                   audit.action == "circuit_breaker.node.cleared" and
                     audit.target_id == ^node.id
               ),
               :count,
               :id
             ) == 0
    end
  end

  defp operator_json(method, path, token, body \\ nil) do
    conn =
      build_conn(method, path, body)
      |> put_req_header("accept", "application/json")

    conn =
      if token,
        do: put_req_header(conn, "authorization", "Bearer #{token}"),
        else: conn

    Router.call(conn, Router.init([]))
  end

  defp configure_control_plane(config) do
    previous = Application.get_env(:orchard_controller, :control_plane)
    Application.put_env(:orchard_controller, :control_plane, config)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:orchard_controller, :control_plane)
      else
        Application.put_env(:orchard_controller, :control_plane, previous)
      end
    end)
  end

  defp tenant_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    {:ok, %{token: token}} = Governance.create_api_key(tenant, %{name: "Primary"})
    token
  end

  defp operator_token!(slug) do
    service_account_token!(slug, :operator)
  end

  defp admin_token!(slug) do
    service_account_token!(slug, :admin)
  end

  defp service_account_token!(slug, role) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{slug}-client",
        owner_contact: "owner@example.com"
      })

    grant_cluster_role!(api_client, role)

    {:ok, %{token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Primary"})

    token
  end

  defp grant_cluster_role!(api_client, :admin) do
    {:ok, _binding} = Governance.ensure_cluster_admin_access(api_client)
  end

  defp grant_cluster_role!(api_client, :operator) do
    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: api_client.id,
      role: :operator,
      tenant_scope_id: nil
    })
    |> Repo.insert!()
  end

  defp insert_node! do
    unique = System.unique_integer([:positive])

    %Node{}
    |> Node.changeset(%{
      id: Ecto.UUID.generate(),
      hostname: "ops-breaker-node-#{unique}.local",
      display_name: "ops-breaker-node-#{unique}",
      advertise_addr: "10.253.#{rem(div(unique, 254), 254)}.#{rem(unique, 254) + 1}",
      rpc_port: 9444,
      state: :active,
      health: :healthy,
      capabilities: %{},
      tool_readiness: %{}
    })
    |> Repo.insert!()
  end

  defp insert_model! do
    unique = System.unique_integer([:positive])

    %Model{}
    |> Model.changeset(%{
      model_id: "ops-breaker-model-#{unique}",
      version: "main",
      state: :active,
      format: "mlx",
      capabilities: ["text"],
      tokenizer: %{"type" => "huggingface", "ref" => "test/tokenizer"},
      artifact_uri: "file:///tmp/ops-breaker-model-#{unique}",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1,
      resident_memory_bytes: 1,
      kv_cache_bytes_per_token: 1,
      prefill_workspace_bytes_per_token: 1,
      runtime_requirements: %{}
    })
    |> Repo.insert!()
  end

  defp open_placement!(node_id, model_id) do
    record_placement_failures!(node_id, model_id, 3)
  end

  defp record_placement_failures!(node_id, model_id, count) do
    now = DateTime.utc_now()

    for seconds_ago <- Enum.reverse(0..(count - 1)) do
      assert {:ok, _decision} =
               CircuitBreakers.record_failure(%{
                 failure_id: Ecto.UUID.generate(),
                 node_id: node_id,
                 model_id: model_id,
                 failure_class: "model_load_failure",
                 occurred_at: DateTime.add(now, -seconds_ago, :second)
               })
    end
  end
end
