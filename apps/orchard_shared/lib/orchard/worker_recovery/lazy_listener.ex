defmodule Orchard.WorkerRecovery.LazyListener do
  @moduledoc false

  require Logger

  @retry_interval_ms 1_000

  defmacro __using__(_opts) do
    quote do
      use GenServer

      alias Orchard.WorkerRecovery.LazyListener

      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker
        }
      end

      @impl true
      def init(opts) do
        {:ok, server_supervisor} = DynamicSupervisor.start_link(strategy: :one_for_one)
        send(self(), :start_listener)

        {:ok,
         %{
           opts: opts,
           server_supervisor: server_supervisor,
           logged_outcomes: %{}
         }}
      end

      @impl true
      def handle_info(:start_listener, state) do
        case LazyListener.start_server(&server_options/1, state) do
          :ok ->
            {:noreply, state}

          :configuration_invalid ->
            {:noreply, LazyListener.log_outcome_once(state, :configuration_invalid)}

          retryable ->
            LazyListener.schedule_retry()
            {:noreply, LazyListener.log_outcome_once(state, retryable)}
        end
      end
    end
  end

  @type retryable :: :identity_unavailable | {:start_failed, term()}
  @type outcome :: :ok | :configuration_invalid | retryable()

  @doc "Separates permanently invalid configuration from a start attempt worth retrying."
  @spec start_server((keyword() -> {:ok, keyword()} | {:error, atom()}), map()) :: outcome()
  def start_server(server_options, state) do
    case server_options.(state.opts) do
      {:ok, options} ->
        start_listener_child(state.server_supervisor, options)

      {:error, :worker_recovery_control_identity_unavailable} ->
        :identity_unavailable

      {:error, :worker_recovery_control_configuration_invalid} ->
        :configuration_invalid
    end
  end

  defp start_listener_child(server_supervisor, options) do
    case DynamicSupervisor.start_child(server_supervisor, {GRPC.Server.Supervisor, options}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:start_failed, reason}
    end
  end

  @doc """
  Re-arms the lazy listener attempt.

  SPEC.md §12.2 scopes the deterministic 1s/2s/4s/8s/16s/30s schedule to
  checkpoint persistence, so every recoverable listener outcome shares this one
  lazy interval instead of a second escalating table.
  """
  @spec schedule_retry() :: reference()
  def schedule_retry, do: Process.send_after(self(), :start_listener, @retry_interval_ms)

  @doc """
  Logs a listener outcome once, and again when a start failure carries a new reason.

  SPEC.md §12.2 refuses every placement while the recovery listener is down, so
  the operator must read the current cause rather than the first one. The
  throttle holds one entry per outcome kind, so an unbounded start failure
  reason cannot grow it.
  """
  @spec log_outcome_once(map(), outcome()) :: map()
  def log_outcome_once(state, outcome) do
    key = outcome_key(outcome)

    if Map.get(state.logged_outcomes, key) == outcome do
      state
    else
      Logger.error(outcome_message(outcome))
      %{state | logged_outcomes: Map.put(state.logged_outcomes, key, outcome)}
    end
  end

  defp outcome_key({:start_failed, _reason}), do: :start_failed
  defp outcome_key(outcome), do: outcome

  defp outcome_message({:start_failed, reason}),
    do: "worker recovery control listener start failed: #{inspect(reason)}"

  defp outcome_message(:identity_unavailable),
    do: "worker recovery control listener identity unavailable; retrying"

  defp outcome_message(:configuration_invalid),
    do: "worker recovery control listener configuration invalid"
end
