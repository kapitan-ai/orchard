defmodule OrchardCLI.RepoRuntime do
  @moduledoc false

  alias Ecto.Adapters.SQL

  @controller_app :orchard_controller
  @controller_env_path "/Library/Application Support/Orchard/config/controller.env"
  @reachable_query "SELECT 1"

  @type error :: {:database_unavailable, String.t()}

  @spec run((-> OrchardCLI.command_result()), keyword()) :: OrchardCLI.command_result()
  def run(fun, opts \\ []) when is_function(fun, 0) do
    json? = Keyword.get(opts, :json, false)

    case with_repo(fun) do
      {:ok, result} -> result
      {:error, reason} -> command_error(reason, json?)
    end
  end

  @spec with_repo((-> result)) :: {:ok, result} | {:error, error()} when result: term()
  def with_repo(fun) when is_function(fun, 0) do
    Application.load(@controller_app)

    case repo_configuration_error() do
      nil -> run_with_repo(fun)
      message -> {:error, {:database_unavailable, message}}
    end
  rescue
    error in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ] ->
      {:error, {:database_unavailable, unavailable_message(Exception.message(error))}}
  end

  @spec command_error(error(), boolean()) :: OrchardCLI.command_result()
  def command_error({:database_unavailable, message}, true) do
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

  def command_error({:database_unavailable, message}, false) do
    {:error, "Error: #{message}", 1}
  end

  defp run_with_repo(fun) do
    case Ecto.Migrator.with_repo(Orchard.Repo, fn repo -> run_after_reachable(repo, fun) end) do
      {:ok, {:repo_runtime_result, result}, _apps} ->
        {:ok, result}

      {:ok, {:repo_runtime_error, message}, _apps} ->
        {:error, {:database_unavailable, message}}

      {:ok, {:repo_runtime_exception, error, stacktrace}, _apps} ->
        reraise error, stacktrace

      {:error, reason} ->
        {:error, {:database_unavailable, unavailable_message(format_reason(reason))}}
    end
  rescue
    error in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ] ->
      {:error, {:database_unavailable, unavailable_message(Exception.message(error))}}
  end

  defp run_after_reachable(repo, fun) do
    case SQL.query(repo, @reachable_query, []) do
      {:ok, _result} -> run_callback(fun)
      {:error, reason} -> {:repo_runtime_error, unavailable_message(format_reason(reason))}
    end
  end

  defp run_callback(fun) do
    {:repo_runtime_result, fun.()}
  rescue
    error in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Postgrex.Error
    ] ->
      {:repo_runtime_error, unavailable_message(Exception.message(error))}

    error ->
      {:repo_runtime_exception, error, __STACKTRACE__}
  end

  defp repo_started? do
    pid = Process.whereis(Orchard.Repo)
    is_pid(pid) and Process.alive?(pid)
  end

  defp repo_configuration_error do
    cond do
      repo_started?() ->
        nil

      not repo_has_connection_config?() ->
        missing_database_url_message()

      not Application.get_env(@controller_app, :start_repo, true) ->
        disabled_repo_message()

      true ->
        nil
    end
  end

  defp repo_has_connection_config? do
    repo_config = Application.get_env(@controller_app, Orchard.Repo, [])
    Keyword.has_key?(repo_config, :url) or Keyword.has_key?(repo_config, :database)
  end

  defp missing_database_url_message do
    "database is unavailable: DATABASE_URL is not configured. For packaged installs, run DB-backed orchardctl commands with sudo so the wrapper can read #{@controller_env_path}, then verify DATABASE_URL is set."
  end

  defp disabled_repo_message do
    "database is unavailable: the controller Repo is configured not to start in this runtime. For packaged installs, run DB-backed orchardctl commands with sudo so the wrapper can read #{@controller_env_path}, then verify DATABASE_URL is set."
  end

  defp unavailable_message(reason) do
    "database is unavailable: #{reason}. Verify DATABASE_URL in #{@controller_env_path}, confirm PostgreSQL is reachable, and run sudo orchardctl migrate if migrations are pending."
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
