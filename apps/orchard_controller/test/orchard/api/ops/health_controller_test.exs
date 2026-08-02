defmodule Orchard.API.Ops.HealthControllerTest.RuntimeStub do
  @moduledoc false

  def snapshot(opts) do
    send(self(), {:runtime_snapshot_called, opts})

    {:ok,
     %{
       worker_state: :idle,
       loaded_models: [%{model_id: "test-model"}],
       active_request_count: 2,
       node_metadata: %{node_id: "node-1", display_name: "Pilot Node"},
       runtime_health: %{ready: true, health_code: nil, health_message: nil}
     }}
  end
end

defmodule Orchard.API.Ops.HealthControllerTest.LicensingStub do
  @moduledoc false

  def inspect_local do
    %Orchard.Licensing{
      state: :valid,
      message: "License bundle is valid.",
      bundle_path: "/tmp/current.json"
    }
  end
end

defmodule Orchard.API.Ops.HealthControllerTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.Router
  alias Orchard.Governance

  describe "GET /ops/v1/health" do
    @describetag :db

    setup do
      previous_console = Application.get_env(:orchard_controller, :console, [])
      previous_mode = Application.get_env(:orchard_controller, :transport_mode)
      previous_degraded = Application.get_env(:orchard_controller, :transport_degraded, false)
      previous_db_checks = Application.get_env(:orchard_controller, :enable_db_checks, true)
      previous_start_repo = Application.get_env(:orchard_controller, :start_repo, true)

      Application.put_env(
        :orchard_controller,
        :console,
        Keyword.merge(previous_console,
          runtime_impl: Orchard.API.Ops.HealthControllerTest.RuntimeStub,
          licensing_impl: Orchard.API.Ops.HealthControllerTest.LicensingStub
        )
      )

      Application.put_env(:orchard_controller, :transport_mode, :direct_https)
      Application.put_env(:orchard_controller, :transport_degraded, false)
      Application.put_env(:orchard_controller, :enable_db_checks, true)
      Application.put_env(:orchard_controller, :start_repo, true)

      on_exit(fn ->
        Application.put_env(:orchard_controller, :console, previous_console)
        Application.put_env(:orchard_controller, :transport_mode, previous_mode)
        Application.put_env(:orchard_controller, :transport_degraded, previous_degraded)
        Application.put_env(:orchard_controller, :enable_db_checks, previous_db_checks)
        Application.put_env(:orchard_controller, :start_repo, previous_start_repo)
      end)

      :ok
    end

    test "SPEC.md §3.1 rejects a missing token with 401" do
      conn = request()

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "invalid_api_key"
      refute_received {:runtime_snapshot_called, _opts}
    end

    test "SPEC.md §3.1 rejects a tenant API token with 403" do
      %{token: token} = create_tenant_token!("ops-health-tenant")
      conn = request(token)

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "operator_required"
      refute_received {:runtime_snapshot_called, _opts}
    end

    test "SPEC.md §3.1 returns protected details to a cluster operator" do
      token = operator_token!("ops-health-operator")
      conn = request(token)
      body = Jason.decode!(conn.resp_body)

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert body["status"] == "ok"

      assert body["readiness_contract"] == %{
               "version" => "orchard.readiness.legacy_m0.v1",
               "check_order" => [
                 "postgres_reachable",
                 "migrations_current",
                 "public_api_https_enabled",
                 "controller_boot_completed"
               ]
             }

      assert body["checks"] == %{
               "postgres_reachable" => true,
               "migrations_current" => true,
               "public_api_https_enabled" => true,
               "controller_boot_completed" => true
             }

      assert body["runtime"]["display_name"] == "Pilot Node"
      assert body["license"]["status"] == "valid"
      assert body["version"] == Orchard.version()
      assert_received {:runtime_snapshot_called, timeout: 1_000}
    end
  end

  defp request(token \\ nil) do
    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, Router.init([]))
  end

  defp create_tenant_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    {:ok, %{token: token}} = Governance.create_api_key(tenant, %{name: "Primary"})
    %{token: token}
  end

  defp operator_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{slug}-client",
        owner_contact: "owner@example.com"
      })

    {:ok, _role_binding} = Governance.ensure_cluster_admin_access(api_client)

    {:ok, %{token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Primary"})

    token
  end
end
