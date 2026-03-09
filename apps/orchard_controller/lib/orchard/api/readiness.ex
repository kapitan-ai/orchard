defmodule Orchard.API.Readiness do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Orchard.Release
  alias Orchard.Repo

  @db_checks_key :enable_db_checks

  @type checks :: %{required(atom()) => boolean()}
  @type status_result :: {:ok, checks()} | {:error, atom(), checks()}

  @spec status() :: status_result()
  def status do
    checks = %{
      controller_boot_completed: true,
      postgres_reachable: postgres_reachable?(),
      migrations_current: migrations_current?()
    }

    if Enum.all?(checks, fn {_check, status} -> status end) do
      {:ok, checks}
    else
      {:error, first_failure(checks), checks}
    end
  end

  defp postgres_reachable? do
    if db_checks_enabled?() and Application.get_env(:orchard_controller, :start_repo, true) do
      case SQL.query(Repo, "SELECT 1", []) do
        {:ok, _result} -> true
        {:error, _reason} -> false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp migrations_current? do
    Release.migrations_current?()
  end

  defp db_checks_enabled? do
    Application.get_env(:orchard_controller, @db_checks_key, true)
  end

  defp first_failure(checks) do
    checks
    |> Enum.find_value(:unknown, fn
      {name, false} -> name
      {_name, true} -> nil
    end)
  end
end
