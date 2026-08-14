defmodule OrchardCLI.Commands.ManagedNodeAgentStop do
  @moduledoc false

  alias Orchard.ManagedNodeAgent.LifecycleState
  alias OrchardCLI.LifecycleSystem

  @type stop_result ::
          {:stopped | :already_stopped, map()} | {:error, String.t(), 1}

  @spec stop(map(), map()) :: stop_result()
  def stop(service, runtime) do
    deps = dependencies(runtime)

    case deps.with_lock.(fn lock -> stop_locked(service, lock, deps) end) do
      {:error, :locked} ->
        {:error,
         "Error: another Orchard lifecycle operation is already in progress.\n" <>
           "Wait for it to finish, then run: sudo orchardctl stop", 1}

      {:error, reason} ->
        stop_error(service, reason)

      result ->
        result
    end
  end

  defp stop_locked(service, lock, deps) do
    context = %{service: service, lock: lock, deps: deps}

    with {:ok, context} <- record_initial(context),
         {:ok, context} <- establish_suppression(context),
         {:ok, context} <- observe_process(context),
         {:ok, context} <- prove_unload(context),
         {:ok, context} <- prove_exit(context),
         {:ok, context} <- prove_terminal(context) do
      result = if context.already_stopped?, do: :already_stopped, else: :stopped
      {result, service}
    else
      {:error, context, reason} ->
        record_failure(context, reason)
        stop_error(service, reason)
    end
  end

  defp record_initial(context) do
    deps = context.deps

    with {:ok, coordinator} <- deps.owner_identity.(),
         owner <- owner_identity(coordinator, context.lock),
         start_state <- deps.read_start_state.(),
         :ok <- admissible_prior_start_state(start_state),
         job_state <- deps.job_state.(context.service),
         process_state <- deps.process_snapshot.(context.service),
         {:ok, records} <- deps.read_evidence.() do
      evidence =
        LifecycleState.new_managed_stop(
          deps.uuid.(),
          owner,
          context.service,
          %{
            eligibility: LifecycleState.observed_eligibility(start_state),
            launchd_job: observed_job(job_state),
            managed_process: observed_process(process_state)
          },
          LifecycleState.reconciliations(records),
          deps.wall_time.()
        )

      context = Map.put(context, :evidence, evidence)

      case publish_evidence(context, evidence) do
        :ok ->
          {:ok,
           context
           |> Map.put(:prior_start_state, start_state)
           |> Map.put(:evidence_persisted?, true)}

        {:error, reason} ->
          {:error, context, {:initial_evidence, reason}}
      end
    else
      {:error, reason} -> {:error, context, {:initial_observation, reason}}
    end
  end

  defp establish_suppression(context) do
    deps = context.deps
    state = LifecycleState.suppressed_state(context.prior_start_state)

    with :ok <- validate_lock(context),
         :ok <- deps.write_start_state.(context.lock, state),
         {:ok, context} <-
           advance(context, "eligibility_suppressed", %{
             eligibility: state.eligibility,
             one_shot_authorization: nil
           }),
         :ok <- validate_lock(context) do
      prove_disablement(context, state)
    else
      {:error, context, reason} -> {:error, context, reason}
      {:error, reason} -> {:error, context, {:suppression, reason}}
    end
  end

  defp prove_disablement(context, state) do
    disable_result = context.deps.disable_job.(context.lock, context.service)

    case context.deps.job_disabled?.(context.service) do
      true ->
        case advance(context, "suppression_proven", %{
               persistent_disablement: true,
               disable_result: inspect(disable_result)
             }) do
          {:ok, context} -> {:ok, Map.put(context, :suppressed_state, state)}
          {:error, context, reason} -> {:error, context, reason}
        end

      false ->
        {:error, context, {:disablement_unproven, disable_result}}

      other ->
        {:error, context, {:disablement_unproven, {disable_result, other}}}
    end
  end

  defp observe_process(context) do
    deps = context.deps
    job_state = deps.job_state.(context.service)
    first = deps.process_snapshot.(context.service)
    second = deps.process_snapshot.(context.service)

    with {:ok, capture} <- stable_capture(first, second),
         {:ok, context} <-
           advance(context, "process_observed", %{
             pre_shutdown_job: observed_job(job_state),
             captured_process: capture
           }) do
      {:ok,
       context
       |> Map.put(:pre_shutdown_job, job_state)
       |> Map.put(:capture, capture)
       |> Map.put(:already_stopped?, job_state == :unloaded and capture == :absent)}
    else
      {:error, context, reason} -> {:error, context, reason}
      {:error, reason} -> {:error, context, {:process_observation, reason}}
    end
  end

  defp prove_unload(%{pre_shutdown_job: :loaded} = context) do
    case validate_lock(context) do
      :ok ->
        bootout_result = context.deps.bootout.(context.lock, context.service)

        with :ok <- wait_for_job_unload(context),
             {:ok, context} <-
               advance(context, "unload_proven", %{
                 job_unloaded: true,
                 bootout_result: inspect(bootout_result)
               }) do
          {:ok, context}
        else
          {:error, context, reason} -> {:error, context, reason}
          {:error, reason} -> {:error, context, {:unload, {bootout_result, reason}}}
        end

      {:error, reason} ->
        {:error, context, {:unload, reason}}
    end
  end

  defp prove_unload(%{pre_shutdown_job: :unloaded, capture: :absent} = context) do
    advance(context, "unload_proven", %{job_unloaded: true})
  end

  defp prove_unload(%{pre_shutdown_job: :unloaded, capture: identity} = context) do
    with :ok <- validate_lock(context),
         :ok <- context.deps.signal_process.(context.lock, identity),
         {:ok, context} <-
           advance(context, "unload_proven", %{
             job_unloaded: true,
             exact_orphan_signal: identity
           }) do
      {:ok, context}
    else
      {:error, context, reason} -> {:error, context, reason}
      {:error, reason} -> {:error, context, {:unload, {:orphan_signal, reason}}}
    end
  end

  defp prove_unload(context), do: {:error, context, {:unload, :unknown_job_state}}

  defp prove_exit(%{capture: :absent} = context) do
    with :ok <- require_no_process(context),
         {:ok, context} <- advance(context, "exit_proven", %{affirmative_absence: true}) do
      {:ok, context}
    else
      {:error, context, reason} -> {:error, context, reason}
      {:error, reason} -> {:error, context, {:exit, reason}}
    end
  end

  defp prove_exit(%{capture: identity} = context) do
    with :ok <- wait_for_exit(context, identity),
         :ok <- require_no_process(context),
         {:ok, context} <- advance(context, "exit_proven", %{captured_exit: identity}) do
      {:ok, context}
    else
      {:error, context, reason} -> {:error, context, reason}
      {:error, reason} -> {:error, context, {:exit, reason}}
    end
  end

  defp prove_terminal(context) do
    deps = context.deps

    with {:ok, state} <- deps.read_start_state.(),
         true <- state == context.suppressed_state,
         true <- deps.job_disabled?.(context.service),
         :unloaded <- deps.job_state.(context.service),
         :ok <- require_no_process(context),
         {:ok, context} <-
           advance(context, "terminal_coherent", %{
             outcome: "stopped",
             suppression_generation: state.eligibility.generation
           }),
         :ok <- validate_lock(context) do
      {:ok, context}
    else
      {:error, context, reason} -> {:error, context, reason}
      {:error, reason} -> {:error, context, {:terminal_proof, reason}}
      false -> {:error, context, {:terminal_proof, :suppression_missing}}
      other -> {:error, context, {:terminal_proof, other}}
    end
  end

  defp wait_for_job_unload(context) do
    wait_until(context, context.deps.unload_timeout_ms, fn ->
      case context.deps.job_state.(context.service) do
        :unloaded -> :done
        :loaded -> :wait
        other -> {:error, other}
      end
    end)
  end

  defp wait_for_exit(context, identity) do
    wait_until(context, context.deps.exit_timeout_ms, fn ->
      identity_state = context.deps.process_identity_state.(identity)
      snapshot = context.deps.process_snapshot.(context.service)

      case {identity_state, snapshot} do
        {:alive, {:ok, [^identity]}} -> :wait
        {state, {:ok, []}} when state in [:exited, :reused] -> :done
        {{:unknown, reason}, _snapshot} -> {:error, {:identity_unknown, reason}}
        {_state, {:error, reason}} -> {:error, {:process_unknown, reason}}
        {state, {:ok, processes}} -> {:error, {:replacement_process, state, processes}}
        {state, _snapshot} -> {:error, {:identity_unknown, state}}
      end
    end)
  end

  defp wait_until(context, timeout_ms, check) do
    deadline = context.deps.monotonic_ms.() + timeout_ms
    do_wait(context, deadline, check)
  end

  defp do_wait(context, deadline, check) do
    case check.() do
      :done ->
        :ok

      :wait ->
        if context.deps.monotonic_ms.() >= deadline do
          {:error, :timeout}
        else
          context.deps.sleep.(context.deps.poll_interval_ms)
          do_wait(context, deadline, check)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_no_process(context) do
    case context.deps.process_snapshot.(context.service) do
      {:ok, []} -> :ok
      {:ok, processes} -> {:error, {:replacement_process, processes}}
      {:error, reason} -> {:error, {:process_unknown, reason}}
    end
  end

  defp stable_capture({:ok, []}, {:ok, []}), do: {:ok, :absent}
  defp stable_capture({:ok, [identity]}, {:ok, [identity]}), do: {:ok, identity}
  defp stable_capture({:ok, first}, {:ok, second}), do: {:error, {:unstable, first, second}}
  defp stable_capture({:error, reason}, _second), do: {:error, {:unknown, reason}}
  defp stable_capture(_first, {:error, reason}), do: {:error, {:unknown, reason}}

  defp advance(context, phase, proofs) do
    evidence = LifecycleState.advance(context.evidence, phase, proofs, context.deps.wall_time.())

    case publish_evidence(context, evidence) do
      :ok -> {:ok, Map.put(context, :evidence, evidence)}
      {:error, reason} -> {:error, context, {:evidence, phase, reason}}
    end
  end

  defp publish_evidence(context, evidence) do
    with :ok <- validate_lock(context) do
      context.deps.write_evidence.(context.lock, evidence)
    end
  end

  defp validate_lock(context), do: context.deps.lock_valid.(context.lock)

  defp record_failure(%{evidence: evidence, evidence_persisted?: true} = context, reason) do
    failed =
      LifecycleState.advance(
        evidence,
        "terminal_failed",
        %{failure: inspect(reason)},
        context.deps.wall_time.()
      )

    if validate_lock(context) == :ok do
      _result = context.deps.write_evidence.(context.lock, failed)
    end

    :ok
  end

  defp record_failure(_context, _reason), do: :ok

  defp observed_job(:loaded), do: "loaded"
  defp observed_job(:unloaded), do: "unloaded"
  defp observed_job(other), do: %{"unknown" => inspect(other)}

  defp observed_process({:ok, []}), do: "absent"
  defp observed_process({:ok, [identity]}), do: %{"identity" => identity}
  defp observed_process({:ok, identities}), do: %{"multiple" => identities}
  defp observed_process({:error, reason}), do: %{"unknown" => inspect(reason)}

  defp admissible_prior_start_state({:ok, state}),
    do: LifecycleState.validate_start_state(state)

  defp admissible_prior_start_state({:error, reason}) when reason in [:missing, :malformed],
    do: :ok

  defp admissible_prior_start_state({:error, reason}), do: {:error, {:unsafe_start_state, reason}}

  defp stop_error(service, reason) do
    {:error,
     "Error: failed to stop #{service.display_name} (#{service.label}).\n" <>
       "Managed Node Agent stop proof failed: #{inspect(reason)}.\n" <>
       "Do not restart the Node Agent until managed recovery verifies suppression.", 1}
  end

  defp owner_identity(coordinator, %{
         guard_identity: guard,
         lock_device: device,
         lock_inode: inode
       }) do
    %{
      coordinator_identity: coordinator,
      lock_guard_identity: guard,
      lock_device: device,
      lock_inode: inode
    }
  end

  defp owner_identity(coordinator, _test_lock), do: coordinator

  defp dependencies(runtime) do
    %{
      with_lock: Map.get(runtime, :with_lifecycle_lock, &LifecycleSystem.with_lock/1),
      lock_valid: Map.get(runtime, :lock_valid, &LifecycleSystem.lock_valid/1),
      owner_identity: Map.get(runtime, :owner_identity, &LifecycleSystem.owner_identity/0),
      read_start_state: Map.get(runtime, :read_start_state, &LifecycleSystem.read_start_state/0),
      read_evidence: Map.get(runtime, :read_evidence, &LifecycleSystem.read_evidence/0),
      write_evidence: Map.get(runtime, :write_evidence, &LifecycleSystem.write_evidence/2),
      write_start_state:
        Map.get(runtime, :write_start_state, &LifecycleSystem.write_start_state/2),
      disable_job: Map.get(runtime, :disable_job, &LifecycleSystem.disable_job/2),
      job_disabled?: Map.get(runtime, :job_disabled?, &LifecycleSystem.job_disabled?/1),
      job_state: Map.get(runtime, :job_state, &LifecycleSystem.job_state/1),
      process_snapshot: Map.get(runtime, :process_snapshot, &LifecycleSystem.process_snapshot/1),
      bootout: Map.get(runtime, :bootout, &LifecycleSystem.bootout/2),
      process_identity_state:
        Map.get(runtime, :process_identity_state, &LifecycleSystem.process_identity_state/1),
      signal_process: Map.get(runtime, :signal_process, &LifecycleSystem.signal_process/2),
      uuid: Map.get(runtime, :uuid, &uuid4/0),
      wall_time:
        Map.get(runtime, :wall_time, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end),
      monotonic_ms:
        Map.get(runtime, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
      sleep: Map.get(runtime, :sleep, &Process.sleep/1),
      unload_timeout_ms: Map.get(runtime, :unload_timeout_ms, 5_000),
      exit_timeout_ms: Map.get(runtime, :exit_timeout_ms, 30_000),
      poll_interval_ms: Map.get(runtime, :poll_interval_ms, 100)
    }
  end

  defp uuid4 do
    <<part1::32, part2::16, part3::16, part4::16, part5::48>> =
      :crypto.strong_rand_bytes(16)

    part3 = Bitwise.bor(Bitwise.band(part3, 0x0FFF), 0x4000)
    part4 = Bitwise.bor(Bitwise.band(part4, 0x3FFF), 0x8000)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [part1, part2, part3, part4, part5]
    )
    |> IO.iodata_to_binary()
  end
end
