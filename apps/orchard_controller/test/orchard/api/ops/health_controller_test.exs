defmodule Orchard.API.Ops.HealthControllerTest.RuntimeStub do
  @moduledoc false

  def snapshot(opts) do
    send(test_pid(), {:runtime_snapshot_called, opts})

    {:ok,
     %{
       worker_state: :idle,
       loaded_models: [%{model_id: "test-model"}],
       active_request_count: 2,
       node_metadata: %{node_id: "node-1", display_name: "Pilot Node"},
       runtime_health: %{ready: true, health_code: nil, health_message: nil}
     }}
  end

  defp test_pid, do: Application.fetch_env!(:orchard_controller, :operator_health_test_pid)
end

defmodule Orchard.API.Ops.HealthControllerTest.PassingReadiness do
  @moduledoc false

  def status do
    send(test_pid(), :readiness_called)

    {:ok,
     %{
       postgres_reachable: true,
       migrations_current: true,
       public_api_https_enabled: true,
       controller_boot_completed: true
     }}
  end

  defp test_pid, do: Application.fetch_env!(:orchard_controller, :operator_health_test_pid)
end

defmodule Orchard.API.Ops.HealthControllerTest.FailingReadiness do
  @moduledoc false

  def status do
    send(test_pid(), :readiness_called)

    {:error, :postgres_reachable,
     %{
       postgres_reachable: false,
       migrations_current: false,
       public_api_https_enabled: false,
       controller_boot_completed: false
     }}
  end

  defp test_pid, do: Application.fetch_env!(:orchard_controller, :operator_health_test_pid)
end

defmodule Orchard.API.Ops.HealthControllerTest.RaiseReadiness do
  @moduledoc false

  def status do
    send(test_pid(), :readiness_called)
    raise("readiness secret at /private/orchard/config")
  end

  defp test_pid, do: Application.fetch_env!(:orchard_controller, :operator_health_test_pid)
end

defmodule Orchard.API.Ops.HealthControllerTest do
  use Orchard.ConnCase, async: false

  @moduletag :db
  @moduletag :live

  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, ApiKeySecret, RoleBinding}
  alias Orchard.Repo

  setup do
    previous_console = Application.get_env(:orchard_controller, :console, [])
    previous_health = Application.get_env(:orchard_controller, :health, [])
    previous_mode = Application.get_env(:orchard_controller, :transport_mode)
    previous_degraded = Application.get_env(:orchard_controller, :transport_degraded, false)
    previous_test_pid = Application.get_env(:orchard_controller, :operator_health_test_pid)

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous_console,
        runtime_impl: Orchard.API.Ops.HealthControllerTest.RuntimeStub
      )
    )

    Application.put_env(:orchard_controller, :health,
      readiness_impl: Orchard.API.Ops.HealthControllerTest.PassingReadiness
    )

    Application.put_env(:orchard_controller, :transport_mode, :direct_https)
    Application.put_env(:orchard_controller, :transport_degraded, false)
    Application.put_env(:orchard_controller, :operator_health_test_pid, self())

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous_console)
      Application.put_env(:orchard_controller, :health, previous_health)
      Application.put_env(:orchard_controller, :transport_mode, previous_mode)
      Application.put_env(:orchard_controller, :transport_degraded, previous_degraded)
      restore_env(:operator_health_test_pid, previous_test_pid)
    end)

    :ok
  end

  test "SPEC.md §3.1 missing credentials return 401 no-store before health probes" do
    conn = request()

    assert_auth_error(conn, 401, "invalid_api_key")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 malformed credentials return 401 no-store before health probes" do
    conn = request_with_authorization_headers(["Token nope"])

    assert_auth_error(conn, 401, "invalid_api_key")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 multiple authorization headers return 401 no-store before health probes" do
    conn =
      request_with_authorization_headers([
        "Bearer #{ApiKeySecret.generate().token}",
        "Bearer #{ApiKeySecret.generate().token}"
      ])

    assert_auth_error(conn, 401, "invalid_api_key")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 an unknown valid bearer returns 401 no-store before health probes" do
    conn = request(ApiKeySecret.generate().token)

    assert_auth_error(conn, 401, "invalid_api_key")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 a tenant-direct token returns 403 no-store before health probes" do
    token = tenant_token!("ops-health-tenant")
    conn = request(token)

    assert_auth_error(conn, 403, "operator_required")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 a tenant-scoped operator returns 403 no-store before health probes" do
    token = service_account_token!("ops-health-tenant-operator", :tenant_operator)
    conn = request(token)

    assert_auth_error(conn, 403, "operator_required")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 a service account without a cluster role returns 403 no-store before health probes" do
    token = service_account_token_without_role!("ops-health-no-cluster-role")
    conn = request(token)

    assert_auth_error(conn, 403, "operator_required")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 a disabled API Client returns 403 no-store before health probes" do
    {tenant, api_client, token} = service_account_token_fixture!("ops-health-disabled")
    {:ok, _disabled} = Governance.disable_api_client(tenant, api_client)
    conn = request(token)

    assert_auth_error(conn, 403, "operator_required")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 a cluster operator receives protected health details with no-store" do
    token = service_account_token!("ops-health-cluster-operator", :operator)
    conn = request(token)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert_no_store(conn)
    assert_success_body(body)
    assert_health_probes()
  end

  test "SPEC.md §3.1 a cluster admin separately receives protected health details with no-store" do
    token = service_account_token!("ops-health-cluster-admin", :admin)
    conn = request(token)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert_no_store(conn)
    assert_success_body(body)
    assert_health_probes()
  end

  test "SPEC.md §3.1 a supported legacy cluster operator credential receives protected health details" do
    token = legacy_service_account_token!("ops-health-legacy-operator")
    conn = request(token)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert_no_store(conn)
    assert_success_body(body)
    assert_health_probes()
  end

  test "SPEC.md §3.1 ordinary readiness failure returns sanitized 503 with no-store" do
    put_readiness_impl(Orchard.API.Ops.HealthControllerTest.FailingReadiness)
    token = service_account_token!("ops-health-failure-admin", :admin)
    conn = request(token)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert_no_store(conn)
    assert body["status"] == "error"
    assert body["reason"] == "postgres_reachable"
    assert body["remediation"]["reason"] == "postgres_reachable"
    assert body["remediation"]["commands"] == ["sudo orchardctl env init"]
    assert_health_probes()
  end

  test "SPEC.md §3.1 readiness exception returns unavailable 503 with no-store" do
    put_readiness_impl(Orchard.API.Ops.HealthControllerTest.RaiseReadiness)
    token = service_account_token!("ops-health-unavailable-operator", :operator)
    conn = request(token)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert_no_store(conn)
    assert body["status"] == "error"
    assert body["reason"] == "readiness_unavailable"

    assert body["remediation"] == %{
             "reason" => "readiness_unavailable",
             "summary" =>
               "Readiness evaluation is unavailable. Retry the request and check Orchard controller logs if the condition persists.",
             "commands" => [],
             "docs_anchor" => nil
           }

    refute conn.resp_body =~ "readiness secret"
    refute conn.resp_body =~ "/private/orchard/config"
    assert_health_probes()
  end

  defp request(token \\ nil)
  defp request(nil), do: request_with_authorization_headers([])
  defp request(token), do: request_with_authorization_headers(["Bearer #{token}"])

  defp request_with_authorization_headers(values) do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> Map.update!(:req_headers, fn headers ->
        Enum.map(values, &{"authorization", &1}) ++ headers
      end)

    get(conn, "/ops/v1/health")
  end

  defp assert_auth_error(conn, status, code) do
    assert conn.status == status
    assert Jason.decode!(conn.resp_body)["error"]["code"] == code
  end

  defp assert_no_store(conn) do
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  defp refute_health_probes do
    refute_received :readiness_called
    refute_received {:runtime_snapshot_called, _opts}
  end

  defp assert_health_probes do
    assert_received :readiness_called
    assert_received {:runtime_snapshot_called, timeout: 1_000}
  end

  defp assert_success_body(body) do
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
    refute Map.has_key?(body, "license")
    assert body["version"] == Orchard.version()
  end

  defp tenant_token!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})
    {:ok, %{token: token}} = Governance.create_api_key(tenant, %{name: "Primary"})
    token
  end

  defp service_account_token!(slug, role) do
    {tenant, api_client, token} = service_account_token_fixture!(slug)
    grant_role!(api_client, tenant, role)
    token
  end

  defp service_account_token_without_role!(slug) do
    {_tenant, _api_client, token} = service_account_token_fixture!(slug)
    token
  end

  defp service_account_token_fixture!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: String.capitalize(slug)})

    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: "#{slug}-client",
        owner_contact: "owner@example.com"
      })

    {:ok, %{token: token}} =
      Governance.create_api_client_api_token(api_client, %{name: "Primary"})

    {tenant, api_client, token}
  end

  defp legacy_service_account_token!(slug) do
    {tenant, api_client, _canonical_token} = service_account_token_fixture!(slug)
    grant_role!(api_client, tenant, :operator)
    token = "orch_opsHealthLegacy.existingSecret"
    {:ok, token_prefix} = ApiKeySecret.token_prefix(token)

    %ApiKey{}
    |> ApiKey.service_account_owned_changeset(%{
      service_account_id: api_client.id,
      name: "Legacy",
      token_prefix: token_prefix,
      secret_hash: ApiKeySecret.hash(token)
    })
    |> Repo.insert!()

    token
  end

  defp grant_role!(api_client, _tenant, :admin) do
    {:ok, _role_binding} = Governance.ensure_cluster_admin_access(api_client)
  end

  defp grant_role!(api_client, _tenant, :operator) do
    insert_role_binding!(api_client, nil)
  end

  defp grant_role!(api_client, tenant, :tenant_operator) do
    insert_role_binding!(api_client, tenant.id)
  end

  defp insert_role_binding!(api_client, tenant_scope_id) do
    %RoleBinding{}
    |> RoleBinding.changeset(%{
      principal_type: :service_account,
      principal_id: api_client.id,
      role: :operator,
      tenant_scope_id: tenant_scope_id
    })
    |> Repo.insert!()
  end

  defp put_readiness_impl(impl) do
    Application.put_env(:orchard_controller, :health, readiness_impl: impl)
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
