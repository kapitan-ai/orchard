defmodule Orchard.Metrics.Bootstrap do
  @moduledoc false
  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{supervisor: nil, opts: opts}, {:continue, :start_metrics}}
  end

  @impl true
  def handle_continue(:start_metrics, state) do
    case start_metrics(state.opts) do
      {:ok, pid} ->
        {:noreply, %{state | supervisor: pid}}

      {:error, reason} ->
        Logger.warning("Metrics subsystem unavailable: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{supervisor: pid} = state) do
    Logger.warning("Metrics subsystem stopped: #{inspect(reason)}")
    {:noreply, %{state | supervisor: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_metrics(opts) do
    case Orchard.Metrics.Supervisor.start_link(opts) do
      {:ok, pid} when is_pid(pid) -> {:ok, pid}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_start_result, other}}
    end
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
