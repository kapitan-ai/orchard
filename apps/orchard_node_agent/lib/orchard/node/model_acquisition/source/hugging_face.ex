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

  alias Orchard.HuggingFace.DownloadSupport
  alias Orchard.Node
  alias Orchard.Node.ModelAcquisition.Request

  # File patterns to download for an MLX model bundle.
  @allowlist_extensions ~w(.json .safetensors .py .tiktoken .jinja .jinja2)
  @allowlist_basenames ~w(tokenizer.model merges.txt vocab.txt vocab.json special_tokens_map.json)

  # -- Public API ------------------------------------------------------------

  @impl true
  def materialize(%Request{} = request) do
    with {:ok, repo_spec} <- parse_hf_uri(request.artifact_source_uri),
         config = hf_config(),
         {:ok, file_entries} <- list_repo_tree(repo_spec, config),
         {:ok, retained} <- filter_and_validate(file_entries),
         {:ok, sanitized} <- sanitize_entry_paths(retained),
         {:ok, file_metas} <- preflight_head(sanitized, repo_spec, config) do
      download_all(file_metas, repo_spec, request, config)
    end
  end

  # -- URI Parsing -----------------------------------------------------------

  @doc "Parses an `hf://org/repo` URI into its components."
  def parse_hf_uri(uri) when is_binary(uri) do
    with %URI{scheme: "hf", host: host, path: path, query: query}
         when is_binary(host) and host != "" <- URI.parse(uri),
         repo_id when repo_id != "" <- build_repo_id(host, path),
         true <- String.contains?(repo_id, "/"),
         {:ok, revision} <- parse_revision(query) do
      {:ok, %{repo_id: repo_id, revision: revision}}
    else
      _ -> {:error, :invalid_source_uri}
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

    if Enum.all?(Map.keys(params), &(&1 == "revision")) do
      revision = Map.get(params, "revision", "main")
      if revision == "", do: :error, else: {:ok, revision}
    else
      :error
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

  @doc "Filters manifest entries to model-relevant files and validates paths."
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

  @doc "Strips leading directory prefixes from entry paths for flat bundle layout."
  def sanitize_entry_paths(entries), do: DownloadSupport.sanitize_entry_paths(entries)

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
           content_length: get_content_length(resp),
           etag: get_etag(resp)
         }}

      {:ok, %{status: status}} ->
        maybe_retry_head_status(url, config, attempt, max_attempts, status)

      {:error, reason} ->
        maybe_retry_head_error(url, config, attempt, max_attempts, reason)
    end
  end

  defp maybe_retry_head_status(url, config, attempt, max_attempts, status)
       when status == 429 or status >= 500 do
    if attempt < max_attempts do
      backoff(attempt)
      do_head_retry(url, config, attempt + 1, max_attempts)
    else
      {:error, {:source_unavailable, "HF HEAD returned #{status}"}}
    end
  end

  defp maybe_retry_head_status(url, _config, _attempt, _max_attempts, status)
       when status in [401, 403] do
    {:error, {:source_unauthorized, "HF returned #{status} for HEAD #{url}"}}
  end

  defp maybe_retry_head_status(url, _config, _attempt, _max_attempts, 404) do
    {:error, {:source_not_found, "HF file not found: #{url}"}}
  end

  defp maybe_retry_head_status(_url, _config, _attempt, _max_attempts, status) do
    {:error, {:source_unavailable, "HF HEAD returned #{status}"}}
  end

  defp maybe_retry_head_error(url, config, attempt, max_attempts, _reason)
       when attempt < max_attempts do
    backoff(attempt)
    do_head_retry(url, config, attempt + 1, max_attempts)
  end

  defp maybe_retry_head_error(_url, _config, _attempt, _max_attempts, reason) do
    {:error, {:source_unavailable, "HF HEAD failed: #{inspect(reason)}"}}
  end

  defp get_content_length(resp) do
    header_int(resp, "content-length") || header_int(resp, "x-linked-size")
  end

  defp header_int(resp, name) do
    case header_values(resp, name) do
      [value | _rest] ->
        case Integer.parse(value) do
          {n, _} -> n
          _ -> nil
        end

      [] ->
        nil
    end
  end

  defp get_etag(resp) do
    case header_values(resp, "x-linked-etag") do
      [value | _rest] -> normalize_etag(value)
      [] -> header_values(resp, "etag") |> List.first() |> normalize_etag()
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

  defp normalize_etag(etag) when is_binary(etag) do
    etag |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  # -- File Download ---------------------------------------------------------

  defp download_all(file_metas, repo_spec, request, config) do
    opts = [
      base_url: Keyword.get(config, :base_url, "https://huggingface.co"),
      repo_spec: repo_spec,
      dest_root: request.staging_path,
      root_label: "staging",
      request_fun: fn method, url, extra_opts -> hf_request(method, url, config, extra_opts) end,
      max_attempts: max(Keyword.get(config, :retry_attempts, 3), 1),
      progress_fun: fn progress, current_file ->
        emit_progress(progress, request, current_file)
      end
    ]

    case DownloadSupport.download_all(file_metas, opts) do
      {:ok, _progress} -> :ok
      {:error, reason} -> map_download_error(reason)
    end
  end

  defp map_download_error({:path_escape, path, root_label}) do
    {:error, {:invalid_source_layout, "path escapes #{root_label} directory: #{path}"}}
  end

  defp map_download_error({:filesystem_error, action, path, reason}) do
    {:error, {:filesystem_error, "#{action} #{path}: #{inspect(reason)}"}}
  end

  defp map_download_error({:range_resume_not_supported, path}) do
    {:error, {:download_failed, "server ignored Range header for #{path}, resume not supported"}}
  end

  defp map_download_error({:redirect_resolution_failed, reason}) do
    {:error, {:download_failed, "redirect resolution failed: #{reason}"}}
  end

  defp map_download_error({:download_incomplete, path, expected_size, actual_size}) do
    {:error,
     {:download_incomplete, "expected #{expected_size} bytes, got #{actual_size} for #{path}"}}
  end

  defp map_download_error({:http_status, status, path}) when status in [401, 403] do
    {:error, {:source_unauthorized, "HF returned #{status} downloading #{path}"}}
  end

  defp map_download_error({:http_status, 404, path}) do
    {:error, {:source_not_found, "HF file not found: #{path}"}}
  end

  defp map_download_error({:http_status, status, path}) do
    {:error, {:download_failed, "HF download returned #{status} for #{path}"}}
  end

  defp map_download_error({:request_failed, path, reason}) do
    {:error, {:download_failed, "HF download failed for #{path}: #{inspect(reason)}"}}
  end

  # -- HTTP Helpers ----------------------------------------------------------

  defp hf_request(method, url, config, extra_opts \\ []) do
    token = Keyword.get(config, :token)
    connect_timeout = Keyword.get(config, :connect_timeout_ms, 10_000)
    receive_timeout = Keyword.get(config, :receive_timeout_ms, 30_000)

    req_options =
      config
      |> Keyword.get(:req_options, [])
      |> sanitize_req_options()

    auth? = Keyword.get(extra_opts, :auth?, true)
    follow_redirects? = Keyword.get(extra_opts, :follow_redirects?, true)

    auth_headers =
      if auth? and token,
        do: [{"authorization", "Bearer #{token}"}],
        else: []

    user_headers = Keyword.get(extra_opts, :headers, [])
    into = Keyword.get(extra_opts, :into)

    base_opts =
      [
        method: method,
        url: url,
        headers: auth_headers ++ user_headers,
        connect_options: [timeout: connect_timeout],
        receive_timeout: receive_timeout,
        retry: false,
        redirect: follow_redirects?
      ]
      |> then(fn opts -> if into, do: Keyword.put(opts, :into, into), else: opts end)

    merged_opts = Keyword.merge(base_opts, req_options)

    Req.request(merged_opts)
  end

  @reserved_req_option_keys [
    :method,
    :url,
    :headers,
    :params,
    :retry,
    :receive_timeout,
    :connect_options,
    :body,
    :json,
    :into,
    :redirect
  ]

  defp sanitize_req_options(req_options) when is_list(req_options) do
    Enum.reject(req_options, fn
      {key, _value} -> key in @reserved_req_option_keys
      _other -> false
    end)
  end

  defp sanitize_req_options(_), do: []

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

    :ok
  end

  # -- Utility ---------------------------------------------------------------

  defp resolve_url(base_url, %{repo_id: repo_id, revision: revision}, file_path) do
    encoded_revision = URI.encode(revision, &URI.char_unreserved?/1)

    encoded_path =
      file_path
      |> Path.split()
      |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)

    "#{base_url}/#{repo_id}/resolve/#{encoded_revision}/#{encoded_path}"
  end

  defp backoff(attempt) do
    Process.sleep(min(250 * Integer.pow(2, attempt - 1), 2_000))
  end

  defp hf_config do
    Node.hf_config()
  end
end
