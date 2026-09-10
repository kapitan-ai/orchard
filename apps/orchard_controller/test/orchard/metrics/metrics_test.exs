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
    Bootstrap,
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

  setup_all do
    assert is_pid(Process.whereis(Bootstrap))

    metrics_monitor =
      case Process.whereis(MetricsSupervisor) do
        nil -> nil
        metrics -> {metrics, Process.monitor(metrics)}
      end

    assert :ok = Supervisor.terminate_child(Orchard.Supervisor, Bootstrap)

    case metrics_monitor do
      nil ->
        :ok

      {metrics, metrics_ref} ->
        assert_receive {:DOWN, ^metrics_ref, :process, ^metrics, _reason}, 5_000
    end

    wait_until_reporter_handlers_detached()

    on_exit(fn ->
      stop_metrics_generation()
      wait_until_reporter_handlers_detached()

      assert {:ok, bootstrap} = Supervisor.restart_child(Orchard.Supervisor, Bootstrap)
      assert is_pid(bootstrap)
      wait_until_metrics_restored()
    end)

    :ok
  end

  setup do
    assert Process.whereis(Bootstrap) == nil
    start_metrics_generation()
    :ok
  end

  test "issue #206 test generation exclusively owns Orchard reporter handlers" do
    reporter = Process.whereis(Orchard.Metrics.Reporter)
    handlers = reporter_handlers()
    owners = handlers |> Enum.map(&reporter_handler_owner/1) |> Enum.uniq()

    assert handlers != []

    assert owners == [reporter],
           "expected only reporter #{inspect(reporter)} to own handlers, surviving handlers: #{inspect(handlers)}"
  end

  test "SPEC.md §9.1 descriptor catalog and immutable histogram buckets are exact" do
    descriptors = Catalog.descriptors()

    assert length(descriptors) == 24

    assert Enum.map(descriptors, & &1.name) == [
             "orchard_http_requests_total",
             "orchard_http_request_duration_seconds",
             "orchard_inference_requests_total",
             "orchard_inference_request_duration_seconds",
             "orchard_inference_attempts_total",
             "orchard_inference_attempt_duration_seconds",
             "orchard_inference_retries_total",
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

    assert descriptor!(:inference_attempt_duration).buckets ==
             [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]

    assert descriptor!(:decode_tokens_per_second).buckets == [1, 2, 5, 10, 20, 40, 80, 120]

    assert descriptor!(:scheduler_duration).buckets ==
             [0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.25, 0.5, 1]

    assert descriptor!(:model_load_duration).buckets ==
             [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120]

    assert Enum.uniq_by(descriptors, & &1.family) == descriptors
    assert Enum.uniq_by(descriptors, & &1.name) == descriptors
    assert Enum.uniq_by(descriptors, &Catalog.event_name(&1.family)) == descriptors
  end

  test "SPEC.md §9.1 worksheet reconciles the accepted floor with runtime attempt families" do
    calculated =
      Enum.reduce(Catalog.descriptors(), 0, fn descriptor, total ->
        cost = if descriptor.type == :histogram, do: length(descriptor.buckets) + 3, else: 1
        total + descriptor.ceiling * cost
      end)

    assert calculated == 2_826
    assert Catalog.worksheet_total() == 2_826
    assert Catalog.series_ceiling() == 5_000
    assert calculated - 2_597 == 229
    assert Catalog.series_ceiling() - calculated == 2_174
  end

  test "SPEC.md §9.1 admits exactly eleven audit domains by three outcomes" do
    domains =
      ~w(tenant api_key service_account role_binding routing_policy tenant_model_access node_admission node_lifecycle circuit_breaker cluster portal_user)

    outcomes = ~w(succeeded failed denied)

    assert descriptor!(:audit_events).ceiling == length(domains) * length(outcomes)

    for action <- domains, outcome <- outcomes do
      assert {:ok, %{action: ^action, outcome: ^outcome}} =
               Normalizer.normalize(:audit_events, %{action: action, outcome: outcome})
    end

    assert {:error, :invalid_labels} =
             Normalizer.normalize(:audit_events, %{action: "portal_user_id", outcome: "succeeded"})

    assert {:error, :invalid_labels} =
             Normalizer.normalize(:audit_events, %{
               action: "support_bundle",
               outcome: "succeeded"
             })
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

  test "SPEC.md §9.1 attempt and retry labels accept only closed legal combinations" do
    failure_classes =
      ~w(
        pre_acceptance_unavailable model_load_failure worker_or_node_loss runtime_failure
        terminal_conformance capacity_rejection cancellation deadline controller_failure
        occupancy_unresolved identity_unresolved
      )

    for attempt <- [1, 2] do
      assert {:ok, %{attempt: attempt_label, outcome: "completed", failure_class: "none"}} =
               Normalizer.normalize(:inference_attempts, %{
                 attempt: attempt,
                 outcome: :completed,
                 failure_class: :none
               })

      assert attempt_label == Integer.to_string(attempt)

      for outcome <- ~w(failed cancelled timed_out interrupted),
          failure_class <- failure_classes do
        assert {:ok, _labels} =
                 Normalizer.normalize(:inference_attempts, %{
                   attempt: attempt,
                   outcome: outcome,
                   failure_class: failure_class
                 })
      end
    end

    legal_retry_pairs = [
      {:retried, :succeeded},
      {:retried, :failed},
      {:not_retryable, :declined},
      {:output_committed, :declined},
      {:cancelled, :declined},
      {:budget_exhausted, :declined},
      {:identity_unresolved, :declined},
      {:occupancy_unresolved, :declined},
      {:no_alternative_node, :declined}
    ]

    for {reason, result} <- legal_retry_pairs do
      assert {:ok, _labels} =
               Normalizer.normalize(:inference_retries, %{reason: reason, result: result})
    end

    invalid_labels = [
      {:inference_attempts, %{attempt: 3, outcome: :failed, failure_class: :runtime_failure}},
      {:inference_attempts, %{attempt: 1, outcome: :completed, failure_class: :runtime_failure}},
      {:inference_attempts, %{attempt: 1, outcome: :failed, failure_class: :none}},
      {:inference_retries, %{reason: :retried, result: :declined}},
      {:inference_retries, %{reason: :no_alternative_node, result: :succeeded}},
      {:inference_retries, %{reason: :retry_exhausted, result: :failed}},
      {:inference_retries, %{reason: :retried, result: :succeeded, request_id: "req-1"}}
    ]

    for {family, labels} <- invalid_labels do
      assert {:error, :invalid_labels} = Normalizer.normalize(family, labels)
    end
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

  test "SPEC.md §9.1 attempt and retry exposition uses only bounded labels" do
    assert :ok =
             SeriesAdmission.emit(:inference_attempts, 1, %{
               attempt: 2,
               outcome: :completed,
               failure_class: :none
             })

    assert :ok =
             SeriesAdmission.emit(:inference_attempt_duration, 1.25, %{
               attempt: 2,
               outcome: :completed
             })

    assert :ok =
             SeriesAdmission.emit(:inference_retries, 1, %{
               reason: :retried,
               result: :succeeded
             })

    assert {:ok, exposition} = Renderer.render()

    assert exposition =~
             ~s(orchard_inference_attempts_total{attempt="2",failure_class="none",outcome="completed"} 1)

    assert exposition =~
             ~s(orchard_inference_attempt_duration_seconds_bucket{attempt="2",outcome="completed",le="2.5"} 1)

    assert exposition =~
             ~s(orchard_inference_attempt_duration_seconds_count{attempt="2",outcome="completed"} 1)

    assert exposition =~
             ~s(orchard_inference_retries_total{reason="retried",result="succeeded"} 1)
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

  defp start_metrics_generation do
    start_supervised!({MetricsSupervisor, gauge_source: EmptyGaugeSource})
    wait_until_polled()
  end

  defp stop_metrics_generation do
    case Process.whereis(MetricsSupervisor) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Supervisor.stop(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end
  end

  defp wait_until_reporter_handlers_detached(attempts \\ 200)

  defp wait_until_reporter_handlers_detached(0) do
    flunk("Orchard reporter handlers survived shutdown: #{inspect(reporter_handlers())}")
  end

  defp wait_until_reporter_handlers_detached(attempts) do
    case reporter_handlers() do
      [] ->
        :ok

      _handlers ->
        Process.sleep(5)
        wait_until_reporter_handlers_detached(attempts - 1)
    end
  end

  defp reporter_handlers do
    Catalog.descriptors()
    |> Enum.flat_map(fn descriptor ->
      event = Catalog.event_name(descriptor.family)

      for %{id: {_module, owner, _metric_name} = id} <- :telemetry.list_handlers(event),
          is_pid(owner) do
        %{event: event, id: id, owner: owner, alive?: Process.alive?(owner)}
      end
    end)
    |> Enum.uniq()
  end

  defp reporter_handler_owner(%{owner: owner}), do: owner

  defp wait_until_metrics_restored(attempts \\ 1_000)

  defp wait_until_metrics_restored(0) do
    flunk(
      "metrics restore did not complete: " <>
        "supervisor=#{inspect(Process.whereis(MetricsSupervisor))}, " <>
        "reporter=#{inspect(Process.whereis(Orchard.Metrics.Reporter))}, " <>
        "handlers=#{inspect(reporter_handlers())}"
    )
  end

  defp wait_until_metrics_restored(attempts) do
    metrics = Process.whereis(MetricsSupervisor)
    reporter = Process.whereis(Orchard.Metrics.Reporter)
    handlers = reporter_handlers()

    if is_pid(metrics) and is_pid(reporter) and handlers != [] and
         Enum.all?(handlers, &(reporter_handler_owner(&1) == reporter)) do
      :ok
    else
      Process.sleep(5)
      wait_until_metrics_restored(attempts - 1)
    end
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
end
