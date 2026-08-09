defmodule Orchard.Metrics.GaugePoller do
  @moduledoc false

  alias Orchard.Metrics.{GaugeSnapshotStore, GaugeSource}

  @families [
    :scheduler_queue_depth,
    :node_heartbeat_lag,
    :node_available_memory,
    :node_swap_used,
    :active_requests,
    :model_resident
  ]

  @spec measurements(keyword()) :: [{module(), atom(), [keyword()]}]
  def measurements(opts) do
    poll_opts = [
      source: Keyword.get(opts, :gauge_source, GaugeSource),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 10_000)
    ]

    [{__MODULE__, :poll, [poll_opts]}]
  end

  @spec poll(keyword()) :: :ok
  def poll(opts) do
    source = Keyword.fetch!(opts, :source)
    interval = Keyword.fetch!(opts, :poll_interval_ms)
    observed_at = System.monotonic_time()

    case read_snapshots(source) do
      {:ok, snapshots} ->
        Enum.each(@families, &replace_family(&1, snapshots, observed_at, interval))

      :error ->
        Enum.each(@families, &GaugeSnapshotStore.fail/1)
    end

    :ok
  end

  defp read_snapshots(source) do
    case source.snapshots(DateTime.utc_now()) do
      snapshots when is_map(snapshots) -> {:ok, snapshots}
      _malformed -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp replace_family(family, snapshots, observed_at, interval) do
    case Map.fetch(snapshots, family) do
      {:ok, entries} ->
        _result = GaugeSnapshotStore.replace(family, entries, observed_at, interval)
        :ok

      :error ->
        GaugeSnapshotStore.fail(family)
    end
  rescue
    _exception ->
      GaugeSnapshotStore.fail(family)
  catch
    _kind, _reason ->
      GaugeSnapshotStore.fail(family)
  end
end
