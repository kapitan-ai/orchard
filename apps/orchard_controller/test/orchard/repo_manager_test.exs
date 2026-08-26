defmodule Orchard.TestSupport.RepoManagerTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo
  alias Orchard.TestSupport.RepoManager

  setup do
    previous_repo_config = Application.fetch_env!(:orchard_controller, Repo)

    on_exit(fn ->
      :ok = RepoManager.stop_repo()
      Application.put_env(:orchard_controller, Repo, previous_repo_config)
      :ok = RepoManager.ensure_repo_started()
    end)

    %{previous_repo_config: previous_repo_config}
  end

  test "ensure_repo_started replaces a running non-sandbox repo", %{
    previous_repo_config: previous_repo_config
  } do
    :ok = RepoManager.stop_repo()

    Application.put_env(
      :orchard_controller,
      Repo,
      Keyword.put(previous_repo_config, :pool, DBConnection.ConnectionPool)
    )

    {:ok, non_sandbox_repo} = Repo.start_link()
    Application.put_env(:orchard_controller, Repo, previous_repo_config)

    assert :ok = RepoManager.ensure_repo_started()
    refute Process.alive?(non_sandbox_repo)
    assert :ok = Sandbox.mode(Repo, :manual)
  end
end
