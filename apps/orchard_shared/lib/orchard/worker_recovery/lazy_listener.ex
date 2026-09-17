defmodule Orchard.WorkerRecovery.LazyListener do
  @moduledoc false

  require Logger

  defmacro __using__(_opts) do
    quote do
      use GenServer

      alias Orchard.WorkerRecovery.LazyListener

      @listener_retry_interval 1_000

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
         %{opts: opts, server_supervisor: server_supervisor, configuration_invalid_logged?: false}}
      end

      @impl true
      def handle_info(:start_listener, state) do
        case LazyListener.start_server(&server_options/1, state) do
          :ok ->
            {:noreply, state}

          :retry ->
            Process.send_after(self(), :start_listener, @listener_retry_interval)
            {:noreply, state}

          :configuration_invalid ->
            {:noreply, LazyListener.log_configuration_invalid_once(state)}
        end
      end
    end
  end

  @spec start_server((keyword() -> {:ok, keyword()} | {:error, atom()}), map()) ::
          :ok | :retry | :configuration_invalid
  def start_server(server_options, state) do
    case server_options.(state.opts) do
      {:ok, options} ->
        case DynamicSupervisor.start_child(
               state.server_supervisor,
               {GRPC.Server.Supervisor, options}
             ) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _reason} -> :configuration_invalid
        end

      {:error, :worker_recovery_control_identity_unavailable} ->
        :retry

      {:error, :worker_recovery_control_configuration_invalid} ->
        :configuration_invalid
    end
  end

  @spec log_configuration_invalid_once(map()) :: map()
  def log_configuration_invalid_once(%{configuration_invalid_logged?: false} = state) do
    Logger.error("worker recovery control listener configuration invalid")
    %{state | configuration_invalid_logged?: true}
  end

  def log_configuration_invalid_once(state), do: state
end
