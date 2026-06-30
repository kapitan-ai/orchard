defmodule Orchard.API.AdminRequestContextTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.AdminRequestContext
  alias Orchard.Governance
  alias Orchard.Governance.RoleBinding
  alias Orchard.Repo

  describe "AdminRequestContext plug" do
    @describetag :db

    test "SPEC.md §7.4 authorizes service-account-owned cluster admin tokens" do
      %{api_client: api_client, api_key: api_key, token: token, tenant: tenant} =
        create_api_client_token!("admin-context-authorized", role: :admin)

      conn =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer #{token}")
        |> AdminRequestContext.call([])

      refute conn.halted
      assert conn.assigns[:tenant_id] == tenant.id
      assert conn.assigns[:principal_type] == :service_account
      assert conn.assigns[:principal_id] == api_client.id
      assert conn.assigns[:service_account_id] == api_client.id
      assert conn.assigns[:api_key_id] == api_key.id
    end

    test "rejects missing, malformed, invalid, revoked, and expired tokens with 401" do
      assert_admin_auth_error(build_conn(:get, "/admin/v1/node-admission/candidates"), 401)

      malformed =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Token nope")

      assert_admin_auth_error(malformed, 401)

      invalid =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer orchard_sk_invalid.invalid")

      assert_admin_auth_error(invalid, 401)

      %{api_key: api_key, token: revoked_token} =
        create_api_client_token!("admin-context-revoked", role: :admin)

      assert {:ok, _revoked} = Governance.revoke_api_key(api_key.id)

      revoked =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer #{revoked_token}")

      assert_admin_auth_error(revoked, 401)

      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      %{token: expired_token} =
        create_api_client_token!("admin-context-expired", role: :admin, expires_at: expired_at)

      expired =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer #{expired_token}")

      assert_admin_auth_error(expired, 401)
    end

    test "rejects tenant-direct keys and non-admin service-account tokens with 403" do
      %{token: tenant_token} = create_tenant_token!("admin-context-tenant-direct")

      tenant_direct =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer #{tenant_token}")

      assert_admin_required(tenant_direct)

      %{token: inference_token} =
        create_api_client_token!("admin-context-inference", role: :inference_client)

      inference =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer #{inference_token}")

      assert_admin_required(inference)

      %{token: operator_token} =
        create_api_client_token!("admin-context-operator", role: :operator)

      operator =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer #{operator_token}")

      assert_admin_required(operator)

      %{token: tenant_admin_token} =
        create_api_client_token!("admin-context-tenant-admin", role: :tenant_admin)

      tenant_admin =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer #{tenant_admin_token}")

      assert_admin_required(tenant_admin)
    end

    test "rejects disabled API Clients with otherwise valid admin tokens" do
      %{token: token} =
        create_api_client_token!("admin-context-disabled", role: :admin, disabled?: true)

      conn =
        build_conn(:get, "/admin/v1/node-admission/candidates")
        |> put_req_header("authorization", "Bearer #{token}")

      assert_admin_required(conn)
    end
  end

  defp assert_admin_auth_error(conn, status) do
    conn = AdminRequestContext.call(conn, [])

    assert conn.halted
    assert conn.status == status

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "invalid_api_key",
               "message" => "Invalid API key provided."
             }
           }
  end

  defp assert_admin_required(conn) do
    conn = AdminRequestContext.call(conn, [])

    assert conn.halted
    assert conn.status == 403

    assert Jason.decode!(conn.resp_body) == %{
             "error" => %{
               "code" => "admin_required",
               "message" => "Admin API requires a cluster-scoped admin API Client token."
             }
           }
  end

  defp create_tenant_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_key(tenant, %{name: "Primary"})

    %{tenant: tenant, api_key: api_key, token: token}
  end

  defp create_api_client_token!(slug, opts) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{slug}-client",
        owner_contact: "owner@example.com"
      })

    grant_role!(api_client, tenant, Keyword.fetch!(opts, :role))

    token_attrs =
      %{name: "Primary"}
      |> maybe_put(:expires_at, Keyword.get(opts, :expires_at))

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_client_api_token(api_client, token_attrs)

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
    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: api_client.id,
      role: :operator,
      tenant_scope_id: nil
    })
    |> Repo.insert!()
  end

  defp grant_role!(api_client, tenant, :tenant_admin) do
    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: api_client.id,
      role: :tenant_admin,
      tenant_scope_id: tenant.id
    })
    |> Repo.insert!()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
