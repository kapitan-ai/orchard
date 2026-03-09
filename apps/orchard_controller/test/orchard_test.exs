defmodule OrchardTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Orchard.API.ErrorJSON
  alias Orchard.API.Readiness
  alias Orchard.API.Router
  alias Orchard.Release

  test "controller version is exposed" do
    assert Orchard.version() == "0.1.0"
  end

  test "health live endpoint responds with ok" do
    conn =
      :get
      |> conn("/health/live")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

    assert conn.status == 200
    assert Jason.decode!(conn.resp_body) == %{"status" => "ok"}
  end

  test "health ready endpoint reports the M0 readiness subset" do
    conn =
      :get
      |> conn("/health/ready")
      |> put_req_header("accept", "application/json")
      |> Router.call(Router.init([]))

    body = Jason.decode!(conn.resp_body)

    assert conn.status == 503
    assert body["status"] == "error"
    assert body["reason"] == "postgres_reachable"
    assert body["checks"]["controller_boot_completed"] == true
    assert body["checks"]["postgres_reachable"] == false
    assert body["checks"]["migrations_current"] == false
  end

  test "readiness and release helpers fail closed without a running repo" do
    assert {:error, :postgres_reachable, _checks} = Readiness.status()
    refute Release.migrations_current?()
  end

  test "error json renders standard status messages" do
    assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end
end
