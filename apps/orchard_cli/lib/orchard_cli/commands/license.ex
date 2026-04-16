defmodule OrchardCLI.Commands.License do
  @moduledoc """
  CLI handler for `orchardctl license` commands.

  Supports:
    orchardctl license activate <key> [--support-root PATH]
    orchardctl license status [--support-root PATH]
    orchardctl license help
  """

  alias Orchard.Licensing
  alias Orchard.NodeIdentityFile

  @default_keygen_api_base_url "https://api.keygen.sh"
  @json_api_content_type "application/vnd.api+json"

  @type request_spec :: %{
          method: :get | :post,
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: map() | nil
        }

  @type request_result ::
          {:ok, %{status: pos_integer(), body: map() | binary() | nil}} | {:error, term()}

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  # credo:disable-for-lines:3 ExSlop.Check.Readability.DocFalseOnPublicFunction
  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(args, runtime) do
    case args do
      ["activate" | rest] -> run_activate(rest, runtime)
      ["status" | rest] -> run_status(rest, runtime)
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _ -> {:error, group_usage(), 1}
    end
  end

  defp run_activate(args, runtime) do
    case parse_activate_opts(args) do
      {:help} ->
        {:ok, activate_usage()}

      {:error, _, _} = error ->
        error

      {:ok, opts, license_key} ->
        do_activate(opts, license_key, runtime)
    end
  end

  defp run_status(args, runtime) do
    case parse_status_opts(args) do
      {:help} ->
        {:ok, status_usage()}

      {:error, _, _} = error ->
        error

      {:ok, opts} ->
        do_status(opts, runtime)
    end
  end

  defp parse_activate_opts(args) do
    switches = [support_root: :string, help: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false) do
          {:help}
        else
          {:error, "Error: missing required argument: <key>\n\n#{activate_usage()}", 1}
        end

      {parsed, [license_key], []} ->
        if Keyword.get(parsed, :help, false) do
          {:help}
        else
          {:ok, parsed, license_key}
        end

      {_parsed, positional, []} ->
        {:error,
         "Error: expected exactly one license key, got: #{Enum.join(positional, ", ")}\n\n#{activate_usage()}",
         1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{activate_usage()}", 1}
    end
  end

  defp parse_status_opts(args) do
    switches = [support_root: :string, help: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false), do: {:help}, else: {:ok, parsed}

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{status_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{status_usage()}", 1}
    end
  end

  defp do_activate(opts, license_key, runtime) do
    licensing_paths = resolve_licensing_paths(opts, runtime)

    with {:ok, config} <- activation_config(licensing_paths, runtime),
         {:ok, node_id, _source} <- ensure_node_identity(runtime, config.node_identity_path),
         {:ok, license_id} <- validate_key(runtime, config, license_key, node_id),
         {:ok, machine_id} <- ensure_machine(runtime, config, license_key, license_id, node_id),
         {:ok, license_certificate} <-
           checkout_license_certificate(runtime, config, license_key, license_id),
         {:ok, machine_certificate} <-
           checkout_machine_certificate(runtime, config, license_key, machine_id),
         {:ok, status} <- install_pair(runtime, config, license_certificate, machine_certificate) do
      {:ok, activation_success_message(status, node_id)}
    else
      {:error, {:config, message}} -> {:error, "Error: #{message}", 1}
      {:error, {:identity, message}} -> {:error, "Error: #{message}", 1}
      {:error, {:validation, message}} -> {:error, "Error: #{message}", 1}
      {:error, {:activation, message}} -> {:error, "Error: #{message}", 1}
      {:error, {:checkout, message}} -> {:error, "Error: #{message}", 1}
      {:error, {:install, message}} -> {:error, "Error: #{message}", 1}
    end
  end

  defp do_status(opts, runtime) do
    config = status_config(resolve_licensing_paths(opts, runtime), runtime)

    status =
      licensing_impl(runtime).inspect_local(
        bundle_path: config.bundle_path,
        node_identity_path: config.node_identity_path,
        keygen_public_key: config.keygen_public_key
      )

    {:ok, render_local_status(status)}
  end

  defp activation_config(licensing_paths, runtime) do
    shared = shared_licensing_config(runtime)

    config = %{
      bundle_path: non_empty_string(licensing_paths.bundle_path),
      node_identity_path: non_empty_string(licensing_paths.node_identity_path),
      keygen_api_base_url:
        non_empty_string(shared[:keygen_api_base_url]) || @default_keygen_api_base_url,
      keygen_account_id: non_empty_string(shared[:keygen_account_id]),
      keygen_public_key: non_empty_string(shared[:keygen_public_key])
    }

    cond do
      is_nil(config.bundle_path) ->
        {:error, {:config, "Licensing bundle path is not configured."}}

      is_nil(config.node_identity_path) ->
        {:error, {:config, "Node identity path is not configured."}}

      is_nil(config.keygen_account_id) ->
        {:error, {:config, "Keygen account ID is not configured."}}

      is_nil(config.keygen_public_key) ->
        {:error, {:config, "Keygen public key is not configured."}}

      true ->
        {:ok, config}
    end
  end

  defp status_config(licensing_paths, runtime) do
    shared = shared_licensing_config(runtime)

    %{
      bundle_path: non_empty_string(licensing_paths.bundle_path),
      node_identity_path: non_empty_string(licensing_paths.node_identity_path),
      keygen_public_key: non_empty_string(shared[:keygen_public_key])
    }
  end

  defp ensure_node_identity(runtime, path) do
    case node_identity_impl(runtime).ensure(path) do
      {:ok, node_id, source} ->
        {:ok, node_id, source}

      {:error, {:invalid_uuid, value}} ->
        {:error, {:identity, "Local node identity is invalid: #{inspect(value)}."}}

      {:error, {:read_failed, reason}} ->
        {:error, {:identity, "Cannot read node identity file #{path}: #{inspect(reason)}."}}

      {:error, {:write_failed, reason}} ->
        {:error, {:identity, "Cannot persist node identity file #{path}: #{inspect(reason)}."}}
    end
  end

  defp validate_key(runtime, config, license_key, _fingerprint) do
    body = %{
      "meta" => %{
        "key" => license_key
      }
    }

    request = %{
      method: :post,
      url: keygen_url(config, ["licenses", "actions", "validate-key"]),
      headers: json_api_headers(),
      body: body
    }

    with {:ok, response} <- perform_request(runtime, request, :validation, "license validation"),
         :ok <- ensure_success_status(response, "license validation", :validation),
         {:ok, body} <- decode_json_body(response.body, "license validation", :validation),
         {:ok, license_id} <- extract_license_id(body) do
      {:ok, license_id}
    else
      {:error, {:validation, _message}} = error -> error
    end
  end

  defp ensure_machine(runtime, config, license_key, license_id, fingerprint) do
    case lookup_existing_machine_id(runtime, config, license_key, fingerprint) do
      {:ok, nil} ->
        activate_machine(runtime, config, license_key, license_id, fingerprint)

      {:ok, machine_id} ->
        {:ok, machine_id}

      {:error, {:activation, _message}} = error ->
        error
    end
  end

  defp activate_machine(runtime, config, license_key, license_id, fingerprint) do
    body = %{
      "data" => %{
        "type" => "machines",
        "attributes" => %{
          "fingerprint" => fingerprint,
          "platform" => "macOS",
          "name" => System.get_env("HOSTNAME") || "Orchard node"
        },
        "relationships" => %{
          "license" => %{
            "data" => %{"type" => "licenses", "id" => license_id}
          }
        }
      }
    }

    request = %{
      method: :post,
      url: keygen_url(config, ["machines"]),
      headers: license_auth_headers(license_key),
      body: body
    }

    with {:ok, response} <-
           perform_request(runtime, request, :activation, "machine activation"),
         :ok <- ensure_success_status(response, "machine activation", :activation),
         {:ok, body} <- decode_json_body(response.body, "machine activation", :activation),
         {:ok, machine_id} <- extract_machine_id(body, "machine activation") do
      {:ok, machine_id}
    else
      {:error, {:activation, _message}} = error -> error
    end
  end

  defp checkout_license_certificate(runtime, config, license_key, license_id) do
    request = %{
      method: :post,
      url: keygen_url(config, ["licenses", license_id, "actions", "check-out"]),
      headers: license_auth_headers(license_key),
      body: nil
    }

    checkout_certificate(runtime, request, "license", :checkout)
  end

  defp checkout_machine_certificate(runtime, config, license_key, machine_id) do
    request = %{
      method: :post,
      url: keygen_url(config, ["machines", machine_id, "actions", "check-out"]),
      headers: license_auth_headers(license_key),
      body: nil
    }

    checkout_certificate(runtime, request, "machine", :checkout)
  end

  defp checkout_certificate(runtime, request, kind, error_kind) do
    action = "#{kind} checkout"

    with {:ok, response} <- perform_request(runtime, request, error_kind, action),
         :ok <- ensure_success_status(response, action, error_kind),
         {:ok, body} <- decode_json_body(response.body, action, error_kind),
         {:ok, certificate} <- extract_certificate(body, kind, error_kind) do
      {:ok, certificate}
    else
      {:error, {^error_kind, _message}} = error -> error
    end
  end

  defp install_pair(runtime, config, license_certificate, machine_certificate) do
    bundle = %{
      license_certificate: license_certificate,
      machine_certificate: machine_certificate
    }

    case licensing_impl(runtime).install_pair(bundle,
           bundle_path: config.bundle_path,
           node_identity_path: config.node_identity_path,
           keygen_public_key: config.keygen_public_key
         ) do
      {:ok, status} ->
        {:ok, status}

      {:error, {:write_failed, reason}} ->
        {:error,
         {:install, "Cannot persist licensing bundle #{config.bundle_path}: #{inspect(reason)}."}}

      {:error, %Licensing{} = status} ->
        {:error, {:install, status.message}}
    end
  end

  defp lookup_existing_machine_id(runtime, config, license_key, fingerprint) do
    do_lookup_existing_machine_id(
      runtime,
      machines_list_request(config, license_key),
      license_key,
      fingerprint,
      MapSet.new()
    )
  end

  defp do_lookup_existing_machine_id(
         runtime,
         %{url: url} = request,
         license_key,
         fingerprint,
         seen_urls
       ) do
    with {:ok, seen_urls} <- track_machine_lookup_url(seen_urls, url),
         {:ok, response} <- perform_request(runtime, request, :activation, "machine lookup"),
         :ok <- ensure_success_status(response, "machine lookup", :activation),
         {:ok, body} <- decode_json_body(response.body, "machine lookup", :activation) do
      continue_machine_lookup(body, runtime, license_key, fingerprint, seen_urls)
    end
  end

  defp continue_machine_lookup(body, runtime, license_key, fingerprint, seen_urls) do
    with {:ok, machine_id} <- existing_machine_id(body, fingerprint),
         {:ok, next_url} <- next_machine_page_url(body) do
      finish_machine_lookup(machine_id, next_url, runtime, license_key, fingerprint, seen_urls)
    end
  end

  defp finish_machine_lookup(
         machine_id,
         _next_url,
         _runtime,
         _license_key,
         _fingerprint,
         _seen_urls
       )
       when is_binary(machine_id) and machine_id != "" do
    {:ok, machine_id}
  end

  defp finish_machine_lookup(_machine_id, next_url, runtime, license_key, fingerprint, seen_urls)
       when is_binary(next_url) and next_url != "" do
    do_lookup_existing_machine_id(
      runtime,
      machine_page_request(next_url, license_key),
      license_key,
      fingerprint,
      seen_urls
    )
  end

  defp finish_machine_lookup(
         _machine_id,
         _next_url,
         _runtime,
         _license_key,
         _fingerprint,
         _seen_urls
       ) do
    {:ok, nil}
  end

  defp track_machine_lookup_url(seen_urls, url) do
    if MapSet.member?(seen_urls, url) do
      {:error, {:activation, "Malformed response from machine lookup."}}
    else
      {:ok, MapSet.put(seen_urls, url)}
    end
  end

  defp machines_list_request(config, license_key) do
    machine_page_request(keygen_url(config, ["machines"]) <> "?limit=100", license_key)
  end

  defp machine_page_request(url, license_key) do
    %{
      method: :get,
      url: url,
      headers: license_auth_headers(license_key),
      body: nil
    }
  end

  defp existing_machine_id(%{"data" => machines}, fingerprint) when is_list(machines) do
    machine_id =
      Enum.find_value(machines, fn
        %{"id" => machine_id, "attributes" => %{"fingerprint" => ^fingerprint}}
        when is_binary(machine_id) and machine_id != "" ->
          machine_id

        _other ->
          nil
      end)

    {:ok, machine_id}
  end

  defp existing_machine_id(_body, _fingerprint) do
    {:error, {:activation, "Malformed response from machine lookup."}}
  end

  defp next_machine_page_url(%{"links" => %{"next" => next_url}})
       when is_binary(next_url) and next_url != "" do
    {:ok, next_url}
  end

  defp next_machine_page_url(%{"links" => %{"next" => nil}}), do: {:ok, nil}
  defp next_machine_page_url(%{"links" => links}) when is_map(links), do: {:ok, nil}
  defp next_machine_page_url(%{}), do: {:ok, nil}

  defp next_machine_page_url(_body) do
    {:error, {:activation, "Malformed response from machine lookup."}}
  end

  defp extract_license_id(%{"meta" => %{"valid" => true}, "data" => %{"id" => license_id}})
       when is_binary(license_id) and license_id != "" do
    {:ok, license_id}
  end

  defp extract_license_id(%{"meta" => %{"valid" => false, "detail" => detail}})
       when is_binary(detail) and detail != "" do
    {:error, {:validation, detail}}
  end

  defp extract_license_id(_body) do
    {:error, {:validation, "Malformed response from license validation."}}
  end

  defp extract_machine_id(%{"data" => %{"id" => machine_id}}, _action)
       when is_binary(machine_id) and machine_id != "" do
    {:ok, machine_id}
  end

  defp extract_machine_id(_body, action) do
    {:error, {:activation, "Malformed #{action} response."}}
  end

  defp extract_certificate(
         %{"data" => %{"attributes" => %{"certificate" => certificate}}},
         _kind,
         _error_kind
       )
       when is_binary(certificate) and certificate != "" do
    {:ok, certificate}
  end

  defp extract_certificate(%{"data" => %{"attributes" => _attributes}}, kind, error_kind) do
    {:error, {error_kind, "Malformed #{kind} checkout response: certificate is missing."}}
  end

  defp extract_certificate(_body, kind, error_kind) do
    {:error, {error_kind, "Malformed #{kind} checkout response."}}
  end

  defp perform_request(runtime, %{} = request, error_kind, action) do
    case request_impl(runtime).(request) do
      {:ok, %{status: status} = response} when is_integer(status) ->
        {:ok, %{status: status, body: Map.get(response, :body)}}

      {:error, reason} ->
        {:error, {error_kind, "#{String.capitalize(action)} request failed: #{inspect(reason)}."}}

      other ->
        {:error,
         {error_kind, "Unexpected HTTP client response during #{action}: #{inspect(other)}."}}
    end
  end

  defp ensure_success_status(%{status: status}, _action, _error_kind) when status in 200..299,
    do: :ok

  defp ensure_success_status(%{status: status, body: body}, action, error_kind) do
    {:error, {error_kind, format_provider_error(action, status, body)}}
  end

  defp decode_json_body(body, _action, _error_kind) when is_map(body), do: {:ok, body}

  defp decode_json_body(body, action, error_kind) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, {error_kind, "Malformed #{action} response."}}

      {:error, _reason} ->
        {:error, {error_kind, "Malformed #{action} response."}}
    end
  end

  defp decode_json_body(_body, action, error_kind) do
    {:error, {error_kind, "Malformed #{action} response."}}
  end

  defp format_provider_error(action, status, %{"errors" => [first | _rest]}) when is_map(first) do
    detail = non_empty_string(first["detail"]) || non_empty_string(first["title"])
    code = non_empty_string(first["code"])
    suffix = if code, do: " (#{code})", else: ""
    summary = detail || "request failed"
    "#{String.capitalize(action)} failed with HTTP #{status}: #{summary}#{suffix}."
  end

  defp format_provider_error(action, status, %{"meta" => %{"detail" => detail}})
       when is_binary(detail) and detail != "" do
    "#{String.capitalize(action)} failed with HTTP #{status}: #{detail}."
  end

  defp format_provider_error(action, status, _body) do
    "#{String.capitalize(action)} failed with HTTP #{status}."
  end

  defp activation_success_message(%Licensing{} = status, node_id) do
    [
      "License activated",
      "  Node fingerprint: #{node_id}",
      "  Bundle path: #{status.bundle_path}",
      "  License state: #{status.state}",
      maybe_line("  License ID: ", status.license_id),
      maybe_line("  Machine ID: ", status.machine_id),
      maybe_line("  Expires at: ", iso8601(status.expires_at))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_local_status(%Licensing{} = status) do
    ([
       "License status: #{status.state}",
       "  Message: #{status.message}",
       "  Bundle path: #{status.bundle_path}"
       | fingerprint_lines(status)
     ] ++
       [
         maybe_line("  License ID: ", status.license_id),
         maybe_line("  Machine ID: ", status.machine_id),
         maybe_line("  Licensee: ", status.licensee),
         maybe_line(
           "  Max machines: ",
           status.max_machines && Integer.to_string(status.max_machines)
         ),
         maybe_line("  Expires at: ", iso8601(status.expires_at))
       ])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp fingerprint_lines(%Licensing{fingerprint: nil}), do: []

  defp fingerprint_lines(%Licensing{
         fingerprint: fingerprint,
         local_node_fingerprint: fingerprint
       })
       when is_binary(fingerprint) do
    ["  Machine certificate fingerprint: #{fingerprint}"]
  end

  defp fingerprint_lines(%Licensing{
         fingerprint: fingerprint,
         local_node_fingerprint: local_fingerprint
       })
       when is_binary(fingerprint) and is_binary(local_fingerprint) do
    [
      "  Local node fingerprint: #{local_fingerprint}",
      "  Machine certificate fingerprint: #{fingerprint}"
    ]
  end

  defp fingerprint_lines(%Licensing{fingerprint: fingerprint}) when is_binary(fingerprint) do
    ["  Machine certificate fingerprint: #{fingerprint}"]
  end

  defp keygen_url(config, segments) do
    base = String.trim_trailing(config.keygen_api_base_url, "/")
    account_id = URI.encode(config.keygen_account_id)
    path = Enum.map_join(segments, "/", &URI.encode/1)
    base <> "/v1/accounts/" <> account_id <> "/" <> path
  end

  defp json_api_headers do
    [
      {"accept", @json_api_content_type},
      {"content-type", @json_api_content_type}
    ]
  end

  defp license_auth_headers(license_key) do
    [{"authorization", "License #{license_key}"} | json_api_headers()]
  end

  defp licensing_impl(runtime), do: Map.get(runtime, :licensing_impl, Licensing)
  defp node_identity_impl(runtime), do: Map.get(runtime, :node_identity_impl, NodeIdentityFile)

  defp shared_config_impl(runtime),
    do:
      Map.get(runtime, :shared_config, fn ->
        Application.get_env(:orchard_shared, :licensing, [])
      end)

  defp shared_licensing_config(runtime), do: shared_config_impl(runtime).()
  defp request_impl(runtime), do: Map.get(runtime, :request, &default_request/1)

  defp resolve_licensing_paths(opts, runtime) do
    case support_root_override(opts) do
      nil ->
        shared = shared_licensing_config(runtime)

        %{
          bundle_path: shared[:bundle_path],
          node_identity_path: shared[:node_identity_path]
        }

      support_root ->
        %{
          bundle_path: bundle_path(support_root),
          node_identity_path: node_identity_path(support_root)
        }
    end
  end

  defp support_root_override(opts) do
    non_empty_string(Keyword.get(opts, :support_root)) ||
      non_empty_string(System.get_env("ORCHARD_SUPPORT_ROOT"))
  end

  defp bundle_path(support_root),
    do: Path.join([support_root, "config", "licensing", "current.json"])

  defp node_identity_path(support_root), do: Path.join([support_root, "data", "node-id"])

  defp default_request(%{method: method, url: url, headers: headers, body: body}) do
    req_opts =
      [
        url: url,
        method: method,
        headers: headers,
        retry: false,
        redirect: false
      ]
      |> maybe_put_body(body)

    case Req.request(Req.new(req_opts)) do
      {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_body(opts, body) when is_map(body),
    do: Keyword.put(opts, :body, Jason.encode!(body))

  defp maybe_put_body(opts, _body), do: opts

  defp maybe_line(_label, nil), do: nil
  defp maybe_line(label, value), do: label <> value

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp non_empty_string(nil), do: nil

  defp non_empty_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_value), do: nil

  defp default_runtime do
    %{
      request: &default_request/1,
      licensing_impl: Licensing,
      node_identity_impl: NodeIdentityFile,
      shared_config: fn -> Application.get_env(:orchard_shared, :licensing, []) end
    }
  end

  defp group_usage do
    """
    Usage: orchardctl license <activate|status|help>

    Manage Orchard's local dual-certificate license bundle.

    Commands:
      activate <key> [--support-root PATH]  Activate a license and install the local bundle
      status [--support-root PATH]          Inspect the local license bundle offline
      help                                  Show this help
    """
    |> String.trim()
  end

  defp activate_usage do
    """
    Usage: orchardctl license activate <key> [--support-root PATH]

    Activate a license using a customer-safe Keygen flow, check out the Orchard
    license + machine certificates, validate them offline, and atomically install
    the local bundle at <support_root>/config/licensing/current.json.

    Options:
      --support-root PATH   Support root directory
                            (default precedence: --support-root, then
                             $ORCHARD_SUPPORT_ROOT, else current environment licensing config)
    """
    |> String.trim()
  end

  defp status_usage do
    """
    Usage: orchardctl license status [--support-root PATH]

    Inspect the local Orchard license bundle offline without contacting the
    controller and without generating a node identity as a side effect.

    Options:
      --support-root PATH   Support root directory
                            (default precedence: --support-root, then
                             $ORCHARD_SUPPORT_ROOT, else current environment licensing config)
    """
    |> String.trim()
  end
end
