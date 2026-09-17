defmodule Orchard.Node.WorkerRecoveryManagerTest do
  use ExUnit.Case, async: false

  alias Orchard.ArtifactBundle
  alias Orchard.Cluster.V1.{EnsureModelLoadedRequest, ExecuteInferenceRequest, UnloadModelRequest}
  alias Orchard.Node

  alias Orchard.Node.{
    ModelManager,
    RuntimeAdapter,
    RuntimeEndpointMapper,
    WorkerRecoveryCustody,
    WorkerRecoveryState,
    WorkerSupervisor
  }

  alias Orchard.Node.Supervisor, as: NodeSupervisor

  @public_unload_call_timeout_ms 11_000

  defmodule Checkpoints do
    use Agent

    def start_link(_),
      do: Agent.start_link(fn -> %{rows: %{}, mode: :ok, calls: []} end, name: __MODULE__)

    def read(key) do
      delay = Agent.get(__MODULE__, &Map.get(&1, :read_delay, 0))
      if delay > 0, do: Process.sleep(delay)

      Agent.get(__MODULE__, fn state ->
        if state.mode == :read_unavailable,
          do: {:error, :unavailable},
          else: {:ok, Map.get(state.rows, key, :absent)}
      end)
    end

    def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})
    def read_delay(ms), do: Agent.update(__MODULE__, &Map.put(&1, :read_delay, ms))
    def calls, do: Agent.get(__MODULE__, & &1.calls)
    def now, do: Agent.get(__MODULE__, &Map.get(&1, :now, System.monotonic_time(:millisecond)))
    def time(now), do: Agent.update(__MODULE__, &Map.put(&1, :now, now))
    def seed(key, row), do: Agent.update(__MODULE__, &put_in(&1, [:rows, key], row))

    def commit(key, epoch, revision, id, record) do
      Agent.get_and_update(__MODULE__, fn state ->
        current = Map.get(state.rows, key)
        result = commit_result(state.mode, current, epoch, revision, id, record)

        rows =
          case result do
            {:ok, row} -> Map.put(state.rows, key, row)
            _ -> state.rows
          end

        {result,
         %{
           state
           | rows: rows,
             mode: next_mode(state.mode),
             calls: [{id, record, System.monotonic_time(:millisecond)} | state.calls]
         }}
      end)
    end

    defp next_mode(:stale_once), do: :ok
    defp next_mode(mode), do: mode

    defp commit_result(mode, current, epoch, revision, id, record) do
      cond do
        mode in [:stale_write, :stale_once] ->
          {:error, :stale_checkpoint}

        unavailable_write?(mode, record) ->
          {:error, :unavailable}

        replay?(current, id, record) ->
          {:ok, current}

        current_revision?(current, epoch, revision) ->
          {:ok,
           %{
             epoch: record["epoch"],
             revision: revision + 1,
             transition_id: id,
             record: record
           }}

        true ->
          {:error, :stale_checkpoint}
      end
    end

    defp unavailable_write?(:write_unavailable, _record), do: true

    defp unavailable_write?(:loaded_unavailable, record),
      do: record["ownership"]["phase"] == "loaded"

    defp unavailable_write?(:interrupt_unavailable, record),
      do: record["ownership"]["phase"] == "cleanup" and is_nil(record["command"])

    defp unavailable_write?(:completed_unavailable, record),
      do: get_in(record, ["command", "phase"]) == "completed"

    defp unavailable_write?(_mode, _record), do: false

    defp replay?(nil, _id, _record), do: false

    defp replay?(current, id, record),
      do: current.transition_id == id and current.record == record

    defp current_revision?(nil, nil, 0), do: true
    defp current_revision?(nil, _epoch, _revision), do: false

    defp current_revision?(current, epoch, revision),
      do: current.epoch == epoch and current.revision == revision
  end

  defmodule Custody do
    def resolve_current(pid), do: if(Process.alive?(pid), do: :unresolved, else: :resolved)
    def resolve_prior_worker_ownership(_, _), do: :unresolved

    def record_runtime_custody(_previous, owner_pid), do: "runtime-custody:#{inspect(owner_pid)}"
  end

  defmodule LoadingExitAdapter do
    defdelegate unload_model(state, opts), to: RuntimeAdapter.Unimplemented
    defdelegate get_status(state, opts), to: RuntimeAdapter.Unimplemented

    defdelegate start_generation(state, request, opts),
      to: RuntimeAdapter.Unimplemented

    defdelegate cancel_generation(state, ref, opts), to: RuntimeAdapter.Unimplemented
    defdelegate finish_generation(state, ref, opts), to: RuntimeAdapter.Unimplemented
    def load_model(_ref, _opts), do: {:error, {:worker_exited, 0}}
  end

  defmodule LoadErrorAdapter do
    defdelegate unload_model(state, opts), to: RuntimeAdapter.Unimplemented
    defdelegate get_status(state, opts), to: RuntimeAdapter.Unimplemented

    defdelegate start_generation(state, request, opts),
      to: RuntimeAdapter.Unimplemented

    defdelegate cancel_generation(state, ref, opts), to: RuntimeAdapter.Unimplemented
    defdelegate finish_generation(state, ref, opts), to: RuntimeAdapter.Unimplemented
    def load_model(_ref, _opts), do: {:error, :simulated_load_failure}
  end

  defmodule BlockingLoadAdapter do
    defdelegate unload_model(state, opts), to: RuntimeAdapter.Unimplemented
    defdelegate get_status(state, opts), to: RuntimeAdapter.Unimplemented

    defdelegate start_generation(state, request, opts),
      to: RuntimeAdapter.Unimplemented

    defdelegate cancel_generation(state, ref, opts), to: RuntimeAdapter.Unimplemented
    defdelegate finish_generation(state, ref, opts), to: RuntimeAdapter.Unimplemented

    def owner(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)
    def clear, do: :persistent_term.erase({__MODULE__, :owner})

    def load_model(_ref, _opts) do
      send(:persistent_term.get({__MODULE__, :owner}), {:recovery_load_blocked, self()})

      receive do
        :finish_recovery_load -> {:ok, %{}}
      end
    end
  end

  setup do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    root = Path.join(System.tmp_dir!(), "orchard-379-#{System.unique_integer([:positive])}")
    start_supervised!(Checkpoints)
    BlockingLoadAdapter.clear()
    :ok = Supervisor.terminate_child(NodeSupervisor, ModelManager)

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.merge(runtime,
        models_root: root,
        worker_backend: "stub",
        worker_recovery_checkpoint_client: Checkpoints,
        worker_recovery_custody: Custody,
        max_loaded_models: 1
      )
    )

    start_supervised!(ModelManager)
    source = Path.join(root, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "config.json"), ~s({"model_type":"test"}))
    File.write!(Path.join(source, "tokenizer.json"), ~s({"version":"1.0"}))
    File.write!(Path.join(source, "model.safetensors"), "test-weights")
    {:ok, hash} = ArtifactBundle.tree_sha256(source)

    request = %EnsureModelLoadedRequest{
      node_id: Node.node_id(),
      model_id: "recovery/test",
      version: "v1",
      artifact_sha256: hash,
      artifact_source_uri: "file://" <> source,
      deadline_unix_ms: System.system_time(:millisecond) + 15_000
    }

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(WorkerSupervisor),
          is_pid(pid),
          do: DynamicSupervisor.terminate_child(WorkerSupervisor, pid)

      BlockingLoadAdapter.clear()
      Application.put_env(:orchard_node_agent, :runtime, runtime)
      Supervisor.restart_child(NodeSupervisor, ModelManager)
      File.rm_rf!(root)
    end)

    %{request: request, key: {request.model_id, request.version}}
  end

  test "SPEC §12.2.2 the loaded checkpoint records runtime custody for the admitted worker",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, worker} = worker_pid(ctx)

    assert {:ok, %{record: record}} = Checkpoints.read(checkpoint_key(ctx))
    assert record["ownership"]["phase"] == "loaded"
    assert record["ownership"]["custody"] == Custody.record_runtime_custody(nil, worker)
  end

  test "SPEC §12.2 manager restart retains prior ownership and cannot treat its empty worker map as cleanup",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, worker} = worker_pid(ctx)
    {:ok, before} = inspect_key(ctx)
    :ok = stop_supervised(ModelManager)
    start_supervised!(ModelManager)
    assert {:ok, after_restart} = inspect_key(ctx)
    refute after_restart.epoch == before.epoch
    assert after_restart.owner_epoch == before.epoch
    assert after_restart.state == "recovery_required"
    refute after_restart.eligible
    assert Process.alive?(worker)

    assert ModelManager.ensure_model_loaded(ctx.request).recovery_refusal ==
             "placement_recovery_required"

    assert {:error, :unavailable} =
             ModelManager.recover_worker_placement(command(ctx, after_restart, "clear"))

    assert :sys.get_state(ModelManager).workers == %{}
  end

  test "SPEC §12.2 cold load checkpoints ownership before spawn and loaded before eligibility",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    assert {:ok, %{eligible: true, revision: 2, key: exact}} = inspect_key(ctx)
    assert exact.node_id == ctx.request.node_id
    records = Checkpoints.calls() |> Enum.reverse() |> Enum.map(&elem(&1, 1))
    assert Enum.map(records, & &1["ownership"]["phase"]) == ["loading", "loaded"]
    assert hd(records)["ownership"]["incarnation"] != nil
  end

  test "SPEC §12.2 death while loaded acknowledgement is unavailable cannot publish success",
       ctx do
    Checkpoints.mode(:loaded_unavailable)
    task = Task.async(fn -> ModelManager.ensure_model_loaded(ctx.request) end)

    eventually(fn ->
      case :sys.get_state(ModelManager).recovery[ctx.key] do
        %{pending: %{record: %{"ownership" => %{"phase" => "loaded"}}}} -> true
        _ -> false
      end
    end)

    worker = :sys.get_state(ModelManager).workers[ctx.key].pid
    Process.exit(worker, :kill)
    eventually(fn -> match?({:ok, %{state: "backoff", eligible: false}}, inspect_key(ctx)) end)
    Checkpoints.mode(:ok)
    refute Task.await(task, 5_000).placement_state == :PLACEMENT_STATE_LOADED
    assert length(:sys.get_state(ModelManager).recovery[ctx.key].policy.history) == 1
  end

  test "SPEC §12.2 write outage admits no worker and retry is paced", ctx do
    Checkpoints.mode(:write_unavailable)
    task = Task.async(fn -> ModelManager.ensure_model_loaded(ctx.request) end)
    eventually(fn -> length(Checkpoints.calls()) == 1 end)
    assert :error = worker_pid(ctx)
    assert {:ok, %{state: "armed", eligible: true}} = inspect_key(ctx)
    Process.sleep(150)
    assert length(Checkpoints.calls()) == 1
    Checkpoints.mode(:ok)
    assert Task.await(task, 5_000).placement_state == :PLACEMENT_STATE_LOADED
    [first, second | _] = Enum.reverse(Checkpoints.calls())
    assert elem(first, 0) == elem(second, 0)
    assert elem(second, 2) - elem(first, 2) >= 1_000
  end

  test "SPEC §12.2 a matching ensure joins the pending admission checkpoint without spawning early",
       ctx do
    Checkpoints.mode(:write_unavailable)
    leader = Task.async(fn -> ModelManager.ensure_model_loaded(ctx.request) end)

    eventually(fn ->
      match?(
        %{pending: %{record: %{"ownership" => %{"phase" => "loading"}}}},
        :sys.get_state(ModelManager).recovery[ctx.key]
      )
    end)

    follower = Task.async(fn -> ModelManager.ensure_model_loaded(ctx.request) end)
    Process.sleep(50)
    assert :error = worker_pid(ctx)
    assert length(Checkpoints.calls()) == 1

    Checkpoints.mode(:ok)
    assert Task.await(leader, 5_000).placement_state == :PLACEMENT_STATE_LOADED
    assert Task.await(follower, 5_000).placement_state == :PLACEMENT_STATE_LOADED
  end

  test "SPEC §12.2 crashed residency restarts without request waiters and retains one slot",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, old} = worker_pid(ctx)
    Process.exit(old, :kill)
    eventually(fn -> match?({:ok, %{state: "backoff"}}, inspect_key(ctx)) end)

    assert ModelManager.ensure_model_loaded(ctx.request).recovery_refusal ==
             "placement_recovery_required"

    other = %{ctx.request | model_id: "recovery/other"}
    assert ModelManager.ensure_model_loaded(other).failure_code == "model_capacity_exhausted"

    eventually(fn ->
      case worker_pid(ctx) do
        {:ok, pid} -> pid != old
        _ -> false
      end
    end)

    assert {:ok, %{eligible: true}} = inspect_key(ctx)
    assert :sys.get_state(ModelManager).recovery[ctx.key].policy.delay_index == 1
    assert :sys.get_state(ModelManager).active_requests == %{}
  end

  test "SPEC §12.2 explicit absent clear is durable and duplicates cannot clear a later crash",
       ctx do
    assert {:ok, evidence} = inspect_key(ctx)
    command = command(ctx, evidence, "clear")
    assert {:ok, %{eligible: true}} = ModelManager.recover_worker_placement(command)
    count = length(Checkpoints.calls())
    assert {:ok, _} = ModelManager.recover_worker_placement(command)
    assert length(Checkpoints.calls()) == count

    assert {:error, :conflict} =
             ModelManager.recover_worker_placement(%{command | reason: "different"})

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, worker} = worker_pid(ctx)
    Process.exit(worker, :kill)
    eventually(fn -> match?({:ok, %{state: "backoff"}}, inspect_key(ctx)) end)
    assert {:ok, %{eligible: false}} = ModelManager.recover_worker_placement(command)
    assert :sys.get_state(ModelManager).recovery[ctx.key].policy.delay_index == 1
  end

  test "SPEC §12.2 loaded clear and busy nonforced recovery unload conflict; forced reload completes",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, evidence} = inspect_key(ctx)

    assert {:error, :conflict} =
             ModelManager.recover_worker_placement(command(ctx, evidence, "clear"))

    execute = %ExecuteInferenceRequest{
      request_id: "prepared",
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

    assert :ok = ModelManager.prepare_request(execute, self())

    assert {:error, :conflict} =
             ModelManager.recover_worker_placement(command(ctx, evidence, "unload"))

    reload = command(ctx, evidence, "reload") |> Map.put(:load_request, ctx.request)
    assert {:ok, %{eligible: true}} = ModelManager.recover_worker_placement(reload)
    assert :sys.get_state(ModelManager).active_requests == %{}

    assert {:ok, _} =
             ModelManager.recover_worker_placement(
               put_in(reload.load_request.deadline_unix_ms, 99)
             )

    assert {:error, :conflict} =
             ModelManager.recover_worker_placement(
               put_in(reload.load_request.artifact_sha256, String.duplicate("b", 64))
             )
  end

  test "SPEC §12.2 BEAM-only stub cleanup requires an explicit reaper ownership receipt", ctx do
    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.delete(Node.runtime_config(), :worker_recovery_custody)
    )

    unrelated = spawn(fn -> :ok end)
    monitor = Process.monitor(unrelated)
    assert_receive {:DOWN, ^monitor, :process, ^unrelated, _}
    assert :unresolved = WorkerRecoveryCustody.resolve_current(unrelated)

    assert :unresolved =
             WorkerRecoveryCustody.resolve_prior_worker_ownership(
               ctx.key,
               "not-a-boot-identity"
             )

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, worker} = worker_pid(ctx)
    Process.exit(worker, :kill)
    eventually(fn -> WorkerRecoveryCustody.resolve_current(worker) == :resolved end)
    eventually(fn -> match?({:ok, %{eligible: true}}, inspect_key(ctx)) end)
    assert {:ok, replacement} = worker_pid(ctx)
    refute replacement == worker
    assert :ok = ModelManager.reset()
  end

  test "SPEC §12.2 resolved nonclean checkpoint permits explicit recovery after restart", ctx do
    entry = WorkerRecoveryState.new("old-epoch")

    record =
      entry
      |> put_in([:policy, :state], :recovery_required)
      |> WorkerRecoveryState.record()

    exact = %{
      node_id: ctx.request.node_id,
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

    Checkpoints.seed(exact, %{
      epoch: "old-epoch",
      revision: 7,
      record: record,
      transition_id: "resolved-nonclean"
    })

    assert {:ok, %{state: "recovery_required", revision: 8} = evidence} = inspect_key(ctx)
    refute :sys.get_state(ModelManager).recovery[ctx.key].prior?
    assert evidence.owner_epoch == evidence.epoch

    assert {:ok, %{state: "armed", eligible: true}} =
             ModelManager.recover_worker_placement(command(ctx, evidence, "clear"))
  end

  test "SPEC §12.2 cold inspection releases clean recovery retention and bounds status placements" do
    for index <- 1..41 do
      assert {:ok, %{eligible: true}} =
               ModelManager.inspect_worker_recovery("cold/#{index}", "v1")
    end

    assert :sys.get_state(ModelManager).recovery == %{}
    assert ModelManager.current().runtime_model_placements == []

    :sys.replace_state(ModelManager, fn state ->
      recovery =
        Map.new(1..41, fn index ->
          entry =
            state.recovery_epoch
            |> WorkerRecoveryState.new()
            |> WorkerRecoveryState.hydrate(:absent)
            |> put_in([:policy, :state], :open)

          {{"retained/#{index}", "v1"}, entry}
        end)

      %{state | recovery: recovery}
    end)

    assert length(ModelManager.current().runtime_model_placements) == 40
  end

  test "SPEC §12.2 retained recovery entries cannot displace a loaded placement from the payload",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    :sys.replace_state(ModelManager, fn state ->
      retained =
        Map.new(1..41, fn index ->
          entry =
            state.recovery_epoch
            |> WorkerRecoveryState.new()
            |> WorkerRecoveryState.hydrate(:absent)
            |> put_in([:policy, :state], :open)

          {{"cold/#{index}", "v1"}, entry}
        end)

      %{state | recovery: Map.merge(state.recovery, retained)}
    end)

    status = ModelManager.current()
    assert length(status.runtime_model_placements) == 40

    observation = RuntimeEndpointMapper.observation_from_status(nil, status)
    assert length(observation.placements) == 40

    assert [loaded] =
             Enum.filter(
               observation.placements,
               &(&1.model_ref.model_id == ctx.request.model_id)
             )

    assert loaded.state == :loaded
    assert loaded.worker_recovery["eligible"] == true
    assert loaded.capacity.max_concurrency > 0
  end

  test "SPEC §12.2 a rejected stale hydration checkpoint replies to its waiter before rehydrating",
       ctx do
    exact = %{
      node_id: ctx.request.node_id,
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

    Checkpoints.seed(exact, %{
      epoch: "old-epoch",
      revision: 4,
      record: WorkerRecoveryState.record(WorkerRecoveryState.new("old-epoch")),
      transition_id: "stale-clean-hydration"
    })

    Checkpoints.mode(:stale_once)

    assert %{ok: false, message: "recovery checkpoint unavailable"} =
             ModelManager.unload_model(%UnloadModelRequest{
               model_id: ctx.request.model_id,
               version: ctx.request.version
             })

    eventually(fn -> match?({:ok, %{state: "armed", eligible: true}}, inspect_key(ctx)) end)
  end

  test "SPEC §12.2 an unavailable epoch-claim checkpoint answers its parked unload waiter", ctx do
    exact = %{
      node_id: ctx.request.node_id,
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

    Checkpoints.seed(exact, %{
      epoch: "old-epoch",
      revision: 4,
      record: WorkerRecoveryState.record(WorkerRecoveryState.new("old-epoch")),
      transition_id: "stale-clean-hydration"
    })

    Checkpoints.mode(:write_unavailable)

    assert %{ok: false, message: "recovery checkpoint unavailable"} =
             ModelManager.unload_model(%UnloadModelRequest{
               model_id: ctx.request.model_id,
               version: ctx.request.version
             })

    assert :sys.get_state(ModelManager).recovery[ctx.key].pending
  end

  # SPEC.md §12.2.1: an unacknowledged pre-effect checkpoint is neither a crash
  # nor a non-crash restart failure, so a claim blocked behind it must defer
  # rather than report worker_unavailable — which §5.10 would otherwise classify
  # as worker_or_node_loss and count toward the Controller placement breaker.
  test "SPEC §12.2 a claim blocked by an unacknowledged epoch claim defers instead of failing",
       ctx do
    exact = %{
      node_id: ctx.request.node_id,
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

    Checkpoints.seed(exact, %{
      epoch: "old-epoch",
      revision: 4,
      record: WorkerRecoveryState.record(WorkerRecoveryState.new("old-epoch")),
      transition_id: "stale-clean-hydration"
    })

    Checkpoints.mode(:write_unavailable)

    assert %{ok: false, message: "recovery checkpoint unavailable"} =
             ModelManager.unload_model(%UnloadModelRequest{
               model_id: ctx.request.model_id,
               version: ctx.request.version
             })

    assert :sys.get_state(ModelManager).recovery[ctx.key].pending

    Checkpoints.mode(:ok)

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED
  end

  test "SPEC §12.2 the application stop hook checkpoints the intentional stop", ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    assert Orchard.NodeAgent.Application.prep_stop(:stopping) == :stopping

    assert ModelManager.ensure_model_loaded(ctx.request).recovery_refusal ==
             "placement_recovery_required"

    assert :error = worker_pid(ctx)
  end

  test "SPEC §12.2 stale checkpoint replies unavailable, rehydrates, and permits a fresh recovery command",
       ctx do
    assert {:ok, evidence} = inspect_key(ctx)
    Checkpoints.mode(:stale_write)

    assert {:error, :unavailable} =
             ModelManager.recover_worker_placement(command(ctx, evidence, "clear"))

    eventually(fn ->
      :sys.get_state(ModelManager).recovery_hydrations == %{} and
        match?(
          %{hydrated?: true, pending: nil, desired: nil},
          :sys.get_state(ModelManager).recovery[ctx.key]
        )
    end)

    Checkpoints.mode(:ok)
    assert {:ok, current} = inspect_key(ctx)

    assert {:ok, %{eligible: true}} =
             ModelManager.recover_worker_placement(
               command(ctx, current, "clear")
               |> Map.put(:command_id, "command-clear-retry")
             )
  end

  test "SPEC §12.2 reset waits for durable cleanup and shutdown refuses new loads", ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, worker} = worker_pid(ctx)
    assert :ok = ModelManager.reset()
    refute Process.alive?(worker)
    entry = :sys.get_state(ModelManager).recovery[ctx.key]
    assert entry.ownership["phase"] == "resolved"
    assert entry.pending == nil
    assert entry.desired == nil
    assert entry.policy.history == []

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    assert :ok = ModelManager.prepare_shutdown()

    assert ModelManager.ensure_model_loaded(ctx.request).recovery_refusal ==
             "placement_recovery_required"

    assert {:ok, evidence} = inspect_key(ctx)
    reload = command(ctx, evidence, "reload") |> Map.put(:load_request, ctx.request)
    assert {:error, :unavailable} = ModelManager.recover_worker_placement(reload)
    assert :error = worker_pid(ctx)
  end

  test "SPEC §12.2 stale asynchronous worker-start notifications cannot replace current custody",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, worker} = worker_pid(ctx)
    send(ModelManager, {:model_load_worker_started, ctx.key, self(), self()})
    assert {:ok, ^worker} = worker_pid(ctx)
    assert Process.alive?(worker)
  end

  test "SPEC §12.2 pending unload cannot be superseded by a late successful load", ctx do
    BlockingLoadAdapter.owner(self())

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(Node.runtime_config(), :runtime_adapter_impl, BlockingLoadAdapter)
    )

    load_task = Task.async(fn -> ModelManager.ensure_model_loaded(ctx.request) end)
    assert_receive {:recovery_load_blocked, adapter_pid}, 5_000

    Checkpoints.mode(:interrupt_unavailable)

    unload_task =
      Task.async(fn ->
        ModelManager.unload_model(%UnloadModelRequest{
          model_id: ctx.request.model_id,
          version: ctx.request.version
        })
      end)

    eventually(fn ->
      match?(
        %{pending: %{record: %{"ownership" => %{"phase" => "cleanup"}}}},
        :sys.get_state(ModelManager).recovery[ctx.key]
      )
    end)

    assert ModelManager.ensure_model_loaded(ctx.request).recovery_refusal ==
             "placement_recovery_required"

    assert {:error, {:worker_recovery_refused, :placement_recovery_required}} =
             ModelManager.prepare_request(
               %ExecuteInferenceRequest{
                 request_id: "pending-intentional-unload",
                 model_id: ctx.request.model_id,
                 version: ctx.request.version
               },
               self()
             )

    send(adapter_pid, :finish_recovery_load)
    Process.sleep(50)

    entry = :sys.get_state(ModelManager).recovery[ctx.key]
    assert entry.ownership["phase"] == "cleanup"
    assert entry.policy.incarnation == nil

    Checkpoints.mode(:ok)
    assert %{ok: true} = Task.await(unload_task, 5_000)
    refute Task.await(load_task, 5_000).placement_state == :PLACEMENT_STATE_LOADED
    assert :error = worker_pid(ctx)
  end

  test "SPEC §12.2 a superseded unload checkpoint replies rather than leaving its caller waiting",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    Checkpoints.mode(:interrupt_unavailable)

    first_unload =
      Task.async(fn ->
        ModelManager.unload_model(%UnloadModelRequest{
          model_id: ctx.request.model_id,
          version: ctx.request.version
        })
      end)

    eventually(fn ->
      match?(
        %{pending: %{record: %{"ownership" => %{"phase" => "cleanup"}}}},
        :sys.get_state(ModelManager).recovery[ctx.key]
      )
    end)

    second_unload =
      Task.async(fn ->
        ModelManager.unload_model(%UnloadModelRequest{
          model_id: ctx.request.model_id,
          version: ctx.request.version
        })
      end)

    assert %{ok: false, message: "recovery checkpoint superseded"} =
             Task.await(first_unload, 5_000)

    Checkpoints.mode(:ok)
    assert %{ok: true} = Task.await(second_unload, 5_000)
  end

  test "SPEC §12.2 ordinary unload returns one bounded negative acknowledgement when cleanup stays unavailable",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    Checkpoints.mode(:interrupt_unavailable)

    unload =
      Task.async(fn ->
        ModelManager.unload_model(%UnloadModelRequest{
          model_id: ctx.request.model_id,
          version: ctx.request.version
        })
      end)

    {epoch, waiter_id} =
      eventually_value(fn ->
        case :sys.get_state(ModelManager).recovery[ctx.key] do
          %{ownership: %{"phase" => "cleanup"}, stop_waiters: [{waiter_id, _from, _ack, _timer}]} =
              entry ->
            {entry.epoch, waiter_id}

          _other ->
            nil
        end
      end)

    send(ModelManager, {:ordinary_unload_deadline, epoch, ctx.key, waiter_id})

    assert %{ok: false, message: "recovery checkpoint unavailable"} = Task.await(unload, 5_000)

    eventually(fn -> :sys.get_state(ModelManager).recovery[ctx.key].stop_waiters == [] end)
    send(ModelManager, {:ordinary_unload_deadline, epoch, ctx.key, waiter_id})
    assert Process.alive?(Process.whereis(ModelManager))
  end

  test "SPEC §12.2 the bounded unload deadline is anchored at the call, not after hydration",
       ctx do
    Checkpoints.read_delay(2_000)
    Checkpoints.mode(:write_unavailable)
    called_at = System.monotonic_time(:millisecond)

    unload =
      Task.async(fn ->
        ModelManager.unload_model(%UnloadModelRequest{
          model_id: ctx.request.model_id,
          version: ctx.request.version
        })
      end)

    {epoch, waiter_id, timer_ref} =
      eventually_value(fn ->
        case :sys.get_state(ModelManager).recovery[ctx.key] do
          %{stop_waiters: [{waiter_id, _from, _ack, timer_ref}]} = entry ->
            {entry.epoch, waiter_id, timer_ref}

          _other ->
            nil
        end
      end)

    remaining = Process.read_timer(timer_ref)
    hydration_ms = System.monotonic_time(:millisecond) - called_at

    assert is_integer(remaining)
    assert hydration_ms >= 2_000
    assert hydration_ms + remaining < @public_unload_call_timeout_ms

    send(ModelManager, {:ordinary_unload_deadline, epoch, ctx.key, waiter_id})
    assert %{ok: false, message: "recovery checkpoint unavailable"} = Task.await(unload, 5_000)
  end

  test "SPEC §12.2 duplicate recovery waits for its durable completion checkpoint", ctx do
    assert {:ok, evidence} = inspect_key(ctx)
    command = command(ctx, evidence, "clear")
    Checkpoints.mode(:completed_unavailable)

    operation = Task.async(fn -> ModelManager.recover_worker_placement(command) end)

    eventually(fn ->
      match?(
        %{command: %{"phase" => "completed", "outcome" => "ok"}, pending: %{}},
        :sys.get_state(ModelManager).recovery[ctx.key]
      )
    end)

    assert {:error, :unavailable} = ModelManager.recover_worker_placement(command)
    Checkpoints.mode(:ok)
    assert {:ok, %{eligible: true}} = Task.await(operation, 5_000)
  end

  test "SPEC §12.2 forced reload resource refusal completes unavailable", ctx do
    resident = %{ctx.request | model_id: "recovery/resident"}
    assert ModelManager.ensure_model_loaded(resident).placement_state == :PLACEMENT_STATE_LOADED
    assert {:ok, evidence} = inspect_key(ctx)

    reload = command(ctx, evidence, "reload") |> Map.put(:load_request, ctx.request)
    assert {:error, :unavailable} = ModelManager.recover_worker_placement(reload)

    assert {:ok, %{state: "recovery_required", eligible: false}} = inspect_key(ctx)
    assert :error = worker_pid(ctx)
    assert :sys.get_state(ModelManager).recovery[ctx.key].command["outcome"] == "unavailable"
  end

  test "SPEC §12.2 ordinary unload fences backoff without clearing policy", ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, worker} = worker_pid(ctx)
    Process.exit(worker, :kill)
    eventually(fn -> match?({:ok, %{state: "backoff"}}, inspect_key(ctx)) end)

    assert %{ok: true} =
             ModelManager.unload_model(%UnloadModelRequest{
               model_id: ctx.request.model_id,
               version: ctx.request.version
             })

    assert {:ok, %{state: "recovery_required", eligible: false}} = inspect_key(ctx)
    Process.sleep(1_100)
    assert :error = worker_pid(ctx)
  end

  test "SPEC §12.2 an outstanding stability-reset checkpoint still admits execution", ctx do
    runtime = Node.runtime_config()
    Checkpoints.time(0)

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(runtime, :worker_recovery_clock, &Checkpoints.now/0)
    )

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    {:ok, crashed} = worker_pid(ctx)
    Process.exit(crashed, :kill)
    eventually(fn -> match?(%{state: :backoff}, recovery_policy(ctx)) end)
    Checkpoints.time(recovery_policy(ctx).due_ms)

    send(
      Process.whereis(ModelManager),
      {:recovery_timer, :sys.get_state(ModelManager).recovery[ctx.key].epoch, ctx.key,
       recovery_policy(ctx).fence}
    )

    eventually(fn -> match?({:ok, _}, worker_pid(ctx)) end)
    eventually(fn -> is_nil(:sys.get_state(ModelManager).recovery[ctx.key].pending) end)

    policy = recovery_policy(ctx)
    assert policy.state == :armed
    assert policy.history != []
    assert policy.delay_index > 0

    Checkpoints.mode(:write_unavailable)
    Checkpoints.time(policy.loaded_since + 600_001)

    send(
      Process.whereis(ModelManager),
      {:recovery_stable, :sys.get_state(ModelManager).recovery[ctx.key].epoch, ctx.key,
       policy.incarnation}
    )

    eventually(fn ->
      match?(
        %{desired: desired} when not is_nil(desired),
        :sys.get_state(ModelManager).recovery[
          ctx.key
        ]
      )
    end)

    assert {:ok, %{state: "armed", eligible: true, reason: nil}} = inspect_key(ctx)

    execute = %ExecuteInferenceRequest{
      request_id: "stability-reset-pending",
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

    assert :ok = ModelManager.prepare_request(execute, self())

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    Checkpoints.mode(:ok)
  end

  test "SPEC §12.2 fifth actual crash opens before any fifth replacement; stale timer cannot bypass",
       ctx do
    runtime = Node.runtime_config()
    Checkpoints.time(0)

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(runtime, :worker_recovery_clock, &Checkpoints.now/0)
    )

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    Enum.each(1..5, fn ordinal ->
      {:ok, pid} = worker_pid(ctx)
      Process.exit(pid, :kill)

      eventually(fn ->
        length(:sys.get_state(ModelManager).recovery[ctx.key].policy.history) == ordinal
      end)

      eventually(fn -> is_nil(:sys.get_state(ModelManager).recovery[ctx.key].pending) end)
      entry = :sys.get_state(ModelManager).recovery[ctx.key]

      if ordinal < 5 do
        assert entry.policy.state == :backoff
        Checkpoints.time(entry.policy.due_ms)

        send(
          Process.whereis(ModelManager),
          {:recovery_timer, entry.epoch, ctx.key, entry.policy.fence}
        )

        eventually(fn -> match?({:ok, _}, worker_pid(ctx)) end)
      else
        assert entry.policy.state == :open
        assert entry.policy.due_ms == nil

        send(
          Process.whereis(ModelManager),
          {:recovery_timer, entry.epoch, ctx.key, entry.policy.fence - 1}
        )
      end
    end)

    assert :error = worker_pid(ctx)

    assert ModelManager.ensure_model_loaded(ctx.request).recovery_refusal ==
             "placement_recovery_required"

    assert {:ok, %{state: "open"}} = inspect_key(ctx)
    status = ModelManager.current()
    assert status.loaded_models == []
    assert [%{worker_recovery_json: json}] = status.runtime_model_placements
    assert Jason.decode!(json)["state"] == "open"
  end

  test "SPEC §12.2 prior loaded ownership is not clean and unknown custody refuses clear", ctx do
    record =
      WorkerRecoveryState.new("old-epoch")
      |> WorkerRecoveryState.hydrate(:absent)
      |> WorkerRecoveryState.record()

    record = %{
      record
      | "ownership" => %{
          "phase" => "loaded",
          "incarnation" => "old-worker",
          "custody" => "old-custody"
        }
    }

    exact = %{
      node_id: ctx.request.node_id,
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

    Checkpoints.seed(exact, %{
      epoch: "old-epoch",
      revision: 7,
      record: record,
      transition_id: "old-transition"
    })

    assert {:ok, %{state: "recovery_required", owner_epoch: "old-epoch", revision: 7} = evidence} =
             inspect_key(ctx)

    assert {:error, :unavailable} =
             ModelManager.recover_worker_placement(command(ctx, evidence, "clear"))

    assert Checkpoints.calls() == []

    assert ModelManager.ensure_model_loaded(ctx.request).recovery_refusal ==
             "placement_recovery_required"
  end

  test "SPEC §12.2 proven clean old checkpoint claims epoch before a normal cold load", ctx do
    record =
      WorkerRecoveryState.new("old-epoch")
      |> WorkerRecoveryState.hydrate(:absent)
      |> WorkerRecoveryState.record()

    exact = %{
      node_id: ctx.request.node_id,
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

    Checkpoints.seed(exact, %{
      epoch: "old-epoch",
      revision: 7,
      record: record,
      transition_id: "clean-stop"
    })

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    assert {:ok, %{eligible: true, revision: 10}} = inspect_key(ctx)

    assert ["resolved", "loading", "loaded"] ==
             Checkpoints.calls()
             |> Enum.reverse()
             |> Enum.map(fn {_, r, _} -> r["ownership"]["phase"] end)
  end

  test "SPEC §12.2 non-crash recovery load failure stops automation without a synthetic crash",
       ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    runtime = Node.runtime_config()

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(runtime, :runtime_adapter_impl, LoadErrorAdapter)
    )

    {:ok, pid} = worker_pid(ctx)
    Process.exit(pid, :kill)
    eventually(fn -> match?({:ok, %{state: "recovery_required"}}, inspect_key(ctx)) end)
    entry = :sys.get_state(ModelManager).recovery[ctx.key]
    assert length(entry.policy.history) == 1
    assert entry.policy.delay_index == 1
  end

  test "SPEC §12.2 actual loading exit counts once, ordinary runtime load error does not", ctx do
    runtime = Node.runtime_config()

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(runtime, :runtime_adapter_impl, LoadingExitAdapter)
    )

    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_FAILED

    eventually(fn -> match?({:ok, %{state: "backoff"}}, inspect_key(ctx)) end)
    assert length(:sys.get_state(ModelManager).recovery[ctx.key].policy.history) == 1

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(runtime, :runtime_adapter_impl, LoadErrorAdapter)
    )

    other = %{ctx.request | model_id: "ordinary/error"}

    Application.put_env(
      :orchard_node_agent,
      :runtime,
      Keyword.put(Node.runtime_config(), :max_loaded_models, 2)
    )

    assert ModelManager.ensure_model_loaded(other).placement_state == :PLACEMENT_STATE_FAILED
    entry = :sys.get_state(ModelManager).recovery[{other.model_id, other.version}]
    assert entry.policy.history == []
    assert entry.policy.delay_index == 0
  end

  test "SPEC §12.2 eviction resumes admission only after victim stop is committed", ctx do
    assert ModelManager.ensure_model_loaded(ctx.request).placement_state ==
             :PLACEMENT_STATE_LOADED

    other = %{ctx.request | model_id: "replacement/model"}
    assert ModelManager.ensure_model_loaded(other).placement_state == :PLACEMENT_STATE_LOADED
    assert :error = worker_pid(ctx)
    assert :sys.get_state(ModelManager).recovery[ctx.key].ownership["phase"] == "resolved"
    assert :sys.get_state(ModelManager).recovery[ctx.key].policy.history == []
  end

  defp worker_pid(ctx), do: GenServer.call(ModelManager, {:loaded_worker_pid, ctx.key})

  defp checkpoint_key(ctx),
    do: %{
      node_id: ctx.request.node_id,
      model_id: ctx.request.model_id,
      version: ctx.request.version
    }

  defp inspect_key(ctx),
    do: ModelManager.inspect_worker_recovery(elem(ctx.key, 0), elem(ctx.key, 1))

  defp recovery_policy(ctx), do: :sys.get_state(ModelManager).recovery[ctx.key].policy

  defp command(ctx, evidence, action),
    do: %{
      key: %{
        node_id: ctx.request.node_id,
        model_id: ctx.request.model_id,
        version: ctx.request.version
      },
      expected_epoch: evidence.epoch,
      expected_revision: evidence.revision,
      command_id: "command-#{action}",
      action: action,
      reason: "operator diagnosis"
    }

  defp eventually_value(fun, attempts \\ 120)
  defp eventually_value(_fun, 0), do: flunk("expected a recovery value")

  defp eventually_value(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(25)
        eventually_value(fun, attempts - 1)

      value ->
        value
    end
  end

  defp eventually(fun, attempts \\ 120)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          eventually(fun, attempts - 1)
        )
  end
end
