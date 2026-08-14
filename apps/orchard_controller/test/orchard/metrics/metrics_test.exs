defmodule Orchard.MetricsTest.EmptyGaugeSource do
  @moduledoc false

  def snapshots(_now) do
    %{
      scheduler_queue_depth: [],
      node_heartbeat_lag: [],
      node_available_memory: [],
      node_swap_used: [],
      active_requests: [],
      model_resident: []
    }
  end
end

defmodule Orchard.MetricsTest do
  use ExUnit.Case, async: false

  alias Orchard.Metrics.{
    CardinalityLedger,
    Catalog,
    GaugeSnapshotStore,
    Normalizer,
    Renderer,
    SeriesAdmission,
    Status
  }

  alias Orchard.Metrics.Supervisor, as: MetricsSupervisor
  alias Orchard.MetricsTest.EmptyGaugeSource

  setup do
    restart_metrics_generation()
    :ok
  end

  test "SPEC.md §9.1 descriptor catalog and immutable histogram buckets are exact" do
    descriptors = Catalog.descriptors()

    assert length(descriptors) == 21

    assert Enum.map(descriptors, & &1.name) == [
             "orchard_http_requests_total",
             "orchard_http_request_duration_seconds",
             "orchard_inference_requests_total",
             "orchard_inference_request_duration_seconds",
             "orchard_input_tokens_total",
             "orchard_output_tokens_total",
             "orchard_decode_tokens_per_second",
             "orchard_scheduler_decisions_total",
             "orchard_scheduler_duration_seconds",
             "orchard_scheduler_queue_depth",
             "orchard_scheduler_rejections_total",
             "orchard_node_heartbeat_lag_seconds",
             "orchard_node_available_memory_bytes",
             "orchard_node_swap_used_bytes",
             "orchard_active_requests",
             "orchard_model_load_duration_seconds",
             "orchard_model_resident",
             "orchard_worker_crashes_total",
             "orchard_quota_rejections_total",
             "orchard_api_key_auth_failures_total",
             "orchard_audit_events_total"
           ]

    assert descriptor!(:http_request_duration).buckets ==
             [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]

    assert descriptor!(:inference_request_duration).buckets ==
             [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]

    assert descriptor!(:decode_tokens_per_second).buckets == [1, 2, 5, 10, 20, 40, 80, 120]

    assert descriptor!(:scheduler_duration).buckets ==
             [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1]

    assert descriptor!(:model_load_duration).buckets ==
             [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]
  end

  test "SPEC.md §9.1 worksheet is exactly 2,588 below the 5,000 ceiling" do
    calculated =
      Enum.reduce(Catalog.descriptors(), 0, fn descriptor, total ->
        cost = if descriptor.type == :histogram, do: length(descriptor.buckets) + 3, else: 1
        total + descriptor.ceiling * cost
      end)

    assert calculated == 2_588
    assert Catalog.worksheet_total() == 2_588
    assert Catalog.series_ceiling() == 5_000
    assert Catalog.series_ceiling() - calculated == 2_412
  end

  test "bounded normalization rejects unknown categorical values and preserves identifiers" do
    assert {:ok, %{endpoint: "public_api", method: "OTHER", status: "success"}} =
             Normalizer.normalize(:http_requests, %{
               endpoint: "public_api",
               method: "TRACE",
               status: 204
             })

    assert {:ok, %{tenant: "tenant-raw", model: "model-1"}} =
             Normalizer.normalize(:input_tokens, %{tenant: "tenant-raw", model: "model-1"})

    assert {:error, :invalid_labels} =
             Normalizer.normalize(:quota_rejections, %{tenant: "t1", reason: "arbitrary"})
  end

  test "series admission charges complete histogram cost and fails closed at identifier ceiling" do
    for tenant <- 1..4 do
      assert :ok =
               SeriesAdmission.emit(:inference_request_duration, 1.0, %{
                 tenant: "tenant-#{tenant}",
                 model: "model-1",
                 status: "completed"
               })
    end

    assert CardinalityLedger.active_series() == 4 * 13

    assert {:error, :metrics_degraded} =
             SeriesAdmission.emit(:inference_request_duration, 1.0, %{
               tenant: "tenant-5",
               model: "model-1",
               status: "completed"
             })

    assert CardinalityLedger.active_series() == 4 * 13
  end

  test "timed-out admission work cannot emit after leaving the bounded queue" do
    admission = Process.whereis(SeriesAdmission)
    :ok = :sys.suspend(admission)

    on_exit(fn ->
      if Process.alive?(admission), do: :sys.resume(admission)
    end)

    started_at = System.monotonic_time(:millisecond)
    assert {:error, :metrics_degraded} = SeriesAdmission.emit(:api_key_auth_failures, 1, %{})
    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 500
    refute Status.healthy?()
    :ok = :sys.resume(admission)
    Process.sleep(30)

    exposition = TelemetryMetricsPrometheus.Core.scrape(Orchard.Metrics.Reporter)
    refute exposition =~ "orchard_api_key_auth_failures_total"
    assert CardinalityLedger.active_series() == 0
  end

  test "a timed-out nested ledger call cannot admit or emit stale work later" do
    ledger = Process.whereis(CardinalityLedger)
    :ok = :sys.suspend(ledger)

    on_exit(fn ->
      if Process.alive?(ledger), do: :sys.resume(ledger)
    end)

    assert {:error, :metrics_degraded} =
             SeriesAdmission.emit(:input_tokens, 7, %{tenant: "tenant-a", model: "model-a"})

    :ok = :sys.resume(ledger)
    Process.sleep(30)

    exposition = TelemetryMetricsPrometheus.Core.scrape(Orchard.Metrics.Reporter)
    refute exposition =~ "orchard_input_tokens_total"
    assert CardinalityLedger.active_series() == 0
  end

  test "transient admission unavailability clears on the next successful admission" do
    admission = Process.whereis(SeriesAdmission)
    :ok = :sys.suspend(admission)

    on_exit(fn ->
      if Process.alive?(admission), do: :sys.resume(admission)
    end)

    assert {:error, :metrics_degraded} = SeriesAdmission.emit(:api_key_auth_failures, 1, %{})
    refute Status.healthy?()

    :ok = :sys.resume(admission)

    assert :ok = SeriesAdmission.emit(:api_key_auth_failures, 1, %{})
    assert Status.healthy?()
  end

  test "a rejected tuple keeps its reporter generation degraded" do
    assert {:error, :metrics_degraded} =
             SeriesAdmission.emit(:quota_rejections, 1, %{tenant: "tenant-a", reason: "arbitrary"})

    refute Status.healthy?()

    assert :ok = SeriesAdmission.emit(:api_key_auth_failures, 1, %{})
    refute Status.healthy?()
  end

  test "expiring a failed gauge family retries an unavailable ledger release" do
    now = System.monotonic_time(:millisecond)
    store = Process.whereis(GaugeSnapshotStore)
    ledger = Process.whereis(CardinalityLedger)

    assert :ok =
             GaugeSnapshotStore.replace(
               :scheduler_queue_depth,
               [%{labels: %{tenant: "tenant-a"}, value: 1}],
               now,
               40
             )

    assert :ok = GaugeSnapshotStore.fail(:scheduler_queue_depth)
    :ok = :sys.suspend(ledger)

    on_exit(fn ->
      if Process.alive?(ledger), do: :sys.resume(ledger)
    end)

    Process.sleep(120)

    assert Process.alive?(store)
    assert [%{value: 1}] = GaugeSnapshotStore.snapshots().scheduler_queue_depth

    :ok = :sys.resume(ledger)
    wait_until_expired(:scheduler_queue_depth)

    assert CardinalityLedger.active_series() == 0
  end

  test "sum-compatible counters expose measurement deltas and zero adds nothing" do
    assert :ok =
             SeriesAdmission.emit(:input_tokens, 7, %{tenant: "tenant-a", model: "model-a"})

    assert :ok =
             SeriesAdmission.emit(:input_tokens, 0, %{tenant: "tenant-a", model: "model-a"})

    assert :ok =
             SeriesAdmission.emit(:output_tokens, 9, %{tenant: "tenant-a", model: "model-a"})

    assert :ok =
             SeriesAdmission.emit(:worker_crashes, 3, %{node: "node-a", model: "model-a"})

    assert :ok =
             SeriesAdmission.emit(:worker_crashes, 4, %{node: "node-a", model: "model-a"})

    exposition = TelemetryMetricsPrometheus.Core.scrape(Orchard.Metrics.Reporter)

    assert exposition =~
             ~s(orchard_input_tokens_total{model="model-a",tenant="tenant-a"} 7)

    assert exposition =~
             ~s(orchard_output_tokens_total{model="model-a",tenant="tenant-a"} 9)

    assert exposition =~
             ~s(orchard_worker_crashes_total{model="model-a",node="node-a"} 7)
  end

  test "SPEC.md §9.1 a replacement reporter never inherits a killed generation's handlers" do
    admission = Process.whereis(SeriesAdmission)
    reporter = Process.whereis(Orchard.Metrics.Reporter)
    reporter_ref = Process.monitor(reporter)

    Process.exit(reporter, :kill)

    assert_receive {:DOWN, ^reporter_ref, :process, ^reporter, :killed}

    wait_until_replaced(SeriesAdmission, admission)

    assert :ok =
             SeriesAdmission.emit(:input_tokens, 7, %{tenant: "tenant-a", model: "model-a"})

    assert :ok =
             SeriesAdmission.emit(:http_request_duration, 0.02, %{
               endpoint: "health",
               status: 200
             })

    exposition = TelemetryMetricsPrometheus.Core.scrape(Orchard.Metrics.Reporter)

    assert exposition =~
             ~s(orchard_input_tokens_total{model="model-a",tenant="tenant-a"} 7)

    assert exposition =~
             ~s(orchard_http_request_duration_seconds_count{endpoint="health",status="success"} 1)
  end

  test "SPEC.md §9.1 HTTP duration exposition contains the immutable buckets" do
    assert :ok =
             SeriesAdmission.emit(:http_request_duration, 0.02, %{
               endpoint: "health",
               status: 200
             })

    assert {:ok, exposition} = Renderer.render()

    assert exposition =~
             ~s(orchard_http_request_duration_seconds_bucket{endpoint="health",status="success",le="0.01"} 0)

    assert exposition =~
             ~s(orchard_http_request_duration_seconds_bucket{endpoint="health",status="success",le="0.025"} 1)

    assert exposition =~
             ~s(orchard_http_request_duration_seconds_bucket{endpoint="health",status="success",le="+Inf"} 1)

    assert exposition =~
             ~s(orchard_http_request_duration_seconds_count{endpoint="health",status="success"} 1)
  end

  test "combined renderer returns core plus gauge exposition and fails closed when degraded" do
    now = System.monotonic_time(:millisecond)

    assert :ok = SeriesAdmission.emit(:api_key_auth_failures, 1, %{})

    assert :ok =
             GaugeSnapshotStore.replace(
               :node_available_memory,
               [%{labels: %{node: "node-1"}, value: 1024}],
               now,
               1_000
             )

    assert {:ok, exposition} = Renderer.render()
    assert exposition =~ "orchard_api_key_auth_failures_total"
    assert exposition =~ ~s(orchard_node_available_memory_bytes{node="node-1"} 1024)

    assert Status.healthy?()
    Status.degrade(:render_test)
    refute Status.healthy?()
    assert {:error, :unavailable} = Renderer.render()
  end

  test "gauge snapshots replace complete maps and ignore older observations" do
    now = System.monotonic_time(:millisecond)

    assert :ok =
             GaugeSnapshotStore.replace(
               :scheduler_queue_depth,
               [
                 %{labels: %{tenant: "tenant-a"}, value: 0},
                 %{labels: %{tenant: "tenant-b"}, value: 2}
               ],
               now,
               60
             )

    assert CardinalityLedger.active_series() == 2

    assert :ok =
             GaugeSnapshotStore.replace(
               :scheduler_queue_depth,
               [%{labels: %{tenant: "tenant-a"}, value: 1}],
               now + 1,
               60
             )

    assert CardinalityLedger.active_series() == 1
    assert :ignored = GaugeSnapshotStore.replace(:scheduler_queue_depth, [], now, 60)
    assert [%{value: 1}] = GaugeSnapshotStore.snapshots().scheduler_queue_depth
    assert CardinalityLedger.active_series() == 1
  end

  test "failed gauge snapshot is retained for two poll intervals then releases its charge" do
    now = System.monotonic_time(:millisecond)
    poll_interval_ms = 400

    assert :ok =
             GaugeSnapshotStore.replace(
               :scheduler_queue_depth,
               [%{labels: %{tenant: "tenant-a"}, value: 1}],
               now,
               poll_interval_ms
             )

    assert :ok = GaugeSnapshotStore.fail(:scheduler_queue_depth)
    assert [%{value: 1}] = GaugeSnapshotStore.snapshots().scheduler_queue_depth
    assert CardinalityLedger.active_series() == 1

    Process.sleep(poll_interval_ms)
    assert [%{value: 1}] = GaugeSnapshotStore.snapshots().scheduler_queue_depth
    assert CardinalityLedger.active_series() == 1

    wait_until_expired(:scheduler_queue_depth)
    assert CardinalityLedger.active_series() == 0
  end

  test "successful gauge replacement cancels a pending failure expiry" do
    now = System.monotonic_time(:millisecond)

    assert :ok =
             GaugeSnapshotStore.replace(
               :scheduler_queue_depth,
               [%{labels: %{tenant: "tenant-a"}, value: 1}],
               now,
               30
             )

    assert :ok = GaugeSnapshotStore.fail(:scheduler_queue_depth)

    assert :ok =
             GaugeSnapshotStore.replace(
               :scheduler_queue_depth,
               [%{labels: %{tenant: "tenant-a"}, value: 2}],
               now + 1,
               30
             )

    Process.sleep(80)
    assert [%{value: 2}] = GaugeSnapshotStore.snapshots().scheduler_queue_depth
    assert CardinalityLedger.active_series() == 1
  end

  defp descriptor!(family) do
    {:ok, descriptor} = Catalog.descriptor(family)
    descriptor
  end

  defp restart_metrics_generation do
    case Process.whereis(MetricsSupervisor) do
      nil ->
        :ok

      pid ->
        Supervisor.stop(pid)
        wait_until_stopped(MetricsSupervisor)
    end

    start_supervised!({MetricsSupervisor, gauge_source: EmptyGaugeSource})

    wait_until_polled()
  end

  defp wait_until_expired(family, attempts \\ 100)

  defp wait_until_expired(family, 0), do: flunk("#{family} snapshot was never expired")

  defp wait_until_expired(family, attempts) do
    if Map.has_key?(GaugeSnapshotStore.snapshots(), family) do
      Process.sleep(10)
      wait_until_expired(family, attempts - 1)
    else
      :ok
    end
  end

  defp wait_until_polled do
    if map_size(GaugeSnapshotStore.snapshots()) == 6 do
      :ok
    else
      Process.sleep(5)
      wait_until_polled()
    end
  end

  defp wait_until_replaced(name, previous, attempts \\ 200)

  defp wait_until_replaced(name, _previous, 0), do: flunk("#{inspect(name)} was never replaced")

  defp wait_until_replaced(name, previous, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _pending ->
        Process.sleep(5)
        wait_until_replaced(name, previous, attempts - 1)
    end
  end

  defp wait_until_stopped(name) do
    if Process.whereis(name) == nil do
      :ok
    else
      Process.sleep(5)
      wait_until_stopped(name)
    end
  end
end
