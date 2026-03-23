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
    * `:revision` — HF revision to download (default: detail's `revision_sha`)
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
          case client.search_models(query, []) do
            {:ok, results} -> {:ok, %{query: query, results: results}}
            {:error, %{} = error} -> {:error, error}
            _other -> {:error, hf_error()}
          end
        end,
        hf_error()
      )

    send(owner, {:model_hub, ref, :search_finished, result})
  end

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

    send(owner, {:model_hub, ref, :detail_finished, result})
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

    send(owner, {:model_hub, ref, :download_finished, result})
  end

  defp do_download_import(client, downloader, owner, ref, repo_id, opts) do
    activate? = Keyword.get(opts, :activate, true)

    # Step 1: Fetch model detail
    detail =
      case client.get_model_detail(repo_id) do
        {:ok, detail} -> detail
        {:error, %{} = error} -> throw({:pipeline_error, {:error, error}})
        _other -> throw({:pipeline_error, {:error, hf_error()}})
      end

    # Step 2: Resolve effective revision
    effective_revision = resolve_revision(opts, detail)
    detail_for_bundle = Map.put(detail, :revision_sha, effective_revision)

    # Step 3: Create temp directory and run pipeline
    temp_dir = create_temp_dir()

    try do
      # Step 4: Download with progress callback
      started_sent? = :atomics.new(1, [])

      progress_callback = fn update ->
        if :atomics.get(started_sent?, 1) == 0 do
          # First callback (preflight): send :download_started
          :atomics.put(started_sent?, 1, 1)

          send(
            owner,
            {:model_hub, ref, :download_started,
             %{
               repo_id: repo_id,
               revision: effective_revision,
               total_files: update.total_files,
               total_bytes: update.total_bytes
             }}
          )
        else
          # Subsequent callbacks: send :download_progress
          send(
            owner,
            {:model_hub, ref, :download_progress,
             %{
               phase: :downloading,
               current_file: update.current_file,
               files_completed: update.files_completed,
               total_files: update.total_files,
               bytes_downloaded: update.bytes_downloaded,
               total_bytes: update.total_bytes
             }}
          )
        end
      end

      {total_files, total_bytes} =
        case downloader.download(repo_id, temp_dir,
               revision: effective_revision,
               progress_callback: progress_callback
             ) do
          {:ok, _dest, summary} ->
            {summary.files_downloaded, summary.total_bytes}

          {:error, reason} ->
            throw({:pipeline_error, {:error, normalize_download_error(reason)}})
        end

      # Step 5: Bundle preparation phase
      send(
        owner,
        {:model_hub, ref, :download_progress,
         %{
           phase: :preparing_bundle,
           current_file: nil,
           files_completed: total_files,
           total_files: total_files,
           bytes_downloaded: total_bytes,
           total_bytes: total_bytes
         }}
      )

      case BundleBuilder.prepare_bundle(temp_dir, repo_id, detail_for_bundle) do
        {:ok, _bundle_dir} -> :ok
        {:error, reason} -> throw({:pipeline_error, {:error, normalize_bundle_error(reason)}})
      end

      # Step 6: Import phase
      send(
        owner,
        {:model_hub, ref, :download_progress,
         %{
           phase: :importing,
           current_file: nil,
           files_completed: total_files,
           total_files: total_files,
           bytes_downloaded: total_bytes,
           total_bytes: total_bytes
         }}
      )

      case Importer.import_bundle(temp_dir,
             artifacts_root: Importer.default_artifacts_root(),
             activate: activate?
           ) do
        {:ok, model} ->
          {:ok,
           %{
             model_id: model.model_id,
             version: model.version,
             state: model.state
           }}

        {:error, reason} ->
          throw({:pipeline_error, {:error, normalize_import_error(reason)}})
      end
    catch
      :throw, {:pipeline_error, result} -> result
    after
      File.rm_rf(temp_dir)
    end
  end

  # ===========================================================================
  # Pipeline helpers
  # ===========================================================================

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
    _exception -> {:error, fallback_error}
  catch
    :throw, {:pipeline_error, result} -> result
    :throw, _value -> {:error, fallback_error}
    :exit, _reason -> {:error, fallback_error}
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

  defp normalize_download_error(reason) when is_tuple(reason) do
    case reason do
      {:unauthorized, msg} ->
        %{status: :unauthorized, code: "hf_unauthorized", message: msg}

      {:not_found, msg} ->
        %{status: :not_found, code: "hf_not_found", message: msg}

      {:rate_limited, msg} ->
        %{status: :rate_limited, code: "hf_rate_limited", message: msg}

      {:unavailable, msg} ->
        %{status: :unavailable, code: "hf_unavailable", message: msg}

      {:invalid_source_layout, msg} ->
        %{status: :error, code: "hf_invalid_source_layout", message: msg}

      {:download_failed, msg} ->
        %{status: :error, code: "hf_download_failed", message: msg}

      {:download_incomplete, msg} ->
        %{status: :error, code: "hf_download_incomplete", message: msg}

      {:filesystem_error, msg} ->
        %{status: :error, code: "download_filesystem_error", message: msg}

      {:callback_failed, msg} ->
        %{status: :error, code: "download_callback_failed", message: msg}

      {_tag, msg} when is_binary(msg) ->
        %{status: :error, code: "hf_download_failed", message: msg}

      _ ->
        download_import_error()
    end
  end

  defp normalize_download_error(_), do: download_import_error()

  defp normalize_bundle_error(reason) when is_tuple(reason) do
    case reason do
      {tag, msg} when is_binary(msg) ->
        %{status: :error, code: "bundle_#{tag}", message: msg}

      _ ->
        %{status: :error, code: "bundle_prepare_failed", message: "Bundle preparation failed."}
    end
  end

  defp normalize_bundle_error(_) do
    %{status: :error, code: "bundle_prepare_failed", message: "Bundle preparation failed."}
  end

  defp normalize_import_error({:duplicate, _msg}) do
    %{
      status: :error,
      code: "model_already_imported",
      message: "This model version is already imported."
    }
  end

  defp normalize_import_error(%Ecto.Changeset{} = _changeset) do
    %{status: :error, code: "model_import_failed", message: "Model import failed."}
  end

  defp normalize_import_error(reason) when is_tuple(reason) do
    case reason do
      {_tag, msg} when is_binary(msg) ->
        %{status: :error, code: "model_import_failed", message: msg}

      _ ->
        %{status: :error, code: "model_import_failed", message: "Model import failed."}
    end
  end

  defp normalize_import_error(_) do
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
