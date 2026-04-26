defmodule OrchardCLI.Commands.LifecycleSupport do
  @moduledoc false

  @type install_role :: :all | :controller | :node_agent
  @type install_role_error_reason ::
          :legacy_not_found | :invalid_marker | :marker_read_error | :invalid_runtime_role
  @type service :: %{
          required(:id) => atom(),
          required(:label) => String.t(),
          required(:plist_path) => String.t(),
          required(:display_name) => String.t()
        }

  @install_role_marker "/Library/Application Support/Orchard/support/.install-role"

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

  @all_services @required_services

  # ── Role Detection ──────────────────────────────────────────────────

  @doc "Returns the installed Orchard role from the marker, falling back to legacy plist inference."
  @spec install_role(map()) :: {:ok, install_role()} | {:error, String.t(), 1}
  def install_role(runtime) do
    case detect_install_role(runtime) do
      {:ok, role} -> {:ok, role}
      {:error, _reason, message, code} -> {:error, message, code}
    end
  end

  @doc "Detects install role with a tagged error reason for callers that need fallback control."
  @spec detect_install_role(map()) ::
          {:ok, install_role()} | {:error, install_role_error_reason(), String.t(), 1}
  def detect_install_role(%{install_role: role}) do
    case normalize_role(role) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, :invalid_runtime_role, invalid_runtime_role_error_message(role), 1}
    end
  end

  def detect_install_role(runtime) do
    case read_marker_role(runtime) do
      {:ok, role} ->
        {:ok, role}

      :missing ->
        infer_role_from_plists(runtime)

      {:error, :invalid_marker, marker_value} ->
        {:error, :invalid_marker, invalid_marker_error_message(marker_value), 1}

      {:error, :marker_read_error, reason} ->
        {:error, :marker_read_error, marker_read_error_message(reason), 1}
    end
  end

  @doc "Formats an install role for operator-facing CLI output."
  @spec display_role(install_role()) :: String.t()
  def display_role(:all), do: "all"
  def display_role(:controller), do: "controller"
  def display_role(:node_agent), do: "node-agent"

  # ── Service Definitions ─────────────────────────────────────────────

  @doc "Returns Orchard launchd services in start or stop order for the current runtime."
  @spec services(:start | :stop, map()) :: [service()]
  def services(direction, runtime) when direction in [:start, :stop] do
    role = runtime |> install_role() |> role_or_all()
    configured = Map.get(runtime, :services)

    services = if is_list(configured), do: configured, else: @required_services

    services = Enum.filter(services, &service_applicable_to_role?(&1, role))

    case direction do
      :start -> services
      :stop -> Enum.reverse(services)
    end
  end

  # ── Root Check ─────────────────────────────────────────────────────

  @doc "Validates that the current runtime has root privileges for lifecycle commands."
  @spec require_root(String.t(), map()) :: :ok | {:error, String.t(), 1}
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

  @doc "Returns packaged plist paths that are neither present on disk nor already loaded."
  @spec missing_plists(map()) :: [String.t()]
  def missing_plists(runtime) do
    services(:start, runtime)
    |> Enum.reject(fn svc -> plist_exists?(svc, runtime) or service_loaded?(svc, runtime) end)
    |> Enum.map(& &1.plist_path)
  end

  @doc "Returns whether any Orchard packaged plist exists for the current runtime."
  @spec any_plist_exists?(map()) :: boolean()
  def any_plist_exists?(runtime) do
    file_regular? = Map.get(runtime, :file_regular?, &File.regular?/1)

    runtime
    |> services_for_context_detection()
    |> Enum.any?(fn svc -> file_regular?.(svc.plist_path) end)
  end

  defp services_for_context_detection(runtime) do
    case install_role(runtime) do
      {:ok, _role} ->
        services(:start, runtime)

      {:error, _message, _code} ->
        reject_unsupported_services(Map.get(runtime, :services, @all_services))
    end
  end

  defp reject_unsupported_services(services) do
    Enum.reject(services, &match?(%{id: :postgres}, &1))
  end

  defp plist_exists?(nil, _runtime), do: false

  defp plist_exists?(svc, runtime) do
    file_regular? = Map.get(runtime, :file_regular?, &File.regular?/1)
    file_regular?.(svc.plist_path)
  end

  # ── Service State Detection ─────────────────────────────────────────

  @doc "Checks whether a launchd service is currently loaded."
  @spec service_loaded?(service(), map()) :: boolean()
  def service_loaded?(svc, runtime) do
    cmd_fn = Map.get(runtime, :cmd, &default_cmd/3)

    case cmd_fn.("launchctl", ["print", "system/#{svc.label}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  # ── Idempotent Start/Stop ───────────────────────────────────────────

  @doc "Ensures a service is loaded in launchd, preserving idempotent and race-safe semantics."
  @spec ensure_started(service(), map()) ::
          {:loaded | :already_loaded, service()} | {:error, String.t(), 1}
  def ensure_started(svc, runtime) do
    if service_loaded?(svc, runtime) do
      {:already_loaded, svc}
    else
      bootstrap_service(svc, runtime)
    end
  end

  @doc "Ensures a service is stopped, preserving idempotent and race-safe launchctl semantics."
  @spec ensure_stopped(service(), map()) ::
          {:stopped | :already_stopped, service()} | {:error, String.t(), 1}
  def ensure_stopped(svc, runtime) do
    if service_loaded?(svc, runtime) do
      bootout_service(svc, runtime)
    else
      {:already_stopped, svc}
    end
  end

  defp read_marker_role(runtime) do
    reader = Map.get(runtime, :read_install_role, &default_read_install_role/0)

    reader.()
    |> normalize_marker_read()
  end

  defp default_read_install_role, do: File.read(@install_role_marker)

  defp normalize_marker_read({:ok, contents}) when is_binary(contents),
    do: parse_marker_role(contents)

  defp normalize_marker_read(contents) when is_binary(contents), do: parse_marker_role(contents)
  defp normalize_marker_read({:error, reason}) when reason in [:enoent, :enotdir], do: :missing

  defp normalize_marker_read({:error, reason}),
    do: {:error, :marker_read_error, inspect(reason)}

  defp normalize_marker_read(other), do: {:error, :marker_read_error, inspect(other)}

  defp parse_marker_role(contents) do
    marker_value = String.trim(contents)

    case normalize_role(marker_value) do
      {:ok, role} -> {:ok, role}
      :error -> {:error, :invalid_marker, marker_value}
    end
  end

  defp normalize_role("all"), do: {:ok, :all}
  defp normalize_role("controller"), do: {:ok, :controller}
  defp normalize_role("node-agent"), do: {:ok, :node_agent}
  defp normalize_role(:all), do: {:ok, :all}
  defp normalize_role(:controller), do: {:ok, :controller}
  defp normalize_role(:node_agent), do: {:ok, :node_agent}
  defp normalize_role(_other), do: :error

  defp infer_role_from_plists(runtime) do
    controller? = service_plist_present?(:controller, runtime)
    node_agent? = service_plist_present?(:node_agent, runtime)

    case {controller?, node_agent?} do
      {true, true} ->
        {:ok, :all}

      {true, false} ->
        {:ok, :controller}

      {false, true} ->
        {:ok, :node_agent}

      {false, false} ->
        {:error, :legacy_not_found, install_role_error_message(), 1}
    end
  end

  defp service_plist_present?(service_id, runtime) do
    service_id
    |> required_service(runtime)
    |> plist_exists?(runtime)
  end

  defp required_service(service_id, runtime) do
    runtime
    |> Map.get(:services, @required_services)
    |> Enum.find(&(&1.id == service_id))
  end

  defp install_role_error_message do
    "Error: Orchard packaged install not found.\n" <>
      "Unable to determine install role from #{@install_role_marker}.\n" <>
      "Expected a valid role marker (all, controller, or node-agent), or installed legacy plist(s):\n" <>
      "  /Library/LaunchDaemons/com.orchard.controller.plist\n" <>
      "  /Library/LaunchDaemons/com.orchard.node-agent.plist\n\n" <>
      "Run the Orchard installer again, or restore the install role marker."
  end

  defp invalid_marker_error_message(marker_value) do
    found = if marker_value == "", do: "empty marker", else: inspect(marker_value)

    "Error: invalid Orchard install role marker at #{@install_role_marker}.\n" <>
      "Expected one of: all, controller, node-agent.\n" <>
      "Found: #{found}\n\n" <>
      "Run the Orchard installer again, or restore the install role marker with a valid role."
  end

  defp marker_read_error_message(reason) do
    "Error: unable to read Orchard install role marker at #{@install_role_marker}.\n" <>
      "Reason: #{reason}\n\n" <>
      "Run the Orchard installer again, or restore marker permissions."
  end

  defp invalid_runtime_role_error_message(role) do
    "Error: invalid install role override #{inspect(role)}.\n" <>
      "Expected one of: all, controller, node-agent."
  end

  defp role_or_all({:ok, role}), do: role
  defp role_or_all({:error, _message, _code}), do: :all

  defp service_applicable_to_role?(%{id: :postgres}, _role), do: false
  defp service_applicable_to_role?(%{id: :controller}, role), do: role in [:all, :controller]
  defp service_applicable_to_role?(%{id: :node_agent}, role), do: role in [:all, :node_agent]
  defp service_applicable_to_role?(_optional_or_unknown, _role), do: true

  defp bootstrap_service(svc, runtime) do
    case run_launchctl(runtime, ["bootstrap", "system", svc.plist_path]) do
      {_output, 0} ->
        {:loaded, svc}

      {output, code} ->
        start_failure_result(svc, runtime, output, code)
    end
  end

  defp bootout_service(svc, runtime) do
    case run_launchctl(runtime, ["bootout", "system/#{svc.label}"]) do
      {_output, 0} ->
        {:stopped, svc}

      {output, code} ->
        stop_failure_result(svc, runtime, output, code)
    end
  end

  defp start_failure_result(svc, runtime, output, code) do
    if service_loaded?(svc, runtime) do
      {:already_loaded, svc}
    else
      {:error,
       lifecycle_error_message(
         "start",
         svc,
         output,
         code,
         "Check: /Library/Application Support/Orchard/logs/"
       ), 1}
    end
  end

  defp stop_failure_result(svc, runtime, output, code) do
    if service_loaded?(svc, runtime) do
      {:error,
       lifecycle_error_message(
         "stop",
         svc,
         output,
         code,
         "Try: sudo launchctl bootout system/#{svc.label}"
       ), 1}
    else
      {:already_stopped, svc}
    end
  end

  defp lifecycle_error_message(action, svc, output, code, guidance) do
    "Error: failed to #{action} #{svc.display_name} (#{svc.label}).\n" <>
      format_launchctl_detail(output, code) <>
      "\n" <> guidance
  end

  defp run_launchctl(runtime, args) do
    cmd_fn = Map.get(runtime, :cmd, &default_cmd/3)
    cmd_fn.("launchctl", args, stderr_to_stdout: true)
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
