defmodule OrchardCLI.EndpointMetadata do
  @moduledoc """
  Reads and writes the non-secret controller endpoint metadata sidecar.

  This file is for endpoint discovery only. It deliberately excludes secrets,
  credentials, private-key paths, database URLs, API keys, and Console state.
  """

  @default_support_root "/Library/Application Support/Orchard"
  @schema_version 1
  @allowed_transport_modes ["plain_http_localhost", "direct_https", "reverse_proxy"]
  @fields [
    :schema_version,
    :transport_mode,
    :public_host,
    :api_https_port,
    :plain_http_port,
    :api_bind_ip,
    :ca_certfile,
    :updated_at,
    :generated_by
  ]
  @input_fields @fields -- [:schema_version, :updated_at]
  @field_names Enum.map(@fields, &Atom.to_string/1)

  @type metadata :: %{
          schema_version: 1,
          transport_mode: String.t(),
          public_host: String.t() | nil,
          api_https_port: pos_integer() | nil,
          plain_http_port: pos_integer() | nil,
          api_bind_ip: String.t() | nil,
          ca_certfile: String.t() | nil,
          updated_at: String.t(),
          generated_by: String.t()
        }

  @spec default_path() :: String.t()
  def default_path do
    support_root = System.get_env("ORCHARD_SUPPORT_ROOT") || @default_support_root
    Path.join([support_root, "public", "endpoint.json"])
  end

  @spec write(map(), keyword()) :: :ok | {:error, {:invalid, String.t()} | File.posix()}
  def write(metadata, opts \\ []) when is_map(metadata) do
    path = Keyword.get(opts, :path, default_path())
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)

    with {:ok, normalized} <- normalize_write_metadata(metadata, now),
         :ok <- ensure_public_dir(Path.dirname(path)),
         {:ok, json} <- Jason.encode(normalized) do
      atomic_write(path, json <> "\n")
    end
  end

  @spec read(keyword()) :: {:ok, metadata()} | {:error, :not_found | {:malformed, String.t()}}
  def read(opts \\ []) do
    path = Keyword.get(opts, :path, default_path())

    with {:ok, contents} <- read_file(path),
         {:ok, decoded} <- decode_json(contents) do
      normalize_read_metadata(decoded)
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:malformed, "could not read endpoint metadata sidecar: #{reason}"}}
    end
  end

  defp decode_json(contents) do
    case Jason.decode(contents) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, {:malformed, "endpoint metadata sidecar must be a JSON object"}}
      {:error, _reason} -> {:error, {:malformed, "malformed JSON in endpoint metadata sidecar"}}
    end
  end

  defp normalize_write_metadata(metadata, now) do
    with {:ok, clean} <- reject_unknown_atom_fields(metadata, @input_fields),
         {:ok, updated_at} <- timestamp(now),
         {:ok, normalized} <- normalize_values(Map.put(clean, :updated_at, updated_at)) do
      {:ok,
       normalized
       |> Map.put(:schema_version, @schema_version)
       |> stringify_keys()}
    end
  end

  defp normalize_read_metadata(decoded) do
    with :ok <- validate_exact_string_fields(decoded),
         {:ok, schema_version} <- require_integer(decoded, "schema_version"),
         :ok <- require_schema_version(schema_version),
         {:ok, values} <- normalize_values(atomize_keys(decoded)) do
      {:ok, Map.put(values, :schema_version, @schema_version)}
    else
      {:error, {:invalid, message}} -> {:error, {:malformed, message}}
    end
  end

  defp reject_unknown_atom_fields(metadata, allowed) do
    unknown =
      metadata
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] -> {:ok, metadata}
      [field | _] -> {:error, {:invalid, "unknown endpoint metadata field: #{field}"}}
    end
  end

  defp validate_exact_string_fields(metadata) do
    keys = Map.keys(metadata)
    unknown = Enum.reject(keys, &(&1 in @field_names))
    missing = Enum.reject(@field_names, &(&1 in keys))

    cond do
      unknown != [] -> {:error, {:invalid, "unknown endpoint metadata field: #{hd(unknown)}"}}
      missing != [] -> {:error, {:invalid, "missing endpoint metadata field: #{hd(missing)}"}}
      true -> :ok
    end
  end

  defp normalize_values(metadata) do
    with {:ok, transport_mode} <- require_transport_mode(metadata[:transport_mode]),
         {:ok, public_host} <- optional_public_host(metadata[:public_host]),
         {:ok, api_https_port} <- optional_port(metadata[:api_https_port], :api_https_port),
         {:ok, plain_http_port} <- optional_port(metadata[:plain_http_port], :plain_http_port),
         {:ok, api_bind_ip} <- optional_string(metadata[:api_bind_ip], :api_bind_ip),
         {:ok, ca_certfile} <- optional_ca_certfile(metadata[:ca_certfile]),
         {:ok, updated_at} <- require_iso8601(metadata[:updated_at], :updated_at),
         {:ok, generated_by} <- require_string(metadata[:generated_by], :generated_by) do
      {:ok,
       %{
         transport_mode: transport_mode,
         public_host: public_host,
         api_https_port: api_https_port,
         plain_http_port: plain_http_port,
         api_bind_ip: api_bind_ip,
         ca_certfile: ca_certfile,
         updated_at: updated_at,
         generated_by: generated_by
       }}
    end
  end

  defp require_transport_mode(mode) when mode in @allowed_transport_modes, do: {:ok, mode}

  defp require_transport_mode(_mode) do
    {:error,
     {:invalid, "transport_mode must be plain_http_localhost, direct_https, or reverse_proxy"}}
  end

  defp require_string(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid, "#{field} must not be empty"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_string(_value, field), do: {:error, {:invalid, "#{field} must be a string"}}

  defp optional_string(nil, _field), do: {:ok, nil}
  defp optional_string(value, field) when is_binary(value), do: require_string(value, field)

  defp optional_string(_value, field),
    do: {:error, {:invalid, "#{field} must be a string or null"}}

  defp optional_public_host(nil), do: {:ok, nil}

  defp optional_public_host(value) when is_binary(value) do
    with {:ok, host} <- require_string(value, :public_host),
         :ok <- validate_public_host(host) do
      {:ok, host}
    end
  end

  defp optional_public_host(_value),
    do: {:error, {:invalid, "public_host must be a hostname/IP string or null"}}

  defp validate_public_host(host) do
    if String.contains?(host, "://") or String.match?(host, ~r/\s/) do
      {:error, {:invalid, "public_host must not include a URL scheme or whitespace"}}
    else
      :ok
    end
  end

  defp optional_ca_certfile(nil), do: {:ok, nil}

  defp optional_ca_certfile(value) when is_binary(value) do
    with {:ok, path} <- require_string(value, :ca_certfile),
         :ok <- validate_public_ca_path(path) do
      {:ok, path}
    end
  end

  defp optional_ca_certfile(_value),
    do: {:error, {:invalid, "ca_certfile must be a public CA certificate path or null"}}

  defp validate_public_ca_path(path) do
    cond do
      String.contains?(path, "/config/") ->
        {:error, {:invalid, "ca_certfile must not point inside protected config directories"}}

      String.ends_with?(path, ".key") ->
        {:error, {:invalid, "ca_certfile must not point to a private key"}}

      not String.contains?(path, "/public/") or not String.ends_with?(path, ".crt") ->
        {:error, {:invalid, "ca_certfile must point to a public .crt file"}}

      true ->
        :ok
    end
  end

  defp require_iso8601(value, field) when is_binary(value) do
    with {:ok, trimmed} <- require_string(value, field),
         {:ok, _datetime, _offset} <- DateTime.from_iso8601(trimmed) do
      {:ok, trimmed}
    else
      {:error, {:invalid, _message}} = error -> error
      _other -> {:error, {:invalid, "#{field} must be an ISO8601 timestamp"}}
    end
  end

  defp require_iso8601(_value, field),
    do: {:error, {:invalid, "#{field} must be an ISO8601 timestamp"}}

  defp optional_port(nil, _field), do: {:ok, nil}
  defp optional_port(port, _field) when is_integer(port) and port in 1..65_535, do: {:ok, port}

  defp optional_port(_port, field),
    do: {:error, {:invalid, "#{field} must be an integer TCP port or null"}}

  defp require_integer(metadata, field) do
    case Map.fetch(metadata, field) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      _other -> {:error, {:invalid, "#{field} must be #{@schema_version}"}}
    end
  end

  defp require_schema_version(@schema_version), do: :ok

  defp require_schema_version(_other),
    do: {:error, {:invalid, "schema_version must be #{@schema_version}"}}

  defp timestamp(now) do
    case now.() do
      %DateTime{} = datetime ->
        {:ok, DateTime.to_iso8601(datetime)}

      value when is_binary(value) ->
        require_iso8601(value, :updated_at)

      _other ->
        {:error, {:invalid, "updated_at clock must return DateTime or ISO8601 string"}}
    end
  end

  defp stringify_keys(metadata),
    do: Map.new(metadata, fn {key, value} -> {to_string(key), value} end)

  defp atomize_keys(metadata) do
    Map.new(metadata, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp ensure_public_dir(dir) do
    support_root = Path.dirname(dir)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(support_root, 0o755) do
      File.chmod(dir, 0o755)
    end
  end

  defp atomic_write(path, contents) do
    tmp_path = path <> ".#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(tmp_path, contents),
         :ok <- File.chmod(tmp_path, 0o644),
         :ok <- File.rename(tmp_path, path),
         :ok <- File.chmod(path, 0o644) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(tmp_path)
        if reason in [:enoent, :eacces], do: error, else: {:error, reason}
    end
  end
end
