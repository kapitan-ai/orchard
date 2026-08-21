defmodule Orchard.Node.ModelManagerTest do
  use ExUnit.Case, async: false

  alias Orchard.Node.ModelManager
  alias Orchard.Node.WorkerSupervisor

  test "issue #222 successful late completion removes an ownerless worker placement" do
    reply_ref = make_ref()

    expired_waiter = %{
      id: make_ref(),
      from: {self(), reply_ref},
      deadline_unix_ms: System.system_time(:millisecond) - 1,
      timer_ref: nil
    }

    fixture = completion_fixture(preload: false, waiters: [expired_waiter])
    next_state = complete_load(fixture)

    assert next_state.inflight_loads == %{}
    assert next_state.load_refs == %{}
    assert next_state.worker_refs == %{}
    assert next_state.workers == %{}

    assert_receive {^reply_ref, %{failure_code: "deadline_exceeded"}}, 1_000

    assert_receive {:DOWN, worker_monitor, :process, worker_pid, _reason}, 1_000
    assert worker_monitor == fixture.worker_test_monitor
    assert worker_pid == fixture.worker_pid
  end

  test "issue #222 explicit preload remains a valid residency owner" do
    fixture = completion_fixture(preload: true, waiters: [])
    next_state = complete_load(fixture)

    assert next_state.inflight_loads == %{}
    assert next_state.load_refs == %{}
    assert next_state.worker_refs == %{fixture.worker_state_monitor => fixture.key}

    assert %{placement_state: :PLACEMENT_STATE_LOADED, pid: worker_pid} =
             Map.fetch!(next_state.workers, fixture.key)

    assert worker_pid == fixture.worker_pid
    assert Process.alive?(worker_pid)
  end

  defp completion_fixture(opts) do
    key = {"model/id", "version"}
    task_pid = spawn(fn -> Process.sleep(:infinity) end)
    task_ref = Process.monitor(task_pid)

    worker_spec =
      Supervisor.child_spec(
        {Task, fn -> Process.sleep(:infinity) end},
        restart: :temporary
      )

    {:ok, worker_pid} = DynamicSupervisor.start_child(WorkerSupervisor, worker_spec)
    worker_state_monitor = Process.monitor(worker_pid)
    worker_test_monitor = Process.monitor(worker_pid)
    waiters = Keyword.fetch!(opts, :waiters)

    on_exit(fn ->
      if Process.alive?(task_pid), do: Process.exit(task_pid, :kill)

      if Process.alive?(worker_pid) do
        DynamicSupervisor.terminate_child(WorkerSupervisor, worker_pid)
      end
    end)

    inflight = %{
      request: %{},
      request_fingerprint: {"fingerprint", nil},
      waiters: waiters,
      replied_waiter_count: 0,
      total_waiter_count: length(waiters),
      preload: Keyword.fetch!(opts, :preload),
      worker_pid: worker_pid,
      task_pid: task_pid,
      task_ref: task_ref,
      leader_waiter_id: waiters |> List.first() |> waiter_id(),
      started_monotonic_ms: System.monotonic_time(:millisecond),
      source_scheme: nil,
      backend: "test"
    }

    state = %{
      active_requests: %{},
      inflight_loads: %{key => inflight},
      load_refs: %{task_ref => key},
      subscriber_refs: %{},
      worker_crash_counter_version: "",
      worker_crashes: %{},
      worker_refs: %{worker_state_monitor => key},
      workers: %{
        key => %{
          model_ref: %{model_id: "model/id", version: "version"},
          monitor_ref: worker_state_monitor,
          pid: worker_pid,
          placement_state: :PLACEMENT_STATE_LOADING,
          request_limit: nil,
          last_used_monotonic_ms: 0
        }
      }
    }

    %{
      key: key,
      state: state,
      task_pid: task_pid,
      worker_pid: worker_pid,
      worker_state_monitor: worker_state_monitor,
      worker_test_monitor: worker_test_monitor
    }
  end

  defp complete_load(fixture) do
    assert {:noreply, next_state} =
             ModelManager.handle_info(
               {:model_load_finished, fixture.key, fixture.task_pid, {:ok, fixture.worker_pid}},
               fixture.state
             )

    next_state
  end

  defp waiter_id(nil), do: nil
  defp waiter_id(waiter), do: waiter.id
end
