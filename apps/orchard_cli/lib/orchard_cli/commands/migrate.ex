defmodule OrchardCLI.Commands.Migrate do
  @moduledoc """
  CLI handler for `orchardctl migrate`.

  Runs packaged controller database migrations by delegating to the installed
  controller release wrapper. The CLI does not run migration logic in-process.
  """

  alias OrchardCLI.Commands.LifecycleSupport

  @controller_wrapper "/Library/Application Support/Orchard/bin/orchard-controller"
  @migration_eval "Orchard.Release.migrate()"

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(["help"], _runtime), do: {:ok, usage()}
  def run(["--help"], _runtime), do: {:ok, usage()}
  def run([], runtime), do: run_migrate(runtime)
  def run(_args, _runtime), do: {:error, usage(), 1}

  defp run_migrate(runtime) do
    with {:ok, role} <- LifecycleSupport.install_role(runtime) do
      migrate_for_role(role, runtime)
    end
  end

  defp migrate_for_role(:node_agent, _runtime) do
    {:ok,
     "Database migrations are not applicable for node-agent role.\n" <>
       "Role: node-agent\n" <>
       "Run: orchardctl status"}
  end

  defp migrate_for_role(role, runtime) when role in [:all, :controller] do
    with :ok <- require_root(runtime) do
      case run_wrapper(runtime) do
        {_output, 0} -> {:ok, success_message(role)}
        {output, code} -> {:error, failure_message(output, code), 1}
      end
    end
  end

  defp require_root(runtime) do
    uid = runtime |> Map.get(:uid, &default_uid/0) |> then(& &1.())

    if uid == 0 do
      :ok
    else
      {:error,
       "Error: root privileges required to run Orchard database migrations.\n" <>
         "Packaged database environment files are root-owned.\n" <>
         "Run: sudo orchardctl migrate", 1}
    end
  end

  defp run_wrapper(runtime) do
    cmd = Map.get(runtime, :cmd, &default_cmd/3)
    cmd.(@controller_wrapper, ["eval", @migration_eval], stderr_to_stdout: true)
  end

  defp success_message(role) do
    "Database migrations completed.\n" <>
      "Role: #{LifecycleSupport.display_role(role)}\n\n" <>
      "Next: configure controller transport before starting services.\n" <>
      "Configure direct HTTPS or reverse-proxy TLS, then run: sudo orchardctl start\n" <>
      "After services are started, run: orchardctl status"
  end

  defp failure_message(output, code) do
    class = classify_failure(output, code)
    line_count = summarized_line_count(output)

    "Error: #{class}.\n" <>
      "Summary: controller wrapper exited without completing migrations.\n" <>
      "Detail: wrapper exit #{code}; captured #{line_count} output line(s) suppressed.\n" <>
      "Logs: /Library/Application Support/Orchard/logs/\n" <>
      "Run: sudo orchardctl migrate"
  end

  defp classify_failure(_output, code) when code in [126, 127], do: "wrapper_invocation_failed"

  defp classify_failure(output, _code) do
    normalized = output |> to_string() |> String.downcase()

    if db_unreachable?(normalized) do
      "db_unreachable"
    else
      "migration_failed"
    end
  end

  defp db_unreachable?(output) do
    String.contains?(output, "connection refused") or
      String.contains?(output, "nxdomain") or
      String.contains?(output, "econnrefused") or
      String.contains?(output, "timeout") or
      String.contains?(output, "postgrex.protocol")
  end

  defp summarized_line_count(output) do
    output
    |> to_string()
    |> String.split("\n", trim: true)
    |> length()
  end

  defp default_runtime, do: %{}

  defp default_cmd(program, args, opts) do
    System.cmd(program, args, opts)
  rescue
    error in ErlangError ->
      case error.original do
        :eacces -> {"", 126}
        :enoent -> {"", 127}
        _other -> {"", 127}
      end
  end

  defp default_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} -> parse_uid(output)
      _other -> -1
    end
  end

  defp parse_uid(output) do
    case output |> String.trim() |> Integer.parse() do
      {uid, ""} -> uid
      _other -> -1
    end
  end

  defp usage do
    """
    Usage: sudo orchardctl migrate

    Run Orchard controller database migrations for packaged all/controller roles.

    Delegates to the installed controller wrapper:
      /Library/Application Support/Orchard/bin/orchard-controller eval 'Orchard.Release.migrate()'

    Requires root because packaged database environment files are root-owned.
    Node-agent role exits successfully because it has no controller database migrations.

    Examples:
      sudo orchardctl migrate
      sudo orchardctl migrate --help
    """
    |> String.trim()
  end
end
