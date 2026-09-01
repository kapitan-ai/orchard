defmodule Orchard.PackagedNodeCommandRuntimeTest do
  use Orchard.DataCase, async: false

  alias Orchard.PackagedNodeCommandRuntime

  test "SPEC 11.9 uses the existing supervised Repo without replacing it" do
    repo_pid = Process.whereis(Orchard.Repo)

    assert {:ok, "ok"} = PackagedNodeCommandRuntime.run(fn -> {:ok, "ok"} end)
    assert Process.whereis(Orchard.Repo) == repo_pid
    assert Process.alive?(repo_pid)
  end

  test "missing supervised Repo fails closed without starting temporary state" do
    repo_pid = Process.whereis(Orchard.Repo)
    missing_repo = Module.concat(__MODULE__, MissingRepo)

    assert {:error, message, 1} =
             PackagedNodeCommandRuntime.run(fn -> flunk("callback must not run") end,
               repo: missing_repo
             )

    assert message =~ "database is unavailable: Controller Repo is not running"
    assert Process.whereis(missing_repo) == nil
    assert Process.whereis(Orchard.Repo) == repo_pid
  end

  test "unreachable Repo and callback database failures are normalized without replacing Repo" do
    repo_pid = Process.whereis(Orchard.Repo)
    query_runner = fn Orchard.Repo, "SELECT 1", [] -> {:error, RuntimeError.exception("down")} end

    assert {:error, message, 1} =
             PackagedNodeCommandRuntime.run(fn -> flunk("callback must not run") end,
               query_runner: query_runner
             )

    assert message =~ "database is unavailable: down"

    assert {:error, callback_message, 1} =
             PackagedNodeCommandRuntime.run(fn ->
               raise DBConnection.ConnectionError, message: "callback connection lost"
             end)

    assert callback_message =~ "database is unavailable: callback connection lost"
    assert Process.whereis(Orchard.Repo) == repo_pid
    assert Process.alive?(repo_pid)
  end
end
