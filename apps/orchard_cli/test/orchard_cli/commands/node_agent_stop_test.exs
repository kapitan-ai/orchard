defmodule OrchardCLI.Commands.NodeAgentStopTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.NodeAgentStop

  @service %{
    id: :node_agent,
    label: "com.orchard.node-agent",
    plist_path: "/tmp/com.orchard.node-agent.plist",
    display_name: "Node Agent"
  }

  test "lock contention prevents Node Agent lifecycle mutation" do
    parent = self()

    runtime =
      runtime(%{
        with_lifecycle_lock: fn _callback -> {:error, :locked} end,
        bootout: fn _lock, _service -> send(parent, :bootout) end,
        signal_process: fn _lock, _identity -> send(parent, :signal) end
      })

    assert {:error, message, 1} = NodeAgentStop.stop(@service, runtime)
    assert message =~ "lifecycle operation is already in progress"
    refute_receive :bootout
    refute_receive :signal
  end

  test "loaded Node Agent is booted out while locked and reports success only after exit proof" do
    parent = self()
    identity = process_identity(4242)

    runtime =
      runtime(%{
        job_state: sequence1([:loaded, :unloaded, :unloaded]),
        process_snapshot:
          sequence1([
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, []},
            {:ok, []}
          ]),
        bootout: fn :lock, @service -> event(parent, :bootout, :ok) end,
        process_identity_state: fn ^identity -> :exited end
      })

    assert {:stopped, @service} = NodeAgentStop.stop(@service, runtime)
    assert_receive {:event, :bootout}
  end

  test "already stopped Node Agent returns without launchd or process mutation" do
    parent = self()

    runtime =
      runtime(%{
        job_state: sequence1([:unloaded, :unloaded]),
        process_snapshot: sequence1(List.duplicate({:ok, []}, 4)),
        bootout: fn _lock, _service -> send(parent, :bootout) end,
        signal_process: fn _lock, _identity -> send(parent, :signal) end
      })

    assert {:already_stopped, @service} = NodeAgentStop.stop(@service, runtime)
    refute_receive :bootout
    refute_receive :signal
  end

  test "captured process exit wait is bounded" do
    identity = process_identity(4242)

    runtime =
      runtime(%{
        job_state: sequence1([:loaded, :unloaded]),
        process_snapshot:
          sequence1([
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, [identity]}
          ]),
        process_identity_state: fn ^identity -> :alive end,
        exit_timeout_ms: 0,
        monotonic_ms: fn -> 0 end
      })

    assert {:error, message, 1} = NodeAgentStop.stop(@service, runtime)
    assert message =~ "timeout"
  end

  test "an alive-to-empty observation race is retried until exit is proven" do
    identity = process_identity(4242)

    runtime =
      runtime(%{
        job_state: sequence1([:loaded, :unloaded, :unloaded]),
        process_snapshot:
          sequence1([
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, []},
            {:ok, []},
            {:ok, []}
          ]),
        process_identity_state: sequence1([:alive, :exited])
      })

    assert {:stopped, @service} = NodeAgentStop.stop(@service, runtime)
  end

  test "unloaded orphan is signaled by exact identity while the lock is held" do
    parent = self()
    identity = process_identity(4242)

    runtime =
      runtime(%{
        job_state: sequence1([:unloaded, :unloaded]),
        process_snapshot:
          sequence1([
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, []},
            {:ok, []}
          ]),
        signal_process: fn :lock, ^identity -> event(parent, :signal, :ok) end,
        process_identity_state: fn ^identity -> :exited end
      })

    assert {:stopped, @service} = NodeAgentStop.stop(@service, runtime)
    assert_receive {:event, :signal}
  end

  test "replacement process prevents a successful stop result" do
    identity = process_identity(4242)
    replacement = process_identity(4343)

    runtime =
      runtime(%{
        job_state: sequence1([:loaded, :unloaded]),
        process_snapshot:
          sequence1([
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, [replacement]}
          ]),
        process_identity_state: fn ^identity -> :exited end
      })

    assert {:error, message, 1} = NodeAgentStop.stop(@service, runtime)
    assert message =~ "replacement_process"
  end

  defp runtime(overrides) do
    Map.merge(
      %{
        with_lifecycle_lock: fn callback -> callback.(:lock) end,
        lock_valid: fn :lock -> :ok end,
        job_state: sequence1([:loaded, :unloaded, :unloaded]),
        process_snapshot: sequence1(List.duplicate({:ok, []}, 4)),
        bootout: fn :lock, @service -> :ok end,
        signal_process: fn :lock, _identity -> :ok end,
        process_identity_state: fn _identity -> :exited end,
        monotonic_ms: fn -> 0 end,
        sleep: fn _milliseconds -> :ok end,
        unload_timeout_ms: 5_000,
        exit_timeout_ms: 30_000,
        poll_interval_ms: 100
      },
      overrides
    )
  end

  defp process_identity(pid) do
    %{pid: pid, start_sec: 91, start_usec: 2, executable: "/tmp/beam.smp", device: 1, inode: 2}
  end

  defp event(parent, name, result) do
    send(parent, {:event, name})
    result
  end

  defp sequence1(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn _argument ->
      Agent.get_and_update(agent, fn
        [value | rest] -> {value, rest}
        [] -> raise "sequence exhausted"
      end)
    end
  end
end
