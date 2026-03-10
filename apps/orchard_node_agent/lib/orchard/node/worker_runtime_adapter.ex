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

  @poll_interval_ms 50
  @rpc_timeout_ms 1_000

  @type generation_entry :: %{pid: pid(), request_id: String.t()}

  @type state :: %{
          channel: GRPC.Channel.t(),
          executable: String.t(),
          generations: %{optional(reference()) => generation_entry()},
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

    shutdown_timeout_ms =
      Keyword.get(opts, :shutdown_timeout_ms, Node.worker_shutdown_timeout_ms())

    socket_path = Keyword.get(opts, :socket_path, Node.worker_socket_path(model_ref))
    models_root = Keyword.get(opts, :models_root, Node.models_root())

    with {:ok, resolved_model_path} <- resolve_model_path(model_ref, models_root),
         {:ok, resolved_executable} <- resolve_executable(executable),
         :ok <- ensure_socket_parent(socket_path),
         :ok <- cleanup_socket(socket_path) do
      start_runtime(
        model_ref,
        resolved_model_path,
        resolved_executable,
        backend,
        socket_path,
        ready_timeout_ms,
        shutdown_timeout_ms
      )
    end
  end

  @impl true
  def unload_model(nil, _opts), do: :ok

  def unload_model(%{} = state, opts) do
    shutdown_timeout_ms = Keyword.get(opts, :shutdown_timeout_ms, state.shutdown_timeout_ms)

    unload_result = unload_model_rpc(state.channel, state.model_ref)
    stop_result = stop_runtime(state.port, state.os_pid, shutdown_timeout_ms)

    cleanup_generation_tasks(state.generations)
    _ = disconnect_channel(state.channel)
    :ok = cleanup_socket(state.socket_path)

    pick_result(unload_result, stop_result)
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
         ready_timeout_ms,
         shutdown_timeout_ms
       ) do
    {:ok, port, os_pid} = start_worker_port(executable, socket_path, backend)

    case wait_for_worker_ready(socket_path, port, ready_timeout_ms) do
      {:ok, channel} ->
        case load_model_rpc(channel, model_ref, model_path, ready_timeout_ms) do
          :ok ->
            {:ok,
             %{
               channel: channel,
               executable: executable,
               generations: %{},
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
    model_path = Path.expand(Path.join([expanded_root, model_id, version]))

    if model_path == expanded_root or String.starts_with?(model_path, expanded_root <> "/") do
      {:ok, model_path}
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

  defp cleanup_socket(socket_path) do
    case File.rm(socket_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:socket_cleanup_failed, reason}}
    end
  end

  defp start_worker_port(executable, socket_path, backend) do
    args = Enum.map(["--socket-path", socket_path, "--backend", backend], &String.to_charlist/1)

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :hide,
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
          case GRPC.Stub.connect(socket_path) do
            {:ok, channel} ->
              timeout_ms = min(remaining_ms, @rpc_timeout_ms)

              case WorkerRuntimeService.Stub.get_status(
                     channel,
                     %WorkerStatusRequest{},
                     timeout: timeout_ms
                   ) do
                {:ok, _status} ->
                  {:ok, channel}

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
    end
  end

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
        {:error, {:worker_load_failed, message}}

      {:error, reason} ->
        {:error, normalize_rpc_error(reason)}
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
          Enum.reduce_while(stream, false, fn
            {:ok, proto_event}, terminal_sent? ->
              case InferenceEventMapper.from_proto(proto_event) do
                {:ok, event} ->
                  send(owner, {:runtime_adapter_event, generation_ref, event})
                  {:cont, terminal_sent? or InferenceEvent.terminal?(event)}

                {:error, reason} ->
                  send(
                    owner,
                    {:runtime_adapter_event, generation_ref,
                     InferenceEvent.failed(
                       "runtime_invalid_event",
                       "worker emitted an invalid event: #{inspect(reason)}",
                       false
                     )}
                  )

                  {:halt, true}
              end

            {:error, reason}, terminal_sent? ->
              cond do
                terminal_sent? ->
                  {:halt, terminal_sent?}

                normalize_rpc_error(reason) == :worker_unavailable ->
                  {:halt, true}

                true ->
                  send(
                    owner,
                    {:runtime_adapter_event, generation_ref,
                     InferenceEvent.failed(
                       "runtime_stream_error",
                       "worker stream failed: #{format_rpc_error(reason)}",
                       false
                     )}
                  )

                  {:halt, true}
              end
          end)

        unless terminal_sent? do
          send(owner, {:runtime_adapter_done, generation_ref})
        end

      {:error, reason} ->
        if normalize_rpc_error(reason) == :worker_unavailable do
          :ok
        else
          send(
            owner,
            {:runtime_adapter_event, generation_ref,
             InferenceEvent.failed(
               "runtime_stream_error",
               "worker stream failed: #{format_rpc_error(reason)}",
               false
             )}
          )

          send(owner, {:runtime_adapter_done, generation_ref})
        end
    end
  end

  defp stop_runtime(port, nil, timeout_ms) do
    cond do
      not port_open?(port) ->
        :ok

      true ->
        case wait_for_port_exit(port, timeout_ms) do
          {:ok, _status} -> :ok
          {:error, :timeout} -> {:error, :worker_shutdown_timeout}
        end
    end
  end

  defp stop_runtime(port, os_pid, timeout_ms) do
    if not port_open?(port) do
      :ok
    else
      send_signal(os_pid, "-TERM")

      case wait_for_port_exit(port, timeout_ms) do
        {:ok, _status} ->
          :ok

        {:error, :timeout} ->
          send_signal(os_pid, "-KILL")

          case wait_for_port_exit(port, timeout_ms) do
            {:ok, _status} -> :ok
            {:error, :timeout} -> {:error, :worker_shutdown_timeout}
          end
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

  defp normalize_rpc_error(%RPCError{status: status}), do: normalize_rpc_status(status)
  defp normalize_rpc_error(other), do: {:rpc_error, inspect(other)}

  defp normalize_rpc_status(status)
       when status in [:unavailable, :cancelled, :deadline_exceeded] do
    :worker_unavailable
  end

  defp normalize_rpc_status(status), do: {:rpc_error, status}

  defp format_rpc_error(%RPCError{status: status, message: message}) do
    "#{status}: #{message}"
  end

  defp format_rpc_error(other), do: inspect(other)
end
