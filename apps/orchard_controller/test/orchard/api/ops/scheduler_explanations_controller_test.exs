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

    test "SPEC.md §7.3.5 returns stable selected rejected and skipped candidate reason-code arrays",
         _context do
      token = operator_token!("ops-scheduler-explanations")
      request = create_request!(%{public_id: "resp_scheduler_explanation"})

      assert {:ok, _request} =
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
                     components: %{pool_bonus: 200},
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

      conn =
        build_conn(:get, "/ops/v1/scheduler/explanations/#{request.public_id}")
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> Router.call(Router.init([]))

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
  end

  defp operator_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{slug}-client",
        owner_contact: "owner@example.com"
      })

    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: api_client.id,
      role: :operator,
      tenant_scope_id: nil
    })
    |> Repo.insert!()

    {:ok, %{token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Operator"})

    token
  end
end
