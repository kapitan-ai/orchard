defmodule Orchard.API.HealthControllerTest do
  use Orchard.ConnCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.{Readiness, Router}

  defmodule RaiseReadiness do
    def status, do: raise("readiness secret")
  end

  test "SPEC.md §3.1 health live returns the exact public body" do
    conn = request("/health/live")

    assert conn.status == 200
    assert conn.resp_body == ~s({"status":"ok"})
  end

  test "SPEC.md §3.1 health ready returns the exact public error body" do
    conn = request("/health/ready")

    assert conn.status == 503
    assert conn.resp_body == ~s({"status":"error"})
  end

  test "SPEC.md §3.1 health ready returns the exact public success body" do
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

    conn = request("/health/ready")

    assert conn.status == 200
    assert conn.resp_body == ~s({"status":"ok"})
  end

  test "SPEC.md §3.1 health ready returns exact error body when readiness raises" do
    previous = Application.get_env(:orchard_controller, :health, [])
    Application.put_env(:orchard_controller, :health, readiness_impl: RaiseReadiness)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :health, previous)
    end)

    conn = request("/health/ready")

    assert conn.status == 503
    assert conn.resp_body == ~s({"status":"error"})
    refute conn.resp_body =~ "secret"
  end

  test "legacy M0 readiness contract is explicit and ordered" do
    assert Readiness.contract_version() == "orchard.readiness.legacy_m0.v1"

    assert Readiness.check_order() == [
             :postgres_reachable,
             :migrations_current,
             :public_api_https_enabled,
             :controller_boot_completed
           ]
  end

  defp request(path) do
    build_conn(:get, path)
    |> put_req_header("accept", "application/json")
    |> Router.call(Router.init([]))
  end
end
