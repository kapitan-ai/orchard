defmodule Orchard.API.HealthControllerTest do
  use Orchard.ConnCase, async: false

  @moduletag :live

  alias Orchard.API.Readiness

  defmodule OkReadiness do
    def status do
      {:ok,
       %{
         postgres_reachable: true,
         migrations_current: true,
         public_api_https_enabled: true,
         controller_boot_completed: true
       }}
    end
  end

  defmodule FailedReadiness do
    def status do
      {:error, :postgres_reachable,
       %{
         postgres_reachable: false,
         migrations_current: false,
         public_api_https_enabled: false,
         controller_boot_completed: false
       }}
    end
  end

  defmodule RaiseReadiness do
    def status, do: raise("readiness secret")
  end

  defmodule ExitReadiness do
    def status, do: exit(:readiness_failed)
  end

  defmodule ThrowReadiness do
    def status, do: throw(:readiness_failed)
  end

  defmodule MalformedReadiness do
    def status, do: {:ok, %{controller_boot_completed: true}}
  end

  defmodule BlockReadiness do
    def status do
      health = Application.fetch_env!(:orchard_controller, :health)
      send(Keyword.fetch!(health, :test_pid), {:readiness_task_started, self()})

      receive do
        :release -> OkReadiness.status()
      end
    end
  end

  setup do
    previous = Application.get_env(:orchard_controller, :health, [])

    on_exit(fn ->
      Application.put_env(:orchard_controller, :health, previous)
    end)

    :ok
  end

  test "SPEC.md §3.1 health live returns the exact public body through Endpoint" do
    conn = request("/health/live")

    assert conn.status == 200
    assert conn.resp_body == ~s({"status":"ok"})
  end

  test "SPEC.md §3.1 health ready returns the exact public success body through Endpoint" do
    put_impl(OkReadiness)
    conn = request("/health/ready")

    assert conn.status == 200
    assert conn.resp_body == ~s({"status":"ok"})
  end

  test "SPEC.md §3.1 health ready returns the exact public error body through Endpoint" do
    put_impl(FailedReadiness)
    assert_unavailable_response()
  end

  test "SPEC.md §3.1 health ready fails closed through Endpoint when readiness raises" do
    put_impl(RaiseReadiness)
    conn = assert_unavailable_response()

    refute conn.resp_body =~ "secret"
  end

  test "SPEC.md §3.1 health ready fails closed through Endpoint when readiness exits" do
    put_impl(ExitReadiness)
    assert_unavailable_response()
  end

  test "SPEC.md §3.1 health ready fails closed through Endpoint when readiness throws" do
    put_impl(ThrowReadiness)
    assert_unavailable_response()
  end

  test "SPEC.md §3.1 health ready fails closed through Endpoint for malformed readiness" do
    put_impl(MalformedReadiness)
    assert_unavailable_response()
  end

  @tag timeout: 7_000
  test "SPEC.md §3.1 health ready times out through Endpoint and terminates readiness work" do
    put_impl(BlockReadiness, test_pid: self())
    started_at = System.monotonic_time(:millisecond)
    request_task = Task.async(fn -> request("/health/ready") end)

    assert_receive {:readiness_task_started, readiness_pid}, 1_000
    monitor_ref = Process.monitor(readiness_pid)

    conn = Task.await(request_task, 6_000)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert conn.status == 503
    assert conn.resp_body == ~s({"status":"error"})
    assert elapsed_ms < 6_000
    assert_receive {:DOWN, ^monitor_ref, :process, ^readiness_pid, _reason}, 500
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

  defp assert_unavailable_response do
    conn = request("/health/ready")

    assert conn.status == 503
    assert conn.resp_body == ~s({"status":"error"})
    conn
  end

  defp request(path) do
    build_conn()
    |> put_req_header("accept", "application/json")
    |> get(path)
  end

  defp put_impl(impl, opts \\ []) do
    health = Application.get_env(:orchard_controller, :health, [])

    Application.put_env(
      :orchard_controller,
      :health,
      Keyword.merge(health, [readiness_impl: impl] ++ opts)
    )
  end
end
