ExUnit.start()

case Process.whereis(Orchard.TestSupport.RepoManager) do
  nil ->
    {:ok, _pid} = Orchard.TestSupport.RepoManager.start_link()

  _pid ->
    :ok
end

:ok = Orchard.TestSupport.RepoManager.ensure_repo_started()
