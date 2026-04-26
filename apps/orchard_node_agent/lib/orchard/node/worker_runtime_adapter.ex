defmodule Orchard.Node.WorkerRuntimeAdapter do
  @moduledoc """
  Runtime adapter that owns a Python worker subprocess speaking the internal
  worker-runtime gRPC contract over a Unix domain socket.
  """

  @behaviour Orchard.Node.RuntimeAdapter

  alias GRPC.{Channel, RPCError}

  alias Orchard.Cluster.V1.{
    CancelInferenceRequest,
    ExecuteInferenceRequest,
    InferenceEventMapper,
    ModelRef,
    ScorePrefixCacheRequest,
    ScorePrefixCacheResponse,
    UnloadModelRequest
  }

  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.ScorePrefixCacheResponse, as: ScoreResponse

  alias Orchard.Node.Worker.V1.{
    LoadModelRequest,
    WorkerMemoryBudgetStatus,
    WorkerPrefixCacheStatus,
    WorkerRuntimeService,
    WorkerStatusRequest
  }

  alias Orchard.PathUtils

  @poll_interval_ms 50
  @rpc_timeout_ms 1_000
  @default_generation_mode "batch"
  @default_max_concurrent_generations "auto"
  @default_auto_max_concurrent_generations 3
  @default_memory_budget_mode "observe"
  @default_memory_budget_utilization 0.90
  @default_memory_budget_overhead_bytes 1_073_741_824
  @default_score_prefix_cache_timeout_ms 150
  @prefix_cache_fingerprint_pattern ~r/^hmac-sha256:[a-f0-9]{64}$/

  @type generation_entry :: %{pid: pid(), request_id: String.t()}

  @type state :: %{
          backend: String.t(),
          channel: GRPC.Channel.t(),
          executable: String.t(),
          generations: %{optional(reference()) => generation_entry()},
          log_path: String.t(),
          model_path: String.t(),
          model_ref: ModelRef.t(),
          os_pid: non_neg_integer() | nil,
          port: port(),
          shutdown_timeout_ms: pos_integer(),
          socket_path: String.t()
        }

  @impl true
  def get_status(%{channel: channel}, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @rpc_timeout_ms)

    case WorkerRuntimeService.Stub.get_status(
           channel,
           %WorkerStatusRequest{},
           timeout: timeout_ms
         ) do
      {:ok, status} ->
        {:ok,
         %{
           ready: Map.get(status, :ready, false),
           health_code: Map.get(status, :health_code, ""),
           health_message: Map.get(status, :health_message, ""),
           memory_budget: memory_budget_from_proto(Map.get(status, :memory_budget)),
           prefix_cache_status: prefix_cache_from_proto(Map.get(status, :prefix_cache))
         }}

      {:error, reason} ->
        {:error, normalize_rpc_error(reason)}
    end
  end

  def get_status(_adapter_state, _opts), do: {:error, :worker_unavailable}

  @spec score_prefix_cache(state() | term(), ScorePrefixCacheRequest.t(), keyword()) ::
          {:ok, ScorePrefixCacheResponse.t()} | {:error, term()}
  def score_prefix_cache(%{channel: channel}, %ScorePrefixCacheRequest{} = request, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_score_prefix_cache_timeout_ms)

    if timeout_ms <= 0 do
      {:ok, ScoreResponse.response("timeout", "worker score request timed out")}
    else
      case WorkerRuntimeService.Stub.score_prefix_cache(channel, request, timeout: timeout_ms) do
        {:ok, response} ->
          {:ok, normalize_score(response)}

        {:error, %RPCError{status: status}} when status in [:unimplemented, 12] ->
          {:ok,
           ScoreResponse.response(
             "unsupported_version",
             "worker does not support ScorePrefixCache"
           )}

        {:error, %RPCError{status: status}} when status in [:deadline_exceeded, 4] ->
          {:ok, ScoreResponse.response("timeout", "worker score request timed out")}

        {:error, reason} ->
          {:ok,
           ScoreResponse.response(
             "error",
             "worker score request failed: #{format_rpc_error(reason)}"
           )}
      end
    end
  end

  def score_prefix_cache(_adapter_state, _request, _opts),
    do: {:ok, ScoreResponse.response("unavailable", "worker runtime is unavailable")}

  def normalize_score(response), do: ScoreResponse.normalize(response)

  defp memory_budget_from_proto(nil), do: nil

  defp memory_budget_from_proto(%WorkerMemoryBudgetStatus{} = budget) do
    %{
      mode: Map.get(budget, :mode, ""),
      budget_available: Map.get(budget, :budget_available, false),
      headroom_available: Map.get(budget, :headroom_available, false),
      status_code: Map.get(budget, :status_code, ""),
      status_message: Map.get(budget, :status_message, ""),
      source: Map.get(budget, :source, ""),
      max_recommended_working_set_size_bytes:
        Map.get(budget, :max_recommended_working_set_size_bytes, 0),
      utilization: Map.get(budget, :utilization, 0.0),
      target_working_set_bytes: Map.get(budget, :target_working_set_bytes, 0),
      overhead_bytes: Map.get(budget, :overhead_bytes, 0),
      resident_memory_bytes: Map.get(budget, :resident_memory_bytes, 0),
      estimated_headroom_bytes: Map.get(budget, :estimated_headroom_bytes, 0),
      kv_cache_bytes_per_token: Map.get(budget, :kv_cache_bytes_per_token, 0),
      prefill_workspace_bytes_per_token: Map.get(budget, :prefill_workspace_bytes_per_token, 0)
    }
  end

  defp memory_budget_from_proto(_other), do: nil

  defp prefix_cache_from_proto(nil), do: nil

  defp prefix_cache_from_proto(%WorkerPrefixCacheStatus{} = status) do
    %{
      implementation: Map.get(status, :implementation, ""),
      enabled: Map.get(status, :enabled, false),
      entry_count: Map.get(status, :entry_count, 0),
      total_bytes: Map.get(status, :total_bytes, 0),
      hits: Map.get(status, :hits, 0),
      misses: Map.get(status, :misses, 0),
      failures: Map.get(status, :failures, 0),
      stores: Map.get(status, :stores, 0),
      evictions: Map.get(status, :evictions, 0),
      configured_max_entries: Map.get(status, :configured_max_entries, 0),
      configured_max_bytes: Map.get(status, :configured_max_bytes, 0),
      status_code: Map.get(status, :status_code, ""),
      status_message: Map.get(status, :status_message, ""),
      session_started_unix_ms: Map.get(status, :session_started_unix_ms, 0),
      prefix_cache_fingerprints:
        prefix_cache_fingerprints_from_proto(Map.get(status, :prefix_cache_fingerprints, []))
    }
  end

  defp prefix_cache_from_proto(_other), do: nil

  defp prefix_cache_fingerprints_from_proto(fingerprints) when is_list(fingerprints) do
    Enum.filter(fingerprints, &valid_prefix_cache_fingerprint?/1)
  end

  defp prefix_cache_fingerprints_from_proto(_fingerprints), do: []

  defp valid_prefix_cache_fingerprint?(fingerprint) when is_binary(fingerprint) do
    Regex.match?(@prefix_cache_fingerprint_pattern, fingerprint)
  end

  defp valid_prefix_cache_fingerprint?(_fingerprint), do: false

  @impl true
  def load_model(%ModelRef{} = model_ref, opts) do
    executable = Keyword.get(opts, :executable, Node.worker_executable())
    backend = Keyword.get(opts, :backend, Node.worker_backend())
    ready_timeout_ms = Keyword.get(opts, :ready_timeout_ms, Node.worker_ready_timeout_ms())
    load_timeout_ms = Keyword.get(opts, :load_timeout_ms, Node.worker_load_timeout_ms())

    shutdown_timeout_ms =
      Keyword.get(opts, :shutdown_timeout_ms, Node.worker_shutdown_timeout_ms())

    socket_path = Keyword.get(opts, :socket_path, Node.worker_socket_path(model_ref))
    log_path = Keyword.get(opts, :log_path, Node.worker_log_path(model_ref))
    models_root = Keyword.get(opts, :models_root, Node.models_root())

    prefix_cache_mode =
      Keyword.get(opts, :prefix_cache_mode, Node.worker_prefix_cache_mode())

    prefix_cache_max_entries =
      Keyword.get(opts, :prefix_cache_max_entries, Node.worker_prefix_cache_max_entries())

    prefix_cache_max_bytes =
      Keyword.get(opts, :prefix_cache_max_bytes, Node.worker_prefix_cache_max_bytes())

    generation_mode =
      Keyword.get(opts, :generation_mode, Node.worker_generation_mode())

    max_concurrent_generations =
      Keyword.get(
        opts,
        :max_concurrent_generations,
        Node.worker_max_concurrent_requests_per_model()
      )

    auto_max_concurrent_generations =
      Keyword.get(
        opts,
        :auto_max_concurrent_generations,
        Node.worker_auto_max_concurrent_requests_per_model()
      )

    memory_budget_mode =
      Keyword.get(opts, :memory_budget_mode, Node.worker_memory_budget_mode())

    memory_budget_utilization =
      Keyword.get(opts, :memory_budget_utilization, Node.worker_memory_budget_utilization())

    memory_budget_overhead_bytes =
      Keyword.get(
        opts,
        :memory_budget_overhead_bytes,
        Node.worker_memory_budget_overhead_bytes()
      )

    load_meta = %{
      model_id: model_ref.model_id,
      version: model_ref.version,
      backend: backend,
      worker_executable: executable,
      ready_timeout_ms: ready_timeout_ms,
      load_timeout_ms: load_timeout_ms,
      shutdown_timeout_ms: shutdown_timeout_ms,
      generation_mode: generation_mode,
      max_concurrent_generations: max_concurrent_generations,
      auto_max_concurrent_generations: auto_max_concurrent_generations,
      memory_budget_mode: memory_budget_mode,
      memory_budget_utilization: memory_budget_utilization,
      memory_budget_overhead_bytes: memory_budget_overhead_bytes,
      adapter: __MODULE__
    }

    emit_runtime_start([:orchard, :node, :worker_runtime, :load, :start], load_meta)
    start_time = System.monotonic_time(:millisecond)

    result =
      with {:ok, resolved_model_path} <- resolve_model_path(model_ref, models_root),
           {:ok, resolved_executable} <- resolve_executable(executable),
           :ok <- ensure_socket_parent(socket_path),
           :ok <- ensure_log_parent(log_path),
           :ok <- cleanup_socket(socket_path) do
        start_runtime(%{
          model_ref: model_ref,
          model_path: resolved_model_path,
          executable: resolved_executable,
          backend: backend,
          socket_path: socket_path,
          log_path: log_path,
          ready_timeout_ms: ready_timeout_ms,
          load_timeout_ms: load_timeout_ms,
          shutdown_timeout_ms: shutdown_timeout_ms,
          prefix_cache_mode: prefix_cache_mode,
          prefix_cache_max_entries: prefix_cache_max_entries,
          prefix_cache_max_bytes: prefix_cache_max_bytes,
          generation_mode: generation_mode,
          max_concurrent_generations: max_concurrent_generations,
          auto_max_concurrent_generations: auto_max_concurrent_generations,
          memory_budget_mode: memory_budget_mode,
          memory_budget_utilization: memory_budget_utilization,
          memory_budget_overhead_bytes: memory_budget_overhead_bytes
        })
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, _adapter_state} ->
        emit_runtime_stop(
          [:orchard, :node, :worker_runtime, :load, :stop],
          duration_ms,
          Map.put(load_meta, :outcome, :loaded)
        )

      {:error, reason} ->
        emit_runtime_exception(
          [:orchard, :node, :worker_runtime, :load, :exception],
          duration_ms,
          Map.put(load_meta, :reason, reason)
        )
    end

    result
  end

  @impl true
  def unload_model(nil, _opts), do: :ok

  def unload_model(%{} = state, opts) do
    shutdown_timeout_ms = Keyword.get(opts, :shutdown_timeout_ms, state.shutdown_timeout_ms)
    skip_rpc? = Keyword.get(opts, :skip_rpc, false)
    force? = Keyword.get(opts, :force, false)

    unload_meta = %{
      model_id: state.model_ref.model_id,
      version: state.model_ref.version,
      backend: state.backend,
      worker_executable: state.executable,
      shutdown_timeout_ms: shutdown_timeout_ms,
      skip_rpc: skip_rpc?,
      force: force?,
      adapter: __MODULE__
    }

    emit_runtime_start([:orchard, :node, :worker_runtime, :unload, :start], unload_meta)
    start_time = System.monotonic_time(:millisecond)

    unload_result = if skip_rpc?, do: :ok, else: unload_model_rpc(state.channel, state.model_ref)
    stop_result = stop_runtime(state.port, state.os_pid, shutdown_timeout_ms)

    cleanup_generation_tasks(state.generations)
    _ = disconnect_channel(state.channel)
    socket_result = cleanup_socket(state.socket_path)

    final_result = pick_unload_result(unload_result, stop_result, socket_result)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case final_result do
      :ok ->
        emit_runtime_stop(
          [:orchard, :node, :worker_runtime, :unload, :stop],
          duration_ms,
          Map.merge(unload_meta, %{
            outcome: :unloaded,
            rpc_result: if(skip_rpc?, do: :skipped, else: unload_result),
            stop_result: stop_result,
            socket_result: socket_result
          })
        )

      {:error, reason} ->
        emit_runtime_exception(
          [:orchard, :node, :worker_runtime, :unload, :exception],
          duration_ms,
          Map.merge(unload_meta, %{
            reason: reason,
            rpc_result: unload_result,
            stop_result: stop_result,
            socket_result: socket_result
          })
        )
    end

    final_result
  end

  @impl true
  def start_generation(%{} = state, %ExecuteInferenceRequest{} = request, opts) do
    owner = Keyword.fetch!(opts, :owner)
    request_id = Keyword.get(opts, :request_id, request.request_id)
    generation_ref = make_ref()

    {:ok, pid} =
      Task.start(fn ->
        safe_stream_generation(state.channel, owner, generation_ref, request)
      end)

    generations = Map.put(state.generations, generation_ref, %{pid: pid, request_id: request_id})
    {:ok, generation_ref, %{state | generations: generations}}
  end

  @impl true
  def cancel_generation(%{} = state, generation_ref, opts) do
    request_id =
      Keyword.get_lazy(opts, :request_id, fn ->
        case Map.get(state.generations, generation_ref) do
          %{request_id: request_id} -> request_id
          _other -> nil
        end
      end)

    if is_binary(request_id) do
      case cancel_rpc(state.channel, request_id, Keyword.get(opts, :controller_session_id)) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  @impl true
  def finish_generation(%{} = state, generation_ref, _opts) do
    case Map.pop(state.generations, generation_ref) do
      {nil, generations} ->
        %{state | generations: generations}

      {%{pid: pid}, generations} ->
        maybe_kill_task(pid)
        %{state | generations: generations}
    end
  end

  defp start_runtime(%{
         model_ref: model_ref,
         model_path: model_path,
         executable: executable,
         backend: backend,
         socket_path: socket_path,
         log_path: log_path,
         ready_timeout_ms: ready_timeout_ms,
         load_timeout_ms: load_timeout_ms,
         shutdown_timeout_ms: shutdown_timeout_ms,
         prefix_cache_mode: prefix_cache_mode,
         prefix_cache_max_entries: prefix_cache_max_entries,
         prefix_cache_max_bytes: prefix_cache_max_bytes,
         generation_mode: generation_mode,
         max_concurrent_generations: max_concurrent_generations,
         memory_budget_mode: memory_budget_mode,
         memory_budget_utilization: memory_budget_utilization,
         memory_budget_overhead_bytes: memory_budget_overhead_bytes
       }) do
    {:ok, port, os_pid} =
      start_worker_port(executable, socket_path, backend, log_path,
        prefix_cache_mode: prefix_cache_mode,
        prefix_cache_max_entries: prefix_cache_max_entries,
        prefix_cache_max_bytes: prefix_cache_max_bytes,
        generation_mode: generation_mode,
        max_concurrent_generations: max_concurrent_generations,
        memory_budget_mode: memory_budget_mode,
        memory_budget_utilization: memory_budget_utilization,
        memory_budget_overhead_bytes: memory_budget_overhead_bytes
      )

    case wait_for_worker_ready(socket_path, port, ready_timeout_ms) do
      {:ok, channel} ->
        case load_model_rpc(channel, model_ref, model_path, load_timeout_ms) do
          :ok ->
            {:ok,
             %{
               backend: backend,
               channel: channel,
               executable: executable,
               generations: %{},
               log_path: log_path,
               model_path: model_path,
               model_ref: model_ref,
               os_pid: os_pid,
               port: port,
               shutdown_timeout_ms: shutdown_timeout_ms,
               socket_path: socket_path
             }}

          {:error, reason} ->
            cleanup_failed_runtime(port, os_pid, channel, socket_path, shutdown_timeout_ms)
            {:error, reason}
        end

      {:error, reason} ->
        cleanup_failed_runtime(port, os_pid, nil, socket_path, shutdown_timeout_ms)
        {:error, reason}
    end
  end

  defp resolve_model_path(%ModelRef{model_id: model_id, version: version}, models_root)
       when is_binary(model_id) and is_binary(version) do
    expanded_root = Path.expand(models_root)

    with {:ok, real_root} <- PathUtils.resolve_realpath(expanded_root),
         candidate = Path.expand(Path.join([real_root, model_id, version])),
         {:ok, real_path} <- PathUtils.resolve_realpath(candidate) do
      ensure_model_path_confined(real_path, real_root)
    else
      {:error, _reason} -> {:error, :invalid_model_path}
    end
  end

  defp ensure_model_path_confined(real_path, real_root) do
    if real_path == real_root or String.starts_with?(real_path, real_root <> "/") do
      {:ok, real_path}
    else
      {:error, :invalid_model_path}
    end
  end

  defp resolve_executable(executable) when is_binary(executable) do
    cond do
      String.contains?(executable, "/") and File.regular?(executable) ->
        {:ok, Path.expand(executable)}

      path = System.find_executable(executable) ->
        {:ok, path}

      true ->
        {:error, :worker_executable_not_found}
    end
  end

  defp ensure_socket_parent(socket_path) do
    socket_path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp ensure_log_parent(log_path) do
    log_path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp cleanup_socket(socket_path) do
    case File.rm(socket_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:socket_cleanup_failed, reason}}
    end
  end

  @doc false
  @spec worker_cli_args(keyword()) :: [String.t()]
  def worker_cli_args(opts \\ []) do
    prefix_cache_mode = Keyword.get(opts, :prefix_cache_mode, "kv")
    prefix_cache_max_entries = Keyword.get(opts, :prefix_cache_max_entries, 8)
    prefix_cache_max_bytes = Keyword.get(opts, :prefix_cache_max_bytes, 0)
    generation_mode = Keyword.get(opts, :generation_mode, @default_generation_mode)

    max_concurrent_generations =
      Keyword.get(opts, :max_concurrent_generations, @default_max_concurrent_generations)

    auto_max_concurrent_generations =
      Keyword.get(
        opts,
        :auto_max_concurrent_generations,
        @default_auto_max_concurrent_generations
      )

    memory_budget_mode = Keyword.get(opts, :memory_budget_mode, @default_memory_budget_mode)

    memory_budget_utilization =
      Keyword.get(opts, :memory_budget_utilization, @default_memory_budget_utilization)

    memory_budget_overhead_bytes =
      Keyword.get(opts, :memory_budget_overhead_bytes, @default_memory_budget_overhead_bytes)

    normalized_memory_budget_utilization =
      normalize_memory_budget_utilization(memory_budget_utilization)

    base_args = [
      "--socket-path",
      to_string(Keyword.fetch!(opts, :socket_path)),
      "--backend",
      to_string(Keyword.fetch!(opts, :backend)),
      "--log-file",
      to_string(Keyword.fetch!(opts, :log_path)),
      "--prefix-cache-mode",
      to_string(prefix_cache_mode),
      "--prefix-cache-max-entries",
      Integer.to_string(prefix_cache_max_entries),
      "--prefix-cache-max-bytes",
      Integer.to_string(prefix_cache_max_bytes)
    ]

    if extended_generation_memory_flags?(
         generation_mode,
         max_concurrent_generations,
         auto_max_concurrent_generations,
         memory_budget_mode,
         normalized_memory_budget_utilization,
         memory_budget_overhead_bytes
       ) do
      base_args ++
        [
          "--generation-mode",
          to_string(generation_mode),
          "--max-concurrent-generations",
          to_string(max_concurrent_generations),
          "--auto-max-concurrent-generations",
          Integer.to_string(auto_max_concurrent_generations),
          "--memory-budget-mode",
          to_string(memory_budget_mode),
          "--memory-budget-utilization",
          :erlang.float_to_binary(normalized_memory_budget_utilization, [:compact, decimals: 6]),
          "--memory-budget-overhead-bytes",
          Integer.to_string(memory_budget_overhead_bytes)
        ]
    else
      base_args
    end
  end

  defp start_worker_port(executable, socket_path, backend, log_path, opts) do
    cli_args =
      worker_cli_args(
        Keyword.merge(opts,
          socket_path: socket_path,
          backend: backend,
          log_path: log_path
        )
      )

    args = Enum.map(cli_args, &String.to_charlist/1)

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        {:line, 4096},
        args: args
      ])

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) and pid >= 0 -> pid
        _other -> nil
      end

    {:ok, port, os_pid}
  end

  defp normalize_memory_budget_utilization(value) when is_float(value), do: value
  defp normalize_memory_budget_utilization(value) when is_integer(value), do: value / 1

  defp normalize_memory_budget_utilization(value) do
    raise ArgumentError,
          "memory_budget_utilization must be an integer or float, got: #{inspect(value)}"
  end

  defp extended_generation_memory_flags?(
         generation_mode,
         max_concurrent_generations,
         auto_max_concurrent_generations,
         memory_budget_mode,
         memory_budget_utilization,
         memory_budget_overhead_bytes
       ) do
    generation_mode != @default_generation_mode or
      max_concurrent_generations != @default_max_concurrent_generations or
      auto_max_concurrent_generations != @default_auto_max_concurrent_generations or
      memory_budget_mode != @default_memory_budget_mode or
      memory_budget_utilization != @default_memory_budget_utilization or
      memory_budget_overhead_bytes != @default_memory_budget_overhead_bytes
  end

  defp wait_for_worker_ready(socket_path, port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_worker_ready(socket_path, port, deadline)
  end

  defp do_wait_for_worker_ready(socket_path, port, deadline) do
    case poll_port(port) do
      {:exit_status, status} ->
        {:error, {:worker_exited, status}}

      :ignore ->
        do_wait_for_worker_ready(socket_path, port, deadline)

      :none ->
        remaining_ms = deadline - System.monotonic_time(:millisecond)

        if remaining_ms <= 0 do
          {:error, :worker_ready_timeout}
        else
          try_connect_and_check(socket_path, port, deadline)
        end
    end
  end

  defp try_connect_and_check(socket_path, port, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    case connect_worker_socket(socket_path) do
      {:ok, channel} ->
        check_connected_worker(channel, socket_path, port, deadline, remaining_ms)

      {:error, _reason} ->
        retry_wait_for_worker_ready(socket_path, port, deadline)
    end
  end

  defp check_connected_worker(channel, socket_path, port, deadline, remaining_ms) do
    timeout_ms = min(remaining_ms, @rpc_timeout_ms)

    case WorkerRuntimeService.Stub.get_status(
           channel,
           %WorkerStatusRequest{},
           timeout: timeout_ms
         ) do
      {:ok, status} ->
        classify_connected_worker_status(channel, status)

      {:error, _reason} ->
        _ = disconnect_channel(channel)
        retry_wait_for_worker_ready(socket_path, port, deadline)
    end
  end

  defp classify_connected_worker_status(channel, status) do
    case classify_worker_status(status) do
      :ready ->
        {:ok, channel}

      {:error, _reason} = err ->
        _ = disconnect_channel(channel)
        err
    end
  end

  defp retry_wait_for_worker_ready(socket_path, port, deadline) do
    Process.sleep(@poll_interval_ms)
    do_wait_for_worker_ready(socket_path, port, deadline)
  end

  @doc false
  @spec connect_worker_socket(String.t()) :: {:ok, Channel.t()} | {:error, term()}
  def connect_worker_socket(socket_path) when is_binary(socket_path) do
    %Channel{
      host: {:local, socket_path},
      port: 0,
      scheme: "unix",
      cred: nil,
      ref: make_ref(),
      adapter: GRPC.Client.Adapters.Gun,
      codec: GRPC.Codec.Proto,
      interceptors: [],
      compressor: nil,
      accepted_compressors: [],
      headers: []
    }
    |> GRPC.Client.Adapters.Gun.connect([])
  end

  # Classify worker health from GetStatus response.
  #
  # Proto3 default values: ready defaults to false, health_code defaults
  # to "".  A worker that hasn't set health fields explicitly (e.g. a
  # legacy or pre-health-check worker) will have ready=false + health_code="".
  # We treat that as "not yet declared unhealthy" (indeterminate) and fall
  # through to :ready, letting the normal readiness poll continue.
  #
  # Only ready=false WITH a non-empty health_code is a definitive "unhealthy"
  # declaration that triggers fail-fast.
  defp classify_worker_status(%{ready: false, health_code: code, health_message: message})
       when is_binary(code) and code != "" do
    {:error, {:worker_unhealthy, code, message || ""}}
  end

  defp classify_worker_status(_status), do: :ready

  defp poll_port(port) do
    receive do
      {^port, {:exit_status, status}} -> {:exit_status, status}
      {^port, {:data, _data}} -> :ignore
    after
      0 -> :none
    end
  end

  defp load_model_rpc(channel, %ModelRef{} = model_ref, model_path, timeout_ms) do
    case WorkerRuntimeService.Stub.load_model(
           channel,
           %LoadModelRequest{
             model_id: model_ref.model_id,
             version: model_ref.version,
             model_path: model_path
           },
           timeout: timeout_ms
         ) do
      {:ok, %{ok: true}} ->
        :ok

      {:ok, %{ok: false, message: message}} ->
        {code, detail} = parse_ack_failure(message)
        {:error, {:worker_load_failed, code, detail}}

      {:error, reason} ->
        {:error, normalize_load_rpc_error(reason)}
    end
  end

  defp unload_model_rpc(channel, %ModelRef{} = model_ref) do
    case WorkerRuntimeService.Stub.unload_model(
           channel,
           %UnloadModelRequest{model_id: model_ref.model_id, version: model_ref.version},
           timeout: @rpc_timeout_ms
         ) do
      {:ok, %{ok: true}} -> :ok
      {:ok, %{ok: false, message: message}} -> {:error, {:worker_unload_failed, message}}
      {:error, reason} -> {:error, normalize_rpc_error(reason)}
    end
  end

  defp cancel_rpc(channel, request_id, controller_session_id) do
    case WorkerRuntimeService.Stub.cancel(
           channel,
           %CancelInferenceRequest{
             request_id: request_id,
             controller_session_id: controller_session_id || ""
           },
           timeout: @rpc_timeout_ms
         ) do
      {:ok, %{ok: true}} -> :ok
      {:ok, %{ok: false, message: message}} -> {:error, {:worker_cancel_failed, message}}
      {:error, reason} -> {:error, normalize_rpc_error(reason)}
    end
  end

  defp safe_stream_generation(channel, owner, generation_ref, request) do
    try do
      stream_generation(channel, owner, generation_ref, request)
    catch
      kind, reason ->
        send(
          owner,
          {:runtime_adapter_done, generation_ref, {:generation_task_failed, kind, reason}}
        )
    end
  end

  defp stream_generation(channel, owner, generation_ref, request) do
    case WorkerRuntimeService.Stub.generate(channel, request, timeout: :infinity) do
      {:ok, stream} ->
        stream_result =
          Enum.reduce_while(stream, :open, fn item, stream_result ->
            handle_stream_item(item, stream_result, owner, generation_ref)
          end)

        emit_stream_done(owner, generation_ref, stream_result)

      {:error, reason} ->
        handle_stream_open_failure(reason, owner, generation_ref)
    end
  end

  defp handle_stream_item({:ok, proto_event}, stream_result, owner, generation_ref) do
    case InferenceEventMapper.from_proto(proto_event) do
      {:ok, event} ->
        send(owner, {:runtime_adapter_event, generation_ref, event})

        if InferenceEvent.terminal?(event) do
          {:halt, :terminal_sent}
        else
          {:cont, stream_result}
        end

      {:error, reason} ->
        emit_runtime_failure(
          owner,
          generation_ref,
          "runtime_invalid_event",
          "worker emitted an invalid event: #{inspect(reason)}"
        )

        {:halt, :terminal_sent}
    end
  end

  defp handle_stream_item(
         {:error, _reason},
         :terminal_sent = stream_result,
         _owner,
         _generation_ref
       ) do
    {:halt, stream_result}
  end

  defp handle_stream_item({:error, reason}, _stream_result, owner, generation_ref) do
    cond do
      worker_unavailable_error?(reason) ->
        {:halt, {:done, :worker_unavailable}}

      stream_cancelled_error?(reason) ->
        {:halt, :open}

      true ->
        emit_runtime_failure(
          owner,
          generation_ref,
          "runtime_stream_error",
          "worker stream failed: #{format_rpc_error(reason)}"
        )

        {:halt, :terminal_sent}
    end
  end

  defp handle_stream_open_failure(reason, owner, generation_ref) do
    cond do
      worker_unavailable_error?(reason) ->
        send(owner, {:runtime_adapter_done, generation_ref, :worker_unavailable})

      stream_cancelled_error?(reason) ->
        send(owner, {:runtime_adapter_done, generation_ref})

      true ->
        emit_runtime_failure(
          owner,
          generation_ref,
          "runtime_stream_error",
          "worker stream failed: #{format_rpc_error(reason)}"
        )

        send(owner, {:runtime_adapter_done, generation_ref})
    end
  end

  defp emit_stream_done(_owner, _generation_ref, :terminal_sent), do: :ok

  defp emit_stream_done(owner, generation_ref, :open),
    do: send(owner, {:runtime_adapter_done, generation_ref})

  defp emit_stream_done(owner, generation_ref, {:done, reason}) do
    send(owner, {:runtime_adapter_done, generation_ref, reason})
  end

  defp emit_runtime_failure(owner, generation_ref, code, message) do
    send(
      owner,
      {:runtime_adapter_event, generation_ref, InferenceEvent.failed(code, message, false)}
    )
  end

  defp stop_runtime(port, nil, timeout_ms) do
    if port_open?(port) do
      case wait_for_port_exit(port, timeout_ms) do
        {:ok, _status} -> :ok
        {:error, :timeout} -> {:error, :worker_shutdown_timeout}
      end
    else
      :ok
    end
  end

  defp stop_runtime(port, os_pid, timeout_ms) do
    if port_open?(port) do
      stop_runtime_with_escalation(port, os_pid, timeout_ms)
    else
      :ok
    end
  end

  # Attempt graceful SIGTERM, then escalate to tree-wide SIGKILL.
  # The tree-kill is defense-in-depth against intermediate launchers
  # (e.g. `uv run`) that swallow signals without forwarding to children.
  defp stop_runtime_with_escalation(port, os_pid, timeout_ms) do
    send_signal(os_pid, "-TERM")

    case wait_for_port_exit(port, timeout_ms) do
      {:ok, _status} ->
        :ok

      {:error, :timeout} ->
        kill_process_tree(os_pid)

        case wait_for_port_exit(port, timeout_ms) do
          {:ok, _status} -> :ok
          {:error, :timeout} -> {:error, :worker_shutdown_timeout}
        end
    end
  end

  defp wait_for_port_exit(port, timeout_ms) do
    receive do
      {^port, {:exit_status, status}} -> {:ok, status}
      {^port, {:data, _data}} -> wait_for_port_exit(port, timeout_ms)
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp send_signal(os_pid, signal) when is_integer(os_pid) and os_pid >= 0 do
    case System.cmd("kill", [signal, Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _exit_status} -> :ok
    end
  end

  # Recursively kill a process tree bottom-up (children first, then parent)
  # using SIGKILL. This guards against intermediate launcher processes
  # (e.g. `uv run`) that may not forward signals to their children.
  defp kill_process_tree(os_pid) when is_integer(os_pid) and os_pid >= 0 do
    {children_output, _} =
      System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true)

    children_output
    |> String.trim()
    |> String.split("\n", trim: true)
    |> Enum.each(fn child_pid_str ->
      case Integer.parse(child_pid_str) do
        {child_pid, _} -> kill_process_tree(child_pid)
        :error -> :ok
      end
    end)

    send_signal(os_pid, "-KILL")
  end

  defp kill_process_tree(_), do: :ok

  defp port_open?(port) do
    not is_nil(Port.info(port))
  end

  defp maybe_kill_task(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end
  end

  defp cleanup_generation_tasks(generations) do
    Enum.each(generations, fn {_generation_ref, %{pid: pid}} ->
      maybe_kill_task(pid)
    end)
  end

  defp cleanup_failed_runtime(port, os_pid, channel, socket_path, shutdown_timeout_ms) do
    _ = stop_runtime(port, os_pid, shutdown_timeout_ms)
    _ = disconnect_channel(channel)
    _ = cleanup_socket(socket_path)
    :ok
  end

  defp disconnect_channel(nil), do: :ok

  defp disconnect_channel(%Channel{host: {:local, _path}, adapter: adapter} = channel) do
    case adapter.disconnect(channel) do
      {:ok, _channel} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp disconnect_channel(channel) do
    case GRPC.Stub.disconnect(channel) do
      {:ok, _channel} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp pick_unload_result(_rpc_result, {:error, reason}, _socket_result), do: {:error, reason}
  defp pick_unload_result(_rpc_result, :ok, {:error, reason}), do: {:error, reason}
  defp pick_unload_result({:error, reason}, :ok, :ok), do: {:error, reason}
  defp pick_unload_result(:ok, :ok, :ok), do: :ok

  # Load-specific RPC error normalization: preserves deadline_exceeded as a
  # distinct reason so ModelLoadFailure classifies it as TIMEOUT (504), not
  # RUNTIME_UNAVAILABLE (503). grpc-elixir may surface statuses as atoms or
  # canonical integer codes depending on the failure path.
  defp normalize_load_rpc_error(%RPCError{status: status}) when status in [:deadline_exceeded, 4],
    do: :deadline_exceeded

  defp normalize_load_rpc_error(error), do: normalize_rpc_error(error)

  defp worker_unavailable_error?(reason), do: normalize_rpc_error(reason) == :worker_unavailable
  defp stream_cancelled_error?(reason), do: normalize_rpc_error(reason) == :rpc_cancelled

  defp normalize_rpc_error(%RPCError{status: status}), do: normalize_rpc_status(status)
  defp normalize_rpc_error(other), do: {:rpc_error, inspect(other)}

  # Parses "code: detail" format from worker Ack.message into {code, detail}.
  # Falls back to {"worker_load_failed", raw_message} for malformed messages.
  defp parse_ack_failure(message) when is_binary(message) do
    case String.split(message, ":", parts: 2) do
      [code_part, detail_part] ->
        code = String.trim(code_part)
        detail = String.trim(detail_part)

        if code != "" and Regex.match?(~r/^[a-z0-9_]+$/, code) do
          {code, detail}
        else
          {"worker_load_failed", String.trim(message)}
        end

      _ ->
        {"worker_load_failed", String.trim(message)}
    end
  end

  defp parse_ack_failure(_), do: {"worker_load_failed", ""}

  defp normalize_rpc_status(status) when status in [:unavailable, :deadline_exceeded, 14, 4] do
    :worker_unavailable
  end

  defp normalize_rpc_status(status) when status in [:cancelled, 1], do: :rpc_cancelled

  defp normalize_rpc_status(status), do: {:rpc_error, status}

  defp format_rpc_error(%RPCError{status: status, message: message}) do
    "#{status}: #{message}"
  end

  defp format_rpc_error(other), do: inspect(other)

  # -- Telemetry helpers -----------------------------------------------------

  defp emit_runtime_start(event, metadata) do
    :telemetry.execute(event, %{system_time: System.system_time()}, metadata)
  end

  defp emit_runtime_stop(event, duration_ms, metadata) do
    :telemetry.execute(event, %{duration_ms: duration_ms}, metadata)
  end

  defp emit_runtime_exception(event, duration_ms, metadata) do
    :telemetry.execute(event, %{duration_ms: duration_ms}, metadata)
  end
end
