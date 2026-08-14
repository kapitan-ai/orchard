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

  @doc false
  @spec start_reporter({module(), atom(), [term()]}) :: term()
  def start_reporter({module, function, args}) do
    detach_orphaned_reporter_handlers()
    apply(module, function, args)
  end

  @impl true
  def init(opts) do
    reporter = Keyword.get(opts, :reporter, TelemetryMetricsPrometheus.Core)

    children = [
      Status,
      CardinalityLedger,
      reporter_child(reporter),
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

  defp reporter_child(reporter) do
    spec =
      Supervisor.child_spec(
        {reporter,
         metrics: Catalog.reporter_metrics(), name: Orchard.Metrics.Reporter, start_async: false},
        []
      )

    %{spec | start: {__MODULE__, :start_reporter, [spec.start]}}
  end

  # A reporter generation detaches its telemetry handlers from `terminate/2` only.
  # A generation killed without terminating leaves handlers bound to the reporter
  # table name, so they keep writing into the table the next generation registers
  # and every observation is counted once per orphaned generation.
  defp detach_orphaned_reporter_handlers do
    for descriptor <- Catalog.descriptors(),
        handler <- :telemetry.list_handlers(Catalog.event_name(descriptor.family)),
        orphaned_handler?(handler.id) do
      :telemetry.detach(handler.id)
    end

    :ok
  end

  defp orphaned_handler?({_module, owner, _metric_name}) when is_pid(owner),
    do: not Process.alive?(owner)

  defp orphaned_handler?(_id), do: false
end
