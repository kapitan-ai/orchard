defmodule Orchard.API.HealthControllerTest do
  use Orchard.ConnCase, async: false

  alias Orchard.API.Router

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
end
