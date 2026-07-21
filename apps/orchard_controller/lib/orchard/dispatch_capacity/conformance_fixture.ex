defmodule Orchard.DispatchCapacity.ConformanceFixture do
  @moduledoc "Deterministic public-interface fixture shared by all five capacity consumers."

  alias Orchard.DispatchCapacity.Evaluator.Input

  @doc "Returns the fixed dispatch-capacity conformance input."
  @spec input() :: Input.t()
  def input do
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
      aggregate_active_count: {:valid, 1},
      controller_dispatch_ceiling: {:valid, 2},
      controller_accounted_allocation: 1,
      placement_capacity: {:valid, 0, 3},
      temporary_legacy_claim_count: 0,
      pool_eligible?: true,
      format_eligible?: true,
      memory_eligible?: true,
      breaker_eligible?: true
    }
  end
end
