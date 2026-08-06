defmodule Orchard.Metrics.WorkerCrashDeduplicatorTest do
  use ExUnit.Case, async: true

  alias Orchard.Metrics.WorkerCrashDeduplicator

  setup do
    test_pid = self()

    pid =
      start_supervised!(
        {WorkerCrashDeduplicator,
         name: nil,
         emitter: fn node_id, model_id, count ->
           send(test_pid, {:worker_crashes, node_id, model_id, count})
         end}
      )

    %{server: pid}
  end

  test "emits accepted positive deltas once and re-baselines resets", %{server: server} do
    observe(server, [%{model_id: "model-a", count: 5, counter_version: "epoch-1"}])
    refute_receive {:worker_crashes, _, _, _}

    observe(server, [%{model_id: "model-a", count: 5, counter_version: "epoch-1"}])
    refute_receive {:worker_crashes, _, _, _}

    observe(server, [%{model_id: "model-a", count: 8, counter_version: "epoch-1"}])
    assert_receive {:worker_crashes, "node-a", "model-a", 3}

    observe(server, [%{model_id: "model-a", count: 2, counter_version: "epoch-1"}])
    refute_receive {:worker_crashes, _, _, _}

    observe(server, [%{model_id: "model-a", count: 3, counter_version: "epoch-1"}])
    assert_receive {:worker_crashes, "node-a", "model-a", 1}

    observe(server, [%{model_id: "model-a", count: 10, counter_version: "epoch-2"}])
    refute_receive {:worker_crashes, _, _, _}

    observe(server, [%{model_id: "model-a", count: 12, counter_version: "epoch-2"}])
    assert_receive {:worker_crashes, "node-a", "model-a", 2}
  end

  test "malformed, duplicate, and overflowing entries cannot emit or advance", %{server: server} do
    observe(server, [%{model_id: "model-a", count: 4, counter_version: "epoch-1"}])

    observe(server, [
      %{model_id: "model-a", count: 5, counter_version: "epoch-1"},
      %{model_id: "model-a", count: 50, counter_version: "epoch-1"}
    ])

    observe(server, [%{model_id: "model-a", count: -1, counter_version: "epoch-1"}])
    refute_receive {:worker_crashes, _, _, _}

    observe(server, [%{model_id: "model-a", count: 5, counter_version: "epoch-1"}])
    assert_receive {:worker_crashes, "node-a", "model-a", 1}

    overflow =
      for suffix <- ~w(a b c d e) do
        %{model_id: "model-#{suffix}", count: 10, counter_version: "epoch-1"}
      end

    observe(server, overflow)
    refute_receive {:worker_crashes, _, _, _}

    observe(server, [%{model_id: "model-e", count: 11, counter_version: "epoch-1"}])
    refute_receive {:worker_crashes, _, _, _}
  end

  test "deduplication state remains bounded to four nodes by four models under churn", %{
    server: server
  } do
    for node <- 1..4, model <- 1..4 do
      observe(server, "node-#{node}", [
        %{model_id: "model-#{model}", count: 1, counter_version: "epoch-1"}
      ])
    end

    assert map_size(:sys.get_state(server).baselines) == 16

    for node <- 1..4, model <- 1..4 do
      observe(server, "node-#{node}", [
        %{model_id: "model-#{model}", count: 2, counter_version: "epoch-1"}
      ])

      assert_receive {:worker_crashes, "node-" <> _, "model-" <> _, 1}
    end

    for suffix <- 5..100 do
      observe(server, "node-#{suffix}", [
        %{model_id: "model-#{suffix}", count: 1, counter_version: "epoch-1"}
      ])

      observe(server, "node-#{suffix}", [
        %{model_id: "model-#{suffix}", count: 2, counter_version: "epoch-1"}
      ])
    end

    refute_receive {:worker_crashes, _, _, _}
    assert map_size(:sys.get_state(server).baselines) == 16
  end

  defp observe(server, entries), do: observe(server, "node-a", entries)

  defp observe(server, node_id, entries) do
    WorkerCrashDeduplicator.observe(node_id, entries, server: server)
  end
end
