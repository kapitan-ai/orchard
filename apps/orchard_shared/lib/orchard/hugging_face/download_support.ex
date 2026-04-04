defmodule Orchard.HuggingFace.DownloadSupport do
  @moduledoc false

  alias Orchard.PathUtils

  @initial_backoff_ms 250
  @max_backoff_ms 2_000
  @max_redirect_hops 5
  @redirect_statuses [301, 302, 303, 307, 308]
  @stream_progress_threshold_bytes 10 * 1_048_576

  @type progress :: %{
          bytes_downloaded: non_neg_integer(),
          total_bytes: non_neg_integer(),
          files_completed: non_neg_integer(),
          total_files: non_neg_integer()
        }

  @type repo_spec :: %{optional(atom()) => term()}
  @type file_meta :: %{required(:path) => String.t(), optional(atom()) => term()}
  @type request_fun :: (atom(), String.t(), keyword() -> {:ok, map()} | {:error, term()})
  @type progress_fun :: (progress(), String.t() | nil -> :ok | {:error, term()})

  @type download_error ::
          {:path_escape, String.t(), String.t()}
          | {:filesystem_error, atom(), String.t(), term()}
          | {:range_resume_not_supported, String.t()}
          | {:download_incomplete, String.t(), non_neg_integer(), non_neg_integer()}
          | {:http_status, non_neg_integer(), String.t()}
          | {:request_failed, String.t(), term()}
          | {:callback_failed, term()}

  @type download_opts :: [
          base_url: String.t(),
          repo_spec: repo_spec(),
          dest_root: String.t(),
          root_label: String.t(),
          request_fun: request_fun(),
          max_attempts: pos_integer(),
          progress_fun: progress_fun() | nil,
          emit_initial_progress?: boolean()
        ]

  @spec sanitize_entry_paths([map()]) ::
          {:ok, [map()]} | {:error, {:invalid_source_layout, String.t()}}
  def sanitize_entry_paths(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn %{path: path} = entry, {:ok, acc} ->
      segments = Path.split(path)

      cond do
        Path.type(path) == :absolute ->
          {:halt, {:error, {:invalid_source_layout, "absolute path in repo tree entry: #{path}"}}}

        Enum.any?(segments, &(&1 in ["..", ".", ""])) ->
          {:halt,
           {:error, {:invalid_source_layout, "path traversal in repo tree entry: #{path}"}}}

        true ->
          {:cont, {:ok, [entry | acc]}}
      end
    end)
    |> case do
      {:ok, sanitized} -> {:ok, Enum.reverse(sanitized)}
      error -> error
    end
  end

  @spec download_all([file_meta()], download_opts()) :: {:ok, progress()} | {:error, term()}
  def download_all(file_metas, opts) do
    with {:ok, context} <- build_context(file_metas, opts),
         :ok <- maybe_emit_initial_progress(context) do
      download_each(context)
    end
  end

  defp build_context(file_metas, opts) do
    total_files = length(file_metas)

    total_bytes =
      Enum.reduce(file_metas, 0, fn meta, acc ->
        acc + (meta[:content_length] || meta.size || 0)
      end)

    dest_root = Path.expand(Keyword.fetch!(opts, :dest_root))

    with {:ok, real_dest_root} <- resolve_dest_root(dest_root) do
      {:ok,
       %{
         file_metas: file_metas,
         base_url: Keyword.fetch!(opts, :base_url),
         repo_spec: Keyword.fetch!(opts, :repo_spec),
         dest_root: dest_root,
         real_dest_root: real_dest_root,
         root_label: Keyword.fetch!(opts, :root_label),
         request_fun: Keyword.fetch!(opts, :request_fun),
         max_attempts: max(Keyword.fetch!(opts, :max_attempts), 1),
         progress_fun: Keyword.get(opts, :progress_fun),
         emit_initial_progress?: Keyword.get(opts, :emit_initial_progress?, false),
         stream_high_water: :counters.new(1, [:atomics]),
         progress: %{
           bytes_downloaded: 0,
           total_bytes: total_bytes,
           files_completed: 0,
           total_files: total_files
         }
       }}
    end
  end

  defp maybe_emit_initial_progress(%{emit_initial_progress?: true} = context) do
    emit_progress(context.progress_fun, context.progress, nil)
  end

  defp maybe_emit_initial_progress(_context), do: :ok

  defp download_each(context) do
    Enum.reduce_while(context.file_metas, {:ok, context.progress}, fn file_meta,
                                                                      {:ok, progress} ->
      case download_entry(context, file_meta, progress) do
        {:ok, updated_progress} -> {:cont, {:ok, updated_progress}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp download_entry(context, file_meta, progress) do
    download_with_retry(context, file_meta, progress, 1)
  end

  defp download_with_retry(context, file_meta, progress, attempt) do
    with {:ok, paths} <- prepare_destination(context, file_meta),
         {:ok, state} <- build_download_state(context, file_meta, paths, progress, attempt) do
      open_partial_file(state)
    end
  end

  defp build_download_state(context, file_meta, paths, progress, attempt) do
    remote_etag = file_meta[:etag]

    with :ok <- ensure_download_slots_safe(paths, file_meta.path, context.root_label),
         {:ok, {offset, resume?}} <-
           compute_resume_offset(
             paths.partial_path,
             paths.etag_path,
             remote_etag,
             file_meta.path,
             context.root_label
           ) do
      bytes_counter = init_bytes_counter(offset, resume?)
      request_url = resolve_url(context.base_url, context.repo_spec, file_meta.path)

      {:ok,
       %{
         context: context,
         file_meta: file_meta,
         dest: paths.dest,
         partial_path: paths.partial_path,
         etag_path: paths.etag_path,
         expected_size: file_meta[:content_length],
         progress: progress,
         attempt: attempt,
         offset: offset,
         resume?: resume?,
         remote_etag: remote_etag,
         extra_headers: range_headers(resume?, offset),
         bytes_counter: bytes_counter,
         request_url: request_url,
         stream_target: nil
       }}
    end
  end

  defp resolve_dest_root(dest_root) do
    case PathUtils.resolve_realpath(dest_root) do
      {:ok, real_dest_root} -> {:ok, real_dest_root}
      {:error, reason} -> {:error, {:filesystem_error, :realpath, dest_root, reason}}
    end
  end

  defp prepare_destination(context, file_meta) do
    with {:ok, parent_dir} <-
           ensure_destination_parent(context.real_dest_root, file_meta.path, context.root_label),
         dest = Path.join(parent_dir, Path.basename(file_meta.path)),
         paths = %{
           dest: dest,
           partial_path: dest <> ".partial",
           etag_path: dest <> ".partial.etag"
         },
         :ok <- ensure_download_slots_safe(paths, file_meta.path, context.root_label) do
      {:ok, paths}
    end
  end

  defp ensure_destination_parent(real_dest_root, repo_path, root_label) do
    repo_path
    |> Path.dirname()
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.reduce_while({:ok, real_dest_root}, fn segment, {:ok, current_dir} ->
      case ensure_directory_component(current_dir, segment, repo_path, root_label) do
        {:ok, next_dir} -> {:cont, {:ok, next_dir}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_directory_component(current_dir, segment, repo_path, root_label) do
    next_dir = Path.join(current_dir, segment)

    case File.lstat(next_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, next_dir}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:path_escape, repo_path, root_label}}

      {:ok, _stat} ->
        {:error, {:filesystem_error, :mkdir, next_dir, :enotdir}}

      {:error, :enoent} ->
        case File.mkdir(next_dir) do
          :ok ->
            {:ok, next_dir}

          {:error, :eexist} ->
            ensure_directory_component(current_dir, segment, repo_path, root_label)

          {:error, reason} ->
            {:error, {:filesystem_error, :mkdir, next_dir, reason}}
        end

      {:error, reason} ->
        {:error, {:filesystem_error, :lstat, next_dir, reason}}
    end
  end

  defp ensure_download_slots_safe(paths, repo_path, root_label) do
    Enum.reduce_while([paths.dest, paths.partial_path, paths.etag_path], :ok, fn path, :ok ->
      case ensure_not_symlink(path, repo_path, root_label) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_not_symlink(path, repo_path, root_label) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:path_escape, repo_path, root_label}}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:filesystem_error, :lstat, path, reason}}
    end
  end

  defp init_bytes_counter(offset, resume?) do
    counter = :counters.new(1, [:atomics])
    if resume? and offset > 0, do: :counters.put(counter, 1, offset)
    counter
  end

  defp open_partial_file(state) do
    with :ok <- ensure_download_slots_safe(state, state.file_meta.path, state.context.root_label),
         :ok <- maybe_write_remote_etag(state),
         {:ok, stream_target} <- resolve_stream_target(state) do
      case File.open(state.partial_path, [:binary | write_mode(state)]) do
        {:ok, file_pid} -> stream_download(%{state | stream_target: stream_target}, file_pid)
        {:error, reason} -> {:error, {:filesystem_error, :open, state.partial_path, reason}}
      end
    end
  end

  defp maybe_write_remote_etag(%{remote_etag: nil}), do: :ok

  defp maybe_write_remote_etag(%{etag_path: etag_path, remote_etag: remote_etag}) do
    case File.write(etag_path, remote_etag) do
      :ok -> :ok
      {:error, reason} -> {:error, {:filesystem_error, :write, etag_path, reason}}
    end
  end

  defp write_mode(%{resume?: true, offset: offset}) when offset > 0, do: [:append]
  defp write_mode(_state), do: [:write]

  defp stream_download(state, file_pid) do
    write_error = :atomics.new(1, [])
    callback_error = :atomics.new(1, [])
    callback_error_key = make_ref()
    last_emitted = :counters.new(1, [:atomics])
    :counters.put(last_emitted, 1, state.progress.bytes_downloaded)

    stream_ctx = %{
      progress_fun: state.context.progress_fun,
      base_progress: state.progress,
      file_meta: state.file_meta,
      resume?: state.resume?,
      callback_error: callback_error,
      callback_error_key: callback_error_key,
      last_emitted: last_emitted,
      high_water: state.context.stream_high_water
    }

    result = request_get(state, download_into(file_pid, state.bytes_counter, write_error, stream_ctx))
    File.close(file_pid)
    bytes_written = :counters.get(state.bytes_counter, 1)

    callback_failed = :atomics.get(callback_error, 1) == 1
    callback_reason = if callback_failed, do: Process.delete(callback_error_key)

    finalize_stream(
      state,
      result,
      bytes_written,
      :atomics.get(write_error, 1) == 1,
      {callback_failed, callback_reason}
    )
  end

  defp download_into(file_pid, bytes_counter, write_error, stream_ctx) do
    fn {:data, chunk}, {req, resp} ->
      case :file.write(file_pid, chunk) do
        :ok ->
          :counters.add(bytes_counter, 1, byte_size(chunk))

          case maybe_emit_streaming_progress(stream_ctx, bytes_counter, resp) do
            :ok ->
              {:cont, {req, resp}}

            {:error, reason} ->
              :atomics.put(stream_ctx.callback_error, 1, 1)
              Process.put(stream_ctx.callback_error_key, reason)
              {:halt, {req, resp}}
          end

        {:error, _reason} ->
          :atomics.put(write_error, 1, 1)
          {:halt, {req, resp}}
      end
    end
  end

  defp maybe_emit_streaming_progress(%{progress_fun: nil}, _bytes_counter, _resp), do: :ok

  defp maybe_emit_streaming_progress(%{resume?: true}, _bytes_counter, %{status: 200}), do: :ok

  defp maybe_emit_streaming_progress(stream_ctx, bytes_counter, _resp) do
    current_file_bytes = :counters.get(bytes_counter, 1)
    absolute_bytes = stream_ctx.base_progress.bytes_downloaded + current_file_bytes
    last = :counters.get(stream_ctx.last_emitted, 1)
    high_water = :counters.get(stream_ctx.high_water, 1)

    if absolute_bytes - last >= @stream_progress_threshold_bytes and absolute_bytes > high_water do
      :counters.put(stream_ctx.last_emitted, 1, absolute_bytes)
      :counters.put(stream_ctx.high_water, 1, absolute_bytes)

      progress = %{
        bytes_downloaded: absolute_bytes,
        total_bytes: stream_ctx.base_progress.total_bytes,
        files_completed: stream_ctx.base_progress.files_completed,
        total_files: stream_ctx.base_progress.total_files
      }

      emit_progress(stream_ctx.progress_fun, progress, stream_ctx.file_meta.path)
    else
      :ok
    end
  end

  defp finalize_stream(state, _result, _bytes_written, true, _callback_result) do
    {:error, {:filesystem_error, :write, state.partial_path, :disk_write_failed}}
  end

  defp finalize_stream(_state, _result, _bytes_written, false, {true, reason}) do
    {:error, {:callback_failed, reason}}
  end

  defp finalize_stream(%{resume?: true} = state, {:ok, %{status: 200}}, bytes_written, false, {false, _})
       when bytes_written > 0 do
    restart_without_resume(state)
  end

  defp finalize_stream(state, {:ok, %{status: status}}, bytes_written, false, {false, _})
       when status in [200, 206] do
    finish_success(state, bytes_written)
  end

  defp finalize_stream(state, {:ok, %{status: status}}, _bytes_written, false, {false, _}) do
    handle_http_error(state, status)
  end

  defp finalize_stream(state, {:error, reason}, _bytes_written, false, {false, _}) do
    handle_request_error(state, reason)
  end

  defp request_get(state, into_fun) do
    %{url: stream_url, auth?: auth?} = state.stream_target

    state.context.request_fun.(:get, stream_url,
      headers: state.extra_headers,
      into: into_fun,
      follow_redirects?: false,
      auth?: auth?
    )
  end

  defp restart_without_resume(state) do
    File.rm(state.partial_path)
    File.rm(state.etag_path)

    if state.attempt < state.context.max_attempts do
      backoff(state.attempt)
      retry_download(state)
    else
      {:error, {:range_resume_not_supported, state.file_meta.path}}
    end
  end

  defp finish_success(state, bytes_written) do
    if size_mismatch?(state, bytes_written) do
      retry_or_incomplete(state, bytes_written)
    else
      promote_partial(state)
    end
  end

  defp size_mismatch?(%{expected_size: nil}, _bytes_written), do: false

  defp size_mismatch?(%{expected_size: expected_size}, bytes_written),
    do: bytes_written != expected_size

  defp retry_or_incomplete(state, bytes_written) do
    if state.attempt < state.context.max_attempts do
      backoff(state.attempt)
      retry_download(state)
    else
      {:error, {:download_incomplete, state.file_meta.path, state.expected_size, bytes_written}}
    end
  end

  defp retry_download(state) do
    download_with_retry(state.context, state.file_meta, state.progress, state.attempt + 1)
  end

  defp promote_partial(state) do
    with :ok <- revalidate_promotion_target(state),
         :ok <- rename_partial(state) do
      finish_promotion(state)
    end
  end

  defp revalidate_promotion_target(state) do
    case prepare_destination(state.context, state.file_meta) do
      {:ok, _paths} ->
        ensure_not_symlink(state.partial_path, state.file_meta.path, state.context.root_label)

      {:error, _} = error ->
        error
    end
  end

  defp rename_partial(state) do
    case File.rename(state.partial_path, state.dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:filesystem_error, :rename, state.partial_path, reason}}
    end
  end

  defp finish_promotion(state) do
    File.rm(state.etag_path)

    file_bytes = state.file_meta[:content_length] || state.file_meta.size || 0

    updated_progress = %{
      state.progress
      | bytes_downloaded: state.progress.bytes_downloaded + file_bytes,
        files_completed: state.progress.files_completed + 1
    }

    with :ok <- emit_progress(state.context.progress_fun, updated_progress, state.file_meta.path) do
      {:ok, updated_progress}
    end
  end

  defp handle_http_error(%{resume?: true} = state, 416) do
    # Stale/corrupted .partial is larger than the real file.
    # Clear scratch state and retry as a fresh download (same attempt number).
    clear_resume_state(state.partial_path, state.etag_path)
    download_with_retry(state.context, state.file_meta, state.progress, state.attempt)
  end

  defp handle_http_error(state, status) do
    if retryable_status?(status) and state.attempt < state.context.max_attempts do
      backoff(state.attempt)
      retry_download(state)
    else
      {:error, {:http_status, status, state.file_meta.path}}
    end
  end

  defp handle_request_error(state, reason) do
    if state.attempt < state.context.max_attempts do
      backoff(state.attempt)
      retry_download(state)
    else
      {:error, {:request_failed, state.file_meta.path, reason}}
    end
  end

  defp emit_progress(nil, _progress, _current_file), do: :ok

  defp emit_progress(progress_fun, progress, current_file),
    do: progress_fun.(progress, current_file)

  defp retryable_status?(status), do: status == 429 or status >= 500

  defp compute_resume_offset(partial_path, etag_path, remote_etag, repo_path, root_label) do
    with :ok <- ensure_not_symlink(partial_path, repo_path, root_label),
         :ok <- ensure_not_symlink(etag_path, repo_path, root_label) do
      cond do
        not File.exists?(partial_path) ->
          {:ok, {0, false}}

        resume_allowed?(etag_path, remote_etag) ->
          {:ok, resume_file_size(partial_path)}

        true ->
          clear_resume_state(partial_path, etag_path)
          {:ok, {0, false}}
      end
    end
  end

  defp resume_allowed?(etag_path, remote_etag) when is_binary(remote_etag) do
    match?({:ok, ^remote_etag}, File.read(etag_path))
  end

  defp resume_allowed?(_etag_path, _remote_etag), do: false

  defp resume_file_size(partial_path) do
    case File.stat(partial_path) do
      {:ok, %{size: size}} -> {size, true}
      {:error, _} -> {0, false}
    end
  end

  defp clear_resume_state(partial_path, etag_path) do
    File.rm(partial_path)
    File.rm(etag_path)
  end

  defp range_headers(true, offset) when offset > 0, do: [{"range", "bytes=#{offset}-"}]
  defp range_headers(_resume?, _offset), do: []

  defp resolve_url(base_url, repo_spec, file_path) do
    repo_id = Map.get(repo_spec, :encoded_repo_id, Map.get(repo_spec, :repo_id, ""))
    revision = Map.get(repo_spec, :revision, "main")
    encoded_revision = URI.encode(revision, &URI.char_unreserved?/1)

    encoded_path =
      file_path
      |> Path.split()
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    "#{base_url}/#{repo_id}/resolve/#{encoded_revision}/#{encoded_path}"
  end

  # -- Redirect Resolution ---------------------------------------------------

  defp resolve_stream_target(state) do
    resolve_redirect_chain(state.request_url, state.request_url, state.context.request_fun, 0)
  end

  defp resolve_redirect_chain(_origin_url, _current_url, _request_fun, hops)
       when hops >= @max_redirect_hops do
    {:error, {:redirect_resolution_failed, "too many redirect hops"}}
  end

  defp resolve_redirect_chain(origin_url, current_url, request_fun, hops) do
    auth? = same_origin?(origin_url, current_url)

    case request_fun.(:head, current_url, follow_redirects?: false, auth?: auth?) do
      {:ok, %{status: status} = resp} when status in @redirect_statuses ->
        case get_location(resp) do
          nil ->
            {:error, {:redirect_resolution_failed, "missing Location header at #{current_url}"}}

          location ->
            next_url = resolve_location(current_url, location)
            resolve_redirect_chain(origin_url, next_url, request_fun, hops + 1)
        end

      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        {:ok, %{url: current_url, auth?: auth?}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status, "redirect resolution"}}

      {:error, reason} ->
        {:error, {:request_failed, "redirect resolution", reason}}
    end
  end

  defp same_origin?(url_a, url_b) do
    uri_a = URI.parse(url_a)
    uri_b = URI.parse(url_b)

    uri_a.scheme == uri_b.scheme and
      uri_a.host == uri_b.host and
      effective_port(uri_a) == effective_port(uri_b)
  end

  defp effective_port(%URI{port: nil, scheme: "https"}), do: 443
  defp effective_port(%URI{port: nil, scheme: "http"}), do: 80
  defp effective_port(%URI{port: port}), do: port

  defp get_location(%{headers: headers}) when is_map(headers) do
    case Map.get(headers, "location", []) do
      [value | _] -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp get_location(%{headers: headers}) when is_list(headers) do
    Enum.find_value(headers, fn
      {"location", value} -> value
      _ -> nil
    end)
  end

  defp get_location(_), do: nil

  defp resolve_location(base_url, location) do
    URI.merge(base_url, location) |> URI.to_string()
  end

  # -- Backoff ---------------------------------------------------------------

  defp backoff(attempt) do
    delay = min(@initial_backoff_ms * Integer.pow(2, max(attempt - 1, 0)), @max_backoff_ms)
    Process.sleep(delay)
  end
end
