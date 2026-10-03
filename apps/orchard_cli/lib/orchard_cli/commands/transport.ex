defmodule OrchardCLI.Commands.Transport do
  @moduledoc """
  CLI handler for `orchardctl transport` commands.
  """

  alias Orchard.EndpointMetadata
  alias OrchardCLI.Commands.{LifecycleSupport, TLS}
  alias OrchardCLI.{ShellEnv, TransportPublication}

  @default_support_root "/Library/Application Support/Orchard"
  @default_https_port 8443
  @transport_assignments [
    {"ORCHARD_TRANSPORT_MODE", "direct_https"},
    {"ORCHARD_PUBLIC_HOST", :host},
    {"ORCHARD_API_HTTPS_PORT", :port}
  ]
  @tls_override_keys ["ORCHARD_TLS_CERTFILE", "ORCHARD_TLS_KEYFILE", "ORCHARD_TLS_CACERTFILE"]

  @spec run([String.t()]) :: OrchardCLI.command_result()
  def run(args), do: run(args, default_runtime())

  @doc false
  @spec run([String.t()], map()) :: OrchardCLI.command_result()
  def run(args, runtime) do
    case args do
      ["enable-local-https" | rest] -> run_enable_local_https(rest, runtime)
      ["help"] -> {:ok, group_usage()}
      ["--help"] -> {:ok, group_usage()}
      [] -> {:error, group_usage(), 1}
      _other -> {:error, group_usage(), 1}
    end
  end

  defp run_enable_local_https(args, runtime) do
    with {:ok, opts} <- parse_enable_opts(args),
         {:ok, config} <- build_enable_config(opts, runtime),
         {:ok, role} <- LifecycleSupport.install_role(runtime) do
      enable_for_role(role, config, runtime)
    else
      {:help} -> {:ok, enable_usage()}
      {:error, _message, _code} = error -> error
    end
  end

  defp parse_enable_opts(args) do
    switches = [host: :string, port: :string, help: :boolean]

    case OptionParser.parse(args, strict: switches) do
      {parsed, [], []} ->
        if Keyword.get(parsed, :help, false), do: {:help}, else: require_host(parsed)

      {_parsed, positional, []} ->
        {:error,
         "Error: unexpected argument(s): #{Enum.join(positional, ", ")}\n\n#{enable_usage()}", 1}

      {_parsed, _positional, invalid} ->
        invalid_str = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
        {:error, "Error: unknown option(s): #{invalid_str}\n\n#{enable_usage()}", 1}
    end
  end

  defp require_host(parsed) do
    case Keyword.fetch(parsed, :host) do
      {:ok, _host} ->
        {:ok, Keyword.put_new(parsed, :port, Integer.to_string(@default_https_port))}

      :error ->
        {:error, "Error: --host is required.\n\n#{enable_usage()}", 1}
    end
  end

  defp build_enable_config(opts, runtime) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)

    with {:ok, validated_host} <- validate_host(host),
         {:ok, validated_port} <- validate_port(port) do
      support_root = support_root(runtime)

      {:ok,
       %{
         host: validated_host,
         port: validated_port,
         support_root: support_root,
         controller_env_path: Path.join([support_root, "config", "controller.env"]),
         tls_dir: Path.join([support_root, "config", "tls"]),
         public_ca_path: Path.join([support_root, "public", "ca.crt"]),
         endpoint_path: Path.join([support_root, "public", "endpoint.json"])
       }}
    end
  end

  defp enable_for_role(:node_agent, _config, _runtime) do
    {:ok,
     "Direct HTTPS transport is not applicable for node-agent role.\n" <>
       "Role: node-agent\n" <>
       "Run on a controller or all-role Orchard host."}
  end

  defp enable_for_role(role, config, runtime) when role in [:all, :controller] do
    with :ok <- require_root(runtime),
         :ok <- require_controller_env(config),
         {:ok, publication} <- prepare_publication(config, runtime) do
      config
      |> publish_and_configure(publication, runtime)
      |> finish_publication(publication)
      |> then(&restart_after_publication(&1, role, config, runtime))
    end
    |> format_error()
  end

  defp format_error({:error, _message, _code} = error), do: error
  defp format_error({:error, message}), do: {:error, "Error: #{message}", 1}
  defp format_error(result), do: result

  defp prepare_publication(%{support_root: support_root}, runtime) do
    opts = Map.get(runtime, :publication_opts, [])

    case TransportPublication.prepare(support_root, opts) do
      {:ok, publication} -> {:ok, publication}
      {:error, reason} -> {:error, TransportPublication.format_error(reason)}
    end
  end

  defp publish_and_configure(config, publication, runtime) do
    with :ok <- reject_tls_overrides(config),
         {:ok, _tls_message} <- run_tls_init(config, publication, runtime),
         {:ok, ca_bytes, ca_certfile, warnings} <- load_public_ca(config, runtime),
         {:ok, endpoint_bytes} <- encode_endpoint_metadata(config, ca_certfile, runtime) do
      case TransportPublication.publish(publication, ca_bytes, endpoint_bytes) do
        {:ok, stage_warnings} ->
          configure(config, runtime, ca_certfile, warnings ++ stage_warnings)

        {:error, reason} ->
          {:ended, {:error, TransportPublication.format_error(reason)}}
      end
    else
      error -> {:abort, error}
    end
  end

  defp configure(config, runtime, ca_certfile, warnings) do
    case upsert_controller_env(config, runtime) do
      :ok -> {:published, ca_certfile, warnings}
      {:error, message} -> {:rollback, message}
    end
  end

  defp finish_publication({:published, ca_certfile, warnings}, publication) do
    case TransportPublication.commit(publication) do
      :ok ->
        {:ok, ca_certfile, warnings}

      {:error, reason} ->
        {:error,
         "public CA and endpoint metadata were published under #{publication.public_dir} " <>
           "and controller.env was updated, but the publication helper did not confirm " <>
           "COMMIT: #{TransportPublication.format_error(reason)}\n" <>
           "Controller restart was NOT attempted. Inspect #{publication.public_dir} and " <>
           "restart the controller once publication is verified."}
    end
  end

  defp finish_publication({:rollback, message}, publication) do
    with {:ok, stage_warnings} <- TransportPublication.rollback(publication),
         :ok <- TransportPublication.commit(publication) do
      {:error, Enum.join([message | stage_warnings], "\n")}
    else
      {:error, reason} ->
        {:error, "#{message}; #{TransportPublication.format_error(reason)}"}
    end
  end

  defp finish_publication({:ended, error}, _publication), do: error

  defp finish_publication({:abort, error}, publication) do
    case TransportPublication.abort(publication) do
      :ok -> error
      {:error, reason} -> append_abort_failure(error, TransportPublication.format_error(reason))
    end
  end

  defp append_abort_failure({:error, message, code}, failure),
    do: {:error, "#{message}\n#{failure}", code}

  defp append_abort_failure({:error, message}, failure), do: {:error, "#{message}; #{failure}"}

  defp restart_after_publication({:ok, ca_certfile, warnings}, role, config, runtime) do
    with {:ok, restart_line} <- restart_controller_if_loaded(role, runtime) do
      {:ok, success_message(config, ca_certfile, warnings, restart_line)}
    end
  end

  defp restart_after_publication(error, _role, _config, _runtime), do: error

  defp require_root(runtime) do
    uid = runtime |> Map.get(:uid, &default_uid/0) |> then(& &1.())

    if uid == 0 do
      :ok
    else
      {:error,
       "Error: root privileges required to enable Orchard local HTTPS transport.\n" <>
         "Run: sudo orchardctl transport enable-local-https --host HOST", 1}
    end
  end

  defp require_controller_env(%{controller_env_path: path}) do
    cond do
      File.regular?(path) ->
        :ok

      File.exists?(path) ->
        {:error, "controller.env is not a regular file. Run: sudo orchardctl env init"}

      true ->
        {:error, "controller.env not found. Run: sudo orchardctl env init"}
    end
  end

  defp run_tls_init(%{host: host, support_root: support_root} = config, publication, runtime) do
    case existing_generated_tls(config) do
      {:ok, :reusable} ->
        {:ok, "existing generated local-CA TLS material reused"}

      {:error, message} ->
        {:error, message, 1}

      :missing ->
        tls_init = Map.get(runtime, :tls_init, &default_tls_init/3)
        tls_init.(host, support_root, publication.stage_dir)
    end
  end

  defp default_tls_init(host, support_root, stage_dir) do
    args = ["init", "--no-trust", "--output-dir", Path.join([support_root, "config", "tls"])]

    args =
      if ip_literal?(host) do
        args ++ ["--ip", host]
      else
        args ++ ["--host", host]
      end

    TLS.run_in_private_stage(args, stage_dir)
  end

  defp reject_tls_overrides(%{controller_env_path: path}) do
    case File.read(path) do
      {:ok, contents} -> reject_active_tls_overrides(contents)
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, :file.format_error(reason)}
    end
  end

  defp reject_active_tls_overrides(contents) do
    active_keys =
      contents
      |> String.split("\n")
      |> Enum.flat_map(&active_tls_override_key/1)
      |> Enum.uniq()

    case active_keys do
      [] ->
        :ok

      keys ->
        {:error,
         "controller.env contains operator-provided TLS overrides (#{Enum.join(keys, ", ")}). " <>
           "Remove those ORCHARD_TLS_* lines before enabling generated local HTTPS."}
    end
  end

  defp active_tls_override_key(line) do
    trimmed = String.trim_leading(line)

    if String.starts_with?(trimmed, "#") do
      []
    else
      Enum.filter(@tls_override_keys, fn key ->
        Regex.match?(~r/^#{Regex.escape(key)}\s*=/, trimmed)
      end)
    end
  end

  defp upsert_controller_env(%{controller_env_path: path, host: host, port: port}, runtime) do
    assignments =
      Enum.map(@transport_assignments, fn
        {key, :host} -> {key, host}
        {key, :port} -> {key, to_string(port)}
        assignment -> assignment
      end)

    upsert = Map.get(runtime, :shell_env_upsert, &ShellEnv.upsert/2)
    upsert.(path, assignments)
  end

  defp load_public_ca(%{tls_dir: tls_dir, public_ca_path: public_ca_path}, runtime) do
    source_ca = Path.join(tls_dir, "ca.crt")
    metadata_path = Path.join(tls_dir, ".orchard-tls-meta.json")
    read_public_ca = Map.get(runtime, :read_public_ca, &read_public_ca/1)

    cond do
      not File.regular?(source_ca) ->
        {:ok, nil, nil, []}

      not generated_local_ca_metadata?(metadata_path) ->
        {:ok, nil, nil, []}

      true ->
        case read_public_ca.(source_ca) do
          {:ok, bytes} ->
            {:ok, bytes, public_ca_path, []}

          {:error, reason} ->
            {:ok, nil, nil,
             [
               "Warning: local CA certificate could not be published for non-root status: #{reason}"
             ]}
        end
    end
  end

  defp read_public_ca(source_ca) do
    case File.read(source_ca) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, :file.format_error(reason)}
    end
  end

  defp existing_generated_tls(%{tls_dir: tls_dir, host: host}) do
    metadata_path = Path.join(tls_dir, ".orchard-tls-meta.json")
    required_files = ["ca.crt", "controller.crt", "controller.key"]

    if Enum.all?(required_files, &File.regular?(Path.join(tls_dir, &1))) and
         generated_local_ca_metadata?(metadata_path) do
      validate_existing_tls_host(metadata_path, host)
    else
      :missing
    end
  end

  defp validate_existing_tls_host(metadata_path, host) do
    case read_generated_local_ca_metadata(metadata_path) do
      {:ok, metadata} ->
        if metadata_includes_host?(metadata, host) do
          {:ok, :reusable}
        else
          {:error, tls_host_mismatch_message(host)}
        end

      :error ->
        :missing
    end
  end

  defp tls_host_mismatch_message(host) do
    tls_flag = if ip_literal?(host), do: "--ip", else: "--host"

    "existing generated TLS material does not include #{tls_flag} #{host}. " <>
      "Regenerate it with orchardctl tls init --force --no-trust #{tls_flag} #{host}."
  end

  defp generated_local_ca_metadata?(metadata_path) do
    match?({:ok, _metadata}, read_generated_local_ca_metadata(metadata_path))
  end

  defp read_generated_local_ca_metadata(metadata_path) do
    with {:ok, contents} <- File.read(metadata_path),
         {:ok, %{"source" => "generated_local_ca"} = metadata} <- Jason.decode(contents) do
      {:ok, metadata}
    else
      _other -> :error
    end
  end

  defp metadata_includes_host?(metadata, host) do
    field = if ip_literal?(host), do: "san_ip", else: "san_dns"

    metadata
    |> Map.get(field, [])
    |> Enum.any?(&(&1 == host))
  end

  defp encode_endpoint_metadata(config, ca_certfile, runtime) do
    metadata = %{
      transport_mode: "direct_https",
      public_host: config.host,
      api_https_port: config.port,
      plain_http_port: nil,
      api_bind_ip: "0.0.0.0",
      ca_certfile: ca_certfile,
      generated_by: "orchardctl transport enable-local-https"
    }

    case EndpointMetadata.encode(metadata, now: Map.get(runtime, :now, &DateTime.utc_now/0)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, {:invalid, message}} -> {:error, message}
    end
  end

  defp restart_controller_if_loaded(role, runtime) do
    case LifecycleSupport.restart_loaded(role, :controller, runtime) do
      {:restarted, _svc} -> {:ok, "Controller restarted."}
      {:not_loaded, _svc} -> {:ok, "Controller is not loaded. Run: sudo orchardctl start"}
      {:error, _message, _code} = error -> error
    end
  end

  defp success_message(config, ca_certfile, warnings, restart_line) do
    ca_line =
      case ca_certfile do
        nil -> "CA certificate: not published"
        path -> "CA certificate: #{path}"
      end

    [
      "Direct HTTPS transport enabled.",
      "Endpoint: #{format_url("https", config.host, config.port)}",
      ca_line,
      "Endpoint metadata: #{config.endpoint_path}"
    ]
    |> Kernel.++(warnings)
    |> Kernel.++([restart_line])
    |> Enum.join("\n")
  end

  defp validate_host(host) when is_binary(host) do
    host = String.trim(host)

    cond do
      host == "" ->
        invalid_host(host)

      String.contains?(host, ["://", " ", "\t", "\n", "\r", ",", "/"]) ->
        invalid_host(host)

      ip_literal?(host) ->
        {:ok, host}

      hostname?(host) ->
        {:ok, host}

      true ->
        invalid_host(host)
    end
  end

  defp validate_host(host), do: invalid_host(host)

  defp invalid_host(host) do
    {:error,
     "Error: invalid --host #{inspect(host)}. Use a DNS hostname, IPv4 address, or IPv6 address without a URL scheme.",
     1}
  end

  defp hostname?(host) do
    byte_size(host) <= 253 and
      host
      |> String.split(".")
      |> Enum.all?(&hostname_label?/1)
  end

  defp hostname_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$/, label)
  end

  defp validate_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {parsed, ""} when parsed in 1..65_535 -> {:ok, parsed}
      _other -> invalid_port(port)
    end
  end

  defp validate_port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp validate_port(port), do: invalid_port(port)

  defp invalid_port(port) do
    {:error,
     "Error: invalid --port #{inspect(port)}. Expected an integer TCP port from 1 to 65535.", 1}
  end

  defp ip_literal?(string) do
    case :inet.parse_address(String.to_charlist(string)) do
      {:ok, _ip} -> true
      {:error, _reason} -> false
    end
  end

  defp format_url(scheme, host, port) do
    formatted_host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    "#{scheme}://#{formatted_host}:#{port}"
  end

  defp support_root(runtime) do
    Map.get(runtime, :support_root) ||
      System.get_env("ORCHARD_SUPPORT_ROOT") ||
      @default_support_root
  end

  defp default_runtime, do: %{}

  defp default_uid do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {output, 0} -> output |> String.trim() |> String.to_integer()
      _other -> -1
    end
  end

  defp group_usage do
    """
    orchardctl transport <command>

    Commands:
      enable-local-https   Configure generated local-CA direct HTTPS for the controller

    Run `orchardctl transport <command> --help` for command-specific options.
    """
    |> String.trim()
  end

  defp enable_usage do
    """
    orchardctl transport enable-local-https --host HOST [--port PORT]

    Generate or reuse Orchard local-CA TLS material, enable direct HTTPS in
    controller.env, publish non-secret endpoint metadata, and restart the
    loaded controller service if present.

    Options:
      --host HOST   Browser/API hostname or IP address to place in TLS SANs
      --port PORT   Public HTTPS port (default: 8443)
      --help        Show this help

    Example:
      sudo orchardctl transport enable-local-https --host mawarduri --port 8443
    """
    |> String.trim()
  end
end
