defmodule OrchardCLI.Commands.Start do
  @moduledoc """
  CLI handler for `orchardctl start`.

  Starts Orchard.app-installed services via launchd (requires root).
  Bootstraps the node agent and controller, polls for readiness, then prints
  the status banner.
  """

  alias OrchardCLI.Commands.{LifecycleSupport, Status}

  @default_ready_timeout_ms 20_000
  @default_poll_interval_ms 500

  # ── Public API ──────────────────────────────────────────────────────

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(["help"], _runtime), do: {:ok, usage()}
  def run(["--help"], _runtime), do: {:ok, usage()}
  def run([], runtime), do: run_start(runtime)
  def run(_args, _runtime), do: {:error, usage(), 1}

  # ── Start Flow ─────────────────────────────────────────────────────

  defp run_start(runtime) do
    with :ok <- LifecycleSupport.require_root("start", runtime),
         {:ok, role} <- LifecycleSupport.install_role(runtime),
         runtime = Map.put(runtime, :install_role, role),
         :ok <- validate_packaged_install(runtime, role) do
      start_services(runtime, role)
    end
  end

  defp validate_packaged_install(runtime, role) do
    case LifecycleSupport.missing_plists(runtime) do
      [] ->
        :ok

      missing ->
        role_name = LifecycleSupport.display_role(role)
        paths = Enum.join(missing, "\n  ")

        {:error,
         "Error: Orchard.app installation for role #{role_name} is incomplete.\n" <>
           "Missing plist(s) for role #{role_name}:\n  #{paths}\n\n" <>
           "orchardctl start/stop manage packaged launchd services only.\n" <>
           "For development, use: bin/dev", 1}
    end
  end

  defp start_services(runtime, role) do
    services = LifecycleSupport.services(:start, runtime)

    case bootstrap_all(services, runtime, []) do
      {:ok, results} ->
        render_start_result(results, runtime, role)

      {:error, _msg, _code} = err ->
        err
    end
  end

  defp bootstrap_all([], _runtime, acc), do: {:ok, Enum.reverse(acc)}

  defp bootstrap_all([svc | rest], runtime, acc) do
    case LifecycleSupport.ensure_started(svc, runtime) do
      {:loaded, _} = result ->
        bootstrap_all(rest, runtime, [result | acc])

      {:already_loaded, _} = result ->
        bootstrap_all(rest, runtime, [result | acc])

      {:error, msg, code} ->
        if acc != [] do
          {:error, msg <> format_partial_start_note(acc), code}
        else
          {:error, msg, code}
        end
    end
  end

  defp render_start_result(results, _runtime, :node_agent) do
    preface = format_preface(results, :node_agent)

    {:ok,
     preface <>
       "\n\n" <>
       "Node Agent role: local launchd state updated.\n" <>
       "Controller: remote/not checked for node-agent role.\n" <>
       "Run: orchardctl status"}
  end

  defp render_start_result(results, runtime, role) do
    poll_and_render(results, runtime, role)
  end

  defp poll_and_render(results, runtime, role) do
    status_runtime = status_runtime_with_role(runtime, role)
    timeout_ms = Map.get(runtime, :ready_timeout_ms, @default_ready_timeout_ms)
    poll_ms = Map.get(runtime, :poll_interval_ms, @default_poll_interval_ms)
    monotonic_ms = Map.get(runtime, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end)
    sleep_fn = Map.get(runtime, :sleep, &Process.sleep/1)

    deadline = monotonic_ms.() + timeout_ms
    snap = poll_ready(status_runtime, deadline, poll_ms, monotonic_ms, sleep_fn)

    preface = format_preface(results, role)

    case snap.state do
      :ready ->
        banner = Status.render_snapshot(snap)
        {:ok, preface <> "\n\n" <> banner}

      :invalid_response ->
        {:error,
         preface <>
           "\n\n" <>
           format_invalid_response(snap) <>
           "\nRun: orchardctl status\n" <>
           "Logs: /Library/Application Support/Orchard/logs/", 1}

      :install_error ->
        {:error,
         preface <>
           "\n\n" <>
           "Error: #{snap.error}\n" <>
           "Run: orchardctl status\n" <>
           "Logs: /Library/Application Support/Orchard/logs/", 1}

      _other ->
        timeout_secs = div(timeout_ms, 1000)
        last_state = format_last_state(snap)

        {:error,
         preface <>
           "\n\n" <>
           "Error: controller did not become ready within #{timeout_secs}s.\n" <>
           last_state <>
           "\nRun: orchardctl status\n" <>
           "Logs: /Library/Application Support/Orchard/logs/", 1}
    end
  end

  defp poll_ready(status_runtime, deadline, poll_ms, monotonic_ms, sleep_fn) do
    snap = if status_runtime, do: Status.snapshot(status_runtime), else: Status.snapshot()

    if terminal_poll_state?(snap) or monotonic_ms.() >= deadline do
      snap
    else
      sleep_fn.(poll_ms)
      poll_ready(status_runtime, deadline, poll_ms, monotonic_ms, sleep_fn)
    end
  end

  defp status_runtime_with_role(runtime, role) do
    status_runtime =
      case Map.get(runtime, :status_runtime, %{}) do
        %{} = configured -> configured
        _other -> %{}
      end

    Map.put_new(status_runtime, :install_role, role)
  end

  defp format_preface(results, role) do
    all_already = Enum.all?(results, fn {action, _} -> action == :already_loaded end)
    any_already = Enum.any?(results, fn {action, _} -> action == :already_loaded end)
    role_line = "\nRole: #{LifecycleSupport.display_role(role)}"

    message =
      cond do
        all_already -> "Orchard services already loaded in launchd."
        any_already -> "Loaded Orchard services into launchd; some services were already loaded."
        true -> "Loaded Orchard services into launchd."
      end

    message <> role_line
  end

  defp format_partial_start_note(results) do
    ordered_results = Enum.reverse(results)

    loaded =
      ordered_results
      |> Enum.filter(fn {action, _svc} -> action == :loaded end)
      |> Enum.map(fn {_action, svc} -> svc.display_name end)

    already_loaded =
      ordered_results
      |> Enum.filter(fn {action, _svc} -> action == :already_loaded end)
      |> Enum.map(fn {_action, svc} -> svc.display_name end)

    note =
      case {loaded, already_loaded} do
        {[], []} ->
          ""

        {loaded, []} ->
          "Note: #{format_service_bucket(loaded, :loaded)}"

        {[], already_loaded} ->
          "Note: #{format_service_bucket(already_loaded, :already_loaded)}"

        {loaded, already_loaded} ->
          "Note: #{format_service_bucket(loaded, :loaded)} " <>
            "#{format_service_bucket(already_loaded, :already_loaded)}"
      end

    "\n" <> note <> "\nRun: sudo orchardctl stop"
  end

  defp format_service_bucket(names, :loaded) do
    "#{join_display_names(names)} #{was_or_were(names)} loaded into launchd but not rolled back."
  end

  defp format_service_bucket(names, :already_loaded) do
    "#{join_display_names(names)} #{was_or_were(names)} already loaded in launchd and not changed."
  end

  defp was_or_were([_one]), do: "was"
  defp was_or_were(_many), do: "were"

  defp join_display_names([name]), do: name
  defp join_display_names(names), do: Enum.join(names, ", ")

  defp terminal_poll_state?(%{state: :ready}), do: true
  defp terminal_poll_state?(%{state: :install_error}), do: true
  defp terminal_poll_state?(%{state: :invalid_response, probe_failure: :all_invalid}), do: true
  defp terminal_poll_state?(_snap), do: false

  defp format_invalid_response(%{display_url: url, error: message}) do
    "Error: invalid health response from #{url}: #{message}\n"
  end

  defp format_last_state(%{state: :offline, display_url: url}) do
    "Last observed status: offline (controller unreachable at #{url})\n"
  end

  defp format_last_state(%{state: :degraded, body: body}) when is_map(body) do
    reason = body["reason"] || "controller reported error"
    "Last observed status: degraded (#{reason})\n"
  end

  defp format_last_state(_snap) do
    "Last observed status: not ready\n"
  end

  # ── Default Runtime ──────────────────────────────────────────────────

  defp default_runtime do
    %{}
  end

  # ── Usage ────────────────────────────────────────────────────────────

  defp usage do
    """
    Usage: sudo orchardctl start

    Start Orchard.app-installed services via launchd.

    Bootstraps the node agent and controller, waits for readiness,
    then prints the system status banner.

    Requires root privileges. For development, use bin/dev instead.

    Examples:
      sudo orchardctl start
      sudo orchardctl start --help
    """
    |> String.trim()
  end
end
