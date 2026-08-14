defmodule OrchardCLI.Commands.ManagedNodeAgentStopTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Stop

  @service %{
    id: :node_agent,
    label: "com.orchard.node-agent",
    plist_path: "/tmp/com.orchard.node-agent.plist",
    display_name: "Node Agent"
  }

  test "SPEC 11.4 lock contention fails without managed mutation" do
    parent = self()

    runtime =
      base_runtime(%{
        with_lifecycle_lock: fn _callback -> {:error, :locked} end,
        write_evidence: fn _lock, _evidence -> mutation(parent, :write_evidence).(nil) end,
        write_start_state: fn _lock, _state -> mutation(parent, :write_start_state).(nil) end,
        disable_job: fn _lock, _service -> mutation(parent, :disable_job).(nil) end,
        bootout: fn _lock, _service -> mutation(parent, :bootout).(nil) end
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "lifecycle operation is already in progress"
    refute_receive {:mutation, _operation}
  end

  test "SPEC 11.4 records suppression and exact exit before coherent success" do
    parent = self()
    identity = %{pid: 4242, start_time: 91, executable: "/tmp/beam.smp", device: 1, inode: 2}

    start_state = %{
      schema_version: 1,
      eligibility: %{state: "suppressed", generation: 1},
      one_shot_authorization: nil
    }

    runtime =
      base_runtime(%{
        with_lifecycle_lock: fn callback -> callback.(:lock) end,
        lock_valid: fn :lock -> event(parent, :lock_valid, :ok) end,
        owner_identity: fn -> {:ok, %{pid: 10, start_time: 20}} end,
        read_start_state: sequence([{:error, :missing}, {:ok, start_state}]),
        read_evidence: fn -> {:ok, []} end,
        write_evidence: fn :lock, evidence ->
          send(parent, {:event, {:evidence, evidence.phase}})
          :ok
        end,
        write_start_state: fn :lock, state ->
          send(parent, {:event, {:start_state, state.eligibility.state}})
          :ok
        end,
        disable_job: fn :lock, _service -> event(parent, :disable, :ok) end,
        job_disabled?: fn _service -> event(parent, :disabled_proof, true) end,
        job_state: sequence1([:loaded, :loaded, :unloaded, :unloaded]),
        process_snapshot:
          sequence1([
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, []},
            {:ok, []},
            {:ok, []}
          ]),
        bootout: fn :lock, _service -> event(parent, :bootout, :ok) end,
        process_identity_state: fn ^identity -> :exited end,
        uuid: fn -> "00000000-0000-4000-8000-000000000001" end,
        wall_time: fn -> "2026-08-14T00:00:00Z" end
      })

    assert {:ok, message} = Stop.run([], runtime)
    assert message =~ "Stopped Orchard services."

    assert collect_events() == [
             :lock_valid,
             {:evidence, "initial"},
             :lock_valid,
             {:start_state, "suppressed"},
             :lock_valid,
             {:evidence, "eligibility_suppressed"},
             :lock_valid,
             :disable,
             :disabled_proof,
             :lock_valid,
             {:evidence, "suppression_proven"},
             :lock_valid,
             {:evidence, "process_observed"},
             :lock_valid,
             :bootout,
             :lock_valid,
             {:evidence, "unload_proven"},
             :lock_valid,
             {:evidence, "exit_proven"},
             :disabled_proof,
             :lock_valid,
             {:evidence, "terminal_coherent"},
             :lock_valid
           ]
  end

  test "initial evidence failure performs no managed mutation" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        write_evidence: fn _lock, _evidence -> {:error, :disk_full} end
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "initial_evidence"
    refute_receive {:event, :start_state}
    refute_receive {:event, :disable}
    refute_receive {:event, :bootout}
  end

  test "unproven disablement fails before final process observation or bootout" do
    parent = self()
    runtime = managed_runtime(parent, %{job_disabled?: fn _service -> false end})

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "disablement_unproven"
    refute_receive {:event, :bootout}
    refute Enum.member?(collect_events(), {:evidence, "process_observed"})
  end

  test "exclusion loss immediately before disablement fails without further mutation" do
    parent = self()
    counter = :counters.new(1, [])

    runtime =
      managed_runtime(parent, %{
        lock_valid: fn :lock ->
          :counters.add(counter, 1, 1)
          if :counters.get(counter, 1) <= 3, do: :ok, else: {:error, :exclusion_lost}
        end
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "exclusion_lost"
    assert_receive {:event, :start_state}
    refute_receive {:event, :disable}
    refute_receive {:event, :bootout}
  end

  test "disable command failure may proceed only when persistent disablement is proven" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        disable_job: fn :lock, _service ->
          event(parent, :disable, {:error, {:disable_failed, 5}})
        end
      })

    assert {:ok, message} = Stop.run([], runtime)
    assert message =~ "Stopped Orchard services."
    assert Enum.member?(collect_events(), {:evidence, "terminal_coherent"})
  end

  test "multiple stable managed instances fail closed without bootout" do
    parent = self()
    first = process_identity(4242)
    second = process_identity(4343)

    runtime =
      managed_runtime(parent, %{
        process_snapshot:
          sequence1([{:ok, [first]}, {:ok, [first, second]}, {:ok, [first, second]}])
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "unstable"
    refute_receive {:event, :bootout}
  end

  test "bootout command failure may succeed only when unload and exit are independently proven" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        bootout: fn :lock, _service ->
          event(parent, :bootout, {:error, {:bootout_failed, 5}})
        end
      })

    assert {:ok, message} = Stop.run([], runtime)
    assert message =~ "Stopped Orchard services."
    assert Enum.member?(collect_events(), {:evidence, "terminal_coherent"})
  end

  test "captured process timeout fails without coherent stopped evidence" do
    parent = self()
    identity = process_identity(4242)

    runtime =
      managed_runtime(parent, %{
        process_snapshot:
          sequence1([
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, [identity]}
          ]),
        process_identity_state: fn ^identity -> :alive end,
        exit_timeout_ms: 0,
        monotonic_ms: fn -> 0 end
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "timeout"
    refute Enum.member?(collect_events(), {:evidence, "terminal_coherent"})
  end

  test "already stopped path reasserts suppression and records coherent evidence" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        job_state: sequence1([:unloaded, :unloaded, :unloaded]),
        process_snapshot: sequence1(List.duplicate({:ok, []}, 5))
      })

    assert {:ok, message} = Stop.run([], runtime)
    assert message =~ "already stopped"
    events = collect_events()
    assert Enum.member?(events, :start_state)
    assert Enum.member?(events, :disable)
    assert Enum.member?(events, {:evidence, "terminal_coherent"})
    refute Enum.member?(events, :bootout)
  end

  test "replacement process after captured exit fails closed" do
    parent = self()
    first = process_identity(4242)
    replacement = process_identity(4343)

    runtime =
      managed_runtime(parent, %{
        process_snapshot:
          sequence1([
            {:ok, [first]},
            {:ok, [first]},
            {:ok, [first]},
            {:ok, [replacement]}
          ])
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "replacement_process"
    refute Enum.member?(collect_events(), {:evidence, "terminal_coherent"})
  end

  test "unloaded live orphan is signaled only after exact capture and exits boundedly" do
    parent = self()
    identity = process_identity(4242)

    runtime =
      managed_runtime(parent, %{
        job_state: sequence1([:unloaded, :unloaded, :unloaded]),
        process_snapshot:
          sequence1([
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, [identity]},
            {:ok, []},
            {:ok, []},
            {:ok, []}
          ]),
        signal_process: fn :lock, ^identity -> event(parent, :signal, :ok) end
      })

    assert {:ok, message} = Stop.run([], runtime)
    assert message =~ "Stopped Orchard services."
    assert Enum.member?(collect_events(), :signal)
    refute_receive {:event, :bootout}
  end

  test "loaded job with affirmative pre-shutdown absence still proves stopped" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        process_snapshot: sequence1(List.duplicate({:ok, []}, 5))
      })

    assert {:ok, message} = Stop.run([], runtime)
    assert message =~ "Stopped Orchard services."
    assert Enum.member?(collect_events(), :bootout)
  end

  test "unknown unload observation fails without terminal success" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        job_state: sequence1([:loaded, :loaded, {:unknown, :launchctl_failed}])
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "unload"
    refute Enum.member?(collect_events(), {:evidence, "terminal_coherent"})
  end

  test "unload timeout is bounded and cannot publish terminal success" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        job_state: sequence1(List.duplicate(:loaded, 4)),
        unload_timeout_ms: 0,
        monotonic_ms: fn -> 0 end
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "timeout"
    refute Enum.member?(collect_events(), {:evidence, "terminal_coherent"})
  end

  test "failed final observation is not repaired by later absence" do
    parent = self()
    identity = process_identity(4242)

    runtime =
      managed_runtime(parent, %{
        process_snapshot: sequence1([{:ok, [identity]}, {:error, :unknown}, {:ok, []}])
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "process_observation"
    refute_receive {:event, :bootout}
  end

  test "SPEC 11.4 resumes an interrupted suppression under the new lock owner" do
    parent = self()

    suppressed = %{
      schema_version: 1,
      eligibility: %{state: "suppressed", generation: 7},
      one_shot_authorization: nil
    }

    written = put_in(suppressed.eligibility.generation, 8)

    runtime =
      managed_runtime(parent, %{
        read_start_state: sequence([{:ok, suppressed}, {:ok, written}])
      })

    assert {:ok, message} = Stop.run([], runtime)
    assert message =~ "Stopped Orchard services."
    assert Enum.member?(collect_events(), {:evidence, "terminal_coherent"})
  end

  test "public stop supersedes interrupted and securely referenced invalid evidence" do
    parent = self()

    interrupted = %{
      operation_id: "interrupted",
      kind: "managed_stop",
      phase: "suppression_proven"
    }

    invalid = %{
      operation_id: "broken",
      kind: "unknown",
      phase: "invalid",
      filename: "broken.json",
      sha256: "abcd"
    }

    runtime =
      managed_runtime(parent, %{
        read_evidence: fn -> {:ok, [interrupted, invalid]} end,
        write_evidence: fn :lock, evidence ->
          send(parent, {:written_evidence, evidence})
          :ok
        end
      })

    assert {:ok, _message} = Stop.run([], runtime)

    assert_receive {:written_evidence,
                    %{
                      phase: "initial",
                      reconciles: [
                        %{operation_id: "interrupted"},
                        %{operation_id: "broken", filename: "broken.json", sha256: "abcd"}
                      ]
                    }}
  end

  test "terminal publication failure cannot report stopped" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        write_evidence: fn :lock, evidence ->
          if evidence.phase == "terminal_coherent" do
            {:error, :disk_full}
          else
            send(parent, {:event, {:evidence, evidence.phase}})
            :ok
          end
        end
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "terminal_coherent"
    refute_receive {:event, {:evidence, "terminal_coherent"}}
  end

  test "unsafe prior lifecycle state fails before evidence or mutation" do
    parent = self()

    runtime =
      managed_runtime(parent, %{
        read_start_state: fn -> {:error, :unsafe_metadata} end
      })

    assert {:error, message, 1} = Stop.run([], runtime)
    assert message =~ "unsafe_start_state"
    refute_receive {:event, {:evidence, _phase}}
    refute_receive {:event, :start_state}
    refute_receive {:event, :disable}
    refute_receive {:event, :bootout}
  end

  defp managed_runtime(parent, overrides) do
    identity = process_identity(4242)

    defaults = %{
      with_lifecycle_lock: fn callback -> callback.(:lock) end,
      lock_valid: fn :lock -> :ok end,
      owner_identity: fn -> {:ok, process_identity(10)} end,
      read_start_state:
        sequence([
          {:error, :missing},
          {:ok,
           %{
             schema_version: 1,
             eligibility: %{state: "suppressed", generation: 1},
             one_shot_authorization: nil
           }}
        ]),
      read_evidence: fn -> {:ok, []} end,
      write_evidence: fn :lock, evidence ->
        send(parent, {:event, {:evidence, evidence.phase}})
        :ok
      end,
      write_start_state: fn :lock, _state -> event(parent, :start_state, :ok) end,
      disable_job: fn :lock, _service -> event(parent, :disable, :ok) end,
      job_disabled?: fn _service -> true end,
      job_state: sequence1([:loaded, :loaded, :unloaded, :unloaded]),
      process_snapshot:
        sequence1([
          {:ok, [identity]},
          {:ok, [identity]},
          {:ok, [identity]},
          {:ok, []},
          {:ok, []},
          {:ok, []}
        ]),
      bootout: fn :lock, _service -> event(parent, :bootout, :ok) end,
      process_identity_state: fn ^identity -> :exited end,
      uuid: fn -> "00000000-0000-4000-8000-000000000001" end,
      wall_time: fn -> "2026-08-14T00:00:00Z" end
    }

    defaults
    |> Map.merge(overrides)
    |> base_runtime()
  end

  defp process_identity(pid) do
    %{pid: pid, start_sec: 91, start_usec: 2, executable: "/tmp/beam.smp", device: 1, inode: 2}
  end

  defp event(parent, name, result) do
    send(parent, {:event, name})
    result
  end

  defp sequence(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn ->
      Agent.get_and_update(agent, fn
        [value | rest] -> {value, rest}
        [] -> raise "sequence exhausted"
      end)
    end
  end

  defp sequence1(values) do
    next = sequence(values)
    fn _value -> next.() end
  end

  defp collect_events(acc \\ []) do
    receive do
      {:event, event} -> collect_events([event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  defp base_runtime(overrides) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        services: [@service],
        read_install_role: fn -> {:ok, "node-agent"} end,
        file_regular?: fn _path -> true end
      },
      overrides
    )
  end

  defp mutation(parent, operation) do
    fn _value ->
      send(parent, {:mutation, operation})
      :ok
    end
  end
end
