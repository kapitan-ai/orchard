defmodule OrchardConsole.ModelHubDownloadCoordinator do
  @moduledoc """
  Authoritative owner of model download lifecycle.

  Wraps `OrchardConsole.ModelHub.start_download_import/4` in a supervised
  GenServer that deduplicates active downloads by `repo_id`, normalizes raw
  seam messages into snapshots, and broadcasts `{:model_hub_download, snapshot}`
  via PubSub on topic `"console:model_hub:downloads"`.

  Any `ModelHubLive` instance can subscribe to receive snapshot updates and
  rehydrate download state on mount — surviving navigation without loss.

  ## Snapshot Shape

      %{
        key: {repo_id, requested_revision},
        repo_id: String.t(),
        catalog_version: String.t() | nil,
        status: :starting | :downloading | :preparing | :importing | :completed | :error,
        progress: map() | nil,
        result: map() | nil,
        error: map() | nil
      }
  """

  use GenServer

  require Logger

  alias OrchardConsole.Redaction

  @topic "console:model_hub:downloads"

  # ===========================================================================
  # Public API
  # ===========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a model download/import for the given `repo_id`.

  Returns `{:ok, snapshot}` on success, `{:error, {:already_downloading, snapshot}}`
  if an active download exists for the same `repo_id`, or `{:error, snapshot}` on
  immediate start failure.

  ## Options

    * `:activate` — activate model after import (default: `true`)
    * `:revision` — HF revision to download (default: resolved by seam)
    * `:catalog_version` — distinct Catalog version for an explicit repair import
  """
  def start_download(repo_id, opts \\ []) do
    GenServer.call(__MODULE__, {:start_download, repo_id, opts})
  end

  @doc "Returns the most recently created or updated snapshot, or `nil`."
  def latest_snapshot do
    GenServer.call(__MODULE__, :latest_snapshot)
  end

  @doc "Returns the most recently created or updated snapshot for `repo_id`, or `nil`."
  def latest_snapshot_for_repo(repo_id) do
    GenServer.call(__MODULE__, {:latest_snapshot_for_repo, repo_id})
  end

  @doc "Lists the latest attempt for every repository and revision in this Controller session."
  @spec list_snapshots() :: [map()]
  def list_snapshots, do: GenServer.call(__MODULE__, :list_snapshots)

  @doc "Controls a transfer before bundle preparation begins."
  @spec control_download({String.t(), String.t() | nil}, :pause | :resume | :cancel) ::
          {:ok, map()} | {:error, :not_found | :not_available}
  def control_download(key, action),
    do: GenServer.call(__MODULE__, {:control_download, key, action})

  @doc "Removes terminal transfer history without deleting Catalog models or artifacts."
  @spec remove_download({String.t(), String.t() | nil}) ::
          :ok | {:error, :not_found | :not_available}
  def remove_download(key), do: GenServer.call(__MODULE__, {:remove_download, key})

  @doc "Subscribe to `{:model_hub_download, snapshot}` broadcasts."
  def subscribe do
    Phoenix.PubSub.subscribe(Orchard.PubSub, @topic)
  end

  @doc "The PubSub topic for download snapshot broadcasts."
  def topic, do: @topic

  @doc false
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ===========================================================================
  # GenServer Callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call({:start_download, repo_id, opts}, _from, state) do
    case validate_repo_id(repo_id) do
      :ok ->
        handle_start_download(repo_id, opts, state)

      {:error, reason} ->
        snapshot = error_snapshot(repo_id, nil, reason)
        {:reply, {:error, snapshot}, state}
    end
  end

  def handle_call(:latest_snapshot, _from, state) do
    snapshot =
      case state.latest_ref do
        nil -> nil
        ref -> get_in(state, [:jobs_by_ref, ref, :snapshot])
      end

    {:reply, snapshot, state}
  end

  def handle_call({:latest_snapshot_for_repo, repo_id}, _from, state) do
    snapshot =
      case Map.get(state.latest_ref_by_repo, repo_id) do
        nil -> nil
        ref -> get_in(state, [:jobs_by_ref, ref, :snapshot])
      end

    {:reply, snapshot, state}
  end

  def handle_call(:list_snapshots, _from, state) do
    snapshots =
      state.jobs_by_ref
      |> Map.values()
      |> Enum.sort_by(& &1.sequence, :desc)
      |> Enum.uniq_by(& &1.snapshot.key)
      |> Enum.map(& &1.snapshot)

    {:reply, snapshots, state}
  end

  def handle_call({:control_download, key, action}, _from, state) do
    job =
      state.jobs_by_ref
      |> Map.values()
      |> Enum.filter(&(&1.snapshot.key == key))
      |> Enum.max_by(& &1.sequence, fn -> nil end)

    control_job(job, action, state)
  end

  def handle_call({:remove_download, key}, _from, state) do
    jobs = state.jobs_by_ref |> Map.values() |> Enum.filter(&(&1.snapshot.key == key))

    cond do
      jobs == [] ->
        {:reply, {:error, :not_found}, state}

      Enum.any?(jobs, &(not terminal?(&1.snapshot.status))) ->
        {:reply, {:error, :not_available}, state}

      true ->
        state = remove_terminal_jobs(state, jobs)
        Phoenix.PubSub.broadcast(Orchard.PubSub, @topic, {:model_hub_download_removed, key})
        {:reply, :ok, state}
    end
  end

  def handle_call({:download_phase, ref, phase}, _from, state) do
    case get_active_job(state, ref) do
      nil ->
        {:reply, {:error, :cancelled}, state}

      %{snapshot: %{status: status}} when status in [:pausing, :paused] ->
        {:reply, {:error, :paused}, state}

      %{snapshot: %{status: :cancelling}} ->
        {:reply, {:error, :cancelled}, state}

      job ->
        snapshot = %{job.snapshot | status: phase}
        broadcast(snapshot)
        {:reply, :ok, update_job_snapshot(state, ref, snapshot)}
    end
  end

  def handle_call({:download_paused, ref}, _from, state) do
    case get_active_job(state, ref) do
      %{snapshot: %{status: :pausing}} = job ->
        snapshot = %{job.snapshot | status: :paused}
        broadcast(snapshot)
        {:reply, :ok, update_job_snapshot(state, ref, snapshot)}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:reset, _from, state) do
    cleanup_all_jobs(state)
    {:reply, :ok, initial_state()}
  end

  @impl true
  def handle_info({:model_hub, ref, :download_started, payload}, state) do
    case get_active_job(state, ref) do
      nil ->
        {:noreply, state}

      job ->
        progress = normalize_download_started(payload, job.snapshot.progress)

        snapshot = %{
          job.snapshot
          | status: preserve_control_status(job.snapshot.status, :downloading),
            progress: progress
        }

        state = update_job_snapshot(state, ref, snapshot)
        broadcast(snapshot)
        {:noreply, state}
    end
  end

  def handle_info({:model_hub, ref, :download_progress, payload}, state) do
    case get_active_job(state, ref) do
      nil ->
        {:noreply, state}

      job ->
        {status, progress} =
          normalize_download_progress(payload, job.snapshot.progress, job.snapshot.status)

        snapshot = %{
          job.snapshot
          | status: preserve_control_status(job.snapshot.status, status),
            progress: progress
        }

        state = update_job_snapshot(state, ref, snapshot)
        broadcast(snapshot)
        {:noreply, state}
    end
  end

  def handle_info({:model_hub, ref, :download_finished, {:ok, result}}, state) do
    finalize_download(ref, state, fn job ->
      result_map = if is_map(result), do: result, else: %{}
      %{job.snapshot | status: :completed, result: result_map, error: nil}
    end)
  end

  def handle_info({:model_hub, ref, :download_finished, {:error, error}}, state) do
    finalize_download(ref, state, fn job ->
      error_map = if is_map(error), do: Redaction.sanitize_error_map(error), else: default_error()
      error_map = cancellation_error(job.snapshot.status, error_map)

      %{
        job.snapshot
        | status: if(error_map[:code] == "download_cancelled", do: :cancelled, else: :error),
          result: nil,
          error: error_map
      }
    end)
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    case Map.get(state.monitor_ref_to_job_ref, monitor_ref) do
      nil -> {:noreply, state}
      job_ref -> handle_download_down(job_ref, monitor_ref, pid, reason, state)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_download_down(job_ref, monitor_ref, pid, reason, state) do
    case Map.get(state.jobs_by_ref, job_ref) do
      nil ->
        {:noreply, remove_monitor_ref(state, monitor_ref)}

      job ->
        handle_download_job_down(job_ref, monitor_ref, pid, reason, state, job)
    end
  end

  defp handle_download_job_down(job_ref, monitor_ref, pid, reason, state, job) do
    if terminal?(job.snapshot.status) do
      # Already terminal — just clean up monitor mapping
      {:noreply, remove_monitor_ref(state, monitor_ref)}
    else
      handle_download_crash(job_ref, monitor_ref, pid, reason, state, job)
    end
  end

  defp handle_download_crash(job_ref, monitor_ref, pid, reason, state, job) do
    Logger.error(
      "ModelHubDownloadCoordinator: download task " <>
        Redaction.safe_inspect(pid) <>
        " for ref " <>
        Redaction.safe_inspect(job_ref) <>
        " crashed: " <> Redaction.safe_inspect(reason)
    )

    snapshot = %{job.snapshot | status: :error, result: nil, error: default_error()}

    state =
      state
      |> update_job_snapshot(job_ref, snapshot)
      |> deactivate_job(job_ref, job)
      |> remove_monitor_ref(monitor_ref)

    broadcast(snapshot)
    {:noreply, state}
  end

  defp remove_monitor_ref(state, monitor_ref) do
    %{state | monitor_ref_to_job_ref: Map.delete(state.monitor_ref_to_job_ref, monitor_ref)}
  end

  defp finalize_download(ref, state, build_snapshot) do
    case Map.get(state.jobs_by_ref, ref) do
      nil ->
        {:noreply, state}

      job ->
        finalize_download_job(ref, state, job, build_snapshot)
    end
  end

  defp finalize_download_job(ref, state, job, build_snapshot) do
    if terminal?(job.snapshot.status) do
      {:noreply, state}
    else
      complete_download_job(ref, state, job, build_snapshot)
    end
  end

  defp complete_download_job(ref, state, job, build_snapshot) do
    snapshot = build_snapshot.(job)

    state =
      state
      |> update_job_snapshot(ref, snapshot)
      |> deactivate_job(ref, job)
      |> cleanup_monitor(job)

    broadcast(snapshot)
    {:noreply, state}
  end

  # ===========================================================================
  # Start Download Internals
  # ===========================================================================

  defp handle_start_download(repo_id, opts, state) do
    # Check for active download for this repo_id
    case Map.get(state.active_ref_by_repo, repo_id) do
      nil ->
        do_start_download(repo_id, opts, state)

      existing_ref ->
        existing_job = Map.get(state.jobs_by_ref, existing_ref)

        if existing_job && active?(existing_job.snapshot.status) do
          {:reply, {:error, {:already_downloading, existing_job.snapshot}}, state}
        else
          # Stale entry — clean it up and start fresh
          state = %{state | active_ref_by_repo: Map.delete(state.active_ref_by_repo, repo_id)}
          do_start_download(repo_id, opts, state)
        end
    end
  end

  defp do_start_download(repo_id, opts, state) do
    ref = make_ref()
    activate? = Keyword.get(opts, :activate, true)
    requested_revision = normalize_revision(Keyword.get(opts, :revision))

    # Build provisional starting snapshot
    snapshot =
      repo_id
      |> starting_snapshot(requested_revision)
      |> Map.put(:catalog_version, Keyword.get(opts, :catalog_version))

    # Insert provisional job BEFORE calling seam (prevents race with fast task messages)
    job = %{
      ref: ref,
      repo_id: repo_id,
      requested_revision: requested_revision,
      sequence: System.unique_integer([:monotonic, :positive]),
      control: :atomics.new(1, []),
      task_pid: nil,
      monitor_ref: nil,
      snapshot: snapshot
    }

    state = put_in(state, [:jobs_by_ref, ref], job)

    # Build seam opts
    seam_opts = [activate: activate?, control: job.control]

    seam_opts =
      if requested_revision,
        do: Keyword.put(seam_opts, :revision, requested_revision),
        else: seam_opts

    seam_opts =
      if Keyword.has_key?(opts, :catalog_version),
        do: Keyword.put(seam_opts, :catalog_version, Keyword.fetch!(opts, :catalog_version)),
        else: seam_opts

    case start_download_import(ref, repo_id, seam_opts) do
      {:ok, pid} when is_pid(pid) ->
        monitor_ref = Process.monitor(pid)

        job = %{job | task_pid: pid, monitor_ref: monitor_ref}

        state =
          state
          |> put_in([:jobs_by_ref, ref], job)
          |> put_in([:active_ref_by_repo, repo_id], ref)
          |> put_in([:latest_ref], ref)
          |> put_in([:latest_ref_by_repo, repo_id], ref)
          |> put_in([:monitor_ref_to_job_ref, monitor_ref], ref)

        broadcast(snapshot)
        {:reply, {:ok, snapshot}, state}

      {:error, reason} ->
        Logger.warning(
          "ModelHubDownloadCoordinator: seam start_download_import returned " <>
            "{:error, reason} for repo " <>
            Redaction.safe_inspect(repo_id) <>
            ": " <> Redaction.safe_inspect(reason)
        )

        reply_with_immediate_start_failure(state, ref, repo_id, snapshot, job)

      other ->
        Logger.error(
          "ModelHubDownloadCoordinator: seam start_download_import returned " <>
            "invalid value for repo " <>
            Redaction.safe_inspect(repo_id) <>
            ": " <> Redaction.safe_inspect(other)
        )

        reply_with_immediate_start_failure(state, ref, repo_id, snapshot, job)
    end
  end

  defp start_download_import(ref, repo_id, seam_opts) do
    model_hub_impl().start_download_import(self(), ref, repo_id, seam_opts)
  rescue
    exception ->
      Logger.error(
        "ModelHubDownloadCoordinator: seam start_download_import raised for repo " <>
          Redaction.safe_inspect(repo_id) <>
          ": " <> Redaction.format_exception(:error, exception, __STACKTRACE__)
      )

      {:error, :seam_start_failed}
  catch
    :throw, value ->
      Logger.error(
        "ModelHubDownloadCoordinator: seam start_download_import threw for repo " <>
          Redaction.safe_inspect(repo_id) <>
          ": " <> Redaction.safe_inspect(value)
      )

      {:error, :seam_start_failed}

    :exit, reason ->
      Logger.error(
        "ModelHubDownloadCoordinator: seam start_download_import exited for repo " <>
          Redaction.safe_inspect(repo_id) <>
          ": " <> Redaction.safe_inspect(reason)
      )

      {:error, :seam_start_failed}
  end

  defp reply_with_immediate_start_failure(state, ref, repo_id, snapshot, job) do
    error = default_error()
    snapshot = %{snapshot | status: :error, error: error}
    job = %{job | snapshot: snapshot}

    state =
      state
      |> put_in([:jobs_by_ref, ref], job)
      |> put_in([:latest_ref], ref)
      |> put_in([:latest_ref_by_repo, repo_id], ref)

    broadcast(snapshot)
    {:reply, {:error, snapshot}, state}
  end

  # ===========================================================================
  # Download Message Normalization
  # ===========================================================================

  defp normalize_download_started(payload, existing_progress) do
    base = existing_progress || %{}

    Map.merge(base, %{
      repo_id: payload_get(payload, :repo_id),
      revision: payload_get(payload, :revision),
      phase: :downloading,
      total_files: payload_get(payload, :total_files),
      total_bytes: payload_get(payload, :total_bytes),
      files_completed: base[:files_completed] || 0,
      bytes_downloaded: base[:bytes_downloaded] || 0,
      current_file: nil
    })
  end

  defp normalize_download_progress(payload, existing_progress, current_status) do
    base = existing_progress || %{}
    phase = payload_get(payload, :phase)
    status = map_download_phase_to_status(phase) || current_status

    progress =
      Map.merge(base, %{
        phase: phase || base[:phase],
        current_file: payload_get(payload, :current_file),
        files_completed: progress_field(payload, base, :files_completed, 0),
        total_files: progress_field(payload, base, :total_files, nil),
        bytes_downloaded: progress_field(payload, base, :bytes_downloaded, 0),
        total_bytes: progress_field(payload, base, :total_bytes, nil)
      })

    {status, progress}
  end

  defp progress_field(payload, base, key, default) do
    payload_get(payload, key) || base[key] || default
  end

  defp payload_get(payload, key) when is_map(payload) do
    Map.get(payload, key, Map.get(payload, Atom.to_string(key)))
  end

  defp payload_get(_payload, _key), do: nil

  defp map_download_phase_to_status(:downloading), do: :downloading
  defp map_download_phase_to_status(:preparing_bundle), do: :preparing
  defp map_download_phase_to_status(:importing), do: :importing
  defp map_download_phase_to_status(_phase), do: nil

  # ===========================================================================
  # State Helpers
  # ===========================================================================

  # Lifecycle note: all jobs (active + terminal) are retained in memory until BEAM restart.
  # Expected cardinality is tiny for demo, but production use should add eviction
  # of terminal jobs after a TTL (e.g., 1 hour) or cap total retained count.
  defp initial_state do
    %{
      jobs_by_ref: %{},
      active_ref_by_repo: %{},
      latest_ref: nil,
      latest_ref_by_repo: %{},
      monitor_ref_to_job_ref: %{}
    }
  end

  defp starting_snapshot(repo_id, requested_revision) do
    %{
      key: {repo_id, requested_revision},
      repo_id: repo_id,
      status: :starting,
      progress: %{
        repo_id: repo_id,
        revision: nil,
        phase: nil,
        current_file: nil,
        files_completed: 0,
        total_files: nil,
        bytes_downloaded: 0,
        total_bytes: nil
      },
      result: nil,
      error: nil
    }
  end

  defp error_snapshot(repo_id, requested_revision, error_map) do
    %{
      key: {repo_id, requested_revision},
      repo_id: repo_id,
      status: :error,
      progress: nil,
      result: nil,
      error: error_map
    }
  end

  defp cancellation_error(:cancelling, %{code: "download_cleanup_failed"} = error), do: error

  defp cancellation_error(:cancelling, _error),
    do: %{
      status: :error,
      code: "download_cancelled",
      message: "Download cancelled. Temporary files removed."
    }

  defp cancellation_error(_status, error), do: error

  defp default_error do
    %{
      status: :error,
      code: "download_import_failed",
      message: "Model download and import failed."
    }
  end

  defp active?(status),
    do:
      status in [:starting, :downloading, :pausing, :paused, :cancelling, :preparing, :importing]

  defp terminal?(status), do: status in [:completed, :error, :cancelled]

  defp preserve_control_status(status, _next) when status in [:pausing, :paused, :cancelling],
    do: status

  defp preserve_control_status(_status, next), do: next

  defp control_job(nil, _action, state), do: {:reply, {:error, :not_found}, state}

  defp control_job(job, action, state) do
    transition = control_transition(job.snapshot.status, action)

    if transition do
      {status, signal} = transition
      :atomics.put(job.control, 1, signal)

      if action in [:resume, :cancel] && is_pid(job.task_pid),
        do: send(job.task_pid, {:model_hub_control, job.ref, action})

      snapshot = %{job.snapshot | status: status}
      broadcast(snapshot)
      {:reply, {:ok, snapshot}, update_job_snapshot(state, job.ref, snapshot)}
    else
      {:reply, {:error, :not_available}, state}
    end
  end

  defp control_transition(status, :pause) when status in [:starting, :downloading],
    do: {:pausing, 1}

  defp control_transition(:paused, :resume), do: {:downloading, 0}

  defp control_transition(status, :cancel)
       when status in [:starting, :downloading, :pausing, :paused], do: {:cancelling, 2}

  defp control_transition(_status, _action), do: nil

  defp get_active_job(state, ref) do
    case Map.get(state.jobs_by_ref, ref) do
      nil -> nil
      job -> if terminal?(job.snapshot.status), do: nil, else: job
    end
  end

  defp update_job_snapshot(state, ref, snapshot) do
    state
    |> update_in([:jobs_by_ref, ref], fn job ->
      Map.merge(job, %{
        snapshot: snapshot,
        updated_sequence: System.unique_integer([:monotonic, :positive])
      })
    end)
    |> Map.put(:latest_ref, ref)
    |> Map.put(:latest_ref_by_repo, Map.put(state.latest_ref_by_repo, snapshot.repo_id, ref))
  end

  defp deactivate_job(state, _ref, job) do
    %{state | active_ref_by_repo: Map.delete(state.active_ref_by_repo, job.repo_id)}
  end

  defp cleanup_monitor(state, job) do
    case job.monitor_ref do
      nil ->
        state

      monitor_ref ->
        Process.demonitor(monitor_ref, [:flush])

        state
        |> put_in([:jobs_by_ref, job.ref, :monitor_ref], nil)
        |> put_in([:jobs_by_ref, job.ref, :task_pid], nil)
        |> Map.put(:monitor_ref_to_job_ref, Map.delete(state.monitor_ref_to_job_ref, monitor_ref))
    end
  end

  defp cleanup_all_jobs(state) do
    for {_ref, job} <- state.jobs_by_ref do
      if job.monitor_ref, do: Process.demonitor(job.monitor_ref, [:flush])

      if job.task_pid && Process.alive?(job.task_pid) do
        Process.exit(job.task_pid, :kill)
      end
    end
  end

  defp remove_terminal_jobs(state, removed_jobs) do
    state = Enum.reduce(removed_jobs, state, fn job, acc -> cleanup_monitor(acc, job) end)
    retained = Map.drop(state.jobs_by_ref, Enum.map(removed_jobs, & &1.ref))

    ordered =
      retained
      |> Map.values()
      |> Enum.sort_by(&Map.get(&1, :updated_sequence, &1.sequence), :desc)

    latest_by_repo =
      Map.filter(state.latest_ref_by_repo, fn {_repo, ref} -> Map.has_key?(retained, ref) end)

    latest_by_repo =
      Enum.reduce(ordered, latest_by_repo, fn job, acc ->
        Map.put_new(acc, job.repo_id, job.ref)
      end)

    latest =
      if Map.has_key?(retained, state.latest_ref), do: state.latest_ref, else: newest_ref(ordered)

    %{
      state
      | jobs_by_ref: retained,
        latest_ref: latest,
        latest_ref_by_repo: latest_by_repo,
        active_ref_by_repo:
          Map.filter(state.active_ref_by_repo, fn {_repo, ref} -> Map.has_key?(retained, ref) end),
        monitor_ref_to_job_ref:
          Map.filter(state.monitor_ref_to_job_ref, fn {_monitor, ref} ->
            Map.has_key?(retained, ref)
          end)
    }
  end

  defp newest_ref([job | _]), do: job.ref
  defp newest_ref([]), do: nil

  defp validate_repo_id(repo_id) when is_binary(repo_id) do
    if String.trim(repo_id) != "", do: :ok, else: {:error, default_error()}
  end

  defp validate_repo_id(_), do: {:error, default_error()}

  defp normalize_revision(rev) when is_binary(rev) do
    case String.trim(rev) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_revision(_), do: nil

  defp broadcast(snapshot) do
    Phoenix.PubSub.broadcast(Orchard.PubSub, @topic, {:model_hub_download, snapshot})
  end

  defp model_hub_impl do
    console_config()[:model_hub_impl] || OrchardConsole.ModelHub
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end
end
