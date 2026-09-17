defmodule Orchard.WorkerRecovery.LazyListenerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Orchard.WorkerRecovery.LazyListener

  @retry_interval_ms 1_000

  defp initial_state, do: %{opts: [], server_supervisor: self(), logged_outcomes: MapSet.new()}

  defp assert_retry_at_lazy_interval do
    refute_receive :start_listener, div(@retry_interval_ms * 7, 10)
    assert_receive :start_listener, @retry_interval_ms
  end

  defp log_once(state, outcome) do
    log =
      capture_log(fn -> send(self(), {:next, LazyListener.log_outcome_once(state, outcome)}) end)

    assert_received {:next, next}
    {log, next}
  end

  # SPEC.md §12.2 scopes the escalating 1s/2s/4s/8s/16s/30s schedule to
  # checkpoint persistence, so repeated listener start failures must not build a
  # second growing backoff.
  test "repeated listener start failures keep retrying on the same lazy interval" do
    LazyListener.schedule_retry()
    assert_retry_at_lazy_interval()

    LazyListener.schedule_retry()
    assert_retry_at_lazy_interval()
  end

  test "a failed listener start logs the discarded start_child reason once per outcome" do
    {log, state} = log_once(initial_state(), {:start_failed, :eaddrinuse})

    assert log =~ "eaddrinuse"

    {repeat, _state} = log_once(state, {:start_failed, :eaddrinuse})

    assert repeat == ""
  end

  test "missing identity and invalid configuration log under separate throttles" do
    {identity_log, state} = log_once(initial_state(), :identity_unavailable)

    assert identity_log =~ "identity unavailable"

    {configuration_log, _state} = log_once(state, :configuration_invalid)

    assert configuration_log =~ "configuration invalid"
  end
end
