defmodule Orchard.Tokenizer.TelemetryCountersTest do
  use ExUnit.Case, async: false

  alias Orchard.Tokenizer.TelemetryCounters

  @events %{
    control_token_in_user_content: [:orchard, :tokenizer, :control_token_in_user_content],
    detector_error: [:orchard, :tokenizer, :detector_error],
    prompt_token_ids_dispatched: [:orchard, :tokenizer, :prompt_token_ids_dispatched],
    unsafe_mode_active: [:orchard, :tokenizer, :unsafe_mode_active],
    parity_drift: [:orchard, :tokenizer, :parity_drift],
    catalog_drift: [:orchard, :tokenizer, :catalog_drift],
    degraded_no_manifest_catalog: [
      :orchard,
      :tokenizer,
      :safe_tokenization,
      :degraded_no_manifest_catalog
    ]
  }

  @counter_keys Map.keys(@events)

  setup do
    TelemetryCounters.reset()
    :ok
  end

  test "SPEC 3.5 snapshot starts with every safe-tokenization counter at zero" do
    snapshot = TelemetryCounters.snapshot()

    assert %DateTime{} = snapshot.started_at

    for key <- @counter_keys do
      assert %{count: 0, last_seen_at: nil} = Map.fetch!(snapshot, key)
    end

    assert %{token_count: 0} = snapshot.prompt_token_ids_dispatched
  end

  test "emitting each watched event updates the corresponding counter" do
    for {key, event_name} <- @events do
      TelemetryCounters.reset()

      :telemetry.execute(event_name, %{count: 2}, %{})

      assert %{^key => %{count: 2}} = TelemetryCounters.snapshot()
    end
  end

  test "prompt_token_ids_dispatched aggregates event count and accumulated token count" do
    event_name = @events.prompt_token_ids_dispatched

    :telemetry.execute(event_name, %{token_count: 3}, %{})
    :telemetry.execute(event_name, %{count: 2, token_count: 5}, %{})

    assert %{
             prompt_token_ids_dispatched: %{
               count: 3,
               token_count: 8,
               last_seen_at: %DateTime{}
             }
           } = TelemetryCounters.snapshot()
  end

  test "malformed measurements normalize without crashing" do
    :telemetry.execute(@events.control_token_in_user_content, %{count: 0}, %{})
    :telemetry.execute(@events.detector_error, %{count: -1}, %{})
    :telemetry.execute(@events.catalog_drift, %{count: "many"}, %{})
    :telemetry.execute(@events.unsafe_mode_active, %{}, %{})
    :telemetry.execute(@events.prompt_token_ids_dispatched, %{token_count: "three"}, %{})
    :telemetry.execute(@events.prompt_token_ids_dispatched, %{count: :bad}, %{})

    snapshot = TelemetryCounters.snapshot()

    assert snapshot.control_token_in_user_content.count == 1
    assert snapshot.detector_error.count == 1
    assert snapshot.catalog_drift.count == 1
    assert snapshot.unsafe_mode_active.count == 1
    assert snapshot.prompt_token_ids_dispatched.count == 2
    assert snapshot.prompt_token_ids_dispatched.token_count == 0
  end

  test "last_seen_at is truncated for observed counters and nil for unseen counters" do
    :telemetry.execute(@events.parity_drift, %{count: 1}, %{})

    snapshot = TelemetryCounters.snapshot()

    assert %DateTime{microsecond: {0, 0}} = snapshot.parity_drift.last_seen_at
    assert snapshot.catalog_drift.last_seen_at == nil
  end

  test "reset returns counters to zero without changing counter process start timestamp" do
    started_at = TelemetryCounters.snapshot().started_at

    :telemetry.execute(@events.degraded_no_manifest_catalog, %{count: 4}, %{})
    assert TelemetryCounters.snapshot().degraded_no_manifest_catalog.count == 4

    assert :ok = TelemetryCounters.reset()

    snapshot = TelemetryCounters.snapshot()
    assert snapshot.started_at == started_at
    assert snapshot.degraded_no_manifest_catalog.count == 0
    assert snapshot.degraded_no_manifest_catalog.last_seen_at == nil
  end

  test "supervisor restart reattaches telemetry handler exactly once" do
    old_pid = Process.whereis(TelemetryCounters)
    assert is_pid(old_pid)

    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^old_pid, _reason}, 1_000
    assert eventually(fn -> restarted?(old_pid) end)

    TelemetryCounters.reset()
    :telemetry.execute(@events.detector_error, %{count: 1}, %{})

    assert TelemetryCounters.snapshot().detector_error.count == 1
  end

  defp restarted?(old_pid) do
    case Process.whereis(TelemetryCounters) do
      pid when is_pid(pid) and pid != old_pid -> true
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
