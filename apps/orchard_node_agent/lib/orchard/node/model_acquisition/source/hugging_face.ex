defmodule Orchard.Node.ModelAcquisition.Source.HuggingFace do
  @moduledoc """
  Source adapter for `hf://` URIs.

  Downloads MLX model bundles from HuggingFace Hub via REST API into
  the staging path. Supports resumable downloads within a single
  `materialize/1` call via `.partial` files and `Range` headers.

  ## URI Format

      hf://org/repo                  # revision defaults to "main"
      hf://org/repo?revision=v1.0    # explicit revision

  ## Algorithm

  1. Parse URI to extract repo ID and revision
  2. List repo tree via HF API (`/api/models/{repo}/tree/{revision}`)
  3. Filter to MLX model allowlist
  4. HEAD each file for size/ETag metadata
  5. Download files sequentially into staging path with retry/resume
  6. Orchestrator handles hash verification and finalization
  """

  @behaviour Orchard.Node.ModelAcquisition.SourceAdapter

  require Logger

  alias Orchard.Node
  alias Orchard.Node.ModelAcquisition.Request

  # File patterns to download for an MLX model bundle.
  @allowlist_extensions ~w(.json .safetensors .py .tiktoken .jinja .jinja2)
  @allowlist_basenames ~w(tokenizer.model merges.txt vocab.txt vocab.json special_tokens_map.json)

  # Backoff parameters for retries
  @initial_backoff_ms 250
  @max_backoff_ms 2_000

  # -- Public API ------------------------------------------------------------

  @impl true
  def materialize(%Request{} = request) do
    with {:ok, repo_spec} <- parse_hf_uri(request.artifact_source_uri),
         config = hf_config(),
         {:ok, file_entries} <- list_repo_tree(repo_spec, config),
         {:ok, retained} <- filter_and_validate(file_entries),
         {:ok, sanitized} <- sanitize_entry_paths(retained),
         {:ok, file_metas} <- preflight_head(sanitized, repo_spec, config),
         :ok <- download_all(file_metas, repo_spec, request, config) do
      :ok
    end
  end

  # -- URI Parsing -----------------------------------------------------------

  @doc false
  def parse_hf_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: "hf", host: host, path: path, query: query}
      when is_binary(host) and host != "" ->
        repo_id = build_repo_id(host, path)

        if repo_id == "" or not String.contains?(repo_id, "/") do
          {:error, :invalid_source_uri}
        else
          case parse_revision(query) do
            {:ok, revision} -> {:ok, %{repo_id: repo_id, revision: revision}}
            :error -> {:error, :invalid_source_uri}
          end
        end

      _ ->
        {:error, :invalid_source_uri}
    end
  end

  def parse_hf_uri(_), do: {:error, :invalid_source_uri}

  defp build_repo_id(host, nil), do: host
  defp build_repo_id(host, "/"), do: host

  defp build_repo_id(host, path) do
    host <> String.trim_trailing(path, "/")
  end

  defp parse_revision(nil), do: {:ok, "main"}
  defp parse_revision(""), do: {:ok, "main"}

  defp parse_revision(query) do
    params = URI.decode_query(query)
    known = MapSet.new(["revision"])
    unknown = params |> Map.keys() |> MapSet.new() |> MapSet.difference(known)

    if MapSet.size(unknown) > 0 do
      :error
    else
      revision = Map.get(params, "revision", "main")
      if revision == "", do: :error, else: {:ok, revision}
    end
  end

  # -- Repo Tree Listing -----------------------------------------------------

  # NOTE: HF tree endpoint may paginate for repos with 1000+ files.
  # Currently we assume a single response contains all entries, which is
  # sufficient for typical MLX model repos. If false `invalid_source_layout`
  # errors appear for large sharded repos, add cursor/Link-header pagination.
  defp list_repo_tree(%{repo_id: repo_id, revision: revision}, config) do
    api_base = Keyword.get(config, :api_base_url, "https://huggingface.co/api")
    encoded_revision = URI.encode(revision, &URI.char_unreserved?/1)
    url = "#{api_base}/models/#{repo_id}/tree/#{encoded_revision}"

    Logger.info("HF: listing repo tree for #{repo_id}@#{revision}")

    case hf_request(:get, url, config) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        entries =
          body
          |> Enum.filter(fn entry -> Map.get(entry, "type") == "file" end)
          |> Enum.map(fn entry ->
            %{
              path: Map.get(entry, "path", ""),
              size: get_file_size(entry),
              oid: Map.get(entry, "oid", "")
            }
          end)

        {:ok, entries}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, {:source_unauthorized, "HF API returned #{status} for #{repo_id}"}}

      {:ok, %{status: 404}} ->
        {:error, {:source_not_found, "HF repo not found: #{repo_id}@#{revision}"}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:source_unavailable, "HF API returned #{status}: #{inspect(body)}"}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:source_unavailable, "HF API transport error: #{inspect(reason)}"}}

      {:error, reason} ->
        {:error, {:source_unavailable, "HF API error: #{inspect(reason)}"}}
    end
  end

  # LFS files have their real size in the lfs sub-object
  defp get_file_size(%{"lfs" => %{"size" => size}}) when is_integer(size), do: size
  defp get_file_size(%{"size" => size}) when is_integer(size), do: size
  defp get_file_size(_), do: 0

  # -- Allowlist Filtering ---------------------------------------------------

  @doc false
  def filter_and_validate(entries) do
    retained =
      Enum.filter(entries, fn %{path: path} ->
        basename = Path.basename(path)
        ext = Path.extname(path)

        basename in @allowlist_basenames or ext in @allowlist_extensions
      end)

    has_weights =
      Enum.any?(retained, fn %{path: path} ->
        Path.extname(path) == ".safetensors"
      end)

    cond do
      retained == [] ->
        {:error, {:invalid_source_layout, "no MLX model files found in repository"}}

      not has_weights ->
        {:error,
         {:invalid_source_layout,
          "no .safetensors weight files found; GGUF format is not supported by MLX backend"}}

      true ->
        {:ok, retained}
    end
  end

  # -- Path Sanitization -----------------------------------------------------

  @doc false
  def sanitize_entry_paths(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn %{path: path} = entry, {:ok, acc} ->
      segments = Path.split(path)

      cond do
        Path.type(path) == :absolute ->
          {:halt,
           {:error,
            {:invalid_source_layout, "absolute path in repo tree entry: #{path}"}}}

        Enum.any?(segments, &(&1 in ["..", ".", ""])) ->
          {:halt,
           {:error,
            {:invalid_source_layout, "path traversal in repo tree entry: #{path}"}}}

        true ->
          {:cont, {:ok, [entry | acc]}}
      end
    end)
    |> case do
      {:ok, sanitized} -> {:ok, Enum.reverse(sanitized)}
      error -> error
    end
  end

  # -- Preflight HEAD --------------------------------------------------------

  defp preflight_head(retained, repo_spec, config) do
    base_url = Keyword.get(config, :base_url, "https://huggingface.co")
    retry_attempts = Keyword.get(config, :retry_attempts, 3)

    result =
      Enum.reduce_while(retained, {:ok, []}, fn entry, {:ok, acc} ->
        url = resolve_url(base_url, repo_spec, entry.path)

        case head_with_retry(url, config, retry_attempts) do
          {:ok, meta} ->
            file_meta = Map.merge(entry, meta)
            {:cont, {:ok, [file_meta | acc]}}

          {:error, _} = err ->
            {:halt, err}
        end
      end)

    case result do
      {:ok, metas} -> {:ok, Enum.reverse(metas)}
      error -> error
    end
  end

  defp head_with_retry(url, config, max_attempts) do
    do_head_retry(url, config, 1, max_attempts)
  end

  defp do_head_retry(url, config, attempt, max_attempts) do
    case hf_request(:head, url, config) do
      {:ok, %{status: 200} = resp} ->
        {:ok,
         %{
           content_length: get_content_length(resp.headers),
           etag: get_etag(resp.headers)
         }}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, {:source_unauthorized, "HF returned #{status} for HEAD #{url}"}}

      {:ok, %{status: 404}} ->
        {:error, {:source_not_found, "HF file not found: #{url}"}}

      {:ok, %{status: status}} when status in [429] and attempt < max_attempts ->
        backoff(attempt)
        do_head_retry(url, config, attempt + 1, max_attempts)

      {:ok, %{status: status}} when status >= 500 and attempt < max_attempts ->
        backoff(attempt)
        do_head_retry(url, config, attempt + 1, max_attempts)

      {:ok, %{status: status}} ->
        {:error, {:source_unavailable, "HF HEAD returned #{status}"}}

      {:error, _} when attempt < max_attempts ->
        backoff(attempt)
        do_head_retry(url, config, attempt + 1, max_attempts)

      {:error, reason} ->
        {:error, {:source_unavailable, "HF HEAD failed: #{inspect(reason)}"}}
    end
  end

  # Req 0.5 returns headers as %{"name" => ["value", ...]} maps
  defp get_content_length(headers) when is_map(headers) do
    find_header_int(headers, "content-length") ||
      find_header_int(headers, "x-linked-size")
  end

  defp find_header_int(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] ->
        case Integer.parse(value) do
          {n, _} -> n
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp get_etag(headers) when is_map(headers) do
    case Map.get(headers, "x-linked-etag") do
      [value | _] ->
        normalize_etag(value)

      _ ->
        case Map.get(headers, "etag") do
          [value | _] -> normalize_etag(value)
          _ -> nil
        end
    end
  end

  defp normalize_etag(etag) when is_binary(etag) do
    etag |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  # -- File Download ---------------------------------------------------------

  defp download_all(file_metas, repo_spec, request, config) do
    base_url = Keyword.get(config, :base_url, "https://huggingface.co")
    retry_attempts = Keyword.get(config, :retry_attempts, 3)
    total_files = length(file_metas)

    total_bytes =
      Enum.reduce(file_metas, 0, fn m, acc ->
        acc + (m[:content_length] || m.size || 0)
      end)

    progress = %{
      bytes_downloaded: 0,
      total_bytes: total_bytes,
      files_completed: 0,
      total_files: total_files
    }

    staging_root = Path.expand(request.staging_path)

    result =
      Enum.reduce_while(file_metas, {:ok, progress}, fn file_meta, {:ok, prog} ->
        url = resolve_url(base_url, repo_spec, file_meta.path)
        dest = Path.join(request.staging_path, file_meta.path)
        expanded_dest = Path.expand(dest)

        # Belt-and-suspenders containment check (sanitize_entry_paths is the primary guard)
        if String.starts_with?(expanded_dest, staging_root <> "/") do
          case download_file(url, dest, file_meta, request, config, retry_attempts, prog) do
            {:ok, updated_prog} ->
              {:cont, {:ok, updated_prog}}

            {:error, _} = err ->
              {:halt, err}
          end
        else
          {:halt,
           {:error,
            {:invalid_source_layout,
             "path escapes staging directory: #{file_meta.path}"}}}
        end
      end)

    case result do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp download_file(url, dest, file_meta, request, config, max_attempts, progress) do
    case File.mkdir_p(Path.dirname(dest)) do
      :ok ->
        do_download_retry(url, dest, file_meta, request, config, 1, max_attempts, progress)

      {:error, reason} ->
        {:error, {:filesystem_error, "mkdir_p #{Path.dirname(dest)}: #{inspect(reason)}"}}
    end
  end

  defp do_download_retry(url, dest, file_meta, request, config, attempt, max_attempts, progress) do
    partial_path = dest <> ".partial"
    etag_path = dest <> ".partial.etag"
    expected_size = file_meta[:content_length]
    remote_etag = file_meta[:etag]

    # Determine resume offset
    {offset, resume?} = compute_resume_offset(partial_path, etag_path, remote_etag)

    # Build request headers for Range resume
    extra_headers = if resume? and offset > 0, do: [{"range", "bytes=#{offset}-"}], else: []

    # Store ETag sidecar for resume on retry
    if remote_etag, do: File.write(etag_path, remote_etag)

    # Stream download to file using Req's `into: fun` callback
    bytes_counter = :counters.new(1, [:atomics])
    if resume? and offset > 0, do: :counters.put(bytes_counter, 1, offset)

    # Determine file open mode: append for resume, write for fresh start
    write_mode = if resume? and offset > 0, do: [:binary, :append], else: [:binary, :write]

    case File.open(partial_path, write_mode) do
      {:ok, file_pid} ->
        do_download_stream(
          url, dest, file_meta, request, config, attempt, max_attempts,
          progress, partial_path, etag_path, expected_size,
          offset, resume?, extra_headers, bytes_counter, file_pid
        )

      {:error, reason} ->
        {:error, {:filesystem_error, "open #{partial_path}: #{inspect(reason)}"}}
    end
  end

  defp do_download_stream(
         url, dest, file_meta, request, config, attempt, max_attempts,
         progress, partial_path, etag_path, expected_size,
         offset, resume?, extra_headers, bytes_counter, file_pid
       ) do
    into_fun = fn {:data, chunk}, {req, resp} ->
      IO.binwrite(file_pid, chunk)
      :counters.add(bytes_counter, 1, byte_size(chunk))
      {:cont, {req, resp}}
    end

    result = hf_request(:get, url, config, headers: extra_headers, into: into_fun)
    File.close(file_pid)
    bytes_written = :counters.get(bytes_counter, 1)

    case result do
      {:ok, %{status: 200}} when resume? and offset > 0 ->
        # Server ignored Range header and sent the full file, but we appended
        # it to the existing partial — the file is now corrupt.
        # Delete the partial and restart this attempt from scratch.
        File.rm(partial_path)
        File.rm(etag_path)

        if attempt < max_attempts do
          backoff(attempt)

          do_download_retry(
            url, dest, file_meta, request, config,
            attempt + 1, max_attempts, progress
          )
        else
          {:error,
           {:download_failed,
            "server ignored Range header for #{file_meta.path}, resume not supported"}}
        end

      {:ok, %{status: status}} when status in [200, 206] ->
        effective_size = bytes_written

        # Verify size if known
        if expected_size && effective_size != expected_size do
          if attempt < max_attempts do
            backoff(attempt)

            do_download_retry(
              url, dest, file_meta, request, config,
              attempt + 1, max_attempts, progress
            )
          else
            {:error,
             {:download_incomplete,
              "expected #{expected_size} bytes, got #{effective_size} for #{file_meta.path}"}}
          end
        else
          # Promote partial to final
          case File.rename(partial_path, dest) do
            :ok ->
              File.rm(etag_path)

              file_bytes = file_meta[:content_length] || file_meta.size || 0

              final_progress = %{
                progress
                | bytes_downloaded: progress.bytes_downloaded + file_bytes,
                  files_completed: progress.files_completed + 1
              }

              emit_progress(final_progress, request, file_meta.path)
              {:ok, final_progress}

            {:error, reason} ->
              {:error, {:filesystem_error, "rename #{partial_path}: #{inspect(reason)}"}}
          end
        end

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, {:source_unauthorized, "HF returned #{status} downloading #{file_meta.path}"}}

      {:ok, %{status: 404}} ->
        {:error, {:source_not_found, "HF file not found: #{file_meta.path}"}}

      {:ok, %{status: status}} when status in [429] and attempt < max_attempts ->
        backoff(attempt)

        do_download_retry(
          url, dest, file_meta, request, config,
          attempt + 1, max_attempts, progress
        )

      {:ok, %{status: status}} when status >= 500 and attempt < max_attempts ->
        backoff(attempt)

        do_download_retry(
          url, dest, file_meta, request, config,
          attempt + 1, max_attempts, progress
        )

      {:ok, %{status: status}} ->
        {:error, {:download_failed, "HF download returned #{status} for #{file_meta.path}"}}

      {:error, _} when attempt < max_attempts ->
        backoff(attempt)

        do_download_retry(
          url, dest, file_meta, request, config,
          attempt + 1, max_attempts, progress
        )

      {:error, reason} ->
        {:error,
         {:download_failed,
          "HF download failed for #{file_meta.path}: #{inspect(reason)}"}}
    end
  end

  defp compute_resume_offset(partial_path, etag_path, remote_etag) do
    if File.exists?(partial_path) do
      case {File.read(etag_path), remote_etag} do
        {{:ok, stored_etag}, etag} when stored_etag == etag and etag != nil ->
          # ETag matches — safe to resume
          case File.stat(partial_path) do
            {:ok, %{size: size}} -> {size, true}
            {:error, _} -> {0, false}
          end

        _ ->
          # ETag mismatch or unknown — restart
          File.rm(partial_path)
          File.rm(etag_path)
          {0, false}
      end
    else
      {0, false}
    end
  end

  # -- HTTP Helpers ----------------------------------------------------------

  defp hf_request(method, url, config, extra_opts \\ []) do
    token = Keyword.get(config, :token)
    connect_timeout = Keyword.get(config, :connect_timeout_ms, 10_000)
    receive_timeout = Keyword.get(config, :receive_timeout_ms, 30_000)
    req_options = Keyword.get(config, :req_options, [])

    auth_headers =
      if token, do: [{"authorization", "Bearer #{token}"}], else: []

    user_headers = Keyword.get(extra_opts, :headers, [])
    into = Keyword.get(extra_opts, :into)

    base_opts =
      [
        method: method,
        url: url,
        headers: auth_headers ++ user_headers,
        connect_options: [timeout: connect_timeout],
        receive_timeout: receive_timeout,
        retry: false
      ]
      |> then(fn opts -> if into, do: Keyword.put(opts, :into, into), else: opts end)

    merged_opts = Keyword.merge(base_opts, req_options)

    Req.request(merged_opts)
  end

  # -- Progress Telemetry ----------------------------------------------------

  defp emit_progress(progress, request, current_path) do
    :telemetry.execute(
      [:orchard, :node, :model_acquisition, :progress],
      %{
        bytes_downloaded: progress.bytes_downloaded,
        total_bytes: progress.total_bytes,
        files_completed: progress.files_completed,
        total_files: progress.total_files
      },
      %{
        model_id: request.model_id,
        version: request.version,
        source_scheme: "hf",
        path: current_path
      }
    )
  end

  # -- Utility ---------------------------------------------------------------

  defp resolve_url(base_url, %{repo_id: repo_id, revision: revision}, file_path) do
    encoded_revision = URI.encode(revision, &URI.char_unreserved?/1)

    encoded_path =
      file_path
      |> Path.split()
      |> Enum.map(fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)
      |> Enum.join("/")

    "#{base_url}/#{repo_id}/resolve/#{encoded_revision}/#{encoded_path}"
  end

  defp backoff(attempt) do
    delay = min(@initial_backoff_ms * Integer.pow(2, attempt - 1), @max_backoff_ms)
    Process.sleep(delay)
  end

  defp hf_config do
    Node.hf_config()
  end
end
