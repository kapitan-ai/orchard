defmodule Orchard.Node.Status do
  @moduledoc """
  In-memory node-runtime status tracker for the M1 gRPC boundary.
  """

  use GenServer

  alias Orchard.Cluster.V1.{
    Ack,
    EnsureModelLoadedRequest,
    EnsureModelLoadedResponse,
    ModelRef,
    StatusResponse,
    UnloadModelRequest
  }

  @type state :: %{
          loaded_models: %{optional({String.t(), String.t()}) => ModelRef.t()},
          active_request_ids: MapSet.t(String.t())
        }

  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec current() :: StatusResponse.t()
  def current do
    GenServer.call(__MODULE__, :current)
  end

  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @spec ensure_model_loaded(EnsureModelLoadedRequest.t()) :: EnsureModelLoadedResponse.t()
  def ensure_model_loaded(%EnsureModelLoadedRequest{} = request) do
    GenServer.call(__MODULE__, {:ensure_model_loaded, request})
  end

  @spec unload_model(UnloadModelRequest.t()) :: Ack.t()
  def unload_model(%UnloadModelRequest{} = request) do
    GenServer.call(__MODULE__, {:unload_model, request})
  end

  @spec begin_request(String.t()) :: :ok
  def begin_request(request_id) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:begin_request, request_id})
  end

  @spec finish_request(String.t()) :: :ok
  def finish_request(request_id) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:finish_request, request_id})
  end

  @spec cancel_request(String.t(), String.t() | nil) :: Ack.t()
  def cancel_request(request_id, controller_session_id \\ nil) when is_binary(request_id) do
    GenServer.call(__MODULE__, {:cancel_request, request_id, controller_session_id})
  end

  @impl true
  def init(_init_arg) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, status_response(state), state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, initial_state()}
  end

  def handle_call({:ensure_model_loaded, %EnsureModelLoadedRequest{} = request}, _from, state) do
    key = model_key(request.model_id, request.version)
    already_loaded = Map.has_key?(state.loaded_models, key)

    loaded_models =
      Map.put(state.loaded_models, key, %ModelRef{
        model_id: request.model_id,
        version: request.version
      })

    reply = %EnsureModelLoadedResponse{
      already_loaded: already_loaded,
      placement_state: :PLACEMENT_STATE_LOADED
    }

    {:reply, reply, %{state | loaded_models: loaded_models}}
  end

  def handle_call({:unload_model, %UnloadModelRequest{} = request}, _from, state) do
    key = model_key(request.model_id, request.version)
    loaded_models = Map.delete(state.loaded_models, key)

    {:reply, %Ack{ok: true, message: "unload accepted"}, %{state | loaded_models: loaded_models}}
  end

  def handle_call({:begin_request, request_id}, _from, state) do
    active_request_ids = MapSet.put(state.active_request_ids, request_id)
    {:reply, :ok, %{state | active_request_ids: active_request_ids}}
  end

  def handle_call({:finish_request, request_id}, _from, state) do
    active_request_ids = MapSet.delete(state.active_request_ids, request_id)
    {:reply, :ok, %{state | active_request_ids: active_request_ids}}
  end

  def handle_call({:cancel_request, request_id, _controller_session_id}, _from, state) do
    active_request_ids = MapSet.delete(state.active_request_ids, request_id)

    {:reply, %Ack{ok: true, message: "cancel accepted"},
     %{state | active_request_ids: active_request_ids}}
  end

  defp initial_state do
    %{loaded_models: %{}, active_request_ids: MapSet.new()}
  end

  defp status_response(state) do
    %StatusResponse{
      worker_state: worker_state(state),
      loaded_models: loaded_models(state),
      active_request_count: MapSet.size(state.active_request_ids)
    }
  end

  defp worker_state(%{active_request_ids: active_request_ids}) do
    if MapSet.size(active_request_ids) > 0 do
      :WORKER_STATE_BUSY
    else
      :WORKER_STATE_IDLE
    end
  end

  defp loaded_models(%{loaded_models: loaded_models}) do
    loaded_models
    |> Map.values()
    |> Enum.sort_by(&{&1.model_id, &1.version})
  end

  defp model_key(model_id, version), do: {model_id, version}
end
