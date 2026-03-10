defmodule Orchard.Requests.RequestServer do
  @moduledoc """
  Per-request `:gen_statem` process that tracks the request lifecycle FSM.

  Each active request has one `RequestServer` process managed by
  `Orchard.Requests.Supervisor`. The process enforces legal state
  transitions per SPEC.md §3.6 and appends a durable request event
  on every transition.

  ## State vocabulary

      received → validated → admitted → queued → scheduled
        → dispatching → running → streaming → completed

      failure exits (from any non-terminal state):
        → failed | cancelled | timed_out | interrupted

  Terminal states (`completed`, `failed`, `cancelled`, `timed_out`,
  `interrupted`) are immutable — no further transitions are allowed.
  """

  @behaviour :gen_statem

  alias Orchard.Requests

  @terminal_states [:completed, :failed, :cancelled, :timed_out, :interrupted]

  @forward_transitions %{
    received: [:validated],
    validated: [:admitted, :scheduled],
    admitted: [:queued, :scheduled],
    queued: [:scheduled],
    scheduled: [:dispatching],
    dispatching: [:running],
    running: [:streaming, :completed],
    streaming: [:completed]
  }

  defstruct [:request_id, :public_id]

  @type t :: %__MODULE__{
          request_id: String.t(),
          public_id: String.t()
        }

  # -- Public API --

  @doc """
  Starts a request server under `Orchard.Requests.Supervisor`.

  ## Options

    * `:request_id` — DB request UUID (required)
    * `:public_id` — public-facing request ID (required)
    * `:initial_state` — starting FSM state (default: `:received`)
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    public_id = Keyword.fetch!(opts, :public_id)
    initial_state = Keyword.get(opts, :initial_state, :received)

    DynamicSupervisor.start_child(
      Orchard.Requests.Supervisor,
      {__MODULE__, {request_id, public_id, initial_state}}
    )
  end

  @doc false
  def child_spec({request_id, public_id, initial_state}) do
    %{
      id: {__MODULE__, request_id},
      start: {__MODULE__, :start_link, [{request_id, public_id, initial_state}]},
      restart: :temporary
    }
  end

  @doc false
  def start_link({request_id, public_id, initial_state}) do
    :gen_statem.start_link(
      {:via, Registry, {Orchard.Requests.Registry, request_id}},
      __MODULE__,
      {request_id, public_id, initial_state},
      []
    )
  end

  @doc """
  Requests a state transition.

  Returns `:ok` on success, or `{:error, reason}` if the transition
  is invalid or the request is already terminal.

  ## Options

    * `:payload` — optional event payload map
  """
  @spec transition(String.t(), atom(), keyword()) :: :ok | {:error, term()}
  def transition(request_id, new_state, opts \\ []) do
    payload = Keyword.get(opts, :payload, %{})

    case lookup(request_id) do
      {:ok, pid} ->
        :gen_statem.call(pid, {:transition, new_state, payload})

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the current FSM state for a request.
  """
  @spec get_state(String.t()) :: {:ok, atom()} | {:error, :not_found}
  def get_state(request_id) do
    case lookup(request_id) do
      {:ok, pid} -> {:ok, :gen_statem.call(pid, :get_state)}
      :error -> {:error, :not_found}
    end
  end

  defp lookup(request_id) do
    case Registry.lookup(Orchard.Requests.Registry, request_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  # -- gen_statem callbacks --

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init({request_id, public_id, initial_state}) do
    data = %__MODULE__{request_id: request_id, public_id: public_id}
    {:ok, initial_state, data}
  end

  @impl true
  def handle_event({:call, from}, :get_state, state, _data) do
    {:keep_state_and_data, [{:reply, from, state}]}
  end

  def handle_event({:call, from}, {:transition, new_state, payload}, current_state, data) do
    case check_transition(current_state, new_state) do
      :ok ->
        apply_transition(from, new_state, payload, data)

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  # Terminal state timeout — stop the process after replying
  def handle_event(:state_timeout, :stop, _state, _data) do
    {:stop, :normal}
  end

  defp check_transition(current_state, _new_state) when current_state in @terminal_states do
    {:error, :already_terminal}
  end

  defp check_transition(current_state, new_state) do
    if valid_transition?(current_state, new_state) do
      :ok
    else
      {:error, {:invalid_transition, current_state, new_state}}
    end
  end

  defp apply_transition(from, new_state, payload, data) do
    case persist_transition(data, new_state, payload) do
      :ok ->
        reply = [{:reply, from, :ok}]
        stop_action = if new_state in @terminal_states, do: [{:state_timeout, 0, :stop}], else: []
        {:next_state, new_state, data, reply ++ stop_action}

      {:error, _} = error ->
        {:keep_state_and_data, [{:reply, from, error}]}
    end
  end

  # -- Transition logic --

  defp valid_transition?(current_state, new_state) do
    # Terminal states can be reached from any non-terminal state
    if new_state in @terminal_states do
      current_state not in @terminal_states
    else
      new_state in Map.get(@forward_transitions, current_state, [])
    end
  end

  defp persist_transition(data, new_state, payload) do
    event_attrs = %{
      event_type: "state_transition",
      state: new_state,
      payload: Map.put(payload, :to_state, to_string(new_state))
    }

    case Requests.append_request_event(data.request_id, event_attrs) do
      {:ok, _event} -> :ok
      {:error, _} = error -> error
    end
  end
end
