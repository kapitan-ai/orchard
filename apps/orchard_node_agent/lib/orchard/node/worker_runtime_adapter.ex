defmodule Orchard.Node.WorkerRuntimeAdapter do
  @moduledoc """
  Runtime adapter that owns a Python worker subprocess speaking the internal
  worker-runtime gRPC contract over a Unix domain socket.
  """

  @behaviour Orchard.Node.RuntimeAdapter

  alias GRPC.RPCError

  alias Orchard.Cluster.V1.{
    CancelInferenceRequest,
    ExecuteInferenceRequest,
    InferenceEventMapper,
    ModelRef,
    UnloadModelRequest
  }

  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.Worker.V1.{LoadModelRequest, WorkerRuntimeService, WorkerStatusRequest}
  alias Orchard.PathUtils

  @poll_interval_ms 50
  @rpc_timeout_ms 1_000

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

    load_meta = %{
      model_id: model_ref.model_id,
      version: model_ref.version,
      backend: backend,
      worker_executable: executable,
      ready_timeout_ms: ready_timeout_ms,
      load_timeout_ms: load_timeout_ms,
      shutdown_timeout_ms: shutdown_timeout_ms,
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
        start_runtime(
          model_ref,
          resolved_model_path,
          resolved_executable,
          backend,
          socket_path,
          log_path,
          ready_timeout_ms,
          load_timeout_ms,
          shutdown_timeout_ms
        )
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
    :ok = cleanup_socket(state.socket_path)

    final_result = pick_result(unload_result, stop_result)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    case final_result do
      :ok ->
        emit_runtime_stop(
          [:orchard, :node, :worker_runtime, :unload, :stop],
          duration_ms,
          Map.merge(unload_meta, %{
            outcome: :unloaded,
            rpc_result: if(skip_rpc?, do: :skipped, else: :ok),
            stop_result: :ok
          })
        )

      {:error, reason} ->
        emit_runtime_exception(
          [:orchard, :node, :worker_runtime, :unload, :exception],
          duration_ms,
          Map.merge(unload_meta, %{
            reason: reason,
            rpc_result: unload_result,
            stop_result: stop_result
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
        stream_generation(state.channel, owner, generation_ref, request)
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

  defp start_runtime(
         model_ref,
         model_path,
         executable,
         backend,
         socket_path,
         log_path,
         ready_timeout_ms,
         load_timeout_ms,
         shutdown_timeout_ms
       ) do
    {:ok, port, os_pid} = start_worker_port(executable, socket_path, backend, log_path)

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

  defp start_worker_port(executable, socket_path, backend, log_path) do
    cli_args = ["--socket-path", socket_path, "--backend", backend, "--log-file", log_path]
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

    case GRPC.Stub.connect(socket_path) do
      {:ok, channel} ->
        timeout_ms = min(remaining_ms, @rpc_timeout_ms)

        case WorkerRuntimeService.Stub.get_status(
               channel,
               %WorkerStatusRequest{},
               timeout: timeout_ms
             ) do
          {:ok, status} ->
            case classify_worker_status(status) do
              :ready ->
                {:ok, channel}

              {:error, _reason} = err ->
                _ = disconnect_channel(channel)
                err
            end

          {:error, _reason} ->
            _ = disconnect_channel(channel)
            Process.sleep(@poll_interval_ms)
            do_wait_for_worker_ready(socket_path, port, deadline)
        end

      {:error, _reason} ->
        Process.sleep(@poll_interval_ms)
        do_wait_for_worker_ready(socket_path, port, deadline)
    end
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

  defp stream_generation(channel, owner, generation_ref, request) do
    case WorkerRuntimeService.Stub.generate(channel, request, timeout: :infinity) do
      {:ok, stream} ->
        terminal_sent? =
          Enum.reduce_while(stream, false, fn item, terminal_sent? ->
            handle_stream_item(item, terminal_sent?, owner, generation_ref)
          end)

        unless terminal_sent? do
          send(owner, {:runtime_adapter_done, generation_ref})
        end

      {:error, reason} ->
        handle_stream_open_failure(reason, owner, generation_ref)
    end
  end

  defp handle_stream_item({:ok, proto_event}, terminal_sent?, owner, generation_ref) do
    case InferenceEventMapper.from_proto(proto_event) do
      {:ok, event} ->
        send(owner, {:runtime_adapter_event, generation_ref, event})
        {:cont, terminal_sent? or InferenceEvent.terminal?(event)}

      {:error, reason} ->
        emit_runtime_failure(
          owner,
          generation_ref,
          "runtime_invalid_event",
          "worker emitted an invalid event: #{inspect(reason)}"
        )

        {:halt, true}
    end
  end

  defp handle_stream_item({:error, _reason}, true = terminal_sent?, _owner, _generation_ref) do
    {:halt, terminal_sent?}
  end

  defp handle_stream_item({:error, reason}, _terminal_sent?, owner, generation_ref) do
    if normalize_rpc_error(reason) == :worker_unavailable do
      {:halt, true}
    else
      emit_runtime_failure(
        owner,
        generation_ref,
        "runtime_stream_error",
        "worker stream failed: #{format_rpc_error(reason)}"
      )

      {:halt, true}
    end
  end

  defp handle_stream_open_failure(reason, owner, generation_ref) do
    unless normalize_rpc_error(reason) == :worker_unavailable do
      emit_runtime_failure(
        owner,
        generation_ref,
        "runtime_stream_error",
        "worker stream failed: #{format_rpc_error(reason)}"
      )

      send(owner, {:runtime_adapter_done, generation_ref})
    end
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

  defp disconnect_channel(channel) do
    case GRPC.Stub.disconnect(channel) do
      {:ok, _channel} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp pick_result(:ok, :ok), do: :ok
  defp pick_result({:error, reason}, _other), do: {:error, reason}
  defp pick_result(:ok, {:error, reason}), do: {:error, reason}

  # Load-specific RPC error normalization: preserves :deadline_exceeded as a
  # distinct reason so ModelLoadFailure classifies it as TIMEOUT (504), not
  # RUNTIME_UNAVAILABLE (503).  Other RPC paths (unload, cancel, stream)
  # intentionally coalesce deadline into :worker_unavailable.
  defp normalize_load_rpc_error(%RPCError{status: :deadline_exceeded}), do: :deadline_exceeded
  defp normalize_load_rpc_error(error), do: normalize_rpc_error(error)

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

  defp normalize_rpc_status(status)
       when status in [:unavailable, :cancelled, :deadline_exceeded] do
    :worker_unavailable
  end

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
