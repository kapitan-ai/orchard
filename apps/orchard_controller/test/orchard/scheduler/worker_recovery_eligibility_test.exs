defmodule Orchard.Scheduler.WorkerRecoveryEligibilityTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.RuntimeEndpoint.{Observation, Placement, Target}
  alias Orchard.Scheduler.{MultiNode, SingleNode, WorkerRecoveryEligibility}
  alias Orchard.TestSupport.DispatchCapacityFixtures

  @model %{model_id: "recovery-model", version: "v1"}
  @node_id "00000000-0000-4000-a000-000000000379"

  defmodule Client do
    def connect(target), do: {:ok, target}
    def disconnect(_target), do: :ok
    def status(_target, _opts), do: {:ok, Process.get(:recovery_observation)}
  end

  # SPEC.md §12.2: a placement that is not loaded holds no recovery state, so a
  # fresh authenticated epoch admits it. The accepted scheduler requirement keeps
  # the production path free of inline status probes, so admission must not
  # depend on any client being reachable.
  test "SPEC §12.2 a cold placement set is admitted on a fresh epoch without probing" do
    assert :ok = WorkerRecoveryEligibility.check(target(), observation(nil, []), @model)

    cold_without_epoch = Map.put(observation(nil, []), :worker_recovery_epoch, nil)

    assert {:error, :worker_recovery_evidence_unavailable} =
             WorkerRecoveryEligibility.check(target(), cold_without_epoch, @model)
  end

  test "SPEC §12.2 projection identity must match the exact Node, model and version" do
    for key <- [
          %{clean().key | node_id: Ecto.UUID.generate()},
          %{clean().key | model_id: "other"},
          %{clean().key | version: "other"},
          nil
        ] do
      projection = %{clean() | key: key}

      assert {:error, _} =
               WorkerRecoveryEligibility.check(target(), observation(projection), @model)
    end
  end

  test "SPEC §12.2 admits only coherent hydrated armed current-epoch evidence" do
    assert :ok = WorkerRecoveryEligibility.evidence("current", clean())

    for invalid <- [
          nil,
          %{},
          %{clean() | epoch: "old"},
          %{clean() | revision: -1},
          %{clean() | hydrated: false},
          %{clean() | eligible: false},
          %{clean() | reason: :placement_crash_breaker_open},
          Map.put(clean(), "epoch", "conflicting")
        ] do
      assert {:error, :worker_recovery_evidence_unavailable} =
               WorkerRecoveryEligibility.evidence("current", invalid)
    end

    assert {:error, _} = WorkerRecoveryEligibility.evidence(nil, clean())
  end

  test "SPEC §12.2 all blocked states reject loaded evidence" do
    for {state, reason} <- blocked_states() do
      projection = %{clean() | state: state, eligible: false, reason: reason}

      assert {:error, ^reason} =
               WorkerRecoveryEligibility.check(target(), observation(projection), @model)

      assert {:error, _} =
               WorkerRecoveryEligibility.evidence("current", %{projection | eligible: true})
    end
  end

  test "SPEC §12.2 missing loaded, duplicate, malformed and old-epoch evidence fail closed" do
    for status <- [
          observation(nil),
          observation(%{clean() | epoch: "old"}),
          observation(:invalid),
          observation(clean()) |> Map.update!(:placements, &(&1 ++ &1))
        ] do
      assert {:error, _} = WorkerRecoveryEligibility.check(target(), status, @model)
    end
  end

  test "SPEC §12.2 stale or future observations cannot authorize a placement" do
    for offset <- [-60_000, 60_000] do
      status =
        Map.put(
          observation(clean()),
          :observed_at,
          DateTime.add(DateTime.utc_now(), offset, :millisecond)
        )

      assert {:error, :worker_recovery_evidence_unavailable} =
               WorkerRecoveryEligibility.check(target(), status, @model)
    end
  end

  test "SPEC §12.2 another version remains independently eligible" do
    blocked =
      observation(%{
        clean()
        | state: :open,
          eligible: false,
          reason: :placement_crash_breaker_open
      })

    assert :ok =
             WorkerRecoveryEligibility.check(target(), blocked, %{@model | version: "v2"})
  end

  test "SPEC §12.2 single-node loaded gate rejects before capacity evaluation" do
    Process.put(
      :recovery_observation,
      observation(%{
        clean()
        | state: :open,
          eligible: false,
          reason: :placement_crash_breaker_open
      })
    )

    assert {:error, _, decision} =
             SingleNode.default_schedule(request(), target(),
               node_resolver: fn _ -> nil end,
               status_client: Client,
               dispatch_capacity_input_provider: fn -> flunk("rejected before capacity") end
             )

    assert Enum.any?(
             decision.rejected_candidates,
             &("placement_crash_breaker_open" in &1.reason_codes)
           )
  end

  test "SPEC §12.2 production scheduler rejects recovery before ranking or an attempt" do
    status =
      observation(%{clean() | state: :backoff, eligible: false, reason: :worker_restart_backoff})

    candidate = %{
      node: %{id: @node_id, health: :healthy},
      target: target(),
      observed_at: status.observed_at,
      availability: :available,
      worker_state: :idle,
      active_request_count: 0,
      max_concurrency: 4,
      placements: status.placements,
      runtime_memory_budgets: [],
      runtime_prefix_cache_statuses: [],
      supports_prompt_token_ids: true,
      worker_recovery_epoch: "current"
    }

    opts = [
      active_runtime_endpoint_targets_provider: fn -> {:ok, [target()]} end,
      runtime_endpoint_targets_provider: fn _ -> [target()] end,
      production_candidate_snapshot_provider: fn _, _, _ ->
        {:ok, %{candidates: [candidate], rejections: []}}
      end,
      circuit_breaker_evaluator: fn _ -> {:ok, %{state: :closed}} end,
      dispatch_capacity_input_provider: fn -> DispatchCapacityFixtures.unmanaged_input() end
    ]

    assert {:error, :cluster_busy, decision} = MultiNode.schedule(request(), opts)
    assert Enum.any?(decision.rejected_candidates, &("worker_restart_backoff" in &1.reason_codes))
  end

  defp request do
    %CanonicalRequest{
      public_id: "recovery-admission",
      internal_id: "recovery-admission-internal",
      endpoint: :chat_completions,
      tenant_id: "tenant",
      model_ref: struct!(CanonicalRequest.ModelRef, @model),
      admission: %{max_cold_start_ms: 1_000}
    }
  end

  defp target,
    do: %Target{
      id: "recovery-test",
      transport: :beam,
      node_id: @node_id,
      address: :"recovery@127.0.0.1"
    }

  defp clean,
    do: %{
      key: %{node_id: @node_id, model_id: "recovery-model", version: "v1"},
      epoch: "current",
      revision: 0,
      state: :armed,
      hydrated: true,
      eligible: true,
      reason: nil
    }

  defp observation(projection, placements \\ nil) do
    placement =
      Placement.new(%{model_ref: @model, state: :loaded}) |> Map.put(:worker_recovery, projection)

    Observation.new(%{
      target: target(),
      endpoint_id: target().id,
      metadata: %{node_id: @node_id},
      observed_at: DateTime.utc_now(),
      availability: :available,
      worker_state: :idle,
      placements: []
    })
    |> Map.put(:placements, placements || [placement])
    |> Map.put(:worker_recovery_epoch, "current")
  end

  defp blocked_states,
    do: [
      backoff: :worker_restart_backoff,
      restarting: :worker_restart_in_progress,
      open: :placement_crash_breaker_open,
      recovery_required: :placement_recovery_required
    ]
end
