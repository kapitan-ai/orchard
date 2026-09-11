defmodule Orchard.API.Ops.RequestRetriesControllerTest.RetryScheduler do
  @moduledoc false

  alias Orchard.CanonicalRequest

  def schedule(%CanonicalRequest{} = request, opts) do
    send(
      Application.fetch_env!(:orchard_controller, :operator_retry_scheduler_owner),
      {:operator_retry_scheduled, request.public_id, opts}
    )

    {:error, :no_active_nodes}
  end
end

defmodule Orchard.API.Ops.RequestRetriesControllerTest do
  use Orchard.ConnCase, async: false

  import Ecto.Query

  alias Ecto.Changeset
  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Governance.RoleBinding
  alias Orchard.Repo
  alias Orchard.Requests

  import Orchard.TestSupport.ModelRequestFixtures
  import Orchard.TestSupport.OperatorRetryFixtures

  setup do
    inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.put(
        inference,
        :scheduler_impl,
        Orchard.API.Ops.RequestRetriesControllerTest.RetryScheduler
      )
    )

    Application.put_env(:orchard_controller, :operator_retry_scheduler_owner, self())

    on_exit(fn ->
      Application.put_env(:orchard_controller, :inference, inference)
      Application.delete_env(:orchard_controller, :operator_retry_scheduler_owner)
    end)

    :ok
  end

  describe "POST /ops/v1/requests/:id/retry" do
    @describetag :db

    test "SPEC.md §7.3 rejects missing and malformed bearer tokens with 401" do
      assert_operator_auth_error(build_conn(:post, retry_path("missing-token")), 401)

      conn =
        build_conn(:post, retry_path("malformed-token"))
        |> put_req_header("authorization", "Token nope")

      assert_operator_auth_error(conn, 401)
    end

    test "SPEC.md §7.3 rejects public tenant and tenant-scoped operator tokens with 403" do
      %{token: tenant_token} = create_tenant_token!("operator-retry-public")

      tenant_token
      |> authorized_conn("public-token")
      |> assert_operator_required()

      %{token: scoped_token} = create_api_client_token!("operator-retry-tenant-operator", :tenant)

      scoped_token
      |> authorized_conn("tenant-operator")
      |> assert_operator_required()
    end

    test "creates and dispatches a descendant in the source tenant for a cluster-scoped operator" do
      source_tenant = create_tenant!("operator-retry-source", :full)
      model = create_model!()
      source = create_full_legacy_source!(source_tenant, model, state: :failed)
      source_id = source.id
      token = operator_token!("operator-retry-cluster-operator")

      conn = post_retry(token, source.public_id)

      assert conn.status == 201

      assert %{
               "id" => descendant_public_id,
               "object" => "request",
               "retry_of_request_id" => ^source_id,
               "state" => state
             } = Jason.decode!(conn.resp_body)

      assert state in ["received", "failed"]
      assert_receive {:operator_retry_scheduled, ^descendant_public_id, [exclude_node_ids: []]}

      descendant = Requests.get_request_by_public_id(descendant_public_id)
      assert descendant.tenant_id == source_tenant.id
      assert descendant.retry_of_request_id == source.id
      assert descendant.idempotency_key == nil
    end

    test "returns retry_source_unavailable without creating a descendant for a retained negotiated snapshot" do
      source_tenant = create_tenant!("operator-retry-negotiated", :full)
      model = create_model!()
      source = create_full_legacy_source!(source_tenant, model, state: :failed)
      token = operator_token!("operator-retry-negotiated-operator")

      source =
        Repo.update!(
          Changeset.change(source,
            canonical_request:
              Map.put(source.canonical_request, "reasoning", %{"mode" => "negotiated"})
          )
        )

      assert descendant_count(source.id) == 0

      conn = post_retry(token, source.public_id)

      assert conn.status == 422

      assert Jason.decode!(conn.resp_body) == %{
               "error" => %{
                 "code" => "retry_source_unavailable",
                 "message" => "Retry source canonical request is unavailable."
               }
             }

      assert descendant_count(source.id) == 0
      refute_receive {:operator_retry_scheduled, _, _}
    end

    test "returns retry_source_not_eligible without creating a descendant for a nonterminal source" do
      source_tenant = create_tenant!("operator-retry-active", :full)
      model = create_model!()
      source = create_full_legacy_source!(source_tenant, model, state: :running)
      token = operator_token!("operator-retry-active-operator")

      conn = post_retry(token, source.public_id)

      assert conn.status == 409

      assert Jason.decode!(conn.resp_body)["error"]["code"] == "retry_source_not_eligible"
      assert descendant_count(source.id) == 0
      refute_receive {:operator_retry_scheduled, _, _}
    end
  end

  defp post_retry(token, request_id) do
    token
    |> authorized_conn(request_id)
    |> Router.call(Router.init([]))
  end

  defp authorized_conn(token, request_id) do
    build_conn(:post, retry_path(request_id))
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp retry_path(request_id), do: "/ops/v1/requests/#{request_id}/retry"

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

  defp create_tenant!(prefix, capture_mode) do
    suffix = System.unique_integer([:positive])

    {:ok, tenant} =
      Governance.create_tenant(%{
        slug: "#{prefix}-#{suffix}",
        name: "#{prefix} #{suffix}",
        request_body_capture_mode: capture_mode
      })

    tenant
  end

  defp create_tenant_token!(prefix) do
    tenant = create_tenant!(prefix, :full)
    {:ok, %{token: token}} = Governance.create_api_key(tenant, %{name: "Primary"})
    %{tenant: tenant, token: token}
  end

  defp operator_token!(prefix) do
    %{token: token} = create_api_client_token!(prefix, :cluster)
    token
  end

  defp create_api_client_token!(prefix, scope) do
    tenant = create_tenant!(prefix, :full)

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{prefix}-client",
        owner_contact: "owner@example.com"
      })

    tenant_scope_id = if scope == :cluster, do: nil, else: tenant.id

    {:ok, _role_binding} =
      %RoleBinding{}
      |> RoleBinding.changeset(%{
        principal_type: :service_account,
        principal_id: api_client.id,
        role: :operator,
        tenant_scope_id: tenant_scope_id
      })
      |> Repo.insert()

    {:ok, %{token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Primary"})

    %{tenant: tenant, token: token}
  end

  defp descendant_count(original_id) do
    Orchard.Requests.Request
    |> where([request], request.retry_of_request_id == ^original_id)
    |> Repo.aggregate(:count)
  end
end
