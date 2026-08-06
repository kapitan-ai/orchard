defmodule Orchard.Metrics.SeriesAdmission do
  @moduledoc false
  use GenServer

  alias Orchard.Metrics.{CardinalityLedger, Catalog, Normalizer, Status}

  @call_timeout_ms 25

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec emit(atom(), number(), map()) :: :ok | {:error, :metrics_degraded}
  def emit(family, value, labels) when is_number(value) do
    deadline = deadline()

    GenServer.call(
      __MODULE__,
      {:emit, family, value, labels, deadline},
      remaining_ms(deadline)
    )
  catch
    :exit, _reason ->
      Status.degrade(:series_admission)
      {:error, :metrics_degraded}
  end

  def emit(_family, _value, _labels), do: {:error, :metrics_degraded}

  @impl true
  def init(_arg), do: {:ok, nil}

  @impl true
  def handle_call({:emit, family, value, labels, deadline}, _from, state) do
    result =
      with false <- expired?(deadline),
           {:ok, normalized} <- Normalizer.normalize(family, labels),
           {:ok, _admission} <- CardinalityLedger.admit_event(family, normalized, deadline),
           false <- expired?(deadline) do
        :telemetry.execute(Catalog.event_name(family), %{value: value}, normalized)
        :ok
      else
        _error ->
          Status.degrade(:series_admission)
          {:error, :metrics_degraded}
      end

    {:reply, result, state}
  rescue
    _exception ->
      Status.degrade(:series_admission)
      {:reply, {:error, :metrics_degraded}, state}
  catch
    _kind, _reason ->
      Status.degrade(:series_admission)
      {:reply, {:error, :metrics_degraded}, state}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @call_timeout_ms
  defp expired?(deadline), do: remaining_ms(deadline) == 0

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
