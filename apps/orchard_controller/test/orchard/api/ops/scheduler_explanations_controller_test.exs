defmodule Orchard.API.Ops.SchedulerExplanationsControllerTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Governance.RoleBinding
  alias Orchard.Repo
  alias Orchard.Requests

  import Orchard.TestSupport.ModelRequestFixtures

  describe "GET /ops/v1/scheduler/explanations/:request_id" do
    @describetag :db

    test "SPEC.md §7.3 rejects missing and malformed bearer tokens with 401" do
      assert_operator_auth_error(build_conn(:get, explanation_path("missing-token")), 401)

      conn =
        build_conn(:get, explanation_path("malformed-token"))
        |> put_req_header("authorization", "Token nope")

      assert_operator_auth_error(conn, 401)
    end

    test "SPEC.md §7.3 rejects public tenant API tokens with 403" do
      %{token: token} = create_tenant_token!("ops-scheduler-public-token")

      token
      |> authorized_conn("public-token")
      |> assert_operator_required()
    end

    test "SPEC.md §7.3 rejects tenant-scoped service-account tokens with 403" do
      %{token: token} =
        create_api_client_token!("ops-scheduler-tenant-token", role: :inference_client)

      token
      |> authorized_conn("tenant-token")
      |> assert_operator_required()
    end

    test "SPEC.md §7.3 rejects tenant-scoped operator role bindings with 403" do
      %{token: token} =
        create_api_client_token!("ops-scheduler-tenant-operator", role: :tenant_operator)

      token
      |> authorized_conn("tenant-operator")
      |> assert_operator_required()
    end

    test "SPEC.md §7.3 rejects disabled service-account tokens with 403" do
      %{token: token} =
        create_api_client_token!("ops-scheduler-disabled-operator",
          role: :operator,
          disabled?: true
        )

      token
      |> authorized_conn("disabled-operator")
      |> assert_operator_required()
    end

    test "SPEC.md §7.3 allows cluster-scoped admin service-account tokens" do
      %{token: token} = create_api_client_token!("ops-scheduler-admin-token", role: :admin)
      request = persist_valid_explanation!("resp_scheduler_explanation_admin")

      conn = get_explanation(token, request.public_id)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["request_id"] == request.public_id
    end

    test "SPEC.md §7.3.5 returns 404 when the request id has no scheduler explanation" do
      token = operator_token!("ops-scheduler-explanation-missing")

      conn = get_explanation(token, "resp_unknown_scheduler_explanation")

      assert conn.status == 404

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "code" => "scheduler_explanation_not_found",
                 "message" => "Scheduler explanation was not found."
               }
             }
    end

    test "SPEC.md §7.3.5 returns 422 when a persisted scheduler explanation is invalid" do
      token = operator_token!("ops-scheduler-explanation-invalid")

      request =
        create_request!(%{
          public_id: "resp_scheduler_explanation_invalid",
          scheduler_decision: %{
            "request_id" => "resp_scheduler_explanation_invalid",
            "selected_node_id" => "node-selected",
            "selection_tier" => "loaded",
            "scored_candidates" => [],
            "rejected_candidates" => [
              %{"node_id" => "node-rejected", "reason_codes" => ["not_a_scheduler_code"]}
            ],
            "skipped_candidates" => []
          }
        })

      conn = get_explanation(token, request.public_id)

      assert conn.status == 422

      assert %{
               "error" => %{
                 "code" => "scheduler_explanation_invalid",
                 "message" => "Persisted scheduler explanation is invalid.",
                 "details" => details
               }
             } = Jason.decode!(conn.resp_body)

      assert details =~ "not_a_scheduler_code"
    end

    test "SPEC.md §7.3.5 returns stable selected rejected and skipped candidate reason-code arrays",
         _context do
      token = operator_token!("ops-scheduler-explanations")
      request = persist_valid_explanation!("resp_scheduler_explanation")

      conn = get_explanation(token, request.public_id)

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "request_id" => request.public_id,
               "selected_node_id" => "node-selected",
               "selection_tier" => "loaded",
               "scored_candidates" => [
                 %{
                   "node_id" => "node-selected",
                   "target_ref" => nil,
                   "eligible" => true,
                   "tier" => "loaded",
                   "score" => 842,
                   "components" => %{"pool_bonus" => 200},
                   "diagnostics" => %{},
                   "reason_codes" => []
                 }
               ],
               "rejected_candidates" => [
                 %{
                   "node_id" => "node-rejected",
                   "target_ref" => nil,
                   "eligible" => false,
                   "tier" => nil,
                   "score" => nil,
                   "components" => %{},
                   "diagnostics" => %{},
                   "reason_codes" => ["node_not_active", "insufficient_memory"]
                 }
               ],
               "skipped_candidates" => [
                 %{
                   "node_id" => "node-skipped",
                   "target_ref" => nil,
                   "eligible" => false,
                   "tier" => nil,
                   "score" => nil,
                   "components" => %{},
                   "diagnostics" => %{},
                   "reason_codes" => ["lower_tier_not_considered"]
                 }
               ]
             }
    end

    test "preserves a legacy persisted degraded health bonus" do
      token = operator_token!("ops-scheduler-legacy-health-bonus")

      request =
        persist_valid_explanation!(
          "resp_scheduler_legacy_health_bonus",
          %{health_bonus: 10}
        )

      conn = get_explanation(token, request.public_id)

      assert conn.status == 200

      assert [
               %{"components" => %{"health_bonus" => 10}}
             ] = Jason.decode!(conn.resp_body)["scored_candidates"]
    end
  end

  defp persist_valid_explanation!(public_id, components \\ %{pool_bonus: 200}) do
    request = create_request!(%{public_id: public_id, payload_capture_mode: :full})

    assert {:ok, request} =
             Requests.record_schedule(request, %{
               request_id: request.public_id,
               selected_node_id: "node-selected",
               selection_tier: :loaded,
               scored_candidates: [
                 %{
                   node_id: "node-selected",
                   eligible: true,
                   tier: :loaded,
                   score: 842,
                   components: components,
                   reason_codes: []
                 }
               ],
               rejected_candidates: [
                 %{
                   node_id: "node-rejected",
                   reason_codes: [:node_not_active, "insufficient_memory"]
                 }
               ],
               skipped_candidates: [
                 %{
                   node_id: "node-skipped",
                   reason_codes: [:lower_tier_not_considered]
                 }
               ]
             })

    request
  end

  defp get_explanation(token, request_id) do
    token
    |> authorized_conn(request_id)
    |> Router.call(Router.init([]))
  end

  defp authorized_conn(token, request_id) do
    build_conn(:get, explanation_path(request_id))
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp explanation_path(request_id), do: "/ops/v1/scheduler/explanations/#{request_id}"

  defp assert_operator_auth_error(conn, status) do
    conn = Router.call(conn, Router.init([]))

    assert conn.halted
    assert conn.status == status

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "invalid_api_key",
               "message" => "Invalid API key provided."
             }
           }
  end

  defp assert_operator_required(conn) do
    conn = Router.call(conn, Router.init([]))

    assert conn.halted
    assert conn.status == 403

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "operator_required",
               "message" =>
                 "Operator API requires a cluster-scoped operator or admin API Client token."
             }
           }
  end

  defp create_tenant_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant, %{name: "Primary"})

    %{tenant: tenant, api_key: api_key, token: token}
  end

  defp operator_token!(slug) do
    %{token: token} = create_api_client_token!(slug, role: :operator)
    token
  end

  defp create_api_client_token!(slug, opts) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{slug}-client",
        owner_contact: "owner@example.com"
      })

    grant_role!(api_client, tenant, Keyword.fetch!(opts, :role))

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Primary"})

    if Keyword.get(opts, :disabled?, false) do
      {:ok, _disabled} = Governance.disable_api_client(tenant, api_client)
    end

    %{tenant: tenant, api_client: api_client, api_key: api_key, token: token}
  end

  defp grant_role!(api_client, _tenant, :admin) do
    {:ok, _role_binding} = Governance.ensure_cluster_admin_access(api_client)
  end

  defp grant_role!(api_client, tenant, :inference_client) do
    {:ok, _role_binding} = Governance.ensure_inference_client_access(api_client, tenant)
  end

  defp grant_role!(api_client, _tenant, :operator) do
    insert_role_binding!(api_client, :operator, nil)
  end

  defp grant_role!(api_client, tenant, :tenant_operator) do
    insert_role_binding!(api_client, :operator, tenant.id)
  end

  defp insert_role_binding!(api_client, role, tenant_scope_id) do
    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: api_client.id,
      role: role,
      tenant_scope_id: tenant_scope_id
    })
    |> Repo.insert!()
  end
end
