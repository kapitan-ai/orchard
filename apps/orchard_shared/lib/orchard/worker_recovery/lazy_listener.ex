defmodule Orchard.WorkerRecovery.LazyListener do
  @moduledoc false

  require Logger

  @identity_retry_interval_ms 1_000
  @start_failure_intervals [1_000, 2_000, 4_000, 8_000, 16_000, 30_000]

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
           configuration_invalid_logged?: false,
           start_failure_streak: 0
         }}
      end

      @impl true
      def handle_info(:start_listener, state) do
        case LazyListener.start_server(&server_options/1, state) do
          :ok ->
            {:noreply, %{state | start_failure_streak: 0}}

          :configuration_invalid ->
            {:noreply, LazyListener.log_configuration_invalid_once(state)}

          retryable ->
            {:noreply, LazyListener.schedule_retry(state, retryable)}
        end
      end
    end
  end

  @type outcome :: :ok | :identity_unavailable | :listener_start_failed | :configuration_invalid

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
      {:error, _reason} -> :listener_start_failed
    end
  end

  @doc "Retries missing identity promptly and a failed listener start on capped backoff."
  @spec schedule_retry(map(), :identity_unavailable | :listener_start_failed) :: map()
  def schedule_retry(state, :identity_unavailable) do
    Process.send_after(self(), :start_listener, @identity_retry_interval_ms)
    %{state | start_failure_streak: 0}
  end

  def schedule_retry(state, :listener_start_failed) do
    streak = state.start_failure_streak
    Process.send_after(self(), :start_listener, start_failure_interval(streak))
    %{state | start_failure_streak: streak + 1}
  end

  @spec log_configuration_invalid_once(map()) :: map()
  def log_configuration_invalid_once(%{configuration_invalid_logged?: false} = state) do
    Logger.error("worker recovery control listener configuration invalid")
    %{state | configuration_invalid_logged?: true}
  end

  def log_configuration_invalid_once(state), do: state

  defp start_failure_interval(streak),
    do: Enum.at(@start_failure_intervals, min(streak, length(@start_failure_intervals) - 1))
end
