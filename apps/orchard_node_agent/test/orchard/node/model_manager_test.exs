defmodule Orchard.Node.ModelManagerTest do
  use ExUnit.Case, async: false

  alias Orchard.Cluster.V1.{Ack, EnsureModelLoadedRequest}
  alias Orchard.Node.CustodyTestHelpers
  alias Orchard.Node.{ModelManager, RuntimeProcessReaper, WorkerRecoveryState, WorkerSupervisor}

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

    worker_monitor = fixture.worker_test_monitor
    worker_pid = fixture.worker_pid

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker_pid, _reason}, 1_000
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

  describe "SPEC.md §4.9 runtime custody" do
    setup do
      :ok = ModelManager.reset()
      :ok
    end

    test "no replacement starts after the owner dies while the old runtime may still run" do
      %{owner_pid: owner_pid, release: release} = hold_custody("model/custody", "v1")

      # The BEAM owner is gone, but its OS runtime is not confirmed stopped.
      Process.exit(owner_pid, :kill)

      assert ensure("model/custody", "v1").failure_code == "model_capacity_exhausted"
      assert :sys.get_state(ModelManager).inflight_loads == %{}

      release.()
    end

    test "reset returns only after the runtimes under custody have exited" do
      %{owner_pid: owner_pid, stop_runtime: stop_runtime} = hold_custody("model/reset", "v1")
      Process.exit(owner_pid, :kill)

      stopper =
        Task.async(fn ->
          Process.sleep(300)
          stop_runtime.()
        end)

      assert :ok = ModelManager.reset()
      assert RuntimeProcessReaper.custody_model_keys() == {:ok, MapSet.new()}
      Task.await(stopper)
    end

    test "reset stays within its wait budget when the reaper stops answering" do
      %{owner_pid: owner_pid, release: release} = hold_custody("model/reset-stuck", "v1")
      Process.exit(owner_pid, :kill)

      suspender =
        Task.async(fn ->
          Process.sleep(2_500)
          :sys.suspend(RuntimeProcessReaper)
        end)

      started = System.monotonic_time(:millisecond)

      try do
        assert :ok = ModelManager.reset()
        assert System.monotonic_time(:millisecond) - started < 4_000
      after
        Task.await(suspender)
        :sys.resume(RuntimeProcessReaper)
      end

      release.()
    end

    # SPEC.md §4.9 and §12.2: settling recovery entries during a reset spends
    # the custody wait budget rather than starting a fresh one afterwards.
    test "reset keeps its wait budget when recovery entries settle late and the reaper stops answering" do
      %{owner_pid: owner_pid, release: release} = hold_custody("model/reset-late", "v1")
      Process.exit(owner_pid, :kill)
      key = {"model/reset-settling", "v1"}

      :sys.replace_state(ModelManager, fn state ->
        entry =
          state.recovery_epoch
          |> WorkerRecoveryState.new()
          |> WorkerRecoveryState.hydrate(:absent)

        %{
          state
          | recovery: Map.put(state.recovery, key, %{entry | prior?: true, pending: :settling})
        }
      end)

      settler =
        Task.async(fn ->
          Process.sleep(1_000)
          :sys.replace_state(ModelManager, &%{&1 | recovery: Map.delete(&1.recovery, key)})
          Process.sleep(1_500)
          :sys.suspend(RuntimeProcessReaper)
        end)

      started = System.monotonic_time(:millisecond)

      try do
        assert :ok = ModelManager.reset()
        assert System.monotonic_time(:millisecond) - started < 4_000
      after
        Task.await(settler)
        :sys.resume(RuntimeProcessReaper)
      end

      release.()
    end

    test "an unanswered custody query refuses the load instead of assuming nothing runs" do
      :sys.suspend(RuntimeProcessReaper)

      try do
        assert ensure("model/unanswered", "v1").failure_code == "model_capacity_exhausted"
      after
        :sys.resume(RuntimeProcessReaper)
      end

      assert :sys.get_state(ModelManager).inflight_loads == %{}
    end

    test "a runtime under custody for another model still takes the only slot" do
      previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

      Application.put_env(
        :orchard_node_agent,
        :runtime,
        Keyword.put(previous_runtime, :max_loaded_models, 1)
      )

      %{release: release} = hold_custody("model/other", "v1")

      try do
        assert ensure("model/new", "v1").failure_code == "model_capacity_exhausted"
        assert :sys.get_state(ModelManager).inflight_loads == %{}
      after
        Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
        release.()
      end
    end

    test "a restarted load for remaining waiters does not launch over an unconfirmed runtime" do
      key = {"model/restart", "v1"}
      %{release: release} = hold_custody("model/restart", "v1")
      task_pid = spawn(fn -> Process.sleep(:infinity) end)
      task_ref = Process.monitor(task_pid)
      now_ms = System.system_time(:millisecond)
      leader = waiter(now_ms - 1)
      follower = waiter(now_ms + 60_000)

      inflight = %{
        request: %{deadline_unix_ms: leader.deadline_unix_ms},
        request_fingerprint: {"fingerprint", nil},
        waiters: [leader, follower],
        replied_waiter_count: 0,
        total_waiter_count: 2,
        preload: false,
        worker_pid: nil,
        task_pid: task_pid,
        task_ref: task_ref,
        leader_waiter_id: leader.id,
        started_monotonic_ms: System.monotonic_time(:millisecond),
        source_scheme: nil,
        backend: "test"
      }

      state = %{
        :sys.get_state(ModelManager)
        | inflight_loads: %{key => inflight},
          load_refs: %{task_ref => key}
      }

      # The leader's deadline passes, so the attempt is aborted and restarted for
      # the follower; the aborted attempt's runtime may still run.
      assert {:noreply, next_state} =
               ModelManager.handle_info(
                 {:inflight_waiter_timeout, key, task_ref, leader.id},
                 state
               )

      assert next_state.inflight_loads == %{}
      assert_receive {_ref, %{failure_code: "deadline_exceeded"}}, 1_000
      assert_receive {_ref, %{failure_code: "model_capacity_exhausted"}}, 1_000

      Process.exit(task_pid, :kill)
      release.()
    end

    # SPEC.md §4.9 custody and SPEC §12.2 recovery share one slot model: a
    # recovery record cannot resolve cleanup while the reaper still holds a
    # runtime for the same model, even without a recorded last Worker.
    test "SPEC §12.2 recovery cleanup stays unresolved while the reaper holds the model's runtime" do
      key = {"model/recovery-custody", "v1"}
      %{release: release} = hold_custody("model/recovery-custody", "v1")
      base = :sys.get_state(ModelManager)

      entry =
        base.recovery_epoch
        |> WorkerRecoveryState.new()
        |> WorkerRecoveryState.hydrate(:absent)
        |> put_in([:ownership, "phase"], "cleanup")

      state = %{base | recovery: Map.put(base.recovery, key, entry)}
      cleanup = {:recovery_cleanup, state.recovery_epoch, key}

      assert {:noreply, held} = ModelManager.handle_info(cleanup, state)
      assert held.recovery[key].ownership["phase"] == "cleanup"

      release.()

      assert {:noreply, cleared} = ModelManager.handle_info(cleanup, state)
      assert cleared.recovery[key].ownership["phase"] == "resolved"
    end

    test "a finished eviction whose runtime is still under custody refuses instead of evicting again" do
      previous_runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

      Application.put_env(
        :orchard_node_agent,
        :runtime,
        Keyword.put(previous_runtime, :max_loaded_models, 1)
      )

      %{release: release} = hold_custody("model/evicted", "v1")
      eviction_ref = make_ref()
      reply_ref = make_ref()

      continuation = %{
        request: ensure_request("model/incoming", "v1"),
        from: {self(), reply_ref},
        meta: %{max_loaded_models: 1, incoming_model_id: "model/incoming"},
        started: System.monotonic_time(:millisecond)
      }

      state = %{
        :sys.get_state(ModelManager)
        | eviction_continuations: %{eviction_ref => continuation}
      }

      try do
        assert {:noreply, next_state} =
                 ModelManager.handle_info({eviction_ref, %Ack{ok: true}}, state)

        assert_receive {^reply_ref, %{failure_code: "model_capacity_exhausted"}}, 1_000
        assert next_state.inflight_loads == %{}
        assert next_state.eviction_continuations == %{}
      after
        Application.put_env(:orchard_node_agent, :runtime, previous_runtime)
        release.()
      end
    end
  end

  # Holds reaper custody of a live OS process for the model, as a launched
  # runtime would. Without a launch identity its exit can only be confirmed by
  # the process actually exiting.
  defp hold_custody(model_id, version) do
    {control_port, control_pid} = CustodyTestHelpers.start_control_child!()
    owner_pid = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, _ref} =
      RuntimeProcessReaper.watch(owner_pid, control_pid, %{
        shutdown_timeout_ms: 200,
        model_ref: %{model_id: model_id, version: version},
        os_identity: nil,
        phase: :loaded,
        socket_path: nil
      })

    release = fn ->
      Process.exit(owner_pid, :kill)
      CustodyTestHelpers.stop_child(control_port, control_pid)
      CustodyTestHelpers.assert_reaper_empty!(10_000)
    end

    stop_runtime = fn -> CustodyTestHelpers.stop_child(control_port, control_pid) end

    on_exit(stop_runtime)
    %{owner_pid: owner_pid, release: release, stop_runtime: stop_runtime}
  end

  defp ensure(model_id, version),
    do: ModelManager.ensure_model_loaded(ensure_request(model_id, version))

  defp ensure_request(model_id, version) do
    %EnsureModelLoadedRequest{
      node_id: "node-local",
      model_id: model_id,
      version: version,
      artifact_sha256: String.duplicate("0", 64),
      preload: true,
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      artifact_source_uri: "file:///nonexistent"
    }
  end

  defp waiter(deadline_unix_ms) do
    %{
      id: make_ref(),
      from: {self(), make_ref()},
      deadline_unix_ms: deadline_unix_ms,
      timer_ref: nil
    }
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

    recovery_epoch = "model-manager-test-epoch"
    recovery_incarnation = "model-manager-test-worker"

    recovery =
      recovery_epoch
      |> WorkerRecoveryState.new()
      |> WorkerRecoveryState.hydrate(:absent)
      |> Map.put(:owner_epoch, recovery_epoch)
      |> Map.put(:revision, 1)
      |> Map.put(:last_worker_pid, worker_pid)
      |> put_in([:policy, :incarnation], recovery_incarnation)
      |> put_in([:ownership], %{
        "phase" => "loading",
        "incarnation" => recovery_incarnation,
        "custody" => "test-custody"
      })

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
      backend: "test",
      recovery_owner: false,
      recovery_incarnation: recovery_incarnation
    }

    state = %{
      active_requests: %{},
      inflight_loads: %{key => inflight},
      load_refs: %{task_ref => key},
      recovery: %{key => recovery},
      recovery_epoch: recovery_epoch,
      recovery_io_refs: %{},
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
    assert {:noreply, pending_state} =
             ModelManager.handle_info(
               {:model_load_finished, fixture.key, fixture.task_pid, {:ok, fixture.worker_pid}},
               fixture.state
             )

    pending = pending_state.recovery[fixture.key].pending

    checkpoint = %{
      epoch: pending.record["epoch"],
      revision: pending.revision + 1,
      transition_id: pending.id,
      record: pending.record
    }

    assert {:noreply, next_state} =
             ModelManager.handle_info(
               {:recovery_checkpoint_result, fixture.state.recovery_epoch, fixture.key,
                pending.id, {:ok, checkpoint}},
               pending_state
             )

    next_state
  end

  defp waiter_id(nil), do: nil
  defp waiter_id(waiter), do: waiter.id
end
