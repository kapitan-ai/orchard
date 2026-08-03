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
  alias OrchardCLI.EndpointMetadata

  @default_support_root "/Library/Application Support/Orchard"
  @connect_timeout_ms 2_000
  @receive_timeout_ms 3_000

  # ── Public API ──────────────────────────────────────────────────────

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  # Public only so tests can inject status-probe runtime without exposing CLI API docs.
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
    if message = invalid_transport_mode_message() do
      %{
        version: version,
        display_version: format_display_version(version, nil),
        state: :install_error,
        role: role,
        error: message
      }
    else
      snapshot_controller_role(runtime, version, role)
    end
  end

  defp snapshot_controller_role(runtime, version, role) do
    {candidates, warnings} = endpoint_candidates(runtime)
    request_fn = Map.get(runtime, :request, &default_request/2)

    case probe_candidates(candidates, request_fn) do
      {:ok, display_url, body} ->
        state = if body["status"] == "ok", do: :ready, else: :degraded
        display_version = format_display_version(version, nil)

        %{
          version: version,
          display_version: display_version,
          state: state,
          role: role,
          base_url: display_url,
          display_url: display_url,
          body: body,
          warnings: warnings
        }

      {:error, :unreachable, display_url, source} ->
        display_version = format_display_version(version, nil)
        warnings = offline_warnings(runtime, source, display_url) ++ warnings

        %{
          version: version,
          display_version: display_version,
          state: :offline,
          role: role,
          base_url: nil,
          display_url: display_url,
          body: nil,
          console_state: :unknown,
          warnings: warnings
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
          probe_failure: probe_failure,
          warnings: warnings
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
    snap.warnings
    |> prepend_warnings(
      render_offline_banner(
        snap.display_version,
        snap.display_url,
        snap.role,
        Map.get(snap, :console_state, :unknown)
      )
    )
  end

  def render_snapshot(snap) do
    display_url = Map.get(snap, :display_url) || Map.fetch!(snap, :base_url)

    snap
    |> Map.get(:warnings, [])
    |> prepend_warnings(render_banner(snap.display_version, display_url, snap.body, snap.role))
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

  defp probe_candidates([], _request_fn),
    do: {:error, :unreachable, "http://localhost:4000", :fallback}

  defp probe_candidates(candidates, request_fn) do
    candidates = Enum.map(candidates, &normalize_candidate/1)
    display_url = hd(candidates) |> candidate_display_url()

    candidates
    |> Enum.reduce_while(
      %{
        display_url: display_url,
        invalid_response: nil,
        saw_unreachable?: false,
        source: hd(candidates).source
      },
      fn candidate, acc ->
        candidate
        |> probe_candidate(request_fn)
        |> reduce_probe_candidate(candidate, acc)
      end
    )
    |> finalize_probe_result()
  end

  defp probe_candidate(candidate, request_fn) do
    url = candidate.probe_url <> "/health/ready"
    opts = build_request_opts(candidate)

    case request_fn.(url, opts) do
      {:ok, %{status: status, body: body}} when is_integer(status) ->
        case decode_health_response(status, body) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, reason} -> {:invalid_response, reason}
        end

      _other ->
        :unreachable
    end
  end

  defp reduce_probe_candidate({:ok, parsed}, candidate, _acc) do
    {:halt, {:ok, candidate_display_url(candidate), parsed}}
  end

  defp reduce_probe_candidate({:invalid_response, reason}, candidate, acc) do
    invalid_response = acc.invalid_response || {candidate_display_url(candidate), reason}
    {:cont, %{acc | invalid_response: invalid_response}}
  end

  defp reduce_probe_candidate(:unreachable, _candidate, acc) do
    {:cont, %{acc | saw_unreachable?: true}}
  end

  defp finalize_probe_result({:ok, _base_url, _body} = success), do: success

  defp finalize_probe_result(%{invalid_response: nil, display_url: display_url, source: source}) do
    {:error, :unreachable, display_url, source}
  end

  defp finalize_probe_result(%{invalid_response: {display_url, message}, saw_unreachable?: true}) do
    {:error, :invalid_response, display_url, message, :mixed}
  end

  defp finalize_probe_result(%{invalid_response: {display_url, message}}) do
    {:error, :invalid_response, display_url, message, :all_invalid}
  end

  defp normalize_candidate(%{probe_url: probe_url, display_url: display_url} = candidate) do
    %{
      probe_url: probe_url,
      display_url: display_url,
      ca_certfile: Map.get(candidate, :ca_certfile),
      source: Map.get(candidate, :source, :runtime)
    }
  end

  defp normalize_candidate(%{base_url: base_url} = candidate) do
    %{
      probe_url: base_url,
      display_url: Map.get(candidate, :display_url, base_url),
      ca_certfile: Map.get(candidate, :ca_certfile),
      source: Map.get(candidate, :source, :runtime)
    }
  end

  defp candidate_display_url(candidate), do: candidate.display_url

  defp offline_warnings(runtime, source, display_url) do
    configured_endpoint_warnings(source, display_url) ++
      installed_not_bootstrapped_warnings(runtime)
  end

  defp configured_endpoint_warnings(:endpoint_metadata, display_url) do
    [
      "Warning: configured endpoint unreachable from endpoint metadata sidecar: #{display_url}"
    ]
  end

  defp configured_endpoint_warnings(_source, _display_url), do: []

  defp installed_not_bootstrapped_warnings(runtime) do
    if LifecycleSupport.any_plist_exists?(runtime) and controller_not_loaded?(runtime) do
      ["Warning: Orchard services are installed but not bootstrapped. Run: sudo orchardctl start"]
    else
      []
    end
  end

  defp controller_not_loaded?(runtime) do
    :start
    |> LifecycleSupport.services(runtime)
    |> Enum.find(&(&1.id == :controller))
    |> case do
      nil -> false
      service -> not LifecycleSupport.service_loaded?(service, runtime)
    end
  end

  defp build_request_opts(candidate) do
    base = [connect_timeout: @connect_timeout_ms, receive_timeout: @receive_timeout_ms]

    case Map.get(candidate, :ca_certfile) do
      nil -> base
      path -> Keyword.put(base, :ca_certfile, path)
    end
  end

  # ── JSON Parsing ────────────────────────────────────────────────────

  defp decode_health_response(http_status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> validate_health_contract(http_status, parsed)
      {:error, _} -> {:error, "malformed JSON in health response"}
    end
  end

  defp decode_health_response(http_status, body) when is_map(body) do
    validate_health_contract(http_status, body)
  end

  defp decode_health_response(_http_status, _), do: {:error, "unexpected response format"}

  defp validate_health_contract(200, %{"status" => "ok"} = body) when map_size(body) == 1 do
    {:ok, body}
  end

  defp validate_health_contract(503, %{"status" => "error"} = body) when map_size(body) == 1 do
    {:ok, body}
  end

  defp validate_health_contract(http_status, body) when is_map(body) do
    {:error,
     "invalid public health pair: HTTP #{http_status} with body keys #{inspect(Map.keys(body))}"}
  end

  defp validate_health_contract(_http_status, _) do
    {:error, "health response missing \"status\" field"}
  end

  # ── Banner Rendering ────────────────────────────────────────────────

  defp display_status_role(:source_dev), do: "source-dev"
  defp display_status_role(role), do: LifecycleSupport.display_role(role)

  defp render_banner(display_version, base_url, body, role) do
    status_label = if body["status"] == "ok", do: "ready", else: "degraded"

    [
      "\u{1F333} Orchard #{display_version}",
      "   Role:    #{display_status_role(role)}",
      console_line(base_url),
      "   API:     #{base_url}/v1",
      "   Status:  #{status_label}",
      diagnostics_hint(status_label)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp diagnostics_hint("degraded") do
    "   Details: use authenticated GET /ops/v1/health for diagnostics"
  end

  defp diagnostics_hint(_status), do: nil

  defp render_offline_banner(display_version, display_url, role, console_state) do
    """
    \u{1F333} Orchard #{display_version}
       Role:    #{display_status_role(role)}
       Console: #{display_url}/console#{console_state_suffix(console_state)}
       API:     #{display_url}/v1
       Status:  offline (controller unreachable)
    """
    |> String.trim()
  end

  defp console_line(base_url), do: "   Console: #{base_url}/console"

  defp console_state_suffix(:enabled), do: " (enabled)"
  defp console_state_suffix(:disabled), do: " (disabled)"
  defp console_state_suffix(_unknown), do: " (unknown)"

  defp prepend_warnings([], banner), do: banner

  defp prepend_warnings(warnings, banner) do
    (warnings ++ [banner])
    |> Enum.join("\n")
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

  # ── Endpoint Candidate Resolution ───────────────────────────────────

  defp endpoint_candidates(runtime) do
    case Map.fetch(runtime, :endpoint_candidates) do
      {:ok, endpoint_candidates_fn} -> {endpoint_candidates_fn.(), []}
      :error -> default_endpoint_candidates(runtime)
    end
  end

  defp default_endpoint_candidates(runtime) do
    cond do
      System.get_env("ORCHARD_TRANSPORT_MODE") in [
        "direct_https",
        "reverse_proxy",
        "plain_http_localhost"
      ] ->
        {fallback_endpoint_candidates_from_env(), []}

      legacy_transport_env_set?() ->
        {fallback_endpoint_candidates_from_env(), []}

      true ->
        endpoint_candidates_from_config_or_sidecar_or_fallback(runtime)
    end
  end

  defp endpoint_candidates_from_config_or_sidecar_or_fallback(runtime) do
    case endpoint_from_config(runtime) do
      {:ok, candidate} ->
        {[Map.put(candidate, :source, :config)], []}

      :fallback ->
        endpoint_candidates_from_sidecar_or_fallback(runtime, [])

      {:error, message} ->
        endpoint_candidates_from_sidecar_or_fallback(runtime, [config_warning(message)])
    end
  end

  defp endpoint_candidates_from_sidecar_or_fallback(runtime, warnings) do
    path = Map.get(runtime, :endpoint_metadata_path, EndpointMetadata.default_path())

    case EndpointMetadata.read(path: path) do
      {:ok, metadata} ->
        case endpoint_candidate_from_metadata(metadata) do
          {:ok, candidate} ->
            {[Map.put(candidate, :source, :endpoint_metadata)], warnings}

          {:error, message} ->
            endpoint_candidates_from_application_config_or_fallback(
              warnings ++ [sidecar_warning(message)]
            )
        end

      {:error, :not_found} ->
        endpoint_candidates_from_application_config_or_fallback(warnings)

      {:error, {:malformed, message}} ->
        endpoint_candidates_from_application_config_or_fallback(
          warnings ++ [sidecar_warning(message)]
        )
    end
  end

  defp endpoint_candidates_from_application_config_or_fallback(warnings) do
    case endpoint_from_application_config() do
      {:ok, candidate} -> {[Map.put(candidate, :source, :config)], warnings}
      :fallback -> {fallback_endpoint_candidates_from_env(), warnings}
    end
  end

  defp config_warning(message) do
    "Warning: ignored endpoint config: #{message}. Run: sudo orchardctl status or check endpoint.json."
  end

  defp sidecar_warning("could not read" <> _rest = message) do
    "Warning: ignored endpoint metadata sidecar: #{message}. Run: sudo orchardctl status or check endpoint.json."
  end

  defp sidecar_warning(message) do
    "Warning: ignored endpoint metadata sidecar: #{message}"
  end

  defp endpoint_candidate_from_metadata(%{transport_mode: "direct_https"} = metadata) do
    with {:ok, host} <- metadata_host(metadata),
         {:ok, port} <- metadata_port(metadata, :api_https_port, 8443) do
      url = format_url("https", host, port)
      {:ok, %{probe_url: url, display_url: url, ca_certfile: metadata.ca_certfile}}
    end
  end

  defp endpoint_candidate_from_metadata(%{transport_mode: "reverse_proxy"} = metadata) do
    with {:ok, host} <- metadata_host(metadata),
         {:ok, port} <- metadata_port(metadata, :api_https_port, 443) do
      url = format_url("https", host, port)
      {:ok, %{probe_url: url, display_url: url, ca_certfile: metadata.ca_certfile}}
    end
  end

  defp endpoint_candidate_from_metadata(%{transport_mode: "plain_http_localhost"} = metadata) do
    with {:ok, host} <- metadata_host(metadata, "localhost"),
         {:ok, port} <- metadata_port(metadata, :plain_http_port, 4000) do
      url = format_url("http", host, port)
      {:ok, %{probe_url: url, display_url: url, ca_certfile: nil}}
    end
  end

  defp metadata_host(metadata, default \\ nil) do
    case metadata.public_host || default do
      host when is_binary(host) -> {:ok, host}
      _other -> {:error, "endpoint metadata missing public_host"}
    end
  end

  defp metadata_port(metadata, field, default) do
    case Map.get(metadata, field) || default do
      port when is_integer(port) and port in 1..65_535 -> {:ok, port}
      _other -> {:error, "endpoint metadata has invalid #{field}"}
    end
  end

  defp invalid_transport_mode_message do
    [
      fn ->
        if invalid_bool = invalid_legacy_tls_disabled() do
          "invalid ORCHARD_TLS_DISABLED: #{invalid_bool}"
        end
      end,
      fn ->
        if partial_legacy_cert_key?() do
          "ORCHARD_TLS_CERTFILE and ORCHARD_TLS_KEYFILE must both be set or both unset"
        end
      end,
      fn ->
        if empty_legacy_cert_key?() do
          "ORCHARD_TLS_CERTFILE and ORCHARD_TLS_KEYFILE must not be empty"
        end
      end,
      fn ->
        if empty_path_env?("ORCHARD_TLS_CACERTFILE") do
          "ORCHARD_TLS_CACERTFILE must not be empty"
        end
      end,
      &invalid_explicit_transport_mode/0,
      &invalid_active_transport_port/0,
      &invalid_active_bind_or_proxy_config/0,
      &invalid_active_tls_material/0
    ]
    |> Enum.find_value(fn check -> check.() end)
  end

  defp empty_path_env?(env_name) do
    case System.get_env(env_name) do
      nil -> false
      value -> String.trim(value) == ""
    end
  end

  defp path_env(env_name), do: System.get_env(env_name)

  defp invalid_explicit_transport_mode do
    case System.get_env("ORCHARD_TRANSPORT_MODE") do
      nil ->
        nil

      mode when mode in ["direct_https", "reverse_proxy", "plain_http_localhost"] ->
        nil

      mode ->
        "invalid ORCHARD_TRANSPORT_MODE: #{mode} (expected reverse_proxy, direct_https, or plain_http_localhost)"
    end
  end

  defp invalid_active_transport_port do
    case resolved_transport_mode_from_env() do
      :plain_http_localhost -> invalid_port_env("PORT")
      :reverse_proxy -> invalid_port_env("PORT") || invalid_port_env("ORCHARD_PUBLIC_PORT")
      :direct_https -> invalid_port_env("ORCHARD_API_HTTPS_PORT")
    end
  end

  defp invalid_active_bind_or_proxy_config do
    case resolved_transport_mode_from_env() do
      :plain_http_localhost ->
        invalid_ip_env("ORCHARD_API_BIND_IP", nil)

      :direct_https ->
        invalid_ip_env("ORCHARD_API_BIND_IP", System.get_env("ORCHARD_API_BIND_IP"))

      :reverse_proxy ->
        invalid_reverse_proxy_bind_or_trusted_proxies()
    end
  end

  defp invalid_reverse_proxy_bind_or_trusted_proxies do
    bind_ip_value = System.get_env("ORCHARD_API_BIND_IP")

    with nil <- invalid_ip_env("ORCHARD_API_BIND_IP", bind_ip_value),
         {:ok, bind_ip} <- parse_ip(bind_ip_value || "127.0.0.1"),
         nil <- invalid_trusted_proxy_cidrs() do
      if loopback_ip?(bind_ip) or non_empty_string(System.get_env("ORCHARD_TRUSTED_PROXIES")) do
        nil
      else
        "ORCHARD_TRUSTED_PROXIES must be set when reverse_proxy binds to a non-loopback address"
      end
    else
      message when is_binary(message) -> message
      _other -> "invalid ORCHARD_API_BIND_IP: #{bind_ip_value}"
    end
  end

  defp invalid_ip_env(_env_name, nil), do: nil
  defp invalid_ip_env(env_name, ""), do: "#{env_name} must not be empty"

  defp invalid_ip_env(env_name, value) do
    case parse_ip(value) do
      {:ok, _ip} -> nil
      :error -> "invalid #{env_name}: #{value}"
    end
  end

  defp invalid_trusted_proxy_cidrs do
    case System.get_env("ORCHARD_TRUSTED_PROXIES") do
      nil ->
        nil

      value ->
        values =
          value
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        cond do
          values == [] -> "ORCHARD_TRUSTED_PROXIES must contain at least one CIDR when set"
          Enum.all?(values, &valid_cidr?/1) -> nil
          true -> "ORCHARD_TRUSTED_PROXIES contains invalid CIDR"
        end
    end
  end

  defp invalid_active_tls_material do
    if resolved_transport_mode_from_env() == :direct_https do
      support_root = support_root()
      tls_dir = Path.join([support_root, "config", "tls"])
      certfile = System.get_env("ORCHARD_TLS_CERTFILE") || Path.join(tls_dir, "controller.crt")
      keyfile = System.get_env("ORCHARD_TLS_KEYFILE") || Path.join(tls_dir, "controller.key")
      cacertfile = path_env("ORCHARD_TLS_CACERTFILE")

      generated_local? =
        is_nil(System.get_env("ORCHARD_TLS_CERTFILE")) and
          is_nil(System.get_env("ORCHARD_TLS_KEYFILE")) and
          generated_local_ca_metadata?(support_root) and
          certfile == Path.join(tls_dir, "controller.crt") and
          keyfile == Path.join(tls_dir, "controller.key")

      with nil <- validate_generated_local_ca_override(support_root, cacertfile, generated_local?),
           nil <- require_regular("TLS certificate", certfile),
           nil <- require_regular("TLS private key", keyfile),
           nil <- validate_cert_key_pair(certfile, keyfile),
           nil <- validate_generated_local_default_ca(support_root, generated_local?) do
        validate_optional_ca(cacertfile)
      end
    end
  end

  defp validate_generated_local_ca_override(_support_root, nil, _generated_local?), do: nil
  defp validate_generated_local_ca_override(_support_root, _cacertfile, false), do: nil

  defp validate_generated_local_ca_override(support_root, cacertfile, true) do
    default_ca = Path.join([support_root, "config", "tls", "ca.crt"])

    if Path.expand(cacertfile) != Path.expand(default_ca) do
      "ORCHARD_TLS_CACERTFILE cannot override generated-local CA publication; unset it or use direct HTTPS operator-provided certificates"
    end
  end

  defp validate_generated_local_default_ca(_support_root, false), do: nil

  defp validate_generated_local_default_ca(support_root, true) do
    support_root
    |> Path.join("config/tls/ca.crt")
    |> validate_explicit_ca_file()
  end

  defp validate_optional_ca(nil), do: nil
  defp validate_optional_ca(path), do: validate_explicit_ca_file(path)

  defp require_regular(label, path) do
    if File.regular?(path), do: nil, else: "#{label} not found: #{path}"
  end

  defp validate_explicit_ca_file(path) do
    cond do
      not File.regular?(path) ->
        "CA certificate not found: #{path}"

      not ca_pem_file?(path) ->
        "TLS CA certificate file is malformed or contains no certificate PEM entry: #{path}"

      true ->
        nil
    end
  end

  defp ca_pem_file?(path), do: openssl_ok?(["x509", "-in", path, "-noout"])

  defp validate_cert_key_pair(certfile, keyfile) do
    [
      {fn -> not openssl_available?() end,
       fn ->
         "openssl is required to validate TLS certificate material before probing direct HTTPS status"
       end},
      {fn -> encrypted_key?(keyfile) end, fn -> "TLS private key is encrypted: #{keyfile}" end},
      {fn -> not openssl_ok?(["x509", "-in", certfile, "-noout"]) end,
       fn ->
         "TLS certificate file is malformed or contains no certificate PEM entry: #{certfile}"
       end},
      {fn -> not openssl_ok?(["x509", "-in", certfile, "-checkend", "0", "-noout"]) end,
       fn -> "TLS certificate has expired or is not currently valid: #{certfile}" end},
      {fn -> not_before_parse_error?(certfile) end,
       fn -> "could not parse TLS certificate validity window: #{certfile}" end},
      {fn -> cert_not_before_epoch!(certfile) > current_epoch() end,
       fn -> "TLS certificate is not valid yet: #{certfile}" end},
      {fn -> not openssl_ok?(["pkey", "-in", keyfile, "-pubout", "-passin", "pass:"]) end,
       fn -> "TLS private key file contains no supported private key PEM entry: #{keyfile}" end},
      {fn -> cert_public_key(certfile) != key_public_key(keyfile) end,
       fn -> "TLS certificate and private key do not match: #{certfile} / #{keyfile}" end}
    ]
    |> Enum.find_value(fn {invalid?, message} -> if invalid?.(), do: message.() end)
  end

  defp encrypted_key?(path) do
    case File.read(path) do
      {:ok, contents} ->
        String.contains?(contents, "ENCRYPTED") or
          String.contains?(contents, "Proc-Type: 4,ENCRYPTED")

      {:error, _reason} ->
        false
    end
  end

  defp cert_public_key(path), do: openssl_stdout(["x509", "-in", path, "-pubkey", "-noout"])

  defp key_public_key(path),
    do: openssl_stdout(["pkey", "-in", path, "-pubout", "-passin", "pass:"])

  defp not_before_parse_error?(path), do: cert_not_before_epoch(path) == :error
  defp cert_not_before_epoch!(path), do: elem(cert_not_before_epoch(path), 1)

  defp cert_not_before_epoch(path) do
    case openssl_stdout(["x509", "-in", path, "-noout", "-startdate"]) do
      "notBefore=" <> date -> parse_openssl_date(String.trim(date))
      _other -> :error
    end
  end

  defp parse_openssl_date(date) do
    case System.cmd("date", ["-j", "-f", "%b %e %T %Y %Z", date, "+%s"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out |> String.trim() |> String.to_integer()}
      _other -> :error
    end
  end

  defp current_epoch, do: System.system_time(:second)

  defp openssl_ok?(args), do: match?({_out, 0}, openssl_cmd(args))

  defp openssl_stdout(args) do
    case openssl_cmd(args) do
      {out, 0} -> out
      _other -> nil
    end
  end

  defp openssl_cmd(args) do
    case System.find_executable("openssl") do
      nil -> {"", 127}
      openssl -> System.cmd(openssl, args, stderr_to_stdout: true)
    end
  end

  defp openssl_available?, do: System.find_executable("openssl") != nil

  defp valid_cidr?(value) do
    with [ip_string, prefix_string] <- String.split(value, "/", parts: 2),
         {:ok, ip} <- parse_ip(ip_string),
         {prefix, ""} <- Integer.parse(prefix_string) do
      max = if tuple_size(ip) == 4, do: 32, else: 128
      prefix in 0..max
    else
      _other -> false
    end
  end

  defp parse_ip(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  defp loopback_ip?({127, _, _, _}), do: true
  defp loopback_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback_ip?(_ip), do: false

  defp invalid_port_env(env_name) do
    case System.get_env(env_name) do
      nil ->
        nil

      "" ->
        "#{env_name} must not be empty"

      value ->
        case Integer.parse(value) do
          {port, ""} when port in 1..65_535 -> nil
          _other -> "invalid #{env_name}: #{value}"
        end
    end
  end

  defp invalid_legacy_tls_disabled do
    case System.get_env("ORCHARD_TLS_DISABLED") do
      nil ->
        nil

      value
      when value in [
             "1",
             "true",
             "TRUE",
             "yes",
             "YES",
             "on",
             "ON",
             "0",
             "false",
             "FALSE",
             "no",
             "NO",
             "off",
             "OFF"
           ] ->
        nil

      value ->
        value
    end
  end

  defp partial_legacy_cert_key? do
    System.get_env("ORCHARD_TLS_CERTFILE") == nil !=
      (System.get_env("ORCHARD_TLS_KEYFILE") == nil)
  end

  defp empty_legacy_cert_key? do
    cert = System.get_env("ORCHARD_TLS_CERTFILE")
    key = System.get_env("ORCHARD_TLS_KEYFILE")
    (cert != nil and cert == "") or (key != nil and key == "")
  end

  defp fallback_endpoint_candidates_from_env do
    case resolved_transport_mode_from_env() do
      :direct_https -> direct_https_candidate_from_env()
      :reverse_proxy -> reverse_proxy_candidate_from_env()
      :plain_http_localhost -> plain_http_localhost_candidate_from_env()
    end
  end

  defp direct_https_candidate_from_env do
    support_root = support_root()
    configured_ca = path_env("ORCHARD_TLS_CACERTFILE")
    default_ca_path = Path.join([support_root, "config", "tls", "ca.crt"])

    generated_local? =
      is_nil(System.get_env("ORCHARD_TLS_CERTFILE")) and
        is_nil(System.get_env("ORCHARD_TLS_KEYFILE")) and
        generated_local_ca_metadata?(support_root)

    ca_certfile =
      configured_ca ||
        if(generated_local? and File.regular?(default_ca_path), do: default_ca_path)

    host = System.get_env("ORCHARD_PUBLIC_HOST") || System.get_env("PHX_HOST") || "localhost"
    port = System.get_env("ORCHARD_API_HTTPS_PORT") || "8443"
    url = format_url("https", host, port)

    [%{probe_url: url, display_url: url, ca_certfile: ca_certfile}]
  end

  defp generated_local_ca_metadata?(support_root) do
    meta_path = Path.join([support_root, "config", "tls", ".orchard-tls-meta.json"])

    with {:ok, meta_json} <- File.read(meta_path),
         {:ok, %{"source" => "generated_local_ca"}} <- Jason.decode(meta_json) do
      true
    else
      _other -> false
    end
  end

  defp reverse_proxy_candidate_from_env do
    port = System.get_env("PORT") || "4000"

    public_host =
      System.get_env("ORCHARD_PUBLIC_HOST") || System.get_env("PHX_HOST") || "localhost"

    public_port = non_empty_string(System.get_env("ORCHARD_PUBLIC_PORT"))
    display_url = format_url("https", public_host, public_port || "443")

    probe_host = reverse_proxy_probe_host(System.get_env("ORCHARD_API_BIND_IP") || "127.0.0.1")

    [%{probe_url: "http://#{probe_host}:#{port}", display_url: display_url, ca_certfile: nil}]
  end

  defp reverse_proxy_probe_host("0.0.0.0"), do: "127.0.0.1"
  defp reverse_proxy_probe_host("::"), do: "[::1]"
  defp reverse_proxy_probe_host("::0"), do: "[::1]"
  defp reverse_proxy_probe_host("::1"), do: "[::1]"

  defp reverse_proxy_probe_host(bind_ip) do
    if String.contains?(bind_ip, ":"), do: "[#{bind_ip}]", else: bind_ip
  end

  defp plain_http_localhost_candidate_from_env do
    port = System.get_env("PORT") || "4000"
    url = "http://localhost:#{port}"

    [%{probe_url: url, display_url: url, ca_certfile: nil}]
  end

  defp resolved_transport_mode_from_env do
    case System.get_env("ORCHARD_TRANSPORT_MODE") do
      "direct_https" -> :direct_https
      "reverse_proxy" -> :reverse_proxy
      "plain_http_localhost" -> :plain_http_localhost
      _ -> legacy_transport_mode_from_env()
    end
  end

  defp legacy_transport_env_set? do
    System.get_env("ORCHARD_TLS_DISABLED") != nil or
      System.get_env("ORCHARD_TLS_CERTFILE") != nil or
      System.get_env("ORCHARD_TLS_KEYFILE") != nil
  end

  defp legacy_transport_mode_from_env do
    cond do
      truthy_env?(System.get_env("ORCHARD_TLS_DISABLED")) ->
        :plain_http_localhost

      System.get_env("ORCHARD_TLS_DISABLED") != nil ->
        :direct_https

      System.get_env("ORCHARD_TLS_CERTFILE") != nil and
          System.get_env("ORCHARD_TLS_KEYFILE") != nil ->
        :direct_https

      true ->
        :plain_http_localhost
    end
  end

  defp truthy_env?(value) when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"], do: true
  defp truthy_env?(_), do: false

  defp endpoint_from_config(runtime) do
    case Map.fetch(runtime, :endpoint_config) do
      {:ok, config_fn} when is_function(config_fn, 0) ->
        config_fn.()
        |> endpoint_candidate_from_config()

      _other ->
        :fallback
    end
  end

  defp endpoint_from_application_config do
    config = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

    if Keyword.get(config, :server) == false do
      :fallback
    else
      endpoint_candidate_from_config(config)
    end
  end

  defp endpoint_candidate_from_config({:error, reason}) do
    {:error, "could not read endpoint config: #{inspect(reason)}"}
  end

  defp endpoint_candidate_from_config(config) when is_list(config) do
    cond do
      http = Keyword.get(config, :http) ->
        port = get_in(http, [:port]) || 4000
        probe_url = "http://localhost:#{port}"
        display_url = endpoint_display_url(config, "http", "localhost", port)
        {:ok, %{probe_url: probe_url, display_url: display_url, ca_certfile: nil}}

      https = Keyword.get(config, :https) ->
        port = get_in(https, [:port]) || 8443
        probe_url = endpoint_display_url(config, "https", "localhost", port)
        ca_certfile = endpoint_ca_certfile(config, https)
        {:ok, %{probe_url: probe_url, display_url: probe_url, ca_certfile: ca_certfile}}

      true ->
        :fallback
    end
  end

  defp endpoint_candidate_from_config(_config), do: :fallback

  defp endpoint_display_url(config, default_scheme, default_host, default_port) do
    url_config = Keyword.get(config, :url, [])
    scheme = Keyword.get(url_config, :scheme, default_scheme)
    host = Keyword.get(url_config, :host, default_host)
    port = Keyword.get(url_config, :port, default_port)

    format_url(scheme, host, port)
  end

  defp endpoint_ca_certfile(config, https_config) do
    case Keyword.get(config, :ca_certfile) || Keyword.get(https_config, :cacertfile) do
      configured_ca when is_binary(configured_ca) ->
        configured_ca

      _other ->
        support_root = support_root()
        ca_path = Path.join([support_root, "config", "tls", "ca.crt"])
        if File.regular?(ca_path), do: ca_path
    end
  end

  defp format_url(scheme, host, port) do
    port_string = to_string(port)
    formatted_host = format_host(host)

    if default_port?(scheme, port_string) do
      "#{scheme}://#{formatted_host}"
    else
      "#{scheme}://#{formatted_host}:#{port_string}"
    end
  end

  defp format_host(host) do
    if String.contains?(host, ":") and not String.starts_with?(host, "[") do
      "[#{host}]"
    else
      host
    end
  end

  defp default_port?("http", "80"), do: true
  defp default_port?("https", "443"), do: true
  defp default_port?(_scheme, _port), do: false

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

  # ── Default Runtime ──────────────────────────────────────────────────

  defp default_runtime do
    %{
      version: fn -> Orchard.version() end,
      request: &default_request/2
    }
  end

  # ── Usage ────────────────────────────────────────────────────────────

  defp usage do
    """
    Usage: orchardctl status

    Show the current Orchard system status.

    Probes the running controller's health endpoint and displays:
    - Local Orchard version and install role
    - Console and API URLs
    - Controller reachability and readiness state

    Examples:
      orchardctl status
      orchardctl status --help
    """
    |> String.trim()
  end
end
