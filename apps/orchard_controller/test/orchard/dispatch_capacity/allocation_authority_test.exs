defmodule Orchard.DispatchCapacity.AllocationAuthorityTest do
  use ExUnit.Case, async: true

  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.{AllocationAuthority, QuarantineStore}
  alias Orchard.DispatchCapacity.Evaluator.Input
  alias Orchard.Inference.QueueManager

  test "SPEC 4.5 the Controller inference subtree supervises the allocation authority" do
    authority = Process.whereis(AllocationAuthority)

    assert is_pid(authority)
    assert Process.alive?(authority)
  end

  test "SPEC 4.5 local Node quarantine blocks replacement acquisition and revalidation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    input = enforcing_input({:valid, 0, 4})

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-before-quarantine",
               input,
               authority: authority
             )

    assert :ok = AllocationAuthority.quarantine_node(authority, node_id)

    assert {:error, :dispatch_capacity_unavailable, blocked} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-quarantine",
               input,
               authority: authority
             )

    refute blocked.eligible?
    assert :node_health_unhealthy in blocked.reason_codes

    assert {:error, :dispatch_capacity_revalidation_failed, revalidation} =
             QueueManager.revalidate_dispatch_capacity(claim, input, authority: authority)

    refute revalidation.eligible?
    assert :ok = QueueManager.release_dispatch_capacity(claim, authority: authority)
  end

  test "SPEC 4.6.2 QueueManager shares one Node allocation bound across placements and lanes" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()

    assert {:ok, first_claim, first_result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-a",
               enforcing_input({:valid, 0, 4}),
               authority: authority
             )

    assert first_result.controller_accounted_allocation == 0
    assert first_result.available_slots == 2

    assert {:ok, second_claim, second_result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-b",
               enforcing_input({:valid, 0, 3}),
               authority: authority
             )

    assert second_result.controller_accounted_allocation == 1
    assert second_result.available_slots == 1

    assert {:error, :dispatch_capacity_unavailable, exhausted} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-c",
               enforcing_input({:valid, 0, 5}),
               authority: authority
             )

    assert exhausted.controller_accounted_allocation == 2
    assert exhausted.dispatch_headroom == 0

    assert exhausted.reason_codes == [
             :controller_dispatch_ceiling_exhausted,
             :dispatch_headroom_exhausted
           ]

    assert :ok = QueueManager.release_dispatch_capacity(first_claim, authority: authority)

    assert {:ok, third_claim, available_again} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-c",
               enforcing_input({:valid, 0, 5}),
               authority: authority
             )

    assert available_again.controller_accounted_allocation == 1
    assert :ok = QueueManager.release_dispatch_capacity(second_claim, authority: authority)
    assert :ok = QueueManager.release_dispatch_capacity(third_claim, authority: authority)
  end

  test "SPEC 4.6.2 two F11 requests racing for the final unit allow one acquisition" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    parent = self()

    contenders =
      for request_id <- ["request-a", "request-b"] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)

          QueueManager.acquire_dispatch_capacity(
            node_id,
            request_id,
            enforcing_input({:valid, 0, 4})
            |> Map.put(:controller_dispatch_ceiling, {:valid, 1}),
            authority: authority
          )
        end)
      end

    contender_pids =
      Enum.map(contenders, fn _task ->
        assert_receive {:ready, contender_pid}
        contender_pid
      end)

    Enum.each(contender_pids, &send(&1, :go))
    results = Enum.map(contenders, &Task.await/1)

    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, :dispatch_capacity_unavailable, _}, &1)
           ) == 1

    Enum.each(results, fn
      {:ok, claim, _result} ->
        assert :ok = QueueManager.release_dispatch_capacity(claim, authority: authority)

      {:error, :dispatch_capacity_unavailable, result} ->
        assert result.dispatch_headroom == 0
    end)
  end

  test "SPEC 4.6.2 two legacy lanes racing for the final slot allow one temporary claim" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    parent = self()

    contenders =
      for request_id <- ["legacy-a", "legacy-b"] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> :ok)

          QueueManager.acquire_dispatch_capacity(
            node_id,
            request_id,
            legacy_input(),
            authority: authority
          )
        end)
      end

    contender_pids =
      Enum.map(contenders, fn _task ->
        assert_receive {:ready, contender_pid}
        contender_pid
      end)

    Enum.each(contender_pids, &send(&1, :go))
    results = Enum.map(contenders, &Task.await/1)

    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, :dispatch_capacity_unavailable, _}, &1)
           ) == 1

    Enum.each(results, fn
      {:ok, claim, result} ->
        assert claim.kind == :legacy
        assert result.authority_decision == :legacy_pre_cutover
        assert result.dispatch_headroom == 0
        assert :ok = QueueManager.release_dispatch_capacity(claim, authority: authority)

      {:error, :dispatch_capacity_unavailable, result} ->
        assert result.legacy_pre_cutover_available_slots == 0
    end)
  end

  test "SPEC 4.6.2 one logical request cannot hold concurrent claims across Nodes" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    first_node_id = Ecto.UUID.generate()
    second_node_id = Ecto.UUID.generate()
    request_id = "request-duplicate-allocation"
    input = enforcing_input({:valid, 0, 4})

    assert {:ok, first_claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               first_node_id,
               request_id,
               input,
               authority: authority
             )

    assert {:error, :dispatch_capacity_request_already_claimed, _result} =
             QueueManager.acquire_dispatch_capacity(
               second_node_id,
               request_id,
               input,
               authority: authority
             )

    assert :ok = QueueManager.release_dispatch_capacity(first_claim, authority: authority)

    assert {:ok, retry_claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               second_node_id,
               request_id,
               input,
               authority: authority
             )

    assert :ok = QueueManager.release_dispatch_capacity(retry_claim, authority: authority)
  end

  test "SPEC 5.9 policy mutation linearizes before held-claim dispatch revalidation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    parent = self()
    input_state = start_supervised!({Agent, fn -> enforcing_input({:valid, 0, 4}) end})

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-under-policy-race",
               Agent.get(input_state, & &1),
               authority: authority
             )

    mutation =
      Task.async(fn ->
        DispatchCapacity.with_policy_mutation_gate(
          node_id,
          fn ->
            send(parent, {:mutation_gate_held, self()})

            receive do
              :commit_mutation ->
                Agent.update(input_state, fn input ->
                  %{input | controller_dispatch_ceiling: {:valid, 0}}
                end)
            end
          end,
          authority: authority
        )
      end)

    assert_receive {:mutation_gate_held, mutation_pid}

    revalidation =
      Task.async(fn ->
        {:ok, lease} =
          QueueManager.acquire_acceptance_gate(node_id, authority: authority)

        try do
          send(parent, :dispatch_gate_acquired)

          QueueManager.revalidate_dispatch_capacity(
            claim,
            Agent.get(input_state, & &1),
            authority: authority
          )
        after
          QueueManager.release_acceptance_gate(lease, authority: authority)
        end
      end)

    send(mutation_pid, :commit_mutation)
    assert :ok = Task.await(mutation)
    assert_receive :dispatch_gate_acquired

    assert {:error, :dispatch_capacity_revalidation_failed, result} =
             Task.await(revalidation)

    assert result.controller_dispatch_ceiling == 0
    assert result.dispatch_headroom == 0
    assert :controller_dispatch_ceiling_zero in result.reason_codes
    assert :ok = QueueManager.release_dispatch_capacity(claim, authority: authority)
  end

  test "SPEC 4.5 unresolved execution quarantine cannot expire or be released without reconciliation" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    input = enforcing_input({:valid, 0, 4})

    assert :ok = AllocationAuthority.quarantine_node(authority, node_id)
    assert MapSet.member?(AllocationAuthority.quarantined_nodes(authority), node_id)
    refute function_exported?(AllocationAuthority, :release_node_quarantine, 2)

    Process.sleep(75)

    assert MapSet.member?(AllocationAuthority.quarantined_nodes(authority), node_id)

    assert {:error, :dispatch_capacity_unavailable, blocked} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-without-terminal-reconciliation",
               input,
               authority: authority
             )

    refute blocked.eligible?
    assert :node_health_unhealthy in blocked.reason_codes
  end

  test "SPEC 4.5 unresolved execution quarantine survives allocation authority restart" do
    store = start_supervised!({QuarantineStore, name: nil})
    node_id = Ecto.UUID.generate()
    other_node_id = Ecto.UUID.generate()
    input = enforcing_input({:valid, 0, 4})
    authority_key = {__MODULE__, self(), make_ref()}
    authority_name = {:global, authority_key}

    authority =
      start_supervised!({AllocationAuthority, name: authority_name, quarantine_store: store})

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-before-authority-restart",
               input,
               authority: authority
             )

    assert :ok = AllocationAuthority.quarantine_node(authority, node_id)

    monitor_ref = Process.monitor(authority)
    Process.exit(authority, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^authority, :killed}

    replacement =
      Enum.reduce_while(1..100, nil, fn _attempt, _replacement ->
        case :global.whereis_name(authority_key) do
          pid when is_pid(pid) and pid != authority -> {:halt, pid}
          _missing -> Process.sleep(10) && {:cont, nil}
        end
      end)

    assert is_pid(replacement)
    assert AllocationAuthority.quarantined_nodes(replacement) == MapSet.new([node_id])

    assert {:error, :dispatch_capacity_revalidation_failed, revalidation} =
             QueueManager.revalidate_dispatch_capacity(claim, input, authority: replacement)

    refute revalidation.eligible?
    assert :node_health_unhealthy in revalidation.reason_codes

    assert {:error, :dispatch_capacity_unavailable, blocked} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-authority-restart",
               input,
               authority: replacement
             )

    refute blocked.eligible?

    assert {:ok, other_claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               other_node_id,
               "other-node-after-authority-restart",
               input,
               authority: replacement
             )

    assert :ok = QueueManager.release_dispatch_capacity(other_claim, authority: replacement)
  end

  test "SPEC 4.5 quarantine store loss keeps dispatch globally fail-closed" do
    node_id = Ecto.UUID.generate()
    other_node_id = Ecto.UUID.generate()
    input = enforcing_input({:valid, 0, 4})
    store_key = {QuarantineStore, self(), make_ref()}
    authority_key = {AllocationAuthority, self(), make_ref()}
    store_name = {:global, store_key}
    authority_name = {:global, authority_key}

    children = [
      Supervisor.child_spec(
        {QuarantineStore, name: store_name},
        id: :quarantine_store
      ),
      Supervisor.child_spec(
        {AllocationAuthority, name: authority_name, quarantine_store: store_name},
        id: :allocation_authority
      )
    ]

    assert %{restart: :temporary} = QuarantineStore.child_spec(name: store_name)

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    assert Process.alive?(supervisor)

    store = :global.whereis_name(store_key)
    authority = :global.whereis_name(authority_key)

    assert {:ok, claim, _result} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-before-store-restart",
               input,
               authority: authority
             )

    assert :ok = AllocationAuthority.quarantine_node(authority, node_id)

    store_monitor_ref = Process.monitor(store)
    authority_monitor_ref = Process.monitor(authority)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^store_monitor_ref, :process, ^store, :killed}
    refute_receive {:DOWN, ^authority_monitor_ref, :process, ^authority, _reason}, 100

    assert Process.alive?(authority)
    assert :global.whereis_name(store_key) == :undefined

    refute Enum.any?(
             Supervisor.which_children(supervisor),
             &match?({:quarantine_store, _, _, _}, &1)
           )

    assert :ets.whereis(QuarantineStore) == :undefined
    refute function_exported?(AllocationAuthority, :release_node_quarantine, 2)

    assert {:error, :dispatch_capacity_quarantine_store_unavailable} =
             AllocationAuthority.quarantined_nodes(authority)

    assert {:error, :dispatch_capacity_revalidation_failed, revalidation} =
             QueueManager.revalidate_dispatch_capacity(
               claim,
               input,
               authority: authority
             )

    refute revalidation.eligible?
    assert :node_health_unhealthy in revalidation.reason_codes

    assert {:error, :dispatch_capacity_unavailable, blocked} =
             QueueManager.acquire_dispatch_capacity(
               node_id,
               "request-after-store-loss",
               input,
               authority: authority
             )

    refute blocked.eligible?
    assert :node_health_unhealthy in blocked.reason_codes

    assert {:error, :dispatch_capacity_unavailable, other_blocked} =
             QueueManager.acquire_dispatch_capacity(
               other_node_id,
               "other-node-after-store-loss",
               input,
               authority: authority
             )

    refute other_blocked.eligible?
    assert :node_health_unhealthy in other_blocked.reason_codes
  end

  test "SPEC 4.5 quarantine of an absent Node identity leaves unmanaged evaluation open" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    input = unmanaged_input()

    assert AllocationAuthority.evaluate(authority, nil, input).eligible?
    assert :ok = AllocationAuthority.quarantine_node(authority, nil)

    result = AllocationAuthority.evaluate(authority, nil, input)

    assert result.eligible?
    assert result.available_slots > 0
  end

  test "SPEC 5.9 a dead external caller cannot receive an acceptance grant" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    caller = spawn(fn -> Process.sleep(:infinity) end)

    Process.exit(caller, :kill)
    refute Process.alive?(caller)

    assert {:error, :dispatch_capacity_caller_down} =
             AllocationAuthority.try_acquire_acceptance_gate(
               authority,
               node_id,
               100,
               nil,
               caller
             )

    assert {:ok, lease} =
             QueueManager.acquire_acceptance_gate(node_id,
               authority: authority,
               gate_timeout_ms: 100
             )

    assert :ok = QueueManager.release_acceptance_gate(lease, authority: authority)
  end

  test "SPEC 5.9 a policy mutation gives up bounded instead of waiting out a dispatch" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    parent = self()

    holder =
      Task.async(fn ->
        {:ok, lease} = QueueManager.acquire_acceptance_gate(node_id, authority: authority)
        send(parent, :gate_held)

        receive do
          :release -> QueueManager.release_acceptance_gate(lease, authority: authority)
        end
      end)

    assert_receive :gate_held

    assert {:error, :dispatch_capacity_acceptance_gate_busy} =
             DispatchCapacity.with_policy_mutation_gate(
               node_id,
               fn -> :never_runs end,
               authority: authority,
               gate_timeout_ms: 60
             )

    send(holder.pid, :release)
    assert :ok = Task.await(holder)

    assert :mutated =
             DispatchCapacity.with_policy_mutation_gate(node_id, fn -> :mutated end,
               authority: authority,
               gate_timeout_ms: 60
             )
  end

  test "SPEC 5.9 an abandoned bounded gate request cannot install a late lease" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    parent = self()

    :ok = :sys.suspend(authority)

    caller =
      spawn(fn ->
        started_at = System.monotonic_time(:millisecond)

        result =
          DispatchCapacity.with_policy_mutation_gate(
            node_id,
            fn -> send(parent, :abandoned_mutation_ran) end,
            authority: authority,
            gate_timeout_ms: 40
          )

        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        send(parent, {:bounded_gate_result, self(), result, elapsed_ms})

        receive do
          :stop -> :ok
        end
      end)

    try do
      assert_receive {:bounded_gate_result, ^caller, {:error, reason}, elapsed_ms}, 250

      assert reason in [
               :dispatch_capacity_acceptance_gate_busy,
               :dispatch_capacity_authority_unavailable
             ]

      assert elapsed_ms < 200
      refute_receive :abandoned_mutation_ran

      :ok = :sys.resume(authority)

      assert :mutated =
               DispatchCapacity.with_policy_mutation_gate(node_id, fn -> :mutated end,
                 authority: authority,
                 gate_timeout_ms: 100
               )

      refute_receive :abandoned_mutation_ran
    after
      :sys.resume(authority)
      send(caller, :stop)
    end
  end

  test "SPEC 5.9 a policy mutation reports an unavailable authority instead of exiting" do
    authority = start_supervised!({AllocationAuthority, name: nil})
    node_id = Ecto.UUID.generate()
    stop_supervised!(AllocationAuthority)

    assert {:error, :dispatch_capacity_authority_unavailable} =
             DispatchCapacity.with_policy_mutation_gate(
               node_id,
               fn -> :never_runs end,
               authority: authority,
               gate_timeout_ms: 60
             )
  end

  defp unmanaged_input do
    %Input{
      authority_phase: :invalid,
      policy_presence: :missing,
      policy_state: :missing,
      management_classification: {:ok, :unmanaged_compatibility},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 4},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: :missing,
      controller_accounted_allocation: 0,
      placement_capacity: :not_applicable,
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end

  defp enforcing_input(placement_capacity) do
    %Input{
      authority_phase: :enforcing,
      policy_presence: :present,
      policy_state: :enforcing,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :healthy,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 4},
      aggregate_active_count: {:valid, 0},
      controller_dispatch_ceiling: {:valid, 2},
      controller_accounted_allocation: 0,
      placement_capacity: placement_capacity,
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end

  defp legacy_input do
    %Input{
      authority_phase: :pre_cutover,
      policy_presence: :present,
      policy_state: :approved_explicit,
      management_classification: {:ok, :production_managed},
      trusted_identity?: true,
      lifecycle_state: :active,
      health: :degraded,
      heartbeat_fresh?: true,
      capacity_observation_fresh?: true,
      observation_time: ~U[2026-07-20 00:00:00.000000Z],
      runtime_concurrency_limit: {:valid, 2},
      aggregate_active_count: {:valid, 1},
      controller_dispatch_ceiling: {:valid, 8},
      controller_accounted_allocation: 0,
      placement_capacity: {:valid, 0, 4},
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end
end
