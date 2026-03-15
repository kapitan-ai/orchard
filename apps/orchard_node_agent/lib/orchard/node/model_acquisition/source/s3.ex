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
             download_object(source_spec, head_meta, request, effective_config, tmp_root),
           :ok <-
             extract_and_cleanup(
               archive_path,
               request.staging_path,
               source_spec.archive_format,
               tmp_root
             ) do
        :ok
      end
    after
      File.rm_rf(tmp_root)
    end
  end

  # -- URI Parsing -----------------------------------------------------------

  @doc false
  def parse_s3_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "s3", host: host, path: path, query: query}
      when is_binary(host) and host != "" ->
        object_key = parse_object_key(path)

        if object_key == "" do
          {:error, :invalid_source_uri}
        else
          with {:ok, params} <- parse_query_params(query),
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

      _ ->
        {:error, :invalid_source_uri}
    end
  end

  def parse_s3_uri(_), do: {:error, :invalid_source_uri}

  defp parse_object_key(nil), do: ""
  defp parse_object_key("/"), do: ""
  defp parse_object_key("/" <> rest), do: URI.decode(rest)
  defp parse_object_key(path), do: URI.decode(path)

  defp parse_query_params(nil), do: {:ok, %{}}
  defp parse_query_params(""), do: {:ok, %{}}

  defp parse_query_params(query) do
    params = URI.decode_query(query)
    known = MapSet.new(["region", "endpoint"])
    unknown = params |> Map.keys() |> MapSet.new() |> MapSet.difference(known)

    if MapSet.size(unknown) > 0 do
      {:error, :invalid_source_uri}
    else
      {:ok, params}
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
      |> Enum.map(fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)
      |> Enum.join("/")

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
        # Req 0.5 returns headers as %{"name" => ["value", ...]}
        content_length = get_header_int(resp.headers, "content-length")

        etag =
          case Map.get(resp.headers, "etag") do
            [val | _] -> normalize_etag(val)
            _ -> nil
          end

        case content_length do
          nil ->
            {:error, {:source_unavailable, "S3 HEAD returned no content-length"}}

          length when is_integer(length) and length > 0 ->
            {:ok, %{content_length: length, etag: etag, url: url}}

          _ ->
            {:error, {:source_unavailable, "S3 HEAD returned invalid content-length"}}
        end

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

  defp get_header_int(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] ->
        case Integer.parse(value) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # -- GET Object (Streaming Download) ---------------------------------------

  defp download_object(source_spec, head_meta, request, config, tmp_root) do
    %{content_length: expected_size, etag: _head_etag, url: url} = head_meta
    %{archive_format: format} = source_spec

    archive_ext = if format == :tar_gz, do: ".tar.gz", else: ".tar"
    partial_path = Path.join(tmp_root, ".source_archive.partial")
    archive_path = Path.join(tmp_root, ".source_archive#{archive_ext}")

    Logger.info("S3: GET #{url} (#{expected_size} bytes)")

    case File.open(partial_path, [:binary, :write]) do
      {:ok, file_pid} ->
        bytes_counter = :counters.new(1, [:atomics])
        last_progress = :counters.new(1, [:atomics])
        write_error = :atomics.new(1, [])

        into_fun = fn {:data, chunk}, {req, resp} ->
          case IO.binwrite(file_pid, chunk) do
            :ok ->
              chunk_size = byte_size(chunk)
              :counters.add(bytes_counter, 1, chunk_size)

              # Emit progress if threshold crossed
              current = :counters.get(bytes_counter, 1)
              last = :counters.get(last_progress, 1)

              if current - last >= @progress_threshold_bytes do
                :counters.put(last_progress, 1, current)
                emit_progress(current, expected_size, 0, request, source_spec.object_key)
              end

              {:cont, {req, resp}}

            {:error, _reason} ->
              # Record write failure; halt will propagate via Req response
              :atomics.put(write_error, 1, 1)
              {:halt, {req, resp}}
          end
        end

        result = s3_request(:get, url, config, into: into_fun)
        File.close(file_pid)
        bytes_written = :counters.get(bytes_counter, 1)

        # Check for write errors first
        if :atomics.get(write_error, 1) == 1 do
          {:error, {:filesystem_error, "write #{partial_path}: disk write failed"}}
        else
          case result do
            {:ok, %{status: 200}} ->
              if bytes_written != expected_size do
                {:error,
                 {:download_incomplete, "expected #{expected_size} bytes, got #{bytes_written}"}}
              else
                # Emit final progress with files_completed: 1
                emit_progress(bytes_written, expected_size, 1, request, source_spec.object_key)

                case File.rename(partial_path, archive_path) do
                  :ok ->
                    {:ok, archive_path}

                  {:error, reason} ->
                    {:error, {:filesystem_error, "rename partial: #{inspect(reason)}"}}
                end
              end

            {:ok, %{status: status}} when status in [401, 403] ->
              {:error, {:source_unauthorized, "S3 returned #{status} during download"}}

            {:ok, %{status: 404}} ->
              {:error, {:source_not_found, "S3 object not found during download"}}

            {:ok, %{status: status}} ->
              {:error, {:source_unavailable, "S3 GET returned #{status}"}}

            {:error, reason} ->
              {:error, {:download_failed, "S3 download failed: #{inspect(reason)}"}}
          end
        end

      {:error, reason} ->
        {:error, {:filesystem_error, "open #{partial_path}: #{inspect(reason)}"}}
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
    %{
      connect_timeout_ms: connect_timeout,
      receive_timeout_ms: receive_timeout,
      req_options: req_options,
      signing_mode: signing_mode
    } = config

    into = Keyword.get(extra_opts, :into)

    base_opts =
      [
        method: method,
        url: url,
        connect_options: [timeout: connect_timeout],
        receive_timeout: receive_timeout,
        retry: false
      ]
      |> then(fn opts -> if into, do: Keyword.put(opts, :into, into), else: opts end)

    # Add S3 signing if credentials are configured
    base_opts =
      if signing_mode == :signed do
        sigv4_opts =
          [
            service: :s3,
            access_key_id: config.access_key_id,
            secret_access_key: config.secret_access_key,
            region: config.region
          ]
          |> then(fn opts ->
            if config.session_token,
              do: Keyword.put(opts, :session_token, config.session_token),
              else: opts
          end)

        Keyword.put(base_opts, :aws_sigv4, sigv4_opts)
      else
        base_opts
      end

    merged_opts = Keyword.merge(base_opts, req_options)

    Req.new()
    |> ReqS3.attach()
    |> Req.request(merged_opts)
  end

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
