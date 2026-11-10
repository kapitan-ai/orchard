defmodule OrchardCLI.OperatorAPIAssertions do
  @moduledoc false

  import ExUnit.Assertions
  import Plug.Conn

  alias Orchard.API.Router
  alias Orchard.Governance
  alias Orchard.Governance.RoleBinding
  alias Orchard.Repo

  @spec assert_json(String.t(), map()) :: true
  def assert_json(path, expected) do
    slug = "cli-parity-#{System.unique_integer([:positive])}"
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: slug})

    {:ok, client} =
      Governance.upsert_api_client(tenant, %{name: slug, owner_contact: "owner@example.com"})

    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: client.id,
      role: :operator,
      tenant_scope_id: nil
    })
    |> Repo.insert!()

    {:ok, %{token: token}} = Governance.create_api_client_api_token(client, %{name: "Parity"})

    conn =
      Plug.Test.conn(:get, path)
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert Jason.decode!(conn.resp_body) == expected
  end
end
