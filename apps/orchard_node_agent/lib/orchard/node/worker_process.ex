defmodule Orchard.Node.WorkerProcess do
  @moduledoc """
  Per-model runtime owner that talks to the configured runtime adapter.
  """

  use GenServer

  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.InferenceEvent
  alias Orchard.Node
  alias Orchard.Node.RuntimeAdapter

  require Logger

  @type state :: %{
          adapter: module(),
          adapter_state: term(),
          loaded?: boolean(),
          manager: pid(),
          model_ref: ModelRef.t(),
          port_log_buffer: binary(),
          requests: %{optional(String.t()) => %{generation_ref: reference(), subscriber: pid()}},
          worker_log_path: String.t() | nil,
          worker_model: String.t(),
          worker_socket_path: String.t() | nil
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec ensure_loaded(pid(), EnsureModelLoadedRequest.t(), keyword()) ::
          :loaded | :already_loaded | {:error, term()}
  def ensure_loaded(pid, %EnsureModelLoadedRequest{} = request, opts \\ []) do
    call_timeout = Keyword.get(opts, :call_timeout, :infinity)
    load_timeout_ms = Keyword.get(opts, :load_timeout_ms, Node.worker_load_timeout_ms())
    GenServer.call(pid, {:ensure_loaded, request, load_timeout_ms}, call_timeout)
  end

  @spec unload(pid(), keyword()) :: :ok | {:error, term()}
  def unload(pid, opts \\ []) do
    GenServer.call(pid, {:unload, opts})
  end

  @spec start_request(pid(), String.t(), ExecuteInferenceRequest.t(), keyword()) ::
          :ok | {:error, term()}
  def start_request(pid, request_id, %ExecuteInferenceRequest{} = request, opts) do
    GenServer.call(pid, {:start_request, request_id, request, opts})
  end

  @spec cancel_request(pid(), String.t()) :: :ok | {:error, term()}
  def cancel_request(pid, request_id) when is_binary(request_id) do
    GenServer.call(pid, {:cancel_request, request_id})
  end

  @doc """
  Returns combined worker status: local process state + adapter health.

  Returns `{:ok, status_map}` or `{:error, reason}`.
  Safe to call from ModelManager — never raises or crashes.
  """
  @spec status(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(pid, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(pid, :status, timeout)
  catch
    :exit, reason -> {:error, {:worker_exit, reason}}
  end

  @impl true
  def init(opts) do
    model_ref = Keyword.fetch!(opts, :model_ref)
    manager = Keyword.fetch!(opts, :manager)

    worker_model = "#{model_ref.model_id}@#{model_ref.version}"

    {:ok,
     %{
       adapter: RuntimeAdapter.impl(),
       adapter_state: nil,
       loaded?: false,
       manager: manager,
       model_ref: model_ref,
       port_log_buffer: <<>>,
       requests: %{},
       worker_log_path: Node.worker_log_path(model_ref),
       worker_model: worker_model,
       worker_socket_path: Node.worker_socket_path(model_ref)
     }}
  end

  @impl true
  def handle_call(
        {:ensure_loaded, %EnsureModelLoadedRequest{}, _load_timeout_ms},
        _from,
        %{loaded?: true} = state
      ) do
    {:reply, :already_loaded, state}
  end

  def handle_call({:ensure_loaded, %EnsureModelLoadedRequest{}, load_timeout_ms}, _from, state) do
    case state.adapter.load_model(state.model_ref,
           owner: self(),
           load_timeout_ms: load_timeout_ms
         ) do
      {:ok, adapter_state} ->
        {:reply, :loaded, %{state | loaded?: true, adapter_state: adapter_state}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unload, opts}, _from, state) do
    force? = Keyword.get(opts, :force, false)

    if map_size(state.requests) > 0 and not force? do
      {:reply, {:error, :active_requests}, state}
    else
      state = maybe_cancel_requests(state, force?)

      case state.adapter.unload_model(state.adapter_state, opts) do
        :ok ->
          {:reply, :ok, %{state | adapter_state: nil, loaded?: false, requests: %{}}}

        {:error, reason} ->
          {:reply, {:error, reason}, %{state | adapter_state: nil, loaded?: false, requests: %{}}}
      end
    end
  end

  def handle_call(
        {:start_request, request_id, %ExecuteInferenceRequest{} = request, opts},
        _from,
        state
      ) do
    subscriber = Keyword.fetch!(opts, :subscriber)

    cond do
      not state.loaded? ->
        {:reply, {:error, :model_not_loaded}, state}

      Map.has_key?(state.requests, request_id) ->
        {:reply, {:error, :already_running}, state}

      request_capacity_reached?(state) ->
        {:reply, {:error, :model_busy}, state}

      true ->
        start_generation(request_id, request, subscriber, state)
    end
  end

  def handle_call(:status, _from, state) do
    adapter_health =
      if state.loaded? and state.adapter_state != nil do
        case state.adapter.get_status(state.adapter_state, timeout_ms: 1_000) do
          {:ok, health} ->
            health

          {:error, _reason} ->
            %{
              ready: false,
              health_code: "worker_status_error",
              health_message: "worker status request failed"
            }
        end
      else
        %{ready: false, health_code: "not_loaded", health_message: "model not yet loaded"}
      end

    status = %{
      model_ref: state.model_ref,
      loaded?: state.loaded?,
      active_request_count: map_size(state.requests),
      ready: adapter_health[:ready] || false,
      health_code: adapter_health[:health_code] || "",
      health_message: adapter_health[:health_message] || "",
      memory_budget: adapter_health[:memory_budget]
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call({:cancel_request, request_id}, _from, state) do
    case Map.fetch(state.requests, request_id) do
      :error ->
        {:reply, :ok, state}

      {:ok, %{generation_ref: generation_ref}} ->
        case state.adapter.cancel_generation(state.adapter_state, generation_ref,
               request_id: request_id
             ) do
          {:ok, adapter_state} ->
            {:reply, :ok, %{state | adapter_state: adapter_state}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_info({:runtime_adapter_event, generation_ref, %InferenceEvent{} = event}, state) do
    case fetch_request_by_generation_ref(state.requests, generation_ref) do
      {:ok, {request_id, %{subscriber: subscriber}}} ->
        send(subscriber, {:node_runtime_event, request_id, event})

        if InferenceEvent.terminal?(event) do
          next_state = finish_generation(state, request_id, generation_ref)
          notify_request_finished(next_state.manager, request_id)
          {:noreply, next_state}
        else
          {:noreply, state}
        end

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:runtime_adapter_done, _generation_ref, :worker_unavailable}, state) do
    {:stop, :runtime_worker_unavailable, state}
  end

  def handle_info(
        {:runtime_adapter_done, generation_ref, {:generation_task_failed, _kind, _reason}},
        state
      ) do
    case fetch_request_by_generation_ref(state.requests, generation_ref) do
      {:ok, {request_id, %{subscriber: subscriber}}} ->
        failed_event =
          InferenceEvent.failed(
            "runtime_generation_task_failed",
            "runtime generation task failed unexpectedly",
            false
          )

        send(subscriber, {:node_runtime_event, request_id, failed_event})
        next_state = finish_generation(state, request_id, generation_ref)
        notify_request_finished(next_state.manager, request_id)
        {:noreply, next_state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:runtime_adapter_done, generation_ref, _reason}, state) do
    handle_info({:runtime_adapter_done, generation_ref}, state)
  end

  def handle_info({:runtime_adapter_done, generation_ref}, state) do
    case fetch_request_by_generation_ref(state.requests, generation_ref) do
      {:ok, {request_id, %{subscriber: subscriber}}} ->
        failed_event =
          InferenceEvent.failed(
            "runtime_stream_ended",
            "runtime stream ended without terminal event",
            false
          )

        send(subscriber, {:node_runtime_event, request_id, failed_event})
        next_state = finish_generation(state, request_id, generation_ref)
        notify_request_finished(next_state.manager, request_id)
        {:noreply, next_state}

      :error ->
        {:noreply, state}
    end
  end

  # --- Port data: line-buffered Logger forwarding ---
  # With {:line, N} mode, complete lines arrive as {:eol, line} and
  # buffer-overflow fragments as {:noeol, partial}.

  def handle_info({port, {:data, {:eol, line}}}, %{adapter_state: %{port: port}} = state) do
    full_line = state.port_log_buffer <> line
    log_worker_line(full_line, state)
    {:noreply, %{state | port_log_buffer: <<>>}}
  end

  def handle_info({port, {:data, {:noeol, partial}}}, %{adapter_state: %{port: port}} = state) do
    {:noreply, %{state | port_log_buffer: state.port_log_buffer <> partial}}
  end

  def handle_info({port, {:exit_status, _status}}, %{adapter_state: %{port: port}} = state) do
    {:stop, :runtime_worker_exited, state}
  end

  # Port data from a non-active port (e.g. stale port after adapter swap)
  def handle_info({port, {:data, _data}}, state) when is_port(port) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, _status}}, state) when is_port(port) do
    {:noreply, state}
  end

  def handle_info({:gun_down, _conn_pid, _protocol, _reason, _streams}, state) do
    {:stop, :runtime_worker_exited, state}
  end

  @impl true
  def terminate(reason, state) do
    # Flush any trailing partial line from the port buffer.
    flush_port_log_buffer(state)

    if is_nil(state.adapter_state) do
      :ok
    else
      # When the worker is already unavailable, skip the unload RPC to avoid a
      # wasted timeout against a dead process. Local cleanup (kill tasks,
      # disconnect channel, remove socket) still runs inside the adapter.
      opts = [force: true, skip_rpc: reason in [:runtime_worker_exited, :runtime_worker_unavailable]]
      _ = state.adapter.unload_model(state.adapter_state, opts)
      :ok
    end
  end

  defp request_capacity_reached?(state) do
    map_size(state.requests) >= Node.effective_worker_request_limit()
  end

  defp start_generation(request_id, request, subscriber, state) do
    case state.adapter.start_generation(state.adapter_state, request,
           owner: self(),
           request_id: request_id
         ) do
      {:ok, generation_ref, adapter_state} ->
        requests =
          Map.put(state.requests, request_id, %{
            generation_ref: generation_ref,
            subscriber: subscriber
          })

        {:reply, :ok, %{state | adapter_state: adapter_state, requests: requests}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp finish_generation(state, request_id, generation_ref) do
    adapter_state =
      state.adapter.finish_generation(
        state.adapter_state,
        generation_ref,
        request_id: request_id
      )

    %{state | adapter_state: adapter_state, requests: Map.delete(state.requests, request_id)}
  end

  defp maybe_cancel_requests(state, false), do: state

  defp maybe_cancel_requests(state, true) do
    adapter_state =
      Enum.reduce(state.requests, state.adapter_state, fn {request_id, request_state},
                                                          adapter_state ->
        case state.adapter.cancel_generation(adapter_state, request_state.generation_ref,
               request_id: request_id
             ) do
          {:ok, next_adapter_state} ->
            next_adapter_state

          {:error, _reason} ->
            adapter_state
        end
      end)

    %{state | adapter_state: adapter_state}
  end

  defp fetch_request_by_generation_ref(requests, generation_ref) do
    Enum.find_value(requests, :error, fn {request_id, request_state} ->
      if request_state.generation_ref == generation_ref do
        {:ok, {request_id, request_state}}
      end
    end)
  end

  defp notify_request_finished(manager, request_id) do
    send(manager, {:worker_request_finished, self(), request_id})
  end

  # -- Port log forwarding helpers -------------------------------------------

  @log_level_map %{
    "DEBUG" => :debug,
    "INFO" => :info,
    "WARNING" => :warning,
    "ERROR" => :error,
    "CRITICAL" => :error
  }

  defp log_worker_line(<<>>, _state), do: :ok

  defp log_worker_line(line, state) do
    line = String.trim_trailing(line, "\r")
    if line == "", do: :ok, else: do_log_worker_line(line, state)
  end

  defp do_log_worker_line(line, state) do
    {level, _msg} = parse_log_level(line)

    metadata = [
      worker_model: state.worker_model,
      worker_socket: state.worker_socket_path,
      worker_log_path: state.worker_log_path
    ]

    Logger.log(level, line, metadata)
  end

  defp parse_log_level("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [level_str, _remainder] ->
        level = Map.get(@log_level_map, level_str, :info)
        {level, rest}

      _no_close_bracket ->
        {:info, rest}
    end
  end

  defp parse_log_level(line), do: {:info, line}

  defp flush_port_log_buffer(%{port_log_buffer: <<>>}), do: :ok

  defp flush_port_log_buffer(%{port_log_buffer: buffer} = state) do
    log_worker_line(buffer, state)
  end
end
