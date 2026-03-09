defmodule Orchard.Release do
  @moduledoc false

  @app :orchard_controller
  @db_checks_key :enable_db_checks

  @spec migrate() :: [term()]
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @spec migrations_current?() :: boolean()
  def migrations_current? do
    case db_checks_enabled?() and Application.get_env(:orchard_controller, :start_repo, true) do
      true ->
        load_app()
        repos() |> Enum.all?(&repo_migrations_current?/1)

      false ->
        false
    end
  rescue
    _ -> false
  end

  defp repo_migrations_current?(repo) do
    {:ok, _, statuses} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.migrations/1)
    Enum.all?(statuses, fn {status, _version, _name} -> status == :up end)
  end

  defp db_checks_enabled? do
    Application.get_env(@app, @db_checks_key, true)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
