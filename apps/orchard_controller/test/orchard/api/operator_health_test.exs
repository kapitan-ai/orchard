defmodule Orchard.API.OperatorHealthTest.RuntimeOkStub do
  @moduledoc false

  def snapshot(opts \\ []) do
    send(self(), {:runtime_snapshot_called, opts})

    {:ok,
     %{
       worker_state: :idle,
       loaded_models: [%{model_id: "test-model", version: "v1"}],
       active_request_count: 2,
       node_metadata: %{
         node_id: "550e8400-e29b-41d4-a716-446655440000",
         display_name: "test-node",
         hostname: "test.local",
         listen_host: "127.0.0.1",
         listen_port: 50_071,
         agent_version: "0.1.0",
         worker_backend: "mlx"
       },
       runtime_health: %{
         ready: true,
         health_code: nil,
         health_message: nil,
         affected_model: nil
       }
     }}
  end
end

defmodule Orchard.API.OperatorHealthTest.RuntimeTimeoutStub do
  @moduledoc false

  def snapshot(_opts \\ []) do
    {:error,
     %{
       status: :timeout,
       code: "node_timeout",
       message: "node status request timed out",
       worker_state: :unknown,
       loaded_models: [],
       active_request_count: 0,
       node_metadata: nil,
       runtime_health: nil
     }}
  end
end

defmodule Orchard.API.OperatorHealthTest.LicensingValidStub do
  @moduledoc false

  def inspect_local do
    Process.get(
      :licensing_status_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: "/tmp/current.json",
        expires_at: ~U[2027-04-15 00:00:00Z]
      }
    )
  end
end

defmodule Orchard.API.OperatorHealthTest do
  use Orchard.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.Ops.HealthController
  alias Orchard.API.ReadinessRemediation

  setup do
    Process.delete(:licensing_status_response)
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        enabled: false,
        username: nil,
        password: nil,
        runtime_impl: Orchard.API.OperatorHealthTest.RuntimeOkStub,
        licensing_impl: Orchard.API.OperatorHealthTest.LicensingValidStub
      )
    )

    previous_mode = Application.get_env(:orchard_controller, :transport_mode)
    previous_cert_source = Application.get_env(:orchard_controller, :transport_cert_source)
    previous_degraded = Application.get_env(:orchard_controller, :transport_degraded)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      Application.put_env(:orchard_controller, :transport_mode, previous_mode)
      Application.put_env(:orchard_controller, :transport_cert_source, previous_cert_source)
      Application.put_env(:orchard_controller, :transport_degraded, previous_degraded)
    end)

    :ok
  end

  test "operator health endpoint reports the M0 readiness subset", %{conn: _conn} do
    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert body["status"] == "error"

    assert body["console"] == %{
             "enabled" => false,
             "auth_mode" => "disabled"
           }

    assert body["remediation"] == %{
             "reason" => "postgres_reachable",
             "summary" =>
               "Postgres is not reachable. Check database configuration and initialize the Orchard environment if it has not been created.",
             "commands" => ["sudo orchardctl env init"],
             "docs_anchor" => "readiness-postgres"
           }

    assert body["version"] == Orchard.version()
    assert body["build_ref"] == Orchard.BuildInfo.git_sha()
    assert body["build_ref"] == "unknown" or body["build_ref"] =~ ~r/\A[0-9a-f]{40}\z/
    assert body["build_date"] == Orchard.BuildInfo.build_date()
    assert body["build_channel"] == Orchard.BuildInfo.build_channel()
    assert body["reason"] == "postgres_reachable"
    assert body["checks"]["controller_boot_completed"] == true
    assert body["checks"]["postgres_reachable"] == false
    assert body["checks"]["migrations_current"] == false
    assert body["checks"]["public_api_https_enabled"] == false

    assert body["transport"] == %{
             "mode" => "plain_http_localhost",
             "degraded" => true,
             "cert_source" => "unknown"
           }

    # Runtime summary is additive and does not affect HTTP status
    assert is_map(body["runtime"])

    assert body["license"] == %{
             "status" => "valid",
             "reason" => nil,
             "message" => "License bundle is valid.",
             "expires_at" => "2027-04-15T00:00:00Z"
           }
  end

  test "operator health reports console metadata without exposing console credentials", %{
    conn: _conn
  } do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        enabled: true,
        auth: :basic,
        username: "console-user",
        password: "secret-password"
      )
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert body["console"] == %{
             "enabled" => true,
             "auth_mode" => "basic"
           }

    refute conn.resp_body =~ "console-user"
    refute conn.resp_body =~ "secret-password"
  end

  test "operator health reports disabled auth mode when console auth is none", %{conn: _conn} do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        enabled: true,
        auth: :none,
        username: "console-user",
        password: "secret-password"
      )
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert body["console"] == %{
             "enabled" => true,
             "auth_mode" => "disabled"
           }

    refute conn.resp_body =~ "console-user"
    refute conn.resp_body =~ "secret-password"
  end

  test "operator health reports mode-aware transport metadata", %{conn: _conn} do
    Application.put_env(:orchard_controller, :transport_mode, :direct_https)
    Application.put_env(:orchard_controller, :transport_cert_source, :operator_provided)
    Application.put_env(:orchard_controller, :transport_degraded, true)

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert body["transport"] == %{
             "mode" => "direct_https",
             "degraded" => false,
             "cert_source" => "operator_provided"
           }

    assert body["checks"]["public_api_https_enabled"] == true
  end

  test "operator health omits remediation when all readiness checks pass", %{conn: _conn} do
    previous_mode = Application.get_env(:orchard_controller, :transport_mode)
    previous_degraded = Application.get_env(:orchard_controller, :transport_degraded, false)
    previous_db_checks = Application.get_env(:orchard_controller, :enable_db_checks, true)
    previous_start_repo = Application.get_env(:orchard_controller, :start_repo, true)

    Application.put_env(:orchard_controller, :transport_mode, :direct_https)
    Application.put_env(:orchard_controller, :transport_degraded, false)
    Application.put_env(:orchard_controller, :enable_db_checks, true)
    Application.put_env(:orchard_controller, :start_repo, true)

    :ok = Sandbox.checkout(Orchard.Repo)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :transport_mode, previous_mode)
      Application.put_env(:orchard_controller, :transport_degraded, previous_degraded)
      Application.put_env(:orchard_controller, :enable_db_checks, previous_db_checks)
      Application.put_env(:orchard_controller, :start_repo, previous_start_repo)
    end)

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert body["status"] == "ok"
    refute Map.has_key?(body, "remediation")
  end

  test "operator health marks plain localhost HTTP as degraded regardless of legacy shim", %{
    conn: _conn
  } do
    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
    Application.put_env(:orchard_controller, :transport_cert_source, :unknown)
    Application.put_env(:orchard_controller, :transport_degraded, false)

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert body["transport"] == %{
             "mode" => "plain_http_localhost",
             "degraded" => true,
             "cert_source" => "unknown"
           }

    assert conn.status == 503
    assert body["status"] == "error"
    # Causal priority: postgres_reachable fails before public_api_https_enabled
    assert body["reason"] == "postgres_reachable"
    assert body["checks"]["postgres_reachable"] == false
    assert body["checks"]["migrations_current"] == false
    assert body["checks"]["public_api_https_enabled"] == false
  end

  test "operator health constrains cert source to direct HTTPS mode", %{conn: _conn} do
    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)
    Application.put_env(:orchard_controller, :transport_cert_source, :operator_provided)

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert body["transport"] == %{
             "mode" => "reverse_proxy",
             "degraded" => false,
             "cert_source" => "unknown"
           }
  end

  test "operator health treats unknown transport mode as degraded", %{conn: _conn} do
    Application.put_env(:orchard_controller, :transport_mode, :bogus)
    Application.put_env(:orchard_controller, :transport_cert_source, :operator_provided)

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert body["transport"] == %{
             "mode" => "unknown",
             "degraded" => true,
             "cert_source" => "unknown"
           }

    assert body["checks"]["public_api_https_enabled"] == false
  end

  test "operator health includes runtime summary with ok status on success", %{conn: _conn} do
    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)
    runtime = body["runtime"]

    assert runtime["status"] == "ok"
    assert runtime["node_id"] == "550e8400-e29b-41d4-a716-446655440000"
    assert runtime["display_name"] == "test-node"
    assert runtime["worker_state"] == "idle"
    assert runtime["health"] == "healthy"
    assert runtime["counts"]["active_requests"] == 2
    assert runtime["counts"]["loaded_models"] == 1
    assert runtime["message"] == nil
  end

  test "operator health runtime probe passes 1s timeout", %{conn: _conn} do
    _conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    assert_received {:runtime_snapshot_called, opts}
    assert opts[:timeout] == 1_000
  end

  test "operator health runtime timeout does not change HTTP status", %{conn: _conn} do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.put(previous, :runtime_impl, Orchard.API.OperatorHealthTest.RuntimeTimeoutStub)
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    # HTTP status driven by readiness, not runtime
    assert conn.status == 503
    assert body["status"] == "error"
    assert body["reason"] == "postgres_reachable"

    # Runtime reports timeout independently
    runtime = body["runtime"]
    assert runtime["status"] == "timeout"
    assert runtime["worker_state"] == "unknown"
    # runtime_health is nil on error → "unsupported"
    assert runtime["health"] == "unsupported"
    assert runtime["message"] == "node status request timed out"
  end

  test "operator health runtime summary has unsupported health when metadata absent", %{
    conn: _conn
  } do
    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    # Default stub has runtime_health, so health is "healthy"
    body = Jason.decode!(conn.resp_body)
    assert body["runtime"]["health"] == "healthy"
  end

  test "operator health license summary is observational and does not change readiness semantics",
       %{
         conn: _conn
       } do
    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert body["status"] == "error"
    assert body["reason"] == "postgres_reachable"
    assert body["license"]["status"] == "valid"
    assert body["license"]["message"] == "License bundle is valid."
  end

  test "operator health includes license tracking when certificate metadata exists", %{
    conn: _conn
  } do
    Process.put(
      :licensing_status_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: "/tmp/current.json",
        expires_at: ~U[2027-04-15 00:00:00Z],
        metadata: %{program: "aieh", reference: "aieh-2026-001"}
      }
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert body["reason"] == "postgres_reachable"

    assert body["license"]["tracking"] == %{
             "program" => "aieh",
             "reference" => "aieh-2026-001"
           }
  end

  test "operator health omits blank tracking subkeys and keeps present subkeys", %{conn: _conn} do
    Process.put(
      :licensing_status_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: "/tmp/current.json",
        metadata: %{program: "   ", reference: "aieh-2026-001"}
      }
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    license = conn.resp_body |> Jason.decode!() |> Map.fetch!("license")

    assert license["tracking"] == %{"reference" => "aieh-2026-001"}
    refute Map.has_key?(license["tracking"], "program")
  end

  test "operator health omits tracking when tracking metadata sanitizes to empty", %{conn: _conn} do
    Process.put(
      :licensing_status_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: "/tmp/current.json",
        metadata: %{program: nil, reference: "  "}
      }
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    license = conn.resp_body |> Jason.decode!() |> Map.fetch!("license")

    refute Map.has_key?(license, "tracking")
  end

  test "operator health includes license identifiers for valid bundles", %{conn: _conn} do
    Process.put(
      :licensing_status_response,
      %Orchard.Licensing{
        state: :valid,
        message: "License bundle is valid.",
        bundle_path: "/tmp/current.json",
        expires_at: ~U[2027-04-15 00:00:00Z],
        license_id: "lic_visible",
        machine_id: "mach_visible",
        licensee: "Acme Orchard Lab",
        max_machines: 3
      }
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    body = Jason.decode!(conn.resp_body)

    assert body["license"]["license_id"] == "lic_visible"
    assert body["license"]["machine_id"] == "mach_visible"
    assert body["license"]["licensee"] == "Acme Orchard Lab"
    assert body["license"]["max_machines"] == 3
  end

  test "operator health includes license identifiers for signed invalid states", %{conn: _conn} do
    for state <- [:expired, :not_yet_valid, :fingerprint_mismatch] do
      Process.put(
        :licensing_status_response,
        %Orchard.Licensing{
          state: state,
          message: "Signed but invalid license.",
          bundle_path: "/tmp/current.json",
          license_id: "lic_visible",
          machine_id: "mach_visible",
          licensee: "Acme Orchard Lab",
          max_machines: 3
        }
      )

      conn =
        build_conn(:get, "/ops/v1/health")
        |> put_req_header("accept", "application/json")
        |> HealthController.show(%{})

      body = Jason.decode!(conn.resp_body)

      assert body["license"]["license_id"] == "lic_visible"
      assert body["license"]["machine_id"] == "mach_visible"
      assert body["license"]["licensee"] == "Acme Orchard Lab"
      assert body["license"]["max_machines"] == 3
    end
  end

  test "operator health omits license identifiers when bundle is missing", %{conn: _conn} do
    Process.put(
      :licensing_status_response,
      %Orchard.Licensing{
        state: :missing_bundle,
        message: "No local license bundle is installed.",
        bundle_path: "/tmp/current.json"
      }
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    license = conn.resp_body |> Jason.decode!() |> Map.fetch!("license")

    for key <- ["license_id", "machine_id", "licensee", "max_machines"] do
      refute Map.has_key?(license, key)
    end
  end

  test "operator health gives sanitized remediation when readiness evaluation is unavailable" do
    assert ReadinessRemediation.for_reason(:readiness_unavailable) == %{
             reason: "readiness_unavailable",
             summary:
               "Readiness evaluation is unavailable. Retry the request and check Orchard controller logs if the condition persists.",
             commands: [],
             docs_anchor: nil
           }
  end

  test "operator health omits license identifiers for invalid signature states", %{conn: _conn} do
    Process.put(
      :licensing_status_response,
      %Orchard.Licensing{
        state: :invalid_license_signature,
        message: "failed signature validation",
        bundle_path: "/tmp/current.json",
        license_id: "lic_hidden",
        machine_id: "mach_hidden",
        licensee: "Hidden",
        max_machines: 1
      }
    )

    conn =
      build_conn(:get, "/ops/v1/health")
      |> put_req_header("accept", "application/json")
      |> HealthController.show(%{})

    license = conn.resp_body |> Jason.decode!() |> Map.fetch!("license")

    for key <- ["license_id", "machine_id", "licensee", "max_machines"] do
      refute Map.has_key?(license, key)
    end
  end
end
