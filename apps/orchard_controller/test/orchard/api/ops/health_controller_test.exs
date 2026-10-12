defmodule Orchard.API.Ops.HealthControllerTest.RuntimeStub do
  @moduledoc false

  def snapshot(opts) do
    send(test_pid(), {:runtime_snapshot_called, opts})

    {result, fields} =
      Application.get_env(:orchard_controller, :operator_health_test_snapshot, {:ok, %{}})

    snapshot = %{
      worker_state: :idle,
      loaded_models: [%{model_id: "test-model"}],
      active_request_count: 2,
      node_metadata: %{node_id: "node-1", display_name: "Pilot Node"},
      runtime_health: %{ready: true, health_code: nil, health_message: nil}
    }

    {result, Map.merge(snapshot, fields)}
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
    previous_snapshot = Application.get_env(:orchard_controller, :operator_health_test_snapshot)

    Application.delete_env(:orchard_controller, :operator_health_test_snapshot)

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
      restore_env(:operator_health_test_snapshot, previous_snapshot)
    end)

    :ok
  end

  test "SPEC.md §3.1 missing credentials return 401 no-store before health probes" do
    put_runtime_snapshot(:ok, %{diagnostics: diagnostics(System.system_time(:millisecond))})
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
    put_runtime_snapshot(:ok, %{diagnostics: diagnostics(System.system_time(:millisecond))})
    token = tenant_token!("ops-health-tenant")
    conn = request(token)

    assert_auth_error(conn, 403, "operator_required")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 a tenant-scoped operator returns 403 no-store before health probes" do
    put_runtime_snapshot(:ok, %{diagnostics: diagnostics(System.system_time(:millisecond))})
    token = service_account_token!("ops-health-tenant-operator", :tenant_operator)
    conn = request(token)

    assert_auth_error(conn, 403, "operator_required")
    assert_no_store(conn)
    refute_health_probes()
  end

  test "SPEC.md §3.1 a service account without a cluster role returns 403 no-store before health probes" do
    put_runtime_snapshot(:ok, %{diagnostics: diagnostics(System.system_time(:millisecond))})
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
    assert Map.fetch!(body["runtime"], "diagnostics") == nil
    assert_health_probes()
  end

  test "SPEC.md §4.6.1 operator health re-normalizes redacted inventory from one snapshot" do
    time = System.system_time(:millisecond) - 5000
    put_runtime_snapshot(:ok, %{diagnostics: diagnostics(time)})
    token = service_account_token!("ops-health-diagnostics", :operator)
    conn = request(token)
    body = Jason.decode!(conn.resp_body)
    block = body["runtime"]["diagnostics"]

    assert conn.status == 200
    assert_success_body(body)
    assert_no_store(conn)
    assert Enum.sort(Map.keys(block)) == ~w(authority inventory runtime schema_version)
    assert block["authority"] == "observation_only"
    assert block["schema_version"] == 1
    assert block["runtime"]["health"] == "ready"
    assert block["runtime"]["observed_at_unix_ms"] == time
    assert block["inventory"]["observed_at_unix_ms"] == time

    cpu = block["inventory"]["cpu"]
    assert cpu["age_ms"] >= 5000
    assert cpu["age_ms"] <= System.system_time(:millisecond) - time

    assert Map.delete(cpu, "age_ms") == %{
             "status" => "observed",
             "source" => "cpu_probe",
             "observed_at_unix_ms" => time,
             "count" => 7
           }

    assert block["inventory"]["nvidia"]["count"] == 1
    assert block["inventory"]["amd"]["count"] == 2
    assert block["inventory"]["memory"]["count"] == nil
    refute conn.resp_body =~ "diagnostic-secret"
    assert_health_probes()
  end

  test "SPEC.md §4.6.1 missing, invalid and unknown diagnostic blocks are null" do
    token = service_account_token!("ops-health-invalid-diagnostics", :operator)

    for block <- [nil, "invalid", %{}, %{schema_version: 2}, %{schema_version: 1.0}] do
      put_runtime_snapshot(:ok, %{diagnostics: block})
      conn = request(token)
      body = Jason.decode!(conn.resp_body)
      assert conn.status == 200
      assert_success_body(body)
      assert Map.fetch!(body["runtime"], "diagnostics") == nil
      assert_health_probes()
    end
  end

  test "SPEC.md §4.6.1 stale, future and invalid source timestamps fail closed in the response" do
    token = service_account_token!("ops-health-diagnostic-freshness", :operator)
    now = System.system_time(:millisecond)

    for {time, state} <- [
          {now - 195_001, "stale"},
          {now + 60_000, "invalid"},
          {nil, "invalid"},
          {"invalid", "invalid"}
        ] do
      put_runtime_snapshot(:ok, %{diagnostics: diagnostics(time)})
      conn = request(token)
      body = Jason.decode!(conn.resp_body)
      block = body["runtime"]["diagnostics"]
      assert conn.status == 200
      assert_success_body(body)
      assert body["runtime"]["health"] == "healthy"
      assert block["inventory"]["status"] == state
      assert block["inventory"]["cpu"]["count"] == nil
      assert block["inventory"]["nvidia"]["count"] == nil
      assert block["inventory"]["amd"]["count"] == nil
      assert block["runtime"]["health"] == "unknown"
      assert block["runtime"]["worker_state"] == "unknown"
      assert_health_probes()
    end

    block = diagnostics(now - 1000)
    block = put_in(block, [:inventory, :cpu, :observed_at_unix_ms], now - 195_001)
    put_runtime_snapshot(:ok, %{diagnostics: block})
    body = token |> request() |> Map.fetch!(:resp_body) |> Jason.decode!()
    assert body["runtime"]["diagnostics"]["inventory"]["cpu"]["count"] == nil
    assert body["runtime"]["diagnostics"]["inventory"]["amd"]["count"] == 2
    assert_health_probes()
  end

  test "SPEC.md §4.6.1 failed runtime snapshots suppress injected positive diagnostics" do
    token = service_account_token!("ops-health-failed-diagnostics", :operator)
    block = diagnostics(System.system_time(:millisecond) - 1000)

    for status <- [:timeout, :unavailable, :error, :ok] do
      put_runtime_snapshot(:error, %{status: status, diagnostics: block})
      conn = request(token)
      body = Jason.decode!(conn.resp_body)
      assert conn.status == 200
      assert_success_body(body)
      assert body["runtime"]["status"] == Atom.to_string(status)
      assert Map.fetch!(body["runtime"], "diagnostics") == nil
      assert_health_probes()
    end
  end

  test "SPEC.md §4.6.1 unavailable snapshots return null diagnostics without changing readiness" do
    Application.put_env(:orchard_controller, :operator_health_test_snapshot, nil)
    token = service_account_token!("ops-health-missing-snapshot", :operator)
    conn = request(token)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert body["status"] == "ok"
    assert body["runtime"]["status"] == "error"
    assert Map.fetch!(body["runtime"], "diagnostics") == nil
    assert_health_probes()
  end

  test "SPEC.md §3.1 public readiness remains status-only with diagnostic evidence available" do
    put_runtime_snapshot(:ok, %{diagnostics: diagnostics(System.system_time(:millisecond))})

    for {impl, status, body} <- [
          {Orchard.API.Ops.HealthControllerTest.PassingReadiness, 200, ~s({"status":"ok"})},
          {Orchard.API.Ops.HealthControllerTest.FailingReadiness, 503, ~s({"status":"error"})}
        ] do
      put_readiness_impl(impl)
      conn = get(build_conn(), "/health/ready")
      assert conn.status == status
      assert conn.resp_body == body
      assert_received :readiness_called
      refute_received {:runtime_snapshot_called, _}
    end
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
    put_runtime_snapshot(:ok, %{diagnostics: diagnostics(System.system_time(:millisecond))})
    token = service_account_token!("ops-health-failure-admin", :admin)
    conn = request(token)
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert_no_store(conn)
    assert body["status"] == "error"
    assert body["reason"] == "postgres_reachable"
    assert body["remediation"]["reason"] == "postgres_reachable"
    assert body["remediation"]["commands"] == ["sudo orchardctl env init"]
    assert body["runtime"]["diagnostics"]["inventory"]["cpu"]["count"] == 7
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
    refute conn.resp_body =~ "diagnostics"
    refute conn.resp_body =~ "diagnostic-secret"
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
    refute_received {:runtime_snapshot_called, _}
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

  defp put_runtime_snapshot(result, fields) do
    Application.put_env(:orchard_controller, :operator_health_test_snapshot, {result, fields})
  end

  defp diagnostics(time) do
    evidence = %{status: "observed", observed_at_unix_ms: time, age_ms: 0}

    %{
      schema_version: 1,
      authority: "observation_only",
      credentials: "diagnostic-secret",
      runtime:
        Map.merge(evidence, %{
          health: "ready",
          worker_state: "idle",
          health_message: "diagnostic-secret"
        }),
      inventory:
        Map.merge(evidence, %{
          cpu: Map.merge(evidence, %{source: "cpu_probe", count: 7, serial: "diagnostic-secret"}),
          nvidia: Map.merge(evidence, %{source: "nvidia_probe", count: 1}),
          amd: Map.merge(evidence, %{source: "amd_probe", count: 2}),
          memory: Map.merge(evidence, %{source: "memory_probe", count: 999}),
          raw_payload: List.duplicate("diagnostic-secret", 10_000)
        })
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:orchard_controller, key)
  defp restore_env(key, value), do: Application.put_env(:orchard_controller, key, value)
end
