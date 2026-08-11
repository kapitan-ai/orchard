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
    previous_artifact_provider =
      Application.get_env(:orchard_controller, :scheduler_artifact_acquirable_provider)

    # Healthy-path tests exercise capacity/ranking/dispatch, not Model Hub layout.
    # Suites that need missing-artifact paths override this provider locally.
    Application.put_env(
      :orchard_controller,
      :scheduler_artifact_acquirable_provider,
      fn _request -> true end
    )

    on_exit(fn ->
      if is_nil(previous_artifact_provider) do
        Application.delete_env(:orchard_controller, :scheduler_artifact_acquirable_provider)
      else
        Application.put_env(
          :orchard_controller,
          :scheduler_artifact_acquirable_provider,
          previous_artifact_provider
        )
      end
    end)

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
