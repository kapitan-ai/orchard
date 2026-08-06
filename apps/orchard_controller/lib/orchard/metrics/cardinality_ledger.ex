defmodule Orchard.Metrics.CardinalityLedger do
  @moduledoc false
  use GenServer

  alias Orchard.Metrics.Catalog

  @call_timeout_ms 25
  @identifier_limits %{tenant: 4, model: 4, node: 4}

  @type labels :: %{optional(atom()) => String.t()}
  @type admission_error :: :ceiling_exceeded | :deadline_exceeded

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @spec admit_event(atom(), labels()) :: {:ok, :new | :existing} | {:error, admission_error()}
  def admit_event(family, labels), do: admit_event(family, labels, deadline())

  @spec admit_event(atom(), labels(), integer()) ::
          {:ok, :new | :existing} | {:error, admission_error()}
  def admit_event(family, labels, deadline) do
    call({:admit_event, family, labels, deadline}, deadline)
  end

  @spec replace_gauge(atom(), [labels()]) :: :ok | {:error, admission_error()}
  def replace_gauge(family, labels) do
    deadline = deadline()
    call({:replace_gauge, family, labels, deadline}, deadline)
  end

  @spec release_gauge(atom()) :: :ok | {:error, :deadline_exceeded}
  def release_gauge(family) do
    deadline = deadline()
    call({:release_gauge, family, deadline}, deadline)
  end

  @spec active_series() :: non_neg_integer()
  def active_series, do: GenServer.call(__MODULE__, :active_series, @call_timeout_ms)

  @impl true
  def init(_arg), do: {:ok, %{events: %{}, gauges: %{}}}

  @impl true
  def handle_call({:admit_event, family, labels, deadline}, _from, state) do
    if expired?(deadline) do
      {:reply, {:error, :deadline_exceeded}, state}
    else
      admit_event_tuple(family, labels, state, deadline)
    end
  end

  def handle_call({:replace_gauge, family, labels, deadline}, _from, state) do
    if expired?(deadline) do
      {:reply, {:error, :deadline_exceeded}, state}
    else
      candidate = put_in(state, [:gauges, family], MapSet.new(Enum.map(labels, &tuple/1)))

      cond do
        not valid?(candidate) -> {:reply, {:error, :ceiling_exceeded}, state}
        expired?(deadline) -> {:reply, {:error, :deadline_exceeded}, state}
        true -> {:reply, :ok, candidate}
      end
    end
  end

  def handle_call({:release_gauge, family, deadline}, _from, state) do
    if expired?(deadline) do
      {:reply, {:error, :deadline_exceeded}, state}
    else
      {:reply, :ok, %{state | gauges: Map.delete(state.gauges, family)}}
    end
  end

  def handle_call(:active_series, _from, state), do: {:reply, series_total(state), state}

  defp admit_event_tuple(family, labels, state, deadline) do
    key = tuple(labels)
    current = Map.get(state.events, family, MapSet.new())

    if MapSet.member?(current, key) do
      reply_existing(state, deadline)
    else
      candidate = put_in(state, [:events, family], MapSet.put(current, key))
      reply_candidate(candidate, state, deadline)
    end
  end

  defp reply_existing(state, deadline) do
    if expired?(deadline) do
      {:reply, {:error, :deadline_exceeded}, state}
    else
      {:reply, {:ok, :existing}, state}
    end
  end

  defp reply_candidate(candidate, state, deadline) do
    cond do
      not valid?(candidate) -> {:reply, {:error, :ceiling_exceeded}, state}
      expired?(deadline) -> {:reply, {:error, :deadline_exceeded}, state}
      true -> {:reply, {:ok, :new}, candidate}
    end
  end

  defp call(message, deadline) do
    if expired?(deadline) do
      {:error, :deadline_exceeded}
    else
      GenServer.call(__MODULE__, message, remaining_ms(deadline))
    end
  catch
    :exit, _reason -> {:error, :deadline_exceeded}
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @call_timeout_ms
  defp expired?(deadline), do: remaining_ms(deadline) == 0

  defp remaining_ms(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp valid?(state) do
    series_total(state) <= Catalog.series_ceiling() and
      family_limits_valid?(state) and identifier_limits_valid?(state)
  end

  defp family_limits_valid?(state) do
    Enum.all?(Catalog.descriptors(), fn descriptor ->
      tuples =
        case descriptor.type do
          :gauge -> Map.get(state.gauges, descriptor.family, MapSet.new())
          _type -> Map.get(state.events, descriptor.family, MapSet.new())
        end

      MapSet.size(tuples) <= descriptor.ceiling
    end)
  end

  defp identifier_limits_valid?(state) do
    tuples =
      (Map.values(state.events) ++ Map.values(state.gauges))
      |> Enum.flat_map(&MapSet.to_list/1)

    Enum.all?(@identifier_limits, fn {identifier, limit} ->
      tuples
      |> Enum.flat_map(fn tuple -> Keyword.get_values(tuple, identifier) end)
      |> MapSet.new()
      |> MapSet.size()
      |> Kernel.<=(limit)
    end)
  end

  defp series_total(state) do
    Enum.reduce(Catalog.descriptors(), 0, fn descriptor, total ->
      tuples =
        case descriptor.type do
          :gauge -> Map.get(state.gauges, descriptor.family, MapSet.new())
          _type -> Map.get(state.events, descriptor.family, MapSet.new())
        end

      total + MapSet.size(tuples) * tuple_cost(descriptor)
    end)
  end

  defp tuple_cost(%{type: :histogram, buckets: buckets}), do: length(buckets) + 3
  defp tuple_cost(_descriptor), do: 1

  defp tuple(labels), do: labels |> Map.to_list() |> Enum.sort()
end
