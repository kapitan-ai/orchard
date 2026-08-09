defmodule Orchard.Metrics.GaugeSnapshotStore do
  @moduledoc false
  use GenServer

  alias Orchard.Metrics.{CardinalityLedger, Catalog, Normalizer, Status}

  @retention_intervals 2
  @release_retry_ms 100

  @type entry :: %{labels: map(), value: number()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec replace(atom(), [entry()], integer(), pos_integer()) ::
          :ok | :ignored | {:error, :metrics_degraded}
  def replace(family, entries, observed_at, poll_interval_ms) do
    GenServer.call(__MODULE__, {:replace, family, entries, observed_at, poll_interval_ms})
  catch
    :exit, _reason -> {:error, :metrics_degraded}
  end

  @spec fail(atom()) :: :ok
  def fail(family), do: GenServer.cast(__MODULE__, {:fail, family})

  @spec snapshots() :: map()
  def snapshots, do: GenServer.call(__MODULE__, :snapshots)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(
        {:replace, family, entries, observed_at, poll_interval_ms},
        _from,
        state
      ) do
    current = Map.get(state, family)

    cond do
      not valid_observation?(entries, observed_at, poll_interval_ms) ->
        {reply, next_state} = fail_snapshot(family, state)
        {:reply, reply, next_state}

      current != nil and observed_at <= current.observed_at ->
        {:reply, :ignored, state}

      true ->
        replace_snapshot(family, entries, observed_at, poll_interval_ms, state)
    end
  end

  def handle_call(:snapshots, _from, state) do
    {:reply, Map.new(state, fn {family, snapshot} -> {family, snapshot.entries} end), state}
  end

  @impl true
  def handle_cast({:fail, family}, state) do
    {_reply, next_state} = fail_snapshot(family, state)
    {:noreply, next_state}
  end

  @impl true
  def handle_info({:expire_failed, family, token}, state) do
    case Map.get(state, family) do
      %{failure_token: ^token} ->
        {:noreply, expire_failed_snapshot(family, token, state)}

      _snapshot ->
        {:noreply, state}
    end
  end

  defp expire_failed_snapshot(family, token, state) do
    case CardinalityLedger.release_gauge(family) do
      :ok ->
        Map.delete(state, family)

      {:error, _reason} ->
        Process.send_after(self(), {:expire_failed, family, token}, @release_retry_ms)
        state
    end
  end

  defp replace_snapshot(family, entries, observed_at, poll_interval_ms, state) do
    with {:ok, descriptor} <- Catalog.descriptor(family),
         true <- descriptor.type == :gauge,
         {:ok, normalized} <- normalize_entries(family, entries),
         :ok <- CardinalityLedger.replace_gauge(family, Enum.map(normalized, & &1.labels)) do
      Status.recover({:gauge, family})

      snapshot = %{
        entries: normalized,
        observed_at: observed_at,
        poll_interval_ms: poll_interval_ms,
        failure_token: nil
      }

      {:reply, :ok, Map.put(state, family, snapshot)}
    else
      _error ->
        {reply, next_state} = fail_snapshot(family, state)
        {:reply, reply, next_state}
    end
  end

  defp fail_snapshot(family, state) do
    Status.degrade({:gauge, family})

    next_state =
      case Map.get(state, family) do
        %{failure_token: nil} = snapshot ->
          token = make_ref()
          expiry_ms = @retention_intervals * snapshot.poll_interval_ms
          Process.send_after(self(), {:expire_failed, family, token}, expiry_ms)
          Map.put(state, family, %{snapshot | failure_token: token})

        _snapshot ->
          state
      end

    {{:error, :metrics_degraded}, next_state}
  end

  defp normalize_entries(family, entries) do
    entries
    |> Enum.reduce_while({:ok, []}, &normalize_entry(family, &1, &2))
    |> case do
      {:ok, normalized} -> validate_unique_entries(Enum.reverse(normalized))
      error -> error
    end
  end

  defp normalize_entry(family, %{labels: labels, value: value}, {:ok, acc})
       when is_number(value) do
    with {:ok, normalized} <- Normalizer.normalize(family, labels),
         true <- valid_value?(family, value) do
      {:cont, {:ok, [%{labels: normalized, value: value} | acc]}}
    else
      false -> {:halt, {:error, :invalid_value}}
      error -> {:halt, error}
    end
  end

  defp normalize_entry(_family, _entry, _acc), do: {:halt, {:error, :invalid_entry}}

  defp validate_unique_entries(entries) do
    tuples = Enum.map(entries, fn entry -> entry.labels |> Map.to_list() |> Enum.sort() end)

    if MapSet.size(MapSet.new(tuples)) == length(tuples) do
      {:ok, entries}
    else
      {:error, :duplicate_labels}
    end
  end

  defp valid_value?(:model_resident, value), do: value in [0, 1]
  defp valid_value?(_family, _value), do: true

  defp valid_observation?(entries, observed_at, poll_interval_ms),
    do:
      is_list(entries) and is_integer(observed_at) and is_integer(poll_interval_ms) and
        poll_interval_ms > 0
end
