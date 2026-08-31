defmodule Orchard.PackagedNodeCommandRuntime do
  @moduledoc false

  alias Ecto.Adapters.SQL
  alias Orchard.PackagedNodeCommand

  @controller_env_path "/Library/Application Support/Orchard/config/controller.env"
  @reachable_query "SELECT 1"

  @type error :: {:database_unavailable, String.t()}
  @type query_runner :: (module(), String.t(), list() -> {:ok, term()} | {:error, Exception.t()})

  @spec run((-> PackagedNodeCommand.result()), keyword()) :: PackagedNodeCommand.result()
  def run(fun, opts \\ []) when is_function(fun, 0) do
    json? = Keyword.get(opts, :json, false)
    repo = Keyword.get(opts, :repo, Orchard.Repo)
    query_runner = Keyword.get(opts, :query_runner, &SQL.query/3)

    case with_repo(fun, repo, query_runner) do
      {:ok, result} -> result
      {:error, reason} -> command_error(reason, json?)
    end
  end

  defp with_repo(fun, repo, query_runner) do
    case Process.whereis(repo) do
      pid when is_pid(pid) ->
        run_after_reachable(fun, repo, query_runner)

      _missing ->
        {:error, {:database_unavailable, unavailable_message("Controller Repo is not running")}}
    end
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:error, {:database_unavailable, unavailable_message(Exception.message(error))}}
  end

  defp run_after_reachable(fun, repo, query_runner) do
    case query_runner.(repo, @reachable_query, []) do
      {:ok, _result} ->
        run_callback(fun)

      {:error, reason} ->
        {:error, {:database_unavailable, unavailable_message(Exception.message(reason))}}
    end
  end

  defp run_callback(fun) do
    {:ok, fun.()}
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] ->
      {:error, {:database_unavailable, unavailable_message(Exception.message(error))}}

    error ->
      reraise error, __STACKTRACE__
  end

  defp command_error({:database_unavailable, message}, true) do
    {:error,
     Jason.encode!(
       %{
         object: "error",
         code: "database_unavailable",
         message: message
       },
       pretty: true
     ), 1}
  end

  defp command_error({:database_unavailable, message}, false) do
    {:error, "Error: #{message}", 1}
  end

  defp unavailable_message(reason) do
    "database is unavailable: #{reason}. Verify DATABASE_URL in #{@controller_env_path}, confirm PostgreSQL is reachable, and run sudo orchardctl migrate if migrations are pending."
  end
end
