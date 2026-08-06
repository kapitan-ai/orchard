defmodule Orchard.Metrics.Status do
  @moduledoc false
  use Agent

  require Logger

  @log_interval_ms 60_000
  @table __MODULE__

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts) do
    Agent.start_link(
      fn ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        %{last_logs: %{}}
      end,
      name: __MODULE__
    )
  end

  @spec degrade(term()) :: :ok
  def degrade(reason) do
    true = :ets.insert(@table, {reason})
    safe_cast({:log_degradation, reason})
  catch
    :error, :badarg -> :ok
    :exit, _reason -> :ok
  end

  @spec recover(term()) :: :ok
  def recover(reason) do
    true = :ets.delete(@table, reason)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @spec healthy?() :: boolean()
  def healthy? do
    :ets.first(@table) == :"$end_of_table"
  catch
    :error, :badarg -> false
  end

  def handle_cast(state, {:log_degradation, reason}) do
    now = System.monotonic_time(:millisecond)
    last_log = Map.get(state.last_logs, reason)

    if last_log == nil or now - last_log >= @log_interval_ms do
      Logger.warning("Metrics reporting degraded: #{inspect(reason)}")
      %{state | last_logs: Map.put(state.last_logs, reason, now)}
    else
      state
    end
  end

  defp safe_cast(message) do
    Agent.cast(__MODULE__, __MODULE__, :handle_cast, [message])
  catch
    :exit, _reason -> :ok
  end
end
