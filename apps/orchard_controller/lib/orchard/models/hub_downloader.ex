defmodule Orchard.Models.HubDownloader do
  @moduledoc """
  Controller-local HF model file downloader.

  Downloads MLX model bundles from HuggingFace Hub via REST API into a local
  directory. Mirrors the proven algorithm from the node-agent's `Source.HuggingFace`
  adapter but reads controller-side config (`:orchard_controller, :hf`) and reports
  progress via a callback instead of telemetry.

  ## Algorithm

  1. List repo tree via HF API (`/api/models/{repo}/tree/{revision}`)
  2. Filter to MLX model allowlist
  3. Sanitize paths (reject absolute, `..`, empty segments)
  4. HEAD preflight each file for content-length + ETag
  5. Download files sequentially with `.partial` + `.partial.etag` resume
  6. Emit progress callback after each file completion

  ## Options

  - `:revision` — HF revision (default: `"main"`)
  - `:progress_callback` — `(progress_update() -> any())`, called per file completion
  - `:hf_config` — keyword override merged over app env (primarily for tests)
  - `:req_options` — keyword list merged on top of config `:req_options`
  """

  require Logger

  alias Orchard.HuggingFace.DownloadSupport

  # File patterns to download for an MLX model bundle.
  @allowlist_extensions ~w(.json .safetensors .py .tiktoken .jinja .jinja2)
  @allowlist_basenames ~w(tokenizer.model merges.txt vocab.txt vocab.json special_tokens_map.json)

  # Backoff parameters for retries
  @initial_backoff_ms 250
  @max_backoff_ms 2_000

  @default_retry_attempts 3
  @default_connect_timeout_ms 10_000
  @default_receive_timeout_ms 30_000

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

  @type download_summary :: %{
          files_downloaded: non_neg_integer(),
          total_bytes: non_neg_integer(),
          revision: String.t()
        }

  @type progress_update :: %{
          files_completed: non_neg_integer(),
          total_files: non_neg_integer(),
          bytes_downloaded: non_neg_integer(),
          total_bytes: non_neg_integer(),
          current_file: String.t() | nil
        }

  @spec download(String.t(), String.t(), keyword()) ::
          {:ok, String.t(), download_summary()} | {:error, term()}
  def download(repo_id, dest_dir, opts \\ [])

  def download(repo_id, _dest_dir, _opts) when not is_binary(repo_id) do
    {:error, {:invalid_repo_id, "Model repository id is invalid."}}
  end

  def download(_repo_id, dest_dir, _opts) when not is_binary(dest_dir) do
    {:error, {:invalid_destination, "Destination path is invalid."}}
  end

  def download(_repo_id, _dest_dir, opts) when not is_list(opts) do
    {:error, {:invalid_options, "Hub downloader options are invalid."}}
  end

  def download(repo_id, dest_dir, opts) do
    with {:ok, repo_spec} <- normalize_repo_id(repo_id),
         {:ok, revision} <- validate_revision(opts),
         {:ok, callback} <- validate_callback(opts),
         config = resolve_config(opts),
         repo_spec = Map.put(repo_spec, :revision, revision),
         :ok <- ensure_dest_dir(dest_dir),
         {:ok, file_entries} <- list_repo_tree(repo_spec, config),
         {:ok, retained} <- filter_and_validate(file_entries),
         {:ok, sanitized} <- sanitize_entry_paths(retained),
         {:ok, file_metas} <- preflight_head(sanitized, repo_spec, config) do
      download_all(file_metas, repo_spec, dest_dir, config, callback)
    end
  end

  # -- Repo ID Normalization -------------------------------------------------

  defp normalize_repo_id(repo_id) do
    trimmed = String.trim(repo_id)
    segments = String.split(trimmed, "/", trim: true)

    with true <- trimmed != "",
         true <- length(segments) >= 2,
         true <- Enum.all?(segments, &valid_repo_segment?/1) do
      encoded =
        Enum.map_join(segments, "/", fn segment ->
          URI.encode(segment, &URI.char_unreserved?/1)
        end)

      {:ok, %{repo_id: trimmed, encoded_repo_id: encoded}}
    else
      _ -> {:error, {:invalid_repo_id, "Model repository id is invalid."}}
    end
  end

  defp valid_repo_segment?(segment) when is_binary(segment) do
    trimmed = String.trim(segment)
    trimmed != "" and trimmed not in [".", ".."]
  end

  # -- Option Validation -----------------------------------------------------

  defp validate_revision(opts) do
    case Keyword.get(opts, :revision, "main") do
      rev when is_binary(rev) and rev != "" -> {:ok, rev}
      nil -> {:ok, "main"}
      _ -> {:error, {:invalid_options, "Hub downloader options are invalid."}}
    end
  end

  defp validate_callback(opts) do
    case Keyword.get(opts, :progress_callback) do
      nil -> {:ok, nil}
      cb when is_function(cb, 1) -> {:ok, cb}
      _ -> {:error, {:invalid_options, "Hub downloader options are invalid."}}
    end
  end

  # -- Config Resolution -----------------------------------------------------

  defp resolve_config(opts) do
    base = Application.get_env(:orchard_controller, :hf, [])
    override = Keyword.get(opts, :hf_config, [])
    merged = Keyword.merge(base, override)

    # Merge req_options: base config, then hf_config override, then opts-level
    base_req_opts = merged |> Keyword.get(:req_options, []) |> sanitize_req_options()
    extra_req_opts = opts |> Keyword.get(:req_options, []) |> sanitize_req_options()
    final_req_opts = Keyword.merge(base_req_opts, extra_req_opts)

    Keyword.put(merged, :req_options, final_req_opts)
  end

  defp sanitize_req_options(req_options) when is_list(req_options) do
    Enum.reject(req_options, fn
      {key, _value} -> key in @reserved_req_option_keys
      _other -> false
    end)
  end

  defp sanitize_req_options(_), do: []

  # -- Destination Setup -----------------------------------------------------

  defp ensure_dest_dir(dest_dir) do
    case File.mkdir_p(dest_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:filesystem_error, "mkdir_p #{dest_dir}: #{inspect(reason)}"}}
    end
  end

  # -- Repo Tree Listing -----------------------------------------------------

  defp list_repo_tree(%{encoded_repo_id: encoded_repo_id, revision: revision}, config) do
    api_base = Keyword.get(config, :api_base_url, "https://huggingface.co/api")
    max_attempts = max(Keyword.get(config, :retry_attempts, @default_retry_attempts), 1)
    encoded_revision = URI.encode(revision, &URI.char_unreserved?/1)
    url = "#{api_base}/models/#{encoded_repo_id}/tree/#{encoded_revision}"

    Logger.info("HubDownloader: listing repo tree for #{encoded_repo_id}@#{revision}")

    do_list_repo_tree(url, config, 1, max_attempts)
  end

  defp do_list_repo_tree(url, config, attempt, max_attempts) do
    case hf_request(:get, url, config) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, list_tree_entries(body)}

      {:ok, %{status: status}} ->
        maybe_retry_tree_status(url, config, attempt, max_attempts, status)

      {:error, reason} ->
        maybe_retry_tree_error(url, config, attempt, max_attempts, reason)
    end
  end

  defp list_tree_entries(body) do
    body
    |> Enum.filter(fn entry -> Map.get(entry, "type") == "file" end)
    |> Enum.map(fn entry ->
      %{
        path: Map.get(entry, "path", ""),
        size: get_file_size(entry),
        oid: Map.get(entry, "oid", "")
      }
    end)
  end

  defp maybe_retry_tree_status(url, config, attempt, max_attempts, status)
       when status == 429 or status >= 500 do
    if attempt < max_attempts do
      backoff(attempt)
      do_list_repo_tree(url, config, attempt + 1, max_attempts)
    else
      terminal_tree_status(status)
    end
  end

  defp maybe_retry_tree_status(_url, _config, _attempt, _max_attempts, status)
       when status in [401, 403] do
    {:error, {:unauthorized, "Hugging Face access denied."}}
  end

  defp maybe_retry_tree_status(_url, _config, _attempt, _max_attempts, 404) do
    {:error, {:not_found, "Hugging Face resource not found."}}
  end

  defp maybe_retry_tree_status(_url, _config, _attempt, _max_attempts, _status) do
    {:error, {:unavailable, "Hugging Face is unavailable."}}
  end

  defp maybe_retry_tree_error(url, config, attempt, max_attempts, _reason) when attempt < max_attempts do
    backoff(attempt)
    do_list_repo_tree(url, config, attempt + 1, max_attempts)
  end

  defp maybe_retry_tree_error(_url, _config, _attempt, _max_attempts, _reason) do
    {:error, {:unavailable, "Hugging Face is unavailable."}}
  end

  defp terminal_tree_status(429), do: {:error, {:rate_limited, "Hugging Face rate limit exceeded."}}
  defp terminal_tree_status(status) when status >= 500, do: {:error, {:unavailable, "Hugging Face is unavailable."}}

  defp get_file_size(%{"lfs" => %{"size" => size}}) when is_integer(size), do: size
  defp get_file_size(%{"size" => size}) when is_integer(size), do: size
  defp get_file_size(_), do: 0

  # -- Allowlist Filtering ---------------------------------------------------

  defp filter_and_validate(entries) do
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

  defp sanitize_entry_paths(entries), do: DownloadSupport.sanitize_entry_paths(entries)

  # -- Preflight HEAD --------------------------------------------------------

  defp preflight_head(retained, repo_spec, config) do
    base_url = Keyword.get(config, :base_url, "https://huggingface.co")
    max_attempts = max(Keyword.get(config, :retry_attempts, @default_retry_attempts), 1)

    result =
      Enum.reduce_while(retained, {:ok, []}, fn entry, {:ok, acc} ->
        url = resolve_file_url(base_url, repo_spec, entry.path)

        case head_with_retry(url, config, 1, max_attempts) do
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

  defp head_with_retry(url, config, attempt, max_attempts) do
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
      head_with_retry(url, config, attempt + 1, max_attempts)
    else
      terminal_head_status(status)
    end
  end

  defp maybe_retry_head_status(_url, _config, _attempt, _max_attempts, status)
       when status in [401, 403] do
    {:error, {:unauthorized, "Hugging Face access denied."}}
  end

  defp maybe_retry_head_status(_url, _config, _attempt, _max_attempts, 404) do
    {:error, {:not_found, "Hugging Face file not found."}}
  end

  defp maybe_retry_head_status(_url, _config, _attempt, _max_attempts, _status) do
    {:error, {:unavailable, "Hugging Face is unavailable."}}
  end

  defp maybe_retry_head_error(url, config, attempt, max_attempts, _reason) when attempt < max_attempts do
    backoff(attempt)
    head_with_retry(url, config, attempt + 1, max_attempts)
  end

  defp maybe_retry_head_error(_url, _config, _attempt, _max_attempts, _reason) do
    {:error, {:unavailable, "Hugging Face is unavailable."}}
  end

  defp terminal_head_status(429), do: {:error, {:rate_limited, "Hugging Face rate limit exceeded."}}
  defp terminal_head_status(status) when status >= 500, do: {:error, {:unavailable, "Hugging Face is unavailable."}}

  defp get_content_length(resp) do
    header_int(resp, "content-length") || header_int(resp, "x-linked-size")
  end

  defp get_etag(resp) do
    case header_values(resp, "x-linked-etag") do
      [value | _] -> normalize_etag(value)
      [] -> header_values(resp, "etag") |> List.first() |> normalize_etag()
    end
  end

  defp header_int(resp, name) do
    case header_values(resp, name) do
      [value | _] ->
        case Integer.parse(value) do
          {n, _} -> n
          _ -> nil
        end

      [] ->
        nil
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

  defp normalize_etag(nil), do: nil

  defp normalize_etag(etag) when is_binary(etag) do
    etag |> String.trim_leading("\"") |> String.trim_trailing("\"")
  end

  # -- File Download ---------------------------------------------------------

  defp download_all(file_metas, repo_spec, dest_dir, config, callback) do
    opts = [
      base_url: Keyword.get(config, :base_url, "https://huggingface.co"),
      repo_spec: repo_spec,
      dest_root: dest_dir,
      root_label: "destination",
      request_fun:
        fn method, url, extra_opts ->
          hf_request(method, url, config, extra_opts)
        end,
      max_attempts: max(Keyword.get(config, :retry_attempts, @default_retry_attempts), 1),
      progress_fun:
        fn progress, current_file ->
          emit_progress(callback, progress, current_file)
        end,
      emit_initial_progress?: true
    ]

    case DownloadSupport.download_all(file_metas, opts) do
      {:ok, progress} ->
        {:ok, dest_dir,
         %{
           files_downloaded: progress.files_completed,
           total_bytes: progress.total_bytes,
           revision: repo_spec.revision
         }}

      {:error, reason} ->
        map_download_error(reason)
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
     {:download_incomplete,
      "expected #{expected_size} bytes, got #{actual_size} for #{path}"}}
  end

  defp map_download_error({:http_status, status, _path}) when status in [401, 403] do
    {:error, {:unauthorized, "Hugging Face access denied."}}
  end

  defp map_download_error({:http_status, 404, path}) do
    {:error, {:not_found, "Hugging Face file not found: #{path}"}}
  end

  defp map_download_error({:http_status, 429, _path}) do
    {:error, {:rate_limited, "Hugging Face rate limit exceeded."}}
  end

  defp map_download_error({:http_status, status, _path}) when status >= 500 do
    {:error, {:unavailable, "Hugging Face is unavailable."}}
  end

  defp map_download_error({:http_status, status, path}) do
    {:error, {:download_failed, "HF download returned #{status} for #{path}"}}
  end

  defp map_download_error({:request_failed, path, _reason}) do
    {:error, {:download_failed, "HF download failed for #{path}"}}
  end

  defp map_download_error({:callback_failed, _} = error), do: {:error, error}
  defp map_download_error({:error, _} = error), do: error

  # -- Progress --------------------------------------------------------------

  defp emit_progress(nil, _progress, _current_file), do: :ok

  defp emit_progress(callback, progress, current_file) do
    update = %{
      files_completed: progress.files_completed,
      total_files: progress.total_files,
      bytes_downloaded: progress.bytes_downloaded,
      total_bytes: progress.total_bytes,
      current_file: current_file
    }

    try do
      callback.(update)
      :ok
    rescue
      _ -> {:error, {:callback_failed, "progress callback failed"}}
    catch
      _, _ -> {:error, {:callback_failed, "progress callback failed"}}
    end
  end

  # -- HTTP Helpers ----------------------------------------------------------

  defp hf_request(method, url, config, extra_opts \\ []) do
    token = Keyword.get(config, :token)
    connect_timeout = Keyword.get(config, :connect_timeout_ms, @default_connect_timeout_ms)
    receive_timeout = Keyword.get(config, :receive_timeout_ms, @default_receive_timeout_ms)
    req_options = Keyword.get(config, :req_options, [])

    auth? = Keyword.get(extra_opts, :auth?, true)
    follow_redirects? = Keyword.get(extra_opts, :follow_redirects?, true)

    auth_headers =
      if auth? and token && token != "",
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

  # -- URL Helpers -----------------------------------------------------------

  defp resolve_file_url(base_url, repo_spec, file_path) do
    repo_id = Map.get(repo_spec, :encoded_repo_id, Map.get(repo_spec, :repo_id, ""))
    revision = Map.get(repo_spec, :revision, "main")
    encoded_revision = URI.encode(revision, &URI.char_unreserved?/1)

    encoded_path =
      file_path
      |> Path.split()
      |> Enum.map_join("/", fn seg -> URI.encode(seg, &URI.char_unreserved?/1) end)

    "#{base_url}/#{repo_id}/resolve/#{encoded_revision}/#{encoded_path}"
  end

  defp backoff(attempt) do
    delay = min(@initial_backoff_ms * Integer.pow(2, max(attempt - 1, 0)), @max_backoff_ms)
    Process.sleep(delay)
  end
end
