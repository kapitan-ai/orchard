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
    :ok = Sandbox.checkout(Orchard.Repo)

    unless tags[:async] do
      Sandbox.mode(Orchard.Repo, {:shared, self()})
    end

    :ok
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r/%{(\w+)}/, message, fn _match, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
