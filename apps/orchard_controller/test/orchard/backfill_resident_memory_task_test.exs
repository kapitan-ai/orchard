defmodule Mix.Tasks.Orchard.Backfill.ResidentMemoryTest.UnexpectedRepo do
end

defmodule Mix.Tasks.Orchard.Backfill.ResidentMemoryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo
  alias Orchard.TestSupport.RepoManager

  setup context do
    previous_ecto_repos = Application.fetch_env!(:orchard_controller, :ecto_repos)
    previous_repo_config = Application.fetch_env!(:orchard_controller, Repo)
    previous_start_endpoint = Application.get_env(:orchard_controller, :start_endpoint, false)
    previous_endpoint_config = Application.fetch_env!(:orchard_controller, Orchard.API.Endpoint)

    unless context[:skip_sandbox] do
      :ok = Sandbox.checkout(Repo)
    end

    Mix.Task.reenable("orchard.backfill.resident_memory")

    on_exit(fn ->
      Application.put_env(:orchard_controller, :ecto_repos, previous_ecto_repos)
      Application.put_env(:orchard_controller, Repo, previous_repo_config)
      Application.put_env(:orchard_controller, :start_endpoint, previous_start_endpoint)
      Application.put_env(:orchard_controller, Orchard.API.Endpoint, previous_endpoint_config)
      Mix.Task.reenable("orchard.backfill.resident_memory")
      :ok = RepoManager.ensure_repo_started()
    end)

    :ok
  end

  test "prints the dry-run banner and zero-count summary" do
    output =
      capture_io(fn ->
        Mix.Task.run("orchard.backfill.resident_memory", [])
      end)

    assert output =~ "DRY RUN — no changes will be written. Pass --apply to execute."
    assert output =~ "processed=0"
    assert output =~ "updated=0"
    assert output =~ "would_update=0"
    assert output =~ "failed=0"
  end

  test "passes through --apply and still prints the summary" do
    output =
      capture_io(fn ->
        Mix.Task.run("orchard.backfill.resident_memory", ["--apply"])
      end)

    assert output =~ "Applying resident_memory_bytes backfill..."
    assert output =~ "processed=0"
    assert output =~ "updated=0"
    assert output =~ "failed=0"
  end

  test "raises a clean startup error when the repo set is misconfigured" do
    Application.put_env(:orchard_controller, :ecto_repos, [Repo, Repo])

    assert_raise Mix.Error,
                 ~r/resident_memory_bytes backfill failed to start: \{:unexpected_repo_count, 2\}/,
                 fn ->
                   capture_io(fn ->
                     Mix.Task.run("orchard.backfill.resident_memory", [])
                   end)
                 end
  end

  test "raises a clean startup error for an unexpected single repo" do
    Application.put_env(
      :orchard_controller,
      :ecto_repos,
      [Mix.Tasks.Orchard.Backfill.ResidentMemoryTest.UnexpectedRepo]
    )

    assert_raise Mix.Error,
                 ~r/resident_memory_bytes backfill failed to start: \{:unexpected_repo, Mix.Tasks.Orchard.Backfill.ResidentMemoryTest.UnexpectedRepo\}/,
                 fn ->
                   capture_io(fn ->
                     Mix.Task.run("orchard.backfill.resident_memory", [])
                   end)
                 end
  end

  @tag skip_sandbox: true
  @tag skip:
         if(System.get_env("ORCHARD_RUN_EXTERNAL_MIX_SMOKE") == "1",
           do: false,
           else: "integration smoke only; set ORCHARD_RUN_EXTERNAL_MIX_SMOKE=1 to run"
         )
  test "external mix dry-run smoke succeeds" do
    {output, 0} = run_mix_command!(["orchard.backfill.resident_memory"])

    assert output =~ "DRY RUN — no changes will be written. Pass --apply to execute."
    assert output =~ "failed=0"
  end

  @tag skip_sandbox: true
  test "raises a clean startup error when DB reachability preflight fails" do
    Application.put_env(
      :orchard_controller,
      Repo,
      Keyword.merge(Application.fetch_env!(:orchard_controller, Repo),
        hostname: 123,
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )
    )

    :ok = RepoManager.stop_repo()

    assert_raise Mix.Error,
                 ~r/resident_memory_bytes backfill failed to start: \{:db_unreachable,/,
                 fn ->
                   capture_io(fn ->
                     Mix.Task.run("orchard.backfill.resident_memory", [])
                   end)
                 end
  end

  defp project_root do
    Path.expand("../../../..", __DIR__)
  end

  defp run_mix_command!(args) do
    task =
      Task.async(fn ->
        System.cmd("mix", args,
          cd: project_root(),
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 60_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> flunk("mix #{Enum.join(args, " ")} timed out")
    end
  end
end
