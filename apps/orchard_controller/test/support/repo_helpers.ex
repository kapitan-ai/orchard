defmodule Orchard.TestSupport.RepoHelpers do
  @moduledoc """
  Helpers for repo-off testing.

  Temporarily unregisters `Orchard.Repo` so that code paths guarded by
  `Process.whereis(Orchard.Repo)` see nil. Always restores the name
  in an `after` block.

  Only safe in `async: false` test modules — the name is global.
  """

  @doc """
  Runs `fun` with `Orchard.Repo` unregistered, then re-registers it.

  Returns the result of `fun`.

      with_repo_unregistered(fn ->
        assert Nodes.list_nodes() == []
      end)
  """
  def with_repo_unregistered(fun) when is_function(fun, 0) do
    repo_pid = Process.whereis(Orchard.Repo)

    unless is_pid(repo_pid) do
      raise "Orchard.Repo is not registered — cannot unregister"
    end

    Process.unregister(Orchard.Repo)

    try do
      fun.()
    after
      case Process.whereis(Orchard.Repo) do
        nil ->
          if Process.alive?(repo_pid) do
            Process.register(repo_pid, Orchard.Repo)
          else
            raise "Orchard.Repo exited while unregistered — cannot restore name"
          end

        ^repo_pid ->
          :ok

        other ->
          raise "Orchard.Repo was re-registered to #{inspect(other)} while unregistered"
      end
    end
  end
end
