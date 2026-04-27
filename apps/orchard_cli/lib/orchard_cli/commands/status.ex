defmodule OrchardCLI.Commands.Status do
  @moduledoc """
  CLI handler for `orchardctl status`.

  Probes the running controller's `/health/ready` endpoint and renders a
  human-readable status banner.

  Supports:
    orchardctl status       — Show system status banner
    orchardctl status help  — Show usage
  """

  alias OrchardCLI.Commands.LifecycleSupport

  @default_support_root "/Library/Application Support/Orchard"
  @connect_timeout_ms 2_000
  @receive_timeout_ms 3_000

  # ── Public API ──────────────────────────────────────────────────────

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  # credo:disable-for-lines:3 ExSlop.Check.Readability.DocFalseOnPublicFunction
  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(["help"], _runtime), do: {:ok, usage()}
  def run(["--help"], _runtime), do: {:ok, usage()}
  def run([], runtime), do: run_status(runtime)
  def run(_args, _runtime), do: {:error, usage(), 1}

  # ── Status Probe ────────────────────────────────────────────────────

  defp run_status(runtime) do
    case snapshot(runtime) do
      %{state: :install_error, error: message} ->
        {:error, message, 1}

      %{state: :invalid_response, display_url: url, error: message} ->
        {:error, "Error: invalid health response from #{url}: #{message}", 1}

      snap ->
        {:ok, render_snapshot(snap)}
    end
  end

  @doc "Builds a structured status snapshot for the current Orchard install role."
  @spec snapshot(map()) :: map()
  def snapshot(runtime \\ default_runtime()) do
    version = Map.get(runtime, :version, fn -> Orchard.version() end).()

    case LifecycleSupport.detect_install_role(runtime) do
      {:ok, role} ->
        runtime = Map.put(runtime, :install_role, role)
        snapshot_for_role(runtime, version, role)

      {:error, :legacy_not_found, _message, _code} ->
        snapshot_for_role(runtime, version, :source_dev)

      {:error, _reason, message, _code} ->
        %{
          version: version,
          display_version: format_display_version(version, nil),
          state: :install_error,
          role: nil,
          error: message
        }
    end
  end

  defp snapshot_for_role(runtime, version, :node_agent = role) do
    %{
      version: version,
      display_version: format_display_version(version, nil),
      state: :node_agent,
      role: role,
      node_agent_loaded?: node_agent_loaded?(runtime),
      node_agent_health: node_agent_health(runtime)
    }
  end

  defp snapshot_for_role(runtime, version, role) do
    candidates = Map.get(runtime, :endpoint_candidates, &default_endpoint_candidates/0).()
    request_fn = Map.get(runtime, :request, &default_request/2)

    case probe_candidates(candidates, request_fn) do
      {:ok, base_url, body} ->
        state = if body["status"] == "ok", do: :ready, else: :degraded
        remote_version = non_empty_string(body["version"]) || version
        build_ref = non_empty_string(body["build_ref"])
        display_version = format_display_version(remote_version, build_ref)

        %{
          version: remote_version,
          display_version: display_version,
          state: state,
          role: role,
          base_url: base_url,
          display_url: base_url,
          body: body
        }

      {:error, :unreachable, display_url} ->
        display_version = format_display_version(version, nil)

        %{
          version: version,
          display_version: display_version,
          state: :offline,
          role: role,
          base_url: nil,
          display_url: display_url,
          body: nil
        }

      {:error, :invalid_response, display_url, message, probe_failure} ->
        %{
          version: version,
          display_version: format_display_version(version, nil),
          state: :invalid_response,
          role: role,
          base_url: nil,
          display_url: display_url,
          body: nil,
          error: message,
          probe_failure: probe_failure
        }
    end
  end

  @doc "Renders a human-readable status banner from a previously built snapshot."
  @spec render_snapshot(map()) :: String.t()
  def render_snapshot(%{state: :install_error, error: message}) do
    message
  end

  def render_snapshot(%{state: :node_agent} = snap) do
    render_node_agent_banner(snap)
  end

  def render_snapshot(%{state: :offline} = snap) do
    render_offline_banner(snap.display_version, snap.display_url, snap.role)
  end

  def render_snapshot(snap) do
    render_banner(snap.display_version, snap.base_url, snap.body, snap.role)
  end

  # ── Node-Agent Local Status ─────────────────────────────────────────

  defp node_agent_loaded?(runtime) do
    LifecycleSupport.services(:start, runtime)
    |> Enum.find(&(&1.id == :node_agent))
    |> case do
      nil -> false
      service -> LifecycleSupport.service_loaded?(service, runtime)
    end
  end

  defp node_agent_health(runtime) do
    case Map.get(runtime, :node_agent_health) do
      health_fn when is_function(health_fn, 0) -> normalize_node_agent_health(health_fn.())
      _other -> :not_available
    end
  end

  defp normalize_node_agent_health({:ok, health}) when is_map(health), do: {:ok, health}
  defp normalize_node_agent_health({:error, reason}), do: {:error, inspect(reason)}
  defp normalize_node_agent_health(health) when is_map(health), do: {:ok, health}
  defp normalize_node_agent_health(_other), do: :not_available

  # ── Candidate Probing ───────────────────────────────────────────────

  defp probe_candidates([], _request_fn), do: {:error, :unreachable, "http://localhost:4000"}

  defp probe_candidates(candidates, request_fn) do
    display_url = hd(candidates) |> Map.fetch!(:base_url)

    candidates
    |> Enum.reduce_while(
      %{display_url: display_url, invalid_response: nil, saw_unreachable?: false},
      fn candidate, acc ->
        candidate
        |> probe_candidate(request_fn)
        |> reduce_probe_candidate(candidate, acc)
      end
    )
    |> finalize_probe_result()
  end

  defp probe_candidate(candidate, request_fn) do
    url = candidate.base_url <> "/health/ready"
    opts = build_request_opts(candidate)

    case request_fn.(url, opts) do
      {:ok, %{status: status, body: body}} when status in 200..599 ->
        case decode_health_response(body) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:invalid_response, reason}
        end

      _other ->
        :unreachable
    end
  end

  defp reduce_probe_candidate({:ok, parsed}, candidate, _acc) do
    {:halt, {:ok, candidate.base_url, parsed}}
  end

  defp reduce_probe_candidate({:invalid_response, reason}, candidate, acc) do
    invalid_response = acc.invalid_response || {candidate.base_url, reason}
    {:cont, %{acc | invalid_response: invalid_response}}
  end

  defp reduce_probe_candidate(:unreachable, _candidate, acc) do
    {:cont, %{acc | saw_unreachable?: true}}
  end

  defp finalize_probe_result({:ok, _base_url, _body} = success), do: success

  defp finalize_probe_result(%{invalid_response: nil, display_url: display_url}) do
    {:error, :unreachable, display_url}
  end

  defp finalize_probe_result(%{invalid_response: {display_url, message}, saw_unreachable?: true}) do
    {:error, :invalid_response, display_url, message, :mixed}
  end

  defp finalize_probe_result(%{invalid_response: {display_url, message}}) do
    {:error, :invalid_response, display_url, message, :all_invalid}
  end

  defp build_request_opts(candidate) do
    base = [connect_timeout: @connect_timeout_ms, receive_timeout: @receive_timeout_ms]

    case Map.get(candidate, :ca_certfile) do
      nil -> base
      path -> Keyword.put(base, :ca_certfile, path)
    end
  end

  # ── JSON Parsing ────────────────────────────────────────────────────

  defp decode_health_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> validate_health_contract(parsed)
      {:error, _} -> {:error, "malformed JSON in health response"}
    end
  end

  defp decode_health_response(body) when is_map(body) do
    # Req may auto-decode JSON
    validate_health_contract(body)
  end

  defp decode_health_response(_), do: {:error, "unexpected response format"}

  defp validate_health_contract(%{"status" => status} = body)
       when status in ["ok", "error"] do
    {:ok, body}
  end

  defp validate_health_contract(%{"status" => other}) do
    {:error, "unexpected health status: #{inspect(other)}"}
  end

  defp validate_health_contract(_) do
    {:error, "health response missing \"status\" field"}
  end

  # ── Banner Rendering ────────────────────────────────────────────────

  defp display_status_role(:source_dev), do: "source-dev"
  defp display_status_role(role), do: LifecycleSupport.display_role(role)

  defp render_banner(display_version, base_url, body, role) do
    status_label = if body["status"] == "ok", do: "ready", else: "degraded"
    details = build_details(body, status_label)
    license_lines = render_license_lines(body["license"])

    ([
       "\u{1F333} Orchard #{display_version}",
       "   Role:    #{display_status_role(role)}",
       "   Console: #{base_url}/console",
       "   API:     #{base_url}/v1",
       "   Status:  #{status_label}#{details}"
     ] ++ license_lines)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_offline_banner(display_version, display_url, role) do
    """
    \u{1F333} Orchard #{display_version}
       Role:    #{display_status_role(role)}
       Console: #{display_url}/console
       API:     #{display_url}/v1
       Status:  offline (controller unreachable)
    """
    |> String.trim()
  end

  defp render_node_agent_banner(snap) do
    [
      "\u{1F333} Orchard #{snap.display_version}",
      "   Role:    #{display_status_role(snap.role)}",
      "   Node Agent: #{launchd_state_label(snap.node_agent_loaded?)}",
      node_agent_health_line(snap.node_agent_health),
      "   Controller: remote/not checked"
    ]
    |> Enum.join("\n")
  end

  defp launchd_state_label(true), do: "loaded"
  defp launchd_state_label(false), do: "not loaded"

  defp node_agent_health_line(:not_available) do
    "   Node Agent Health: not checked (no local node-agent health/readiness probe available)"
  end

  defp node_agent_health_line({:error, reason}) do
    "   Node Agent Health: unavailable (#{reason})"
  end

  defp node_agent_health_line({:ok, health}) do
    ready = Map.get(health, :ready, Map.get(health, "ready"))
    code = Map.get(health, :health_code, Map.get(health, "health_code"))
    message = Map.get(health, :health_message, Map.get(health, "health_message"))

    ["   Node Agent Health: #{readiness_label(ready)}", code, message]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" — ")
  end

  defp readiness_label(true), do: "ready"
  defp readiness_label(false), do: "not ready"
  defp readiness_label(_unknown), do: "reported"

  defp build_details(body, status_label) do
    runtime_details =
      body
      |> Map.get("runtime")
      |> runtime_detail_string()

    detail_suffix(status_label, body["reason"], runtime_details)
  end

  defp runtime_detail_string(runtime) when not is_map(runtime), do: "runtime unavailable"

  defp runtime_detail_string(%{"status" => "ok"} = runtime) do
    runtime
    |> runtime_ok_parts()
    |> Enum.join(", ")
  end

  defp runtime_detail_string(runtime) do
    "runtime #{runtime["status"] || "unavailable"}"
  end

  defp runtime_ok_parts(runtime) do
    [
      runtime_node_detail(runtime),
      runtime_worker_detail(runtime),
      runtime_model_detail(runtime),
      runtime_health_detail(runtime)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp runtime_node_detail(runtime) do
    if runtime["node_id"], do: "1 node", else: "0 nodes"
  end

  defp runtime_worker_detail(runtime), do: runtime["worker_state"]

  defp runtime_model_detail(runtime) do
    count = loaded_model_count(runtime)
    if count == 1, do: "1 model loaded", else: "#{count} models loaded"
  end

  defp loaded_model_count(runtime) do
    case runtime["counts"] do
      %{} = counts -> counts["loaded_models"] || 0
      _other -> 0
    end
  end

  defp runtime_health_detail(runtime) do
    case runtime["health"] do
      health when health in ["degraded", "unhealthy"] -> "health: #{health}"
      _other -> nil
    end
  end

  defp detail_suffix("degraded", reason, runtime_details) when is_binary(reason) do
    " (#{reason}, #{runtime_details})"
  end

  defp detail_suffix(_status, _reason, runtime_details) do
    " (#{runtime_details})"
  end

  defp render_license_lines(%{"status" => status, "message" => message} = license)
       when is_binary(status) and is_binary(message) do
    reason = non_empty_string(Map.get(license, "reason"))
    expires_at = non_empty_string(Map.get(license, "expires_at"))

    suffix =
      [reason && "reason: #{reason}", expires_at && "expires: #{expires_at}"]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> ""
        parts -> " (" <> Enum.join(parts, ", ") <> ")"
      end

    ([
       "   License: #{status} — #{message}#{suffix}",
       license_identity_line("License ID", license["license_id"]),
       license_identity_line("Machine ID", license["machine_id"]),
       license_identity_line("Licensee", license["licensee"]),
       license_identity_line("Max machines", license["max_machines"])
     ] ++ tracking_lines(license["tracking"]))
    |> Enum.reject(&is_nil/1)
  end

  defp render_license_lines(_license), do: []

  defp license_identity_line(_label, nil), do: nil

  defp license_identity_line(label, value) when is_binary(value) do
    case non_empty_string(value) do
      nil -> nil
      trimmed -> "   #{label}: #{trimmed}"
    end
  end

  defp license_identity_line(label, value) when is_integer(value), do: "   #{label}: #{value}"
  defp license_identity_line(_label, _value), do: nil

  defp tracking_lines(tracking) when is_map(tracking) do
    case format_tracking(tracking) do
      nil -> []
      formatted -> ["   Tracking: #{formatted}"]
    end
  end

  defp tracking_lines(_tracking), do: []

  defp format_tracking(tracking) do
    [
      tracking_part("program", tracking["program"]),
      tracking_part("ref", tracking["reference"])
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  defp tracking_part(_key, value) when not is_binary(value), do: nil

  defp tracking_part(key, value) do
    case non_empty_string(value) do
      nil -> nil
      trimmed -> "#{key}=#{trimmed}"
    end
  end

  # ── Endpoint Candidate Resolution ───────────────────────────────────

  defp default_endpoint_candidates do
    case endpoint_from_config() do
      {:ok, candidate} ->
        [candidate]

      :fallback ->
        # Packaged install defaults: try HTTPS first, then HTTP
        support_root = support_root()
        ca_path = Path.join([support_root, "config", "tls", "ca.crt"])
        ca_certfile = if File.regular?(ca_path), do: ca_path, else: nil

        [
          %{base_url: "https://localhost:8443", ca_certfile: ca_certfile},
          %{base_url: "http://localhost:4000", ca_certfile: nil}
        ]
    end
  end

  defp endpoint_from_config do
    config = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

    cond do
      http = Keyword.get(config, :http) ->
        port = get_in(http, [:port]) || 4000
        {:ok, %{base_url: "http://localhost:#{port}", ca_certfile: nil}}

      https = Keyword.get(config, :https) ->
        port = get_in(https, [:port]) || 8443
        support_root = support_root()
        ca_path = Path.join([support_root, "config", "tls", "ca.crt"])
        ca_certfile = if File.regular?(ca_path), do: ca_path, else: nil
        {:ok, %{base_url: "https://localhost:#{port}", ca_certfile: ca_certfile}}

      true ->
        :fallback
    end
  end

  defp support_root do
    System.get_env("ORCHARD_SUPPORT_ROOT") || @default_support_root
  end

  # ── Default HTTP Request ────────────────────────────────────────────

  defp default_request(url, opts) do
    ca_certfile = Keyword.get(opts, :ca_certfile)
    connect_timeout = Keyword.get(opts, :connect_timeout, @connect_timeout_ms)
    receive_timeout = Keyword.get(opts, :receive_timeout, @receive_timeout_ms)

    req_opts =
      [
        url: url,
        method: :get,
        retry: false,
        redirect: false,
        connect_options: [timeout: connect_timeout]
      ]
      |> add_ca_cert_connect_options(ca_certfile)

    case OrchardCLI.HTTP.request(req_opts, receive_timeout: receive_timeout) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Adds a CA certificate path to Req connection options for controller health probes.

  Req 0.5.x passes CA certificate paths to Mint/Finch through nested
  `:transport_opts`, so this helper preserves existing connection options while
  adding `:cacertfile`.
  """
  @spec add_ca_cert_connect_options(keyword(), String.t() | nil) :: keyword()
  def add_ca_cert_connect_options(opts, nil), do: opts

  def add_ca_cert_connect_options(opts, ca_path) when is_binary(ca_path) do
    transport_opts = [cacertfile: ca_path]

    Keyword.update(opts, :connect_options, [transport_opts: transport_opts], fn connect_opts ->
      Keyword.update(
        connect_opts,
        :transport_opts,
        transport_opts,
        &Keyword.merge(&1, transport_opts)
      )
    end)
  end

  # ── Version Formatting ────────────────────────────────────────────────

  defp format_display_version(version, build_ref) do
    base = "v" <> version

    case non_empty_string(build_ref) do
      nil -> base
      ref -> base <> " (" <> ref <> ")"
    end
  end

  defp non_empty_string(nil), do: nil

  defp non_empty_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed != "" and trimmed != "unknown", do: trimmed
  end

  defp non_empty_string(_), do: nil

  # ── Default Runtime ──────────────────────────────────────────────────

  defp default_runtime do
    %{
      version: fn -> Orchard.version() end,
      endpoint_candidates: &default_endpoint_candidates/0,
      request: &default_request/2
    }
  end

  # ── Usage ────────────────────────────────────────────────────────────

  defp usage do
    """
    Usage: orchardctl status

    Show the current Orchard system status.

    Probes the running controller's health endpoint and displays:
    - Console and API URLs
    - Readiness status
    - Runtime summary (node, worker state, loaded models)

    Examples:
      orchardctl status
      orchardctl status --help
    """
    |> String.trim()
  end
end
