defmodule Orchard.Release do
  @moduledoc false

  alias Ecto.Adapters.SQL

  @app :orchard_controller
  @db_checks_key :enable_db_checks
  @migration_advisory_lock_key 6_701_900_247
  @migration_lock_query "SELECT pg_try_advisory_xact_lock($1)"
  @reachable_query "SELECT 1"

  @type migration_lock_result ::
          {:ok, :locked}
          | {:error, :locked_by_other}
          | {:error, :database_checks_disabled}
          | {:error, :repo_not_started}
          | {:error, term()}

  @type migration_status_result :: {:ok, :current | :pending} | {:error, term()}

  @spec migrate() :: [term()]
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @spec postgres_reachable?() :: boolean()
  def postgres_reachable? do
    if db_checks_enabled?() and start_repo?() do
      load_app()
      repos() |> Enum.all?(&repo_reachable?/1)
    else
      false
    end
  rescue
    _error in [
      ArgumentError,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ] ->
      false
  end

  @spec migration_lockable?() :: migration_lock_result()
  def migration_lockable? do
    cond do
      not db_checks_enabled?() ->
        {:error, :database_checks_disabled}

      not start_repo?() ->
        {:error, :repo_not_started}

      true ->
        load_app()
        lockable_repos(repos())
    end
  rescue
    error in [
      ArgumentError,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ] ->
      {:error, error}
  end

  @spec migration_advisory_lock_key() :: integer()
  def migration_advisory_lock_key, do: @migration_advisory_lock_key

  @spec migration_status() :: migration_status_result()
  def migration_status do
    cond do
      not db_checks_enabled?() ->
        {:error, :database_checks_disabled}

      not start_repo?() ->
        {:error, :repo_not_started}

      true ->
        load_app()
        repos() |> migration_status_for_repos()
    end
  rescue
    error in [
      ArgumentError,
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      MatchError,
      Postgrex.Error
    ] ->
      {:error, error}
  end

  @spec migrations_current?() :: boolean()
  def migrations_current? do
    case migration_status() do
      {:ok, :current} -> true
      {:ok, :pending} -> false
      {:error, _reason} -> false
    end
  end

  defp repo_reachable?(repo) do
    case Ecto.Migrator.with_repo(repo, fn started_repo ->
           SQL.query(started_repo, @reachable_query, [])
         end) do
      {:ok, {:ok, _result}, _apps} -> true
      {:ok, {:error, _reason}, _apps} -> false
      {:error, _reason} -> false
    end
  end

  defp lockable_repos(repos) do
    Enum.reduce_while(repos, {:ok, :locked}, fn repo, _result ->
      case repo_migration_lockable(repo) do
        {:ok, :locked} = result -> {:cont, result}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp repo_migration_lockable(repo) do
    case Ecto.Migrator.with_repo(repo, &run_migration_lock_transaction/1) do
      {:ok, {:ok, {:ok, %{rows: [[true]]}}}, _apps} -> {:ok, :locked}
      {:ok, {:ok, {:ok, %{rows: [[false]]}}}, _apps} -> {:error, :locked_by_other}
      {:ok, {:ok, {:ok, result}}, _apps} -> {:error, {:unexpected_lock_result, result}}
      {:ok, {:ok, {:error, reason}}, _apps} -> {:error, reason}
      {:ok, {:error, reason}, _apps} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_migration_lock_transaction(repo) do
    repo.transaction(fn ->
      SQL.query(repo, @migration_lock_query, [@migration_advisory_lock_key])
    end)
  end

  defp migration_status_for_repos(repos) do
    Enum.reduce_while(repos, {:ok, :current}, fn repo, result ->
      case repo_migration_status(repo) do
        {:ok, :current} -> {:cont, result}
        {:ok, :pending} -> {:cont, {:ok, :pending}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp repo_migration_status(repo) do
    case Ecto.Migrator.with_repo(repo, &Ecto.Migrator.migrations/1) do
      {:ok, statuses, _apps} when is_list(statuses) -> classify_migration_statuses(statuses)
      {:ok, statuses, _apps} -> {:error, {:unexpected_migration_statuses, statuses}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_migration_statuses(statuses) do
    if Enum.all?(statuses, fn {status, _version, _name} -> status == :up end) do
      {:ok, :current}
    else
      {:ok, :pending}
    end
  end

  defp db_checks_enabled? do
    Application.get_env(@app, @db_checks_key, true)
  end

  defp start_repo? do
    Application.get_env(@app, :start_repo, true)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
