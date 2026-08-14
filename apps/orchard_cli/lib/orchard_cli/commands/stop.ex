defmodule OrchardCLI.Commands.Stop do
  @moduledoc """
  CLI handler for `orchardctl stop`.

  Stops Orchard services via launchd (packaged install only, requires root).
  Boots out the controller and node agent in reverse dependency order.
  """

  alias OrchardCLI.Commands.{LifecycleSupport, ManagedNodeAgentStop}

  # ── Public API ──────────────────────────────────────────────────────

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(["help"], _runtime), do: {:ok, usage()}
  def run(["--help"], _runtime), do: {:ok, usage()}
  def run([], runtime), do: run_stop(runtime)
  def run(_args, _runtime), do: {:error, usage(), 1}

  # ── Stop Flow ──────────────────────────────────────────────────────

  defp run_stop(runtime) do
    with :ok <- LifecycleSupport.require_root("stop", runtime),
         {:ok, role} <- LifecycleSupport.install_role(runtime),
         runtime = Map.put(runtime, :install_role, role),
         :ok <- validate_packaged_context(runtime) do
      stop_services(runtime, role)
    end
  end

  defp validate_packaged_context(runtime) do
    services = LifecycleSupport.services(:stop, runtime)
    any_loaded = Enum.any?(services, &LifecycleSupport.service_loaded?(&1, runtime))

    if any_loaded or LifecycleSupport.any_plist_exists?(runtime) do
      :ok
    else
      {:error,
       "Error: Orchard packaged install not found.\n\n" <>
         "orchardctl start/stop manage packaged launchd services only.\n" <>
         "For development, use: bin/dev", 1}
    end
  end

  defp stop_service(%{id: :node_agent} = service, runtime) do
    runtime
    |> Map.get(:managed_node_agent_stop, &ManagedNodeAgentStop.stop/2)
    |> then(& &1.(service, runtime))
  end

  defp stop_service(service, runtime), do: LifecycleSupport.ensure_stopped(service, runtime)

  defp stop_services(runtime, role) do
    services = LifecycleSupport.services(:stop, runtime)

    case bootout_all(services, runtime, []) do
      {:ok, results} ->
        {:ok, format_result(results, role)}

      {:error, _msg, _code} = err ->
        err
    end
  end

  defp bootout_all([], _runtime, acc), do: {:ok, Enum.reverse(acc)}

  defp bootout_all([svc | rest], runtime, acc) do
    case stop_service(svc, runtime) do
      {:stopped, _} = result ->
        bootout_all(rest, runtime, [result | acc])

      {:already_stopped, _} = result ->
        bootout_all(rest, runtime, [result | acc])

      {:error, msg, code} ->
        if acc != [] do
          {:error,
           msg <>
             "\nNote: some services may have been partially stopped.\n" <>
             "Run: sudo orchardctl stop", code}
        else
          {:error, msg, code}
        end
    end
  end

  defp format_result(results, role) do
    all_already = Enum.all?(results, fn {action, _} -> action == :already_stopped end)
    any_already = Enum.any?(results, fn {action, _} -> action == :already_stopped end)
    role_line = "\nRole: #{LifecycleSupport.display_role(role)}"

    message =
      cond do
        all_already -> "Orchard services are already stopped."
        any_already -> "Stopped Orchard services; some services were already stopped."
        true -> "Stopped Orchard services."
      end

    message <> role_line
  end

  # ── Default Runtime ──────────────────────────────────────────────────

  defp default_runtime do
    %{}
  end

  # ── Usage ────────────────────────────────────────────────────────────

  defp usage do
    """
    Usage: sudo orchardctl stop

    Stop Orchard services via launchd (packaged install only).

    Boots out the controller and node agent. Safe to run when
    services are already stopped.

    Requires root privileges.

    Examples:
      sudo orchardctl stop
      sudo orchardctl stop --help
    """
    |> String.trim()
  end
end
