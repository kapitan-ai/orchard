defmodule OrchardCLI.Commands.NodeAgentStop do
  @moduledoc false

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

    with :ok <- validate_lock(context),
         {:ok, job_state} <- known_job_state(deps.job_state.(service)),
         {:ok, capture} <-
           stable_capture(deps.process_snapshot.(service), deps.process_snapshot.(service)),
         :ok <- stop_job_or_process(context, job_state, capture),
         :ok <- prove_exit(context, capture),
         :ok <- require_no_process(context),
         :unloaded <- deps.job_state.(service),
         :ok <- validate_lock(context) do
      result =
        if job_state == :unloaded and capture == :absent, do: :already_stopped, else: :stopped

      {result, service}
    else
      {:error, reason} -> stop_error(service, reason)
      other -> stop_error(service, {:terminal_state, other})
    end
  end

  defp stop_job_or_process(context, :loaded, _capture) do
    with :ok <- validate_lock(context) do
      bootout_result = context.deps.bootout.(context.lock, context.service)

      case wait_for_job_unload(context) do
        :ok -> :ok
        {:error, reason} -> {:error, {:unload, {bootout_result, reason}}}
      end
    end
  end

  defp stop_job_or_process(_context, :unloaded, :absent), do: :ok

  defp stop_job_or_process(context, :unloaded, identity) do
    with :ok <- validate_lock(context),
         :ok <- context.deps.signal_process.(context.lock, identity) do
      :ok
    else
      {:error, reason} -> {:error, {:orphan_signal, reason}}
    end
  end

  defp prove_exit(context, :absent), do: require_no_process(context)

  defp prove_exit(context, identity) do
    wait_until(context, context.deps.exit_timeout_ms, fn ->
      identity_state = context.deps.process_identity_state.(identity)
      snapshot = context.deps.process_snapshot.(context.service)

      case {identity_state, snapshot} do
        {:alive, {:ok, [^identity]}} -> :wait
        {:alive, {:ok, []}} -> :wait
        {state, {:ok, []}} when state in [:exited, :reused] -> :done
        {{:unknown, reason}, _snapshot} -> {:error, {:identity_unknown, reason}}
        {_state, {:error, reason}} -> {:error, {:process_unknown, reason}}
        {state, {:ok, processes}} -> {:error, {:replacement_process, state, processes}}
        {state, _snapshot} -> {:error, {:identity_unknown, state}}
      end
    end)
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

  defp known_job_state(state) when state in [:loaded, :unloaded], do: {:ok, state}
  defp known_job_state(state), do: {:error, {:unknown_job_state, state}}

  defp stable_capture({:ok, []}, {:ok, []}), do: {:ok, :absent}
  defp stable_capture({:ok, [identity]}, {:ok, [identity]}), do: {:ok, identity}

  defp stable_capture({:ok, first}, {:ok, second}),
    do: {:error, {:unstable_process, first, second}}

  defp stable_capture({:error, reason}, _second), do: {:error, {:process_unknown, reason}}
  defp stable_capture(_first, {:error, reason}), do: {:error, {:process_unknown, reason}}

  defp validate_lock(context), do: context.deps.lock_valid.(context.lock)

  defp stop_error(service, reason) do
    {:error,
     "Error: failed to stop #{service.display_name} (#{service.label}).\n" <>
       "Node Agent stop proof failed: #{inspect(reason)}.", 1}
  end

  defp dependencies(runtime) do
    %{
      with_lock: Map.get(runtime, :with_lifecycle_lock, &LifecycleSystem.with_lock/1),
      lock_valid: Map.get(runtime, :lock_valid, &LifecycleSystem.lock_valid/1),
      job_state: Map.get(runtime, :job_state, &LifecycleSystem.job_state/1),
      process_snapshot: Map.get(runtime, :process_snapshot, &LifecycleSystem.process_snapshot/1),
      bootout: Map.get(runtime, :bootout, &LifecycleSystem.bootout/2),
      process_identity_state:
        Map.get(runtime, :process_identity_state, &LifecycleSystem.process_identity_state/1),
      signal_process: Map.get(runtime, :signal_process, &LifecycleSystem.signal_process/2),
      monotonic_ms:
        Map.get(runtime, :monotonic_ms, fn -> System.monotonic_time(:millisecond) end),
      sleep: Map.get(runtime, :sleep, &Process.sleep/1),
      unload_timeout_ms: Map.get(runtime, :unload_timeout_ms, 5_000),
      exit_timeout_ms: Map.get(runtime, :exit_timeout_ms, 30_000),
      poll_interval_ms: Map.get(runtime, :poll_interval_ms, 100)
    }
  end
end
