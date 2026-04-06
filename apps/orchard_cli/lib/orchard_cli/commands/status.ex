defmodule OrchardCLI.Commands.Status do
  @moduledoc """
  CLI handler for `orchardctl status`.

  Probes the running controller's `/health/ready` endpoint and renders a
  human-readable status banner.

  Supports:
    orchardctl status       — Show system status banner
    orchardctl status help  — Show usage
  """

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
      %{state: :invalid_response, display_url: url, error: message} ->
        {:error, "Error: invalid health response from #{url}: #{message}", 1}

      snap ->
        {:ok, render_snapshot(snap)}
    end
  end

  @doc false
  @spec snapshot(map()) :: map()
  def snapshot(runtime \\ default_runtime()) do
    version = Map.get(runtime, :version, fn -> Orchard.version() end).()
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
          base_url: nil,
          display_url: display_url,
          body: nil
        }

      {:error, :invalid_response, display_url, message, probe_failure} ->
        %{
          version: version,
          display_version: format_display_version(version, nil),
          state: :invalid_response,
          base_url: nil,
          display_url: display_url,
          body: nil,
          error: message,
          probe_failure: probe_failure
        }
    end
  end

  @doc false
  @spec render_snapshot(map()) :: String.t()
  def render_snapshot(%{state: :offline} = snap) do
    render_offline_banner(snap.display_version, snap.display_url)
  end

  def render_snapshot(snap) do
    render_banner(snap.display_version, snap.base_url, snap.body)
  end

  # ── Candidate Probing ───────────────────────────────────────────────

  defp probe_candidates([], _request_fn), do: {:error, :unreachable, "http://localhost:4000"}

  defp probe_candidates(candidates, request_fn) do
    display_url = hd(candidates) |> Map.fetch!(:base_url)

    candidates
    |> Enum.reduce_while(
      %{display_url: display_url, invalid_response: nil, saw_unreachable?: false},
      fn candidate, acc ->
        url = candidate.base_url <> "/health/ready"
        opts = build_request_opts(candidate)

        case request_fn.(url, opts) do
          {:ok, %{status: status, body: body}} when status in 200..599 ->
            case decode_health_response(body) do
              {:ok, parsed} ->
                {:halt, {:ok, candidate.base_url, parsed}}

              {:error, reason} ->
                invalid_response = acc.invalid_response || {candidate.base_url, reason}
                {:cont, %{acc | invalid_response: invalid_response}}
            end

          _ ->
            {:cont, %{acc | saw_unreachable?: true}}
        end
      end
    )
    |> finalize_probe_result()
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

  defp render_banner(display_version, base_url, body) do
    status_label = if body["status"] == "ok", do: "ready", else: "degraded"
    details = build_details(body, status_label)

    """
    \u{1F333} Orchard #{display_version}
       Console: #{base_url}/console
       API:     #{base_url}/v1
       Status:  #{status_label}#{details}
    """
    |> String.trim()
  end

  defp render_offline_banner(display_version, display_url) do
    """
    \u{1F333} Orchard #{display_version}
       Console: #{display_url}/console
       API:     #{display_url}/v1
       Status:  offline (controller unreachable)
    """
    |> String.trim()
  end

  defp build_details(body, status_label) do
    runtime = body["runtime"]

    cond do
      # No runtime block or not a map (malformed payload)
      not is_map(runtime) ->
        detail_suffix(status_label, body["reason"], "runtime unavailable")

      # Runtime probe itself failed (timeout, error, etc.)
      runtime["status"] != "ok" ->
        runtime_detail = "runtime #{runtime["status"] || "unavailable"}"
        detail_suffix(status_label, body["reason"], runtime_detail)

      # Runtime is ok — build full detail string
      true ->
        parts = []

        # Node presence
        parts =
          if runtime["node_id"],
            do: parts ++ ["1 node"],
            else: parts ++ ["0 nodes"]

        # Worker state
        worker = runtime["worker_state"]
        parts = if worker, do: parts ++ [worker], else: parts

        # Model count
        counts = runtime["counts"]
        model_count = if is_map(counts), do: counts["loaded_models"] || 0, else: 0

        model_text =
          if model_count == 1, do: "1 model loaded", else: "#{model_count} models loaded"

        parts = parts ++ [model_text]

        # Runtime health (surface degraded/unhealthy when different from system status)
        health = runtime["health"]

        parts =
          if health in ["degraded", "unhealthy"],
            do: parts ++ ["health: #{health}"],
            else: parts

        detail_suffix(status_label, body["reason"], Enum.join(parts, ", "))
    end
  end

  defp detail_suffix("degraded", reason, runtime_details) when is_binary(reason) do
    " (#{reason}, #{runtime_details})"
  end

  defp detail_suffix(_status, _reason, runtime_details) do
    " (#{runtime_details})"
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
      |> maybe_add_ca_cert(ca_certfile)

    case Req.request(Req.new(req_opts), receive_timeout: receive_timeout) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_ca_cert(opts, nil), do: opts

  defp maybe_add_ca_cert(opts, ca_path) do
    Keyword.update(opts, :connect_options, [cacertfile: ca_path], fn connect_opts ->
      Keyword.put(connect_opts, :cacertfile, ca_path)
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
