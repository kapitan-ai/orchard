defmodule Orchard.Node.ModelAcquisition.Source.S3 do
  @moduledoc """
  Source adapter for `s3://` URIs.

  Downloads model bundles as tar/tar.gz archives from S3-compatible
  object stores into the staging path, then safely extracts them.

  ## URI Format

      s3://bucket/key.tar.gz                          # default region
      s3://bucket/key.tar.gz?region=us-west-2         # explicit region
      s3://bucket/key.tar.gz?endpoint=http://minio:9000  # custom endpoint

  ## Algorithm

  1. Parse URI to extract bucket, object key, and query overrides
  2. HEAD object for content-length and ETag
  3. Stream GET into a `.partial` file in staging
  4. Rename partial to final archive name
  5. Safe extraction via `Tar.extract_archive/3`
  6. Delete archive file
  7. Orchestrator handles hash verification and finalization
  """

  @behaviour Orchard.Node.ModelAcquisition.SourceAdapter

  require Logger

  alias Orchard.Node
  alias Orchard.Node.ModelAcquisition.Request
  alias Orchard.Node.ModelAcquisition.Tar

  # Progress emission threshold: emit every 8 MiB
  @progress_threshold_bytes 8 * 1024 * 1024

  # -- Public API ------------------------------------------------------------

  @impl true
  def materialize(%Request{} = request) do
    # Use a sibling temp directory for archive download + extraction scratch
    # work so that no temp names (`.source_archive.*`, extract dirs) can
    # collide with legitimate archive entries inside staging_path.
    unique = System.unique_integer([:positive]) |> Integer.to_string()
    tmp_root = Path.join(Path.dirname(request.staging_path), ".orchard-s3-tmp-#{unique}")

    try do
      with :ok <- mkdir_p(tmp_root),
           {:ok, source_spec} <- parse_s3_uri(request.artifact_source_uri),
           {:ok, effective_config} <- resolve_config(source_spec),
           {:ok, head_meta} <- head_object(source_spec, effective_config),
           {:ok, archive_path} <-
             download_object(source_spec, head_meta, request, effective_config, tmp_root) do
        extract_and_cleanup(
          archive_path,
          request.staging_path,
          source_spec.archive_format,
          tmp_root
        )
      end
    after
      File.rm_rf(tmp_root)
    end
  end

  # -- URI Parsing -----------------------------------------------------------

  @doc false
  def parse_s3_uri(uri) when not is_binary(uri), do: {:error, :invalid_source_uri}

  def parse_s3_uri(uri) when is_binary(uri) do
    with {:ok, host, object_key, query} <- parse_s3_location(uri),
         {:ok, params} <- parse_query_params(query),
         {:ok, format} <- detect_archive_format(object_key) do
      {:ok,
       %{
         bucket: host,
         object_key: object_key,
         region: Map.get(params, "region"),
         endpoint: Map.get(params, "endpoint"),
         archive_format: format
       }}
    end
  end

  defp parse_s3_location(uri) do
    case URI.parse(uri) do
      %URI{scheme: "s3", host: host, path: path, query: query}
      when is_binary(host) and host != "" ->
        case parse_object_key(path) do
          "" -> {:error, :invalid_source_uri}
          object_key -> {:ok, host, object_key, query}
        end

      _ ->
        {:error, :invalid_source_uri}
    end
  end

  defp parse_object_key(nil), do: ""
  defp parse_object_key("/"), do: ""
  defp parse_object_key("/" <> rest), do: URI.decode(rest)
  defp parse_object_key(path), do: URI.decode(path)

  defp parse_query_params(nil), do: {:ok, %{}}
  defp parse_query_params(""), do: {:ok, %{}}

  defp parse_query_params(query) do
    params = URI.decode_query(query)

    if Enum.all?(Map.keys(params), &(&1 in ["region", "endpoint"])) do
      {:ok, params}
    else
      {:error, :invalid_source_uri}
    end
  end

  defp detect_archive_format(object_key) do
    cond do
      String.ends_with?(object_key, ".tar.gz") ->
        {:ok, :tar_gz}

      String.ends_with?(object_key, ".tar") ->
        {:ok, :tar}

      true ->
        {:error, {:unsupported_archive_extension, "expected .tar or .tar.gz, got: #{object_key}"}}
    end
  end

  # -- Config Resolution -----------------------------------------------------

  # Security/Trust: The effective endpoint can come from either the runtime
  # config (`Node.s3_config/0`) or the `artifact_source_uri` query string
  # (`?endpoint=http://...`). Both redirect the node-agent's outbound
  # request destination, and SigV4 credentials will be attached to that
  # request if configured. Therefore `artifact_source_uri` must be treated
  # as an admin-controlled, trusted input — it comes from the controller's
  # model registry, not from end-users. This is intentionally permissive
  # to support MinIO and other S3-compatible stores. If `artifact_source_uri`
  # ever becomes user-supplied, add an endpoint allowlist here.
  defp resolve_config(source_spec) do
    base = Node.s3_config()

    region = source_spec.region || Keyword.get(base, :region, "us-east-1")
    endpoint = source_spec.endpoint || Keyword.get(base, :endpoint)
    access_key_id = Keyword.get(base, :access_key_id)
    secret_access_key = Keyword.get(base, :secret_access_key)
    session_token = Keyword.get(base, :session_token)
    force_path_style? = Keyword.get(base, :force_path_style?, false)
    connect_timeout_ms = Keyword.get(base, :connect_timeout_ms, 10_000)
    receive_timeout_ms = Keyword.get(base, :receive_timeout_ms, 60_000)
    req_options = Keyword.get(base, :req_options, [])

    with {:ok, signing_mode} <-
           validate_credentials(access_key_id, secret_access_key, session_token) do
      {:ok,
       %{
         region: region,
         endpoint: endpoint,
         access_key_id: access_key_id,
         secret_access_key: secret_access_key,
         session_token: session_token,
         force_path_style?: force_path_style?,
         connect_timeout_ms: connect_timeout_ms,
         receive_timeout_ms: receive_timeout_ms,
         req_options: req_options,
         signing_mode: signing_mode
       }}
    end
  end

  defp validate_credentials(access_key_id, secret_access_key, session_token) do
    cond do
      not is_nil(access_key_id) and not is_nil(secret_access_key) ->
        {:ok, :signed}

      is_nil(access_key_id) and is_nil(secret_access_key) and is_nil(session_token) ->
        {:ok, :unsigned}

      true ->
        {:error,
         {:invalid_source_config,
          "S3 credentials partially configured: provide both access_key_id and secret_access_key, or neither"}}
    end
  end

  # -- URL Construction ------------------------------------------------------

  defp build_object_url(source_spec, config) do
    %{bucket: bucket, object_key: key} = source_spec
    %{endpoint: endpoint, region: region, force_path_style?: force_path_style?} = config

    encoded_key =
      key
      |> Path.split()
      |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)

    cond do
      endpoint != nil and force_path_style? ->
        "#{endpoint}/#{bucket}/#{encoded_key}"

      endpoint != nil ->
        # virtual-hosted style with custom endpoint
        uri = URI.parse(endpoint)

        "#{uri.scheme}://#{bucket}.#{uri.host}#{if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""}/#{encoded_key}"

      force_path_style? ->
        "https://s3.#{region}.amazonaws.com/#{bucket}/#{encoded_key}"

      true ->
        "https://#{bucket}.s3.#{region}.amazonaws.com/#{encoded_key}"
    end
  end

  # -- HEAD Object -----------------------------------------------------------

  defp head_object(source_spec, config) do
    url = build_object_url(source_spec, config)

    Logger.info("S3: HEAD #{url}")

    case s3_request(:head, url, config) do
      {:ok, %{status: 200} = resp} ->
        build_head_meta(resp, url)

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, {:source_unauthorized, "S3 returned #{status} for HEAD"}}

      {:ok, %{status: 404}} ->
        {:error, {:source_not_found, "S3 object not found"}}

      {:ok, %{status: status}} ->
        {:error, {:source_unavailable, "S3 HEAD returned #{status}"}}

      {:error, reason} ->
        {:error, {:source_unavailable, "S3 HEAD failed: #{inspect(reason)}"}}
    end
  end

  defp build_head_meta(resp, url) do
    case validate_content_length(get_header_int(resp, "content-length")) do
      {:ok, content_length} ->
        {:ok, %{content_length: content_length, etag: get_etag(resp), url: url}}

      {:error, message} ->
        {:error, {:source_unavailable, message}}
    end
  end

  defp validate_content_length(nil), do: {:error, "S3 HEAD returned no content-length"}
  defp validate_content_length(length) when is_integer(length) and length > 0, do: {:ok, length}
  defp validate_content_length(_length), do: {:error, "S3 HEAD returned invalid content-length"}

  defp get_header_int(resp, name) do
    case header_values(resp, name) do
      [value | _rest] ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      [] ->
        nil
    end
  end

  defp get_etag(resp) do
    case header_values(resp, "etag") do
      [value | _rest] -> normalize_etag(value)
      [] -> nil
    end
  end

  defp header_values(%{headers: headers}, name), do: header_values(headers, name)

  defp header_values(headers, name) when is_map(headers) do
    case Map.get(headers, name, []) do
      values when is_list(values) -> values
      value when is_binary(value) -> [value]
      _other -> []
    end
  end

  defp header_values(headers, name) when is_list(headers) do
    for {header_name, value} <- headers, header_name == name, is_binary(value), do: value
  end

  defp header_values(_headers, _name), do: []

  # -- GET Object (Streaming Download) ---------------------------------------

  defp download_object(source_spec, head_meta, request, config, tmp_root) do
    state = build_download_state(source_spec, head_meta, request, config, tmp_root)

    Logger.info("S3: GET #{state.url} (#{state.expected_size} bytes)")

    case File.open(state.partial_path, [:binary, :write]) do
      {:ok, file_pid} ->
        stream_download_to_file(state, file_pid)

      {:error, reason} ->
        {:error, {:filesystem_error, "open #{state.partial_path}: #{inspect(reason)}"}}
    end
  end

  defp build_download_state(source_spec, head_meta, request, config, tmp_root) do
    archive_ext = if source_spec.archive_format == :tar_gz, do: ".tar.gz", else: ".tar"

    %{
      config: config,
      url: head_meta.url,
      expected_size: head_meta.content_length,
      request: request,
      object_key: source_spec.object_key,
      partial_path: Path.join(tmp_root, ".source_archive.partial"),
      archive_path: Path.join(tmp_root, ".source_archive#{archive_ext}")
    }
  end

  defp stream_download_to_file(state, file_pid) do
    counters = build_download_counters()
    result = execute_download_request(state, file_pid, counters)
    File.close(file_pid)
    finalize_download(state, result, counters)
  end

  defp build_download_counters do
    %{
      bytes_counter: :counters.new(1, [:atomics]),
      last_progress: :counters.new(1, [:atomics]),
      write_error: :atomics.new(1, [])
    }
  end

  defp execute_download_request(state, file_pid, counters) do
    s3_request(:get, state.url, state.config, into: download_into(file_pid, counters, state))
  end

  defp download_into(file_pid, counters, state) do
    fn {:data, chunk}, {req, resp} ->
      case write_download_chunk(file_pid, chunk, counters, state) do
        :ok -> {:cont, {req, resp}}
        :error -> {:halt, {req, resp}}
      end
    end
  end

  defp write_download_chunk(file_pid, chunk, counters, state) do
    case :file.write(file_pid, chunk) do
      :ok ->
        chunk_size = byte_size(chunk)
        :counters.add(counters.bytes_counter, 1, chunk_size)
        maybe_emit_threshold_progress(counters, state)
        :ok

      {:error, _reason} ->
        :atomics.put(counters.write_error, 1, 1)
        :error
    end
  end

  defp maybe_emit_threshold_progress(counters, state) do
    current = :counters.get(counters.bytes_counter, 1)
    last = :counters.get(counters.last_progress, 1)

    if current - last >= @progress_threshold_bytes do
      :counters.put(counters.last_progress, 1, current)
      emit_progress(current, state.expected_size, 0, state.request, state.object_key)
    end
  end

  defp finalize_download(state, result, counters) do
    bytes_written = :counters.get(counters.bytes_counter, 1)

    if :atomics.get(counters.write_error, 1) == 1 do
      {:error, {:filesystem_error, "write #{state.partial_path}: disk write failed"}}
    else
      handle_download_result(state, result, bytes_written)
    end
  end

  defp handle_download_result(state, {:ok, %{status: 200}}, bytes_written) do
    if bytes_written != state.expected_size do
      {:error,
       {:download_incomplete, "expected #{state.expected_size} bytes, got #{bytes_written}"}}
    else
      finalize_successful_download(state, bytes_written)
    end
  end

  defp handle_download_result(_state, {:ok, %{status: status}}, _bytes_written)
       when status in [401, 403] do
    {:error, {:source_unauthorized, "S3 returned #{status} during download"}}
  end

  defp handle_download_result(_state, {:ok, %{status: 404}}, _bytes_written) do
    {:error, {:source_not_found, "S3 object not found during download"}}
  end

  defp handle_download_result(_state, {:ok, %{status: status}}, _bytes_written) do
    {:error, {:source_unavailable, "S3 GET returned #{status}"}}
  end

  defp handle_download_result(_state, {:error, reason}, _bytes_written) do
    {:error, {:download_failed, "S3 download failed: #{inspect(reason)}"}}
  end

  defp finalize_successful_download(state, bytes_written) do
    emit_progress(bytes_written, state.expected_size, 1, state.request, state.object_key)

    case File.rename(state.partial_path, state.archive_path) do
      :ok -> {:ok, state.archive_path}
      {:error, reason} -> {:error, {:filesystem_error, "rename partial: #{inspect(reason)}"}}
    end
  end

  # -- Extract & Cleanup -----------------------------------------------------

  defp extract_and_cleanup(archive_path, staging_path, archive_format, tmp_root) do
    extract_root = Path.join(tmp_root, ".extract")

    case Tar.extract_archive(archive_path, staging_path, archive_format, extract_root) do
      :ok ->
        File.rm(archive_path)
        :ok

      {:error, _} = err ->
        File.rm(archive_path)
        err
    end
  end

  # -- HTTP Helpers ----------------------------------------------------------

  defp s3_request(method, url, config, extra_opts \\ []) do
    merged_opts =
      method
      |> base_request_options(url, config)
      |> maybe_put_into(Keyword.get(extra_opts, :into))
      |> maybe_put_sigv4(config)
      |> Keyword.merge(config.req_options)

    Req.new()
    |> ReqS3.attach()
    |> Req.request(merged_opts)
  end

  defp base_request_options(method, url, config) do
    [
      method: method,
      url: url,
      connect_options: [timeout: config.connect_timeout_ms],
      receive_timeout: config.receive_timeout_ms,
      retry: false
    ]
  end

  defp maybe_put_into(opts, nil), do: opts
  defp maybe_put_into(opts, into), do: Keyword.put(opts, :into, into)

  defp maybe_put_sigv4(opts, %{signing_mode: :signed} = config) do
    Keyword.put(opts, :aws_sigv4, sigv4_options(config))
  end

  defp maybe_put_sigv4(opts, _config), do: opts

  defp sigv4_options(config) do
    [
      service: :s3,
      access_key_id: config.access_key_id,
      secret_access_key: config.secret_access_key,
      region: config.region
    ]
    |> maybe_put_session_token(config.session_token)
  end

  defp maybe_put_session_token(opts, nil), do: opts

  defp maybe_put_session_token(opts, session_token),
    do: Keyword.put(opts, :session_token, session_token)

  # -- Progress Telemetry ----------------------------------------------------

  defp emit_progress(bytes_downloaded, total_bytes, files_completed, request, object_key) do
    :telemetry.execute(
      [:orchard, :node, :model_acquisition, :progress],
      %{
        bytes_downloaded: bytes_downloaded,
        total_bytes: total_bytes,
        files_completed: files_completed,
        total_files: 1
      },
      %{
        model_id: request.model_id,
        version: request.version,
        source_scheme: "s3",
        path: object_key
      }
    )
  end

  # -- Utility ---------------------------------------------------------------

  defp normalize_etag(etag) when is_binary(etag) do
    etag |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  defp mkdir_p(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:filesystem_error, "mkdir_p #{path}: #{inspect(reason)}"}}
    end
  end
end
