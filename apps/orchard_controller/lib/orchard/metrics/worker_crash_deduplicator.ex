defmodule Orchard.Metrics.WorkerCrashDeduplicator do
  @moduledoc false
  use GenServer

  alias Orchard.DomainMetrics

  @call_timeout_ms 25
  @identifier_limit 4
  @entry_limit 4
  @baseline_limit @identifier_limit * @identifier_limit
  @uint64_max 18_446_744_073_709_551_615
  @string_limit_bytes 512

  @type entry :: %{model_id: String.t(), count: non_neg_integer(), counter_version: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec observe(String.t(), [term()], keyword()) :: :ok
  def observe(node_id, entries, opts \\ [])

  def observe(node_id, entries, opts) when is_binary(node_id) and node_id != "" do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:observe, node_id, entries},
      @call_timeout_ms
    )
  catch
    :exit, _reason -> :ok
  end

  def observe(_node_id, _entries, _opts), do: :ok

  @impl true
  def init(opts) do
    {:ok,
     %{
       baselines: %{},
       emitter: Keyword.get(opts, :emitter, &DomainMetrics.worker_crashes/3)
     }}
  end

  @impl true
  def handle_call({:observe, node_id, entries}, _from, state) do
    baselines =
      entries
      |> normalize_entries()
      |> Enum.reduce(state.baselines, fn entry, baselines ->
        accept_entry(node_id, entry, baselines, state.emitter)
      end)

    {:reply, :ok, %{state | baselines: baselines}}
  rescue
    _exception -> {:reply, :ok, state}
  catch
    _kind, _reason -> {:reply, :ok, state}
  end

  defp normalize_entries(entries) when is_list(entries) do
    entries
    |> Enum.take(@entry_limit + 1)
    |> normalize_bounded_entries()
  end

  defp normalize_entries(_entries), do: []

  defp normalize_bounded_entries(entries) when length(entries) <= @entry_limit do
    entries
    |> Enum.group_by(&model_id/1)
    |> Enum.flat_map(fn
      {model_id, [entry]} when is_binary(model_id) and model_id != "" ->
        case normalize_entry(entry) do
          {:ok, normalized} -> [normalized]
          :error -> []
        end

      {_model_id, _duplicates} ->
        []
    end)
  end

  defp normalize_bounded_entries(_overflow), do: []

  defp normalize_entry(entry) when is_map(entry) do
    model_id = value(entry, :model_id)
    count = value(entry, :count)
    counter_version = value(entry, :counter_version)

    if valid_string?(model_id) and is_integer(count) and count in 0..@uint64_max and
         valid_string?(counter_version) do
      {:ok, %{model_id: model_id, count: count, counter_version: counter_version}}
    else
      :error
    end
  end

  defp normalize_entry(_entry), do: :error

  defp accept_entry(node_id, entry, baselines, emitter) do
    key = {node_id, entry.model_id}

    if admitted_identifier_pair?(baselines, key) do
      case Map.get(baselines, key) do
        %{counter_version: version, count: previous}
        when version == entry.counter_version and entry.count > previous ->
          emitter.(node_id, entry.model_id, entry.count - previous)
          Map.put(baselines, key, entry)

        _baseline_or_reset ->
          Map.put(baselines, key, entry)
      end
    else
      baselines
    end
  end

  defp admitted_identifier_pair?(baselines, {node_id, model_id}) do
    keys = Map.keys(baselines)
    nodes = keys |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    models = keys |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    (Map.has_key?(baselines, {node_id, model_id}) or map_size(baselines) < @baseline_limit) and
      (MapSet.member?(nodes, node_id) or MapSet.size(nodes) < @identifier_limit) and
      (MapSet.member?(models, model_id) or MapSet.size(models) < @identifier_limit)
  end

  defp model_id(entry) when is_map(entry), do: value(entry, :model_id)
  defp model_id(_entry), do: nil

  defp valid_string?(value) do
    is_binary(value) and value != "" and String.valid?(value) and
      byte_size(value) <= @string_limit_bytes
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
