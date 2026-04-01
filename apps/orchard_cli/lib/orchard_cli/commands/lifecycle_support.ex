defmodule OrchardCLI.Commands.LifecycleSupport do
  @moduledoc false

  # Internal helpers shared by Start and Stop commands.
  # Owns service definitions, root checks, and idempotent launchctl operations.

  @required_services [
    %{
      id: :node_agent,
      label: "com.orchard.node-agent",
      plist_path: "/Library/LaunchDaemons/com.orchard.node-agent.plist",
      display_name: "Node Agent"
    },
    %{
      id: :controller,
      label: "com.orchard.controller",
      plist_path: "/Library/LaunchDaemons/com.orchard.controller.plist",
      display_name: "Controller"
    }
  ]

  @optional_services [
    %{
      id: :postgres,
      label: "com.orchard.postgres",
      plist_path: "/Library/LaunchDaemons/com.orchard.postgres.plist",
      display_name: "Managed Postgres"
    }
  ]

  @all_services @optional_services ++ @required_services

  # ── Service Definitions ─────────────────────────────────────────────

  @doc false
  def services(direction, runtime) when direction in [:start, :stop] do
    configured = Map.get(runtime, :services)

    services =
      if is_list(configured) do
        configured
      else
        included_optional_services(runtime) ++ @required_services
      end

    case direction do
      :start -> services
      :stop -> Enum.reverse(services)
    end
  end

  # ── Root Check ─────────────────────────────────────────────────────

  @doc false
  def require_root(command, runtime) do
    uid_fn = Map.get(runtime, :uid, &default_uid/0)

    if uid_fn.() == 0 do
      :ok
    else
      {:error,
       "Error: root privileges required to #{command} Orchard services.\n" <>
         "Run: sudo orchardctl #{command}", 1}
    end
  end

  # ── Plist Detection ────────────────────────────────────────────────

  @doc false
  def missing_plists(runtime) do
    services(:start, runtime)
    |> Enum.reject(fn svc -> plist_exists?(svc, runtime) or service_loaded?(svc, runtime) end)
    |> Enum.map(& &1.plist_path)
  end

  @doc false
  def any_plist_exists?(runtime) do
    file_regular? = Map.get(runtime, :file_regular?, &File.regular?/1)
    services = Map.get(runtime, :services, @all_services)

    services
    |> Enum.any?(fn svc -> file_regular?.(svc.plist_path) end)
  end

  defp included_optional_services(runtime) do
    Enum.filter(@optional_services, fn svc ->
      plist_exists?(svc, runtime) or service_loaded?(svc, runtime)
    end)
  end

  defp plist_exists?(svc, runtime) do
    file_regular? = Map.get(runtime, :file_regular?, &File.regular?/1)
    file_regular?.(svc.plist_path)
  end

  # ── Service State Detection ─────────────────────────────────────────

  @doc false
  def service_loaded?(svc, runtime) do
    cmd_fn = Map.get(runtime, :cmd, &default_cmd/3)

    case cmd_fn.("launchctl", ["print", "system/#{svc.label}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  # ── Idempotent Start/Stop ───────────────────────────────────────────

  @doc false
  def ensure_started(svc, runtime) do
    if service_loaded?(svc, runtime) do
      {:already_running, svc}
    else
      cmd_fn = Map.get(runtime, :cmd, &default_cmd/3)

      case cmd_fn.("launchctl", ["bootstrap", "system", svc.plist_path], stderr_to_stdout: true) do
        {_output, 0} ->
          {:started, svc}

        {output, code} ->
          # Race: someone else may have started it between our check and bootstrap
          if service_loaded?(svc, runtime) do
            {:already_running, svc}
          else
            {:error,
             "Error: failed to start #{svc.display_name} (#{svc.label}).\n" <>
               format_launchctl_detail(output, code) <>
               "\nCheck: /Library/Application Support/Orchard/logs/", 1}
          end
      end
    end
  end

  @doc false
  def ensure_stopped(svc, runtime) do
    if not service_loaded?(svc, runtime) do
      {:already_stopped, svc}
    else
      cmd_fn = Map.get(runtime, :cmd, &default_cmd/3)

      case cmd_fn.("launchctl", ["bootout", "system/#{svc.label}"], stderr_to_stdout: true) do
        {_output, 0} ->
          {:stopped, svc}

        {output, code} ->
          # Race: service may have exited between our check and bootout
          if not service_loaded?(svc, runtime) do
            {:already_stopped, svc}
          else
            {:error,
             "Error: failed to stop #{svc.display_name} (#{svc.label}).\n" <>
               format_launchctl_detail(output, code) <>
               "\nTry: sudo launchctl bootout system/#{svc.label}", 1}
          end
      end
    end
  end

  # ── Defaults ──────────────────────────────────────────────────────

  defp format_launchctl_detail(output, code) do
    summary =
      output
      |> to_string()
      |> String.trim()
      |> String.split("\n", trim: true)
      |> List.first()

    case summary do
      nil -> "launchctl exit #{code}"
      "" -> "launchctl exit #{code}"
      line -> "launchctl exit #{code}: #{line}"
    end
  end

  defp default_cmd(program, args, opts) do
    System.cmd(program, args, opts)
  rescue
    e in ErlangError -> {Exception.message(e), 127}
  end

  defp default_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _ -> -1
    end
  end
end
