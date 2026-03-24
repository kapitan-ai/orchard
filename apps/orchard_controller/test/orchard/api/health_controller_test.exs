defmodule Orchard.API.HealthControllerTest.RuntimeOkStub do
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
         listen_port: 50071,
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

defmodule Orchard.API.HealthControllerTest.RuntimeTimeoutStub do
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

defmodule Orchard.API.HealthControllerTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.Router

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        runtime_impl: Orchard.API.HealthControllerTest.RuntimeOkStub
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)
    :ok
  end

  test "health live endpoint responds with ok", %{conn: _conn} do
    conn =
      build_conn(:get, "/health/live")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "health ready endpoint reports the M0 readiness subset", %{conn: _conn} do
    conn =
      build_conn(:get, "/health/ready")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert body["status"] == "error"
    assert body["reason"] == "postgres_reachable"
    assert body["checks"]["controller_boot_completed"] == true
    assert body["checks"]["postgres_reachable"] == false
    assert body["checks"]["migrations_current"] == false
    assert body["checks"]["public_api_https_enabled"] == true
    # Runtime summary is additive and does not affect HTTP status
    assert is_map(body["runtime"])
  end

  test "health ready endpoint reflects transport degraded state", %{conn: _conn} do
    previous = Application.get_env(:orchard_controller, :transport_degraded, false)
    Application.put_env(:orchard_controller, :transport_degraded, true)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :transport_degraded, previous)
    end)

    conn =
      build_conn(:get, "/health/ready")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert body["status"] == "error"
    # Causal priority: postgres_reachable fails before public_api_https_enabled
    assert body["reason"] == "postgres_reachable"
    assert body["checks"]["postgres_reachable"] == false
    assert body["checks"]["migrations_current"] == false
    assert body["checks"]["public_api_https_enabled"] == false
  end

  test "health ready includes runtime summary with ok status on success", %{conn: _conn} do
    conn =
      build_conn(:get, "/health/ready")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

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

  test "health ready runtime probe passes 1s timeout", %{conn: _conn} do
    _conn =
      build_conn(:get, "/health/ready")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

    assert_received {:runtime_snapshot_called, opts}
    assert opts[:timeout] == 1_000
  end

  test "health ready runtime timeout does not change HTTP status", %{conn: _conn} do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.put(previous, :runtime_impl, Orchard.API.HealthControllerTest.RuntimeTimeoutStub)
    )

    conn =
      build_conn(:get, "/health/ready")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

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

  test "health ready runtime summary has unsupported health when metadata absent", %{conn: _conn} do
    conn =
      build_conn(:get, "/health/ready")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

    # Default stub has runtime_health, so health is "healthy"
    body = Jason.decode!(conn.resp_body)
    assert body["runtime"]["health"] == "healthy"
  end
end
