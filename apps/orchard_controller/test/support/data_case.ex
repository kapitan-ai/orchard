defmodule Orchard.DataCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias Orchard.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Orchard.DataCase
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    ensure_repo_started!()
    :ok = Sandbox.checkout(Orchard.Repo)

    unless tags[:async] do
      Sandbox.mode(Orchard.Repo, {:shared, self()})
    end

    :ok
  end

  defp ensure_repo_started! do
    case Process.whereis(Orchard.Repo) do
      nil ->
        case Orchard.Repo.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
