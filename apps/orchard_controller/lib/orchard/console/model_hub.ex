defmodule OrchardConsole.ModelHub do
  @moduledoc """
  Console-facing async seam for the Model Hub.

  Wraps synchronous `Orchard.Models.HubClient` calls and multi-step download
  pipelines in unlinked tasks, sending ref-tagged messages back to the owner.

  Injectable via `:model_hub_impl` in `:orchard_controller, :console` config.
  Dependencies are injectable via `:model_hub_client_impl` and
  `:model_hub_download_impl`.

  ## Message Contract

  `start_search/3` sends one completion message:

      {:model_hub, ref, :search_finished, {:ok, %{query: query, results: results}}}
      {:model_hub, ref, :search_finished, {:error, error_map}}

  `start_detail/3` sends one completion message:

      {:model_hub, ref, :detail_finished, {:ok, detail}}
      {:model_hub, ref, :detail_finished, {:error, error_map}}

  `start_download_import/4` sends streaming messages:

      {:model_hub, ref, :download_started, %{repo_id, revision, total_files, total_bytes}}
      {:model_hub, ref, :download_progress, %{phase, current_file, files_completed, total_files, bytes_downloaded, total_bytes}}
      {:model_hub, ref, :download_finished, {:ok, %{model_id, version, state}}}
      {:model_hub, ref, :download_finished, {:error, error_map}}
  """

  require Logger

  alias Orchard.Models.{BundleBuilder, HubClient, HubDownloader, Importer}
  alias OrchardConsole.Redaction

  @type error_map :: %{
          status: atom(),
          code: String.t(),
          message: String.t()
        }

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Starts an async model search and returns `{:ok, pid}` immediately.
  """
  @spec start_search(pid(), term(), String.t() | nil) :: {:ok, pid()}
  def start_search(owner, ref, query) do
    client = model_hub_client_impl()
    Task.start(fn -> run_search(client, owner, ref, query) end)
  end

  @doc """
  Starts an async model detail lookup and returns `{:ok, pid}` immediately.
  """
  @spec start_detail(pid(), term(), String.t()) :: {:ok, pid()}
  def start_detail(owner, ref, repo_id) do
    client = model_hub_client_impl()
    Task.start(fn -> run_detail(client, owner, ref, repo_id) end)
  end

  @doc """
  Starts an async download → build → import pipeline.

  Returns `{:ok, pid}` immediately. The task is unlinked.

  ## Options

    * `:activate` — activate model after import (default: `true`)
    * `:revision` - Selected immutable HF revision (default: detail's `revision_sha`).
      Refreshed provider detail must still match this revision before downloading.
  """
  @spec start_download_import(pid(), term(), String.t(), keyword()) :: {:ok, pid()}
  def start_download_import(owner, ref, repo_id, opts \\ []) do
    client = model_hub_client_impl()
    downloader = model_hub_download_impl()

    Task.start(fn ->
      run_download_import(client, downloader, owner, ref, repo_id, opts)
    end)
  end

  # ===========================================================================
  # Search / Detail (existing)
  # ===========================================================================

  defp run_search(client, owner, ref, query) do
    result =
      protect_result(
        fn ->
          lookup = start_optional_repo_lookup(client, query)

          case client.search_models(query, []) do
            {:ok, results} ->
              direct = collect_optional_lookup(lookup)
              {:ok, %{query: query, results: merge_search_results(direct, results)}}

            {:error, %{} = error} ->
              cancel_optional_lookup(lookup)
              {:error, error}

            _other ->
              cancel_optional_lookup(lookup)
              {:error, hf_error()}
          end
        end,
        hf_error()
      )

    send(owner, {:model_hub, ref, :search_finished, Redaction.sanitize_result(result)})
  end

  # ---------------------------------------------------------------------------
  # Direct repo-ID lookup (parallel to normal search)
  # ---------------------------------------------------------------------------

  # Returns {:waiting, pid, ref} when query looks like a HuggingFace repo ID
  # (exactly two non-empty slash-delimited segments), or :skip otherwise.
  # Spawns a child process linked to the calling (search) task so that
  # killing the search task also terminates the lookup child.
  defp start_optional_repo_lookup(client, query) do
    case repo_lookup_candidate(query) do
      {:ok, repo_id} ->
        # Trap exits so child crashes become messages rather than killing us.
        Process.flag(:trap_exit, true)
        lookup_ref = make_ref()
        parent = self()

        {:ok, pid} =
          Task.start_link(fn ->
            result =
              try do
                client.get_model_detail(repo_id)
              rescue
                _ -> {:error, :lookup_failed}
              catch
                _, _ -> {:error, :lookup_failed}
              end

            send(parent, {:model_hub_repo_lookup, lookup_ref, result})
          end)

        {:waiting, pid, lookup_ref}

      :skip ->
        :skip
    end
  end

  # Waits for the optional lookup result and returns the detail map on success,
  # or nil on failure/timeout/crash.
  defp collect_optional_lookup(:skip), do: nil

  defp collect_optional_lookup({:waiting, _pid, lookup_ref}) do
    receive do
      {:model_hub_repo_lookup, ^lookup_ref, {:ok, detail}} ->
        detail

      {:model_hub_repo_lookup, ^lookup_ref, _} ->
        nil

      {:EXIT, _pid, _reason} ->
        nil
    after
      5000 ->
        nil
    end
  end

  # Kills the optional lookup child (no-op if already :skip).
  defp cancel_optional_lookup(:skip), do: :ok

  defp cancel_optional_lookup({:waiting, pid, _ref}) do
    Process.exit(pid, :kill)
  end

  # Detects whether a query string looks like a HuggingFace repo ID.
  # Requires exactly two non-empty slash-delimited segments (e.g. "owner/model").
  defp repo_lookup_candidate(nil), do: :skip

  defp repo_lookup_candidate(query) when is_binary(query) do
    case String.split(String.trim(query), "/") do
      [org, model] when org != "" and model != "" -> {:ok, String.trim(query)}
      _ -> :skip
    end
  end

  defp repo_lookup_candidate(_), do: :skip

  # Converts a detail map (atom-keyed) into a search-result-compatible map.
  # Only the fields needed for the search results table are included.
  defp detail_to_search_result(detail) do
    %{
      repo_id: Map.get(detail, :repo_id),
      author: Map.get(detail, :author),
      downloads: Map.get(detail, :downloads),
      likes: Map.get(detail, :likes),
      tags: Map.get(detail, :tags),
      pipeline_tag: Map.get(detail, :pipeline_tag),
      library_name: Map.get(detail, :library_name),
      used_storage_bytes: Map.get(detail, :used_storage_bytes),
      safetensors_total: Map.get(detail, :safetensors_total),
      last_modified: Map.get(detail, :last_modified),
      gated: Map.get(detail, :gated)
    }
  end

  # Prepends the direct detail result to search results, deduplicating by repo_id.
  # The direct result takes precedence (first occurrence wins).
  defp merge_search_results(nil, search_results), do: search_results

  defp merge_search_results(direct_detail, search_results) do
    direct = detail_to_search_result(direct_detail)
    direct_repo_id = direct.repo_id

    filtered =
      Enum.reject(search_results, fn result ->
        search_result_repo_id(result) == direct_repo_id
      end)

    [direct | filtered]
  end

  defp search_result_repo_id(%{repo_id: id}), do: id
  defp search_result_repo_id(%{"repo_id" => id}), do: id
  defp search_result_repo_id(_), do: nil

  defp run_detail(client, owner, ref, repo_id) do
    result =
      protect_result(
        fn ->
          case client.get_model_detail(repo_id) do
            {:ok, detail} -> {:ok, detail}
            {:error, %{} = error} -> {:error, error}
            _other -> {:error, hf_error()}
          end
        end,
        hf_error()
      )

    send(owner, {:model_hub, ref, :detail_finished, Redaction.sanitize_result(result)})
  end

  # ===========================================================================
  # Download / Import Pipeline
  # ===========================================================================

  defp run_download_import(client, downloader, owner, ref, repo_id, opts) do
    result =
      protect_result(
        fn ->
          do_download_import(client, downloader, owner, ref, repo_id, opts)
        end,
        download_import_error()
      )

    result = apply_cancellation_result(result, opts)
    send(owner, {:model_hub, ref, :download_finished, Redaction.sanitize_result(result)})
  end

  defp apply_cancellation_result({:error, %{code: "download_cleanup_failed"}} = result, _opts),
    do: result

  defp apply_cancellation_result(result, opts) do
    if check_download_control(opts) == {:error, :cancelled},
      do: {:error, cancelled_error()},
      else: result
  end

  defp do_download_import(client, downloader, owner, ref, repo_id, opts) do
    activate? = Keyword.get(opts, :activate, true)
    detail = fetch_model_detail!(client, repo_id)
    {detail_for_bundle, effective_revision} = build_detail_for_bundle(detail, opts)
    temp_dir = create_temp_dir()

    try do
      {total_files, total_bytes} =
        download_model!(downloader, owner, ref, repo_id, effective_revision, temp_dir, opts)

      enter_phase!(owner, ref, :preparing, opts)
      send_pipeline_progress(owner, ref, :preparing_bundle, total_files, total_bytes)
      prepare_bundle!(temp_dir, repo_id, detail_for_bundle)
      enter_phase!(owner, ref, :importing, opts)
      send_pipeline_progress(owner, ref, :importing, total_files, total_bytes)
      import_bundle!(temp_dir, activate?)
    catch
      :throw, {:pipeline_error, result} -> result
    after
      cleanup_temp_dir!(temp_dir, opts)
    end
  end

  # ===========================================================================
  # Pipeline helpers
  # ===========================================================================

  defp cleanup_temp_dir!(temp_dir, opts) do
    cleanup = Keyword.get(opts, :cleanup_fun, &File.rm_rf/1)

    case cleanup.(temp_dir) do
      {:ok, _paths} ->
        :ok

      {:error, _reason, _path} ->
        throw(
          {:pipeline_error,
           {:error,
            %{
              status: :error,
              code: "download_cleanup_failed",
              message:
                "Temporary transfer files could not be removed. Check Controller storage and the Catalog before retrying."
            }}}
        )
    end
  end

  defp fetch_model_detail!(client, repo_id) do
    case client.get_model_detail(repo_id) do
      {:ok, detail} -> detail
      {:error, %{} = error} -> throw({:pipeline_error, {:error, error}})
      _other -> throw({:pipeline_error, {:error, hf_error()}})
    end
  end

  defp build_detail_for_bundle(detail, opts) do
    effective_revision = resolve_revision(opts, detail)

    if effective_revision != resolve_revision_from_detail(detail) do
      throw(
        {:pipeline_error,
         {:error,
          %{
            status: :error,
            code: "hf_revision_changed",
            message:
              "The provider revision changed. Refresh the search and select the model again before importing."
          }}}
      )
    end

    {detail, effective_revision}
  end

  defp download_model!(downloader, owner, ref, repo_id, revision, temp_dir, opts) do
    progress_callback = build_progress_callback(owner, ref, repo_id, revision)

    case downloader.download(repo_id, temp_dir,
           revision: revision,
           progress_callback: progress_callback,
           control_fun: fn -> check_download_control(opts) end,
           wait_fun: fn -> wait_download_control(owner, ref, opts) end
         ) do
      {:ok, _dest, summary} -> {summary.files_downloaded, summary.total_bytes}
      {:error, reason} -> throw({:pipeline_error, {:error, normalize_download_error(reason)}})
    end
  end

  defp check_download_control(opts) do
    case Keyword.get(opts, :control) do
      nil ->
        :ok

      control ->
        case :atomics.get(control, 1) do
          0 -> :ok
          1 -> {:error, :paused}
          2 -> {:error, :cancelled}
        end
    end
  end

  defp wait_download_control(owner, ref, opts) do
    monitor = Process.monitor(owner)

    try do
      await_download_control(owner, ref, monitor, opts)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp await_download_control(owner, ref, monitor, opts) do
    case check_download_control(opts) do
      :ok ->
        :ok

      {:error, :cancelled} ->
        {:error, {:callback_failed, :cancelled}}

      {:error, :paused} ->
        GenServer.call(owner, {:download_paused, ref})

        receive do
          {:model_hub_control, ^ref, _action} -> await_download_control(owner, ref, monitor, opts)
          {:DOWN, ^monitor, :process, ^owner, _reason} -> {:error, {:callback_failed, :cancelled}}
        end
    end
  end

  defp enter_phase!(owner, ref, phase, opts) do
    if Keyword.has_key?(opts, :control) do
      case GenServer.call(owner, {:download_phase, ref, phase}) do
        :ok ->
          :ok

        {:error, :paused} ->
          resume_phase!(owner, ref, phase, opts)

        {:error, :cancelled} ->
          throw({:pipeline_error, {:error, cancelled_error()}})
      end
    end
  end

  defp resume_phase!(owner, ref, phase, opts) do
    case wait_download_control(owner, ref, opts) do
      :ok -> enter_phase!(owner, ref, phase, opts)
      _ -> throw({:pipeline_error, {:error, cancelled_error()}})
    end
  end

  defp cancelled_error,
    do: %{
      status: :error,
      code: "download_cancelled",
      message: "Download cancelled. Temporary files removed."
    }

  defp build_progress_callback(owner, ref, repo_id, revision) do
    started_sent? = :atomics.new(1, [])

    fn update ->
      if :atomics.get(started_sent?, 1) == 0 do
        :atomics.put(started_sent?, 1, 1)
        send_download_started(owner, ref, repo_id, revision, update)
      else
        send_download_progress(
          owner,
          ref,
          :downloading,
          update.current_file,
          update.files_completed,
          update.total_files,
          update.bytes_downloaded,
          update.total_bytes
        )
      end
    end
  end

  defp send_download_started(owner, ref, repo_id, revision, update) do
    send(
      owner,
      {:model_hub, ref, :download_started,
       %{
         repo_id: repo_id,
         revision: revision,
         total_files: update.total_files,
         total_bytes: update.total_bytes
       }}
    )
  end

  defp send_pipeline_progress(owner, ref, phase, total_files, total_bytes) do
    send_download_progress(
      owner,
      ref,
      phase,
      nil,
      total_files,
      total_files,
      total_bytes,
      total_bytes
    )
  end

  defp send_download_progress(
         owner,
         ref,
         phase,
         current_file,
         files_completed,
         total_files,
         bytes_downloaded,
         total_bytes
       ) do
    send(
      owner,
      {:model_hub, ref, :download_progress,
       %{
         phase: phase,
         current_file: current_file,
         files_completed: files_completed,
         total_files: total_files,
         bytes_downloaded: bytes_downloaded,
         total_bytes: total_bytes
       }}
    )
  end

  defp prepare_bundle!(temp_dir, repo_id, detail_for_bundle) do
    case BundleBuilder.prepare_bundle(temp_dir, repo_id, detail_for_bundle) do
      {:ok, _bundle_dir} -> :ok
      {:error, reason} -> throw({:pipeline_error, {:error, normalize_bundle_error(reason)}})
    end
  end

  defp import_bundle!(temp_dir, activate?) do
    case Importer.import_bundle(temp_dir,
           artifacts_root: Importer.default_artifacts_root(),
           activate: activate?
         ) do
      {:ok, model} ->
        {:ok,
         %{
           id: model.id,
           model_id: model.model_id,
           version: model.version,
           artifact_sha256: model.artifact_sha256,
           state: model.state
         }}

      {:error, reason} ->
        throw({:pipeline_error, {:error, normalize_import_error(reason)}})
    end
  end

  defp resolve_revision(opts, detail) do
    case Keyword.get(opts, :revision) do
      rev when is_binary(rev) ->
        trimmed = String.trim(rev)

        if trimmed != "" do
          trimmed
        else
          resolve_revision_from_detail(detail)
        end

      _ ->
        resolve_revision_from_detail(detail)
    end
  end

  defp resolve_revision_from_detail(detail) do
    case Map.get(detail, :revision_sha) do
      sha when is_binary(sha) and sha != "" -> sha
      _ -> throw({:pipeline_error, {:error, revision_unavailable_error()}})
    end
  end

  defp create_temp_dir do
    dir = Path.join(System.tmp_dir!(), "orchard-model-hub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  # ===========================================================================
  # Error normalization
  # ===========================================================================

  defp protect_result(fun, fallback_error) do
    fun.()
  rescue
    exception ->
      formatted = Redaction.format_exception(:error, exception, __STACKTRACE__)

      Logger.error("ModelHub: pipeline rescued exception:\n" <> formatted)
      {:error, fallback_error}
  catch
    :throw, {:pipeline_error, result} ->
      result

    :throw, value ->
      Logger.error("ModelHub: pipeline caught throw: " <> Redaction.safe_inspect(value))
      {:error, fallback_error}

    :exit, reason ->
      Logger.error("ModelHub: pipeline caught exit: " <> Redaction.safe_inspect(reason))
      {:error, fallback_error}
  end

  defp hf_error do
    %{status: :error, code: "hf_error", message: "Hugging Face request failed."}
  end

  defp download_import_error do
    %{
      status: :error,
      code: "download_import_failed",
      message: "Model download and import failed."
    }
  end

  defp revision_unavailable_error do
    %{
      status: :error,
      code: "hf_revision_unavailable",
      message: "Hugging Face revision is unavailable."
    }
  end

  defp normalize_download_error({:cancelled, _message}), do: cancelled_error()

  defp normalize_download_error({:unauthorized, msg}),
    do: %{status: :unauthorized, code: "hf_unauthorized", message: msg}

  defp normalize_download_error({:not_found, msg}),
    do: %{status: :not_found, code: "hf_not_found", message: msg}

  defp normalize_download_error({:rate_limited, msg}),
    do: %{status: :rate_limited, code: "hf_rate_limited", message: msg}

  defp normalize_download_error({:unavailable, msg}),
    do: %{status: :unavailable, code: "hf_unavailable", message: msg}

  defp normalize_download_error({:invalid_source_layout, msg}),
    do: %{status: :error, code: "hf_invalid_source_layout", message: msg}

  defp normalize_download_error({:download_failed, msg}),
    do: %{status: :error, code: "hf_download_failed", message: msg}

  defp normalize_download_error({:download_incomplete, msg}),
    do: %{status: :error, code: "hf_download_incomplete", message: msg}

  defp normalize_download_error({:filesystem_error, msg}),
    do: %{status: :error, code: "download_filesystem_error", message: msg}

  defp normalize_download_error({:callback_failed, msg}),
    do: %{status: :error, code: "download_callback_failed", message: msg}

  defp normalize_download_error({_tag, msg}) when is_binary(msg),
    do: %{status: :error, code: "hf_download_failed", message: msg}

  defp normalize_download_error(other) do
    Logger.warning("ModelHub: unrecognized download error: " <> Redaction.safe_inspect(other))
    download_import_error()
  end

  defp normalize_bundle_error(reason) when is_tuple(reason) do
    case reason do
      {tag, msg} when is_binary(msg) ->
        %{status: :error, code: "bundle_#{tag}", message: msg}

      _ ->
        Logger.warning("ModelHub: unrecognized bundle error: " <> Redaction.safe_inspect(reason))
        %{status: :error, code: "bundle_prepare_failed", message: "Bundle preparation failed."}
    end
  end

  defp normalize_import_error({:duplicate, _msg}) do
    %{
      status: :error,
      code: "model_already_imported",
      message: "This model version is already imported."
    }
  end

  defp normalize_import_error(%Ecto.Changeset{} = changeset) do
    fields = Enum.map(changeset.errors, fn {field, _} -> field end)

    Logger.warning(
      "ModelHub: changeset import error fields=" <>
        Redaction.safe_inspect(fields) <>
        " change_count=" <> Integer.to_string(map_size(changeset.changes))
    )

    %{status: :error, code: "model_import_failed", message: "Model import failed."}
  end

  defp normalize_import_error(reason) when is_tuple(reason) do
    case reason do
      {_tag, msg} when is_binary(msg) ->
        %{status: :error, code: "model_import_failed", message: msg}

      _ ->
        Logger.warning("ModelHub: unrecognized import error: " <> Redaction.safe_inspect(reason))
        %{status: :error, code: "model_import_failed", message: "Model import failed."}
    end
  end

  defp normalize_import_error(reason) do
    Logger.warning("ModelHub: unrecognized import error: " <> Redaction.safe_inspect(reason))
    %{status: :error, code: "model_import_failed", message: "Model import failed."}
  end

  # ===========================================================================
  # Config seam
  # ===========================================================================

  defp model_hub_client_impl do
    console_config()
    |> Keyword.get(:model_hub_client_impl, HubClient)
  end

  defp model_hub_download_impl do
    console_config()
    |> Keyword.get(:model_hub_download_impl, HubDownloader)
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end
end
