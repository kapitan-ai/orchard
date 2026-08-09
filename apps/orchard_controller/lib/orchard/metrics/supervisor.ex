defmodule Orchard.Metrics.Supervisor do
  @moduledoc false
  use Supervisor

  alias Orchard.Metrics.{
    CardinalityLedger,
    Catalog,
    GaugePoller,
    GaugeSnapshotStore,
    SeriesAdmission,
    Status,
    WorkerCrashDeduplicator
  }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    reporter = Keyword.get(opts, :reporter, TelemetryMetricsPrometheus.Core)

    children = [
      Status,
      CardinalityLedger,
      {reporter,
       metrics: Catalog.reporter_metrics(), name: Orchard.Metrics.Reporter, start_async: false},
      SeriesAdmission,
      WorkerCrashDeduplicator,
      GaugeSnapshotStore,
      %{
        id: :orchard_metrics_poller,
        start:
          {:telemetry_poller, :start_link,
           [
             [
               measurements: GaugePoller.measurements(opts),
               period: Keyword.get(opts, :poll_interval_ms, 10_000)
             ]
           ]}
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 2, max_seconds: 5)
  end
end
