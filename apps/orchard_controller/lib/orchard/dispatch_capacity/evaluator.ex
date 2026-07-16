defmodule Orchard.DispatchCapacity.Evaluator do
  @moduledoc """
  Pure evaluation of Orchard's Controller dispatch-capacity contract.

  The evaluator consumes normalized caller-owned facts. It performs no reads,
  writes, clock access, transport work, or allocation mutation.
  """

  defmodule Input do
    @moduledoc "Typed facts required for one dispatch-capacity evaluation."

    @enforce_keys [
      :authority_phase,
      :policy_presence,
      :policy_state,
      :management_classification,
      :trusted_identity?,
      :lifecycle_state,
      :health,
      :heartbeat_fresh?,
      :capacity_observation_fresh?,
      :observation_time,
      :runtime_concurrency_limit,
      :aggregate_active_count,
      :controller_dispatch_ceiling,
      :controller_accounted_allocation,
      :placement_capacity,
      :temporary_legacy_claim_count,
      :pool_eligible?,
      :format_eligible?,
      :memory_eligible?,
      :breaker_eligible?
    ]
    defstruct @enforce_keys

    @type evidence(value) :: {:valid, value} | :missing | :invalid
    @type placement ::
            :not_applicable
            | :unknown
            | :invalid
            | {:valid, non_neg_integer(), pos_integer()}

    @type t :: %__MODULE__{
            authority_phase: :pre_cutover | :enforcing | term(),
            policy_presence: :present | :missing | term(),
            policy_state: :shadow_legacy | :approved_explicit | :enforcing | :missing | term(),
            management_classification:
              {:ok,
               :production_managed
               | :unmanaged_source_development
               | :unmanaged_compatibility}
              | {:error,
                 :runtime_endpoint_management_class_missing
                 | :runtime_endpoint_management_class_invalid}
              | term(),
            trusted_identity?: boolean() | term(),
            lifecycle_state: :active | term(),
            health: :healthy | :degraded | :unhealthy | :unreachable | term(),
            heartbeat_fresh?: boolean() | term(),
            capacity_observation_fresh?: boolean() | term(),
            observation_time: term(),
            runtime_concurrency_limit: evidence(pos_integer()) | term(),
            aggregate_active_count: evidence(non_neg_integer()) | term(),
            controller_dispatch_ceiling: evidence(non_neg_integer()) | term(),
            controller_accounted_allocation: non_neg_integer() | term(),
            placement_capacity: placement() | term(),
            temporary_legacy_claim_count: non_neg_integer() | term(),
            pool_eligible?: boolean() | term(),
            format_eligible?: boolean() | term(),
            memory_eligible?: boolean() | term(),
            breaker_eligible?: boolean() | term()
          }
  end

  defmodule Result do
    @moduledoc "Typed output from one dispatch-capacity evaluation."

    @type authority_decision ::
            :legacy_pre_cutover
            | :f11_enforcing
            | :unmanaged_source_development
            | :unmanaged_compatibility
            | :fail_closed

    @type management_class ::
            :production_managed
            | :unmanaged_source_development
            | :unmanaged_compatibility
            | :missing
            | :invalid

    @type reason_code ::
            :runtime_endpoint_management_class_missing
            | :runtime_endpoint_management_class_invalid
            | :dispatch_capacity_phase_policy_mismatch
            | :controller_dispatch_ceiling_missing
            | :dispatch_ceiling_shadow_mismatch
            | :dispatch_ceiling_not_approved
            | :controller_dispatch_ceiling_invalid
            | :runtime_endpoint_identity_untrusted
            | :node_lifecycle_not_active
            | :node_health_invalid
            | :node_health_unhealthy
            | :node_health_not_healthy
            | :node_health_degraded
            | :node_heartbeat_stale
            | :runtime_capacity_observation_stale
            | :runtime_concurrency_limit_unknown
            | :runtime_active_request_count_legacy_fallback
            | :controller_accounted_allocation_invalid
            | :temporary_legacy_claim_count_invalid
            | :pool_not_allowed
            | :model_format_unsupported
            | :memory_headroom_insufficient
            | :circuit_breaker_open
            | :placement_capacity_unknown
            | :placement_capacity_invalid
            | :controller_dispatch_ceiling_not_yet_enforcing
            | :dispatch_capacity_pre_cutover_legacy
            | :controller_dispatch_ceiling_zero
            | :runtime_concurrency_limit_exhausted
            | :controller_dispatch_ceiling_exhausted
            | :dispatch_headroom_exhausted
            | :placement_capacity_exhausted

    @enforce_keys [
      :runtime_concurrency_enforcement_limit,
      :controller_dispatch_ceiling,
      :effective_dispatch_limit,
      :controller_accounted_allocation,
      :dispatch_headroom,
      :placement_capacity,
      :placement_headroom,
      :authority_phase,
      :policy_state,
      :management_class,
      :authority_decision,
      :available_slots,
      :temporary_legacy_available_slots,
      :legacy_pre_cutover_limit,
      :legacy_pre_cutover_reported_allocation,
      :legacy_pre_cutover_claim_count,
      :legacy_pre_cutover_available_slots,
      :eligible?,
      :observation_time,
      :reason_codes
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            runtime_concurrency_enforcement_limit: pos_integer() | nil,
            controller_dispatch_ceiling: non_neg_integer() | nil,
            effective_dispatch_limit: non_neg_integer(),
            controller_accounted_allocation: non_neg_integer() | nil,
            dispatch_headroom: non_neg_integer(),
            placement_capacity:
              :not_applicable | :unknown | :invalid | {:valid, non_neg_integer(), pos_integer()},
            placement_headroom: non_neg_integer() | nil,
            authority_phase: :pre_cutover | :enforcing | :invalid,
            policy_state: :shadow_legacy | :approved_explicit | :enforcing | :missing | :invalid,
            management_class: management_class(),
            authority_decision: authority_decision(),
            available_slots: non_neg_integer(),
            temporary_legacy_available_slots: non_neg_integer() | nil,
            legacy_pre_cutover_limit: pos_integer() | nil,
            legacy_pre_cutover_reported_allocation: non_neg_integer() | nil,
            legacy_pre_cutover_claim_count: non_neg_integer() | nil,
            legacy_pre_cutover_available_slots: non_neg_integer() | nil,
            eligible?: boolean(),
            observation_time: term(),
            reason_codes: [reason_code()]
          }
  end

  alias __MODULE__.{Input, Result}

  @reason_precedence [
    :runtime_endpoint_management_class_missing,
    :runtime_endpoint_management_class_invalid,
    :dispatch_capacity_phase_policy_mismatch,
    :controller_dispatch_ceiling_missing,
    :dispatch_ceiling_shadow_mismatch,
    :dispatch_ceiling_not_approved,
    :controller_dispatch_ceiling_invalid,
    :runtime_endpoint_identity_untrusted,
    :node_lifecycle_not_active,
    :node_health_invalid,
    :node_health_unhealthy,
    :node_health_not_healthy,
    :node_health_degraded,
    :node_heartbeat_stale,
    :runtime_capacity_observation_stale,
    :runtime_concurrency_limit_unknown,
    :runtime_active_request_count_legacy_fallback,
    :controller_accounted_allocation_invalid,
    :temporary_legacy_claim_count_invalid,
    :pool_not_allowed,
    :model_format_unsupported,
    :memory_headroom_insufficient,
    :circuit_breaker_open,
    :placement_capacity_unknown,
    :placement_capacity_invalid,
    :controller_dispatch_ceiling_not_yet_enforcing,
    :dispatch_capacity_pre_cutover_legacy,
    :controller_dispatch_ceiling_zero,
    :runtime_concurrency_limit_exhausted,
    :controller_dispatch_ceiling_exhausted,
    :dispatch_headroom_exhausted,
    :placement_capacity_exhausted
  ]

  @reason_order @reason_precedence |> Enum.with_index() |> Map.new()

  @doc "Evaluates the shared dispatch-capacity contract from normalized facts."
  @spec evaluate(Input.t()) :: Result.t()
  def evaluate(%Input{} = input) do
    management_class = management_class(input.management_classification)
    {decision, policy_reasons, ceiling} = authority_decision(input, management_class)
    runtime_limit = valid_positive(input.runtime_concurrency_limit)
    allocation = valid_counter(input.controller_accounted_allocation)
    placement = normalize_placement(input.placement_capacity)

    common_reasons = common_reasons(input, decision, placement)

    evaluation =
      evaluate_decision(decision, input, runtime_limit, ceiling, allocation)

    {available_slots, placement_headroom, placement_reasons} =
      bound_by_placement(evaluation.aggregate_slots, placement)

    reasons =
      policy_reasons ++
        common_reasons ++ evaluation.reasons ++ placement_reasons

    eligible? =
      decision != :fail_closed and evaluation.capacity_established? and
        common_gates_pass?(input, decision, placement) and available_slots > 0

    %Result{
      runtime_concurrency_enforcement_limit: runtime_limit,
      controller_dispatch_ceiling: visible_ceiling(decision, ceiling),
      effective_dispatch_limit: evaluation.effective_limit,
      controller_accounted_allocation: allocation,
      dispatch_headroom: evaluation.dispatch_headroom,
      placement_capacity: placement,
      placement_headroom: placement_headroom,
      authority_phase: normalize_phase(input.authority_phase),
      policy_state: normalize_policy_state(input.policy_state),
      management_class: management_class,
      authority_decision: decision,
      available_slots: available_slots,
      temporary_legacy_available_slots: evaluation.temporary_legacy_slots,
      legacy_pre_cutover_limit: evaluation.legacy_limit,
      legacy_pre_cutover_reported_allocation: evaluation.legacy_reported_allocation,
      legacy_pre_cutover_claim_count: evaluation.legacy_claim_count,
      legacy_pre_cutover_available_slots: evaluation.temporary_legacy_slots,
      eligible?: eligible?,
      observation_time: input.observation_time,
      reason_codes: order_reasons(reasons)
    }
  end

  defp authority_decision(_input, :missing) do
    {:fail_closed, [:runtime_endpoint_management_class_missing], nil}
  end

  defp authority_decision(_input, :invalid) do
    {:fail_closed, [:runtime_endpoint_management_class_invalid], nil}
  end

  defp authority_decision(_input, :unmanaged_source_development),
    do: {:unmanaged_source_development, [], nil}

  defp authority_decision(_input, :unmanaged_compatibility),
    do: {:unmanaged_compatibility, [], nil}

  defp authority_decision(input, :production_managed), do: production_decision(input)

  defp production_decision(%Input{policy_presence: presence}) when presence != :present do
    {:fail_closed, [:controller_dispatch_ceiling_missing], nil}
  end

  defp production_decision(%Input{} = input) do
    ceiling = valid_tagged_non_negative(input.controller_dispatch_ceiling)

    case {input.authority_phase, input.policy_state, input.controller_dispatch_ceiling} do
      {:pre_cutover, :shadow_legacy, :missing} ->
        {:legacy_pre_cutover,
         [:dispatch_ceiling_not_approved, :dispatch_capacity_pre_cutover_legacy], nil}

      {:pre_cutover, :approved_explicit, {:valid, value}}
      when is_integer(value) and value >= 0 ->
        {:legacy_pre_cutover,
         [:controller_dispatch_ceiling_not_yet_enforcing, :dispatch_capacity_pre_cutover_legacy] ++
           zero_ceiling_reason(value), value}

      {:enforcing, :enforcing, {:valid, value}} when is_integer(value) and value >= 0 ->
        {:f11_enforcing, zero_ceiling_reason(value), value}

      _other ->
        reasons =
          phase_policy_reasons(input.authority_phase, input.policy_state) ++
            ceiling_integrity_reasons(input.policy_state, input.controller_dispatch_ceiling) ++
            zero_ceiling_reason(ceiling)

        {:fail_closed, reasons, ceiling}
    end
  end

  defp phase_policy_reasons(phase, policy)
       when {phase, policy} in [
              {:pre_cutover, :shadow_legacy},
              {:pre_cutover, :approved_explicit},
              {:enforcing, :enforcing}
            ],
       do: []

  defp phase_policy_reasons(phase, policy)
       when phase in [:pre_cutover, :enforcing] and
              policy in [:shadow_legacy, :approved_explicit, :enforcing],
       do: [:dispatch_capacity_phase_policy_mismatch]

  defp phase_policy_reasons(_phase, policy)
       when policy in [:shadow_legacy, :approved_explicit, :enforcing],
       do: [:dispatch_capacity_phase_policy_mismatch]

  defp phase_policy_reasons(_phase, _policy), do: [:dispatch_ceiling_not_approved]

  defp ceiling_integrity_reasons(:shadow_legacy, :missing), do: []

  defp ceiling_integrity_reasons(:shadow_legacy, _ceiling),
    do: [:dispatch_ceiling_shadow_mismatch]

  defp ceiling_integrity_reasons(policy, {:valid, value})
       when policy in [:approved_explicit, :enforcing] and is_integer(value) and value >= 0,
       do: []

  defp ceiling_integrity_reasons(policy, :missing)
       when policy in [:approved_explicit, :enforcing],
       do: [:controller_dispatch_ceiling_missing]

  defp ceiling_integrity_reasons(policy, _ceiling)
       when policy in [:approved_explicit, :enforcing],
       do: [:controller_dispatch_ceiling_invalid]

  defp ceiling_integrity_reasons(_policy, _ceiling), do: []

  defp evaluate_decision(:f11_enforcing, input, runtime_limit, ceiling, allocation) do
    blockers = f11_capacity_blockers(input, runtime_limit, allocation)

    if blockers == [] do
      effective_limit = min(runtime_limit, ceiling)
      headroom = max(effective_limit - allocation, 0)

      %{
        effective_limit: effective_limit,
        dispatch_headroom: headroom,
        aggregate_slots: headroom,
        temporary_legacy_slots: nil,
        legacy_limit: nil,
        legacy_reported_allocation: nil,
        legacy_claim_count: nil,
        capacity_established?: true,
        reasons: f11_exhaustion_reasons(runtime_limit, ceiling, headroom)
      }
    else
      empty_evaluation(blockers)
    end
  end

  defp evaluate_decision(:legacy_pre_cutover, input, _runtime_limit, _ceiling, _allocation) do
    legacy_evaluation(input, true)
  end

  defp evaluate_decision(decision, input, _runtime_limit, _ceiling, _allocation)
       when decision in [:unmanaged_source_development, :unmanaged_compatibility] do
    legacy_evaluation(input, false)
  end

  defp evaluate_decision(:fail_closed, _input, _runtime_limit, _ceiling, _allocation) do
    empty_evaluation([])
  end

  defp legacy_evaluation(%Input{capacity_observation_fresh?: fresh?}, _subtract_claims?)
       when fresh? != true do
    empty_evaluation([])
  end

  defp legacy_evaluation(input, subtract_claims?) do
    claims =
      if subtract_claims?,
        do: valid_counter(input.temporary_legacy_claim_count),
        else: 0

    legacy_evaluation_with_claims(input, claims, subtract_claims?)
  end

  defp legacy_evaluation_with_claims(_input, nil, _subtract_claims?) do
    empty_evaluation([:temporary_legacy_claim_count_invalid])
  end

  defp legacy_evaluation_with_claims(input, claims, subtract_claims?) do
    runtime_limit = valid_positive(input.runtime_concurrency_limit) || 1
    reported_active = valid_tagged_non_negative(input.aggregate_active_count) || 0
    slots = max(runtime_limit - reported_active - claims, 0)

    %{
      effective_limit: 0,
      dispatch_headroom: 0,
      aggregate_slots: slots,
      capacity_established?: true,
      reasons: legacy_fallback_reasons(input) ++ legacy_exhaustion_reasons(slots)
    }
    |> Map.merge(
      legacy_result_fields(subtract_claims?, slots, runtime_limit, reported_active, claims)
    )
  end

  defp legacy_result_fields(true, slots, runtime_limit, reported_active, claims) do
    %{
      temporary_legacy_slots: slots,
      legacy_limit: runtime_limit,
      legacy_reported_allocation: reported_active,
      legacy_claim_count: claims
    }
  end

  defp legacy_result_fields(false, _slots, _runtime_limit, _reported_active, _claims) do
    %{
      temporary_legacy_slots: nil,
      legacy_limit: nil,
      legacy_reported_allocation: nil,
      legacy_claim_count: nil
    }
  end

  defp legacy_exhaustion_reasons(0), do: [:runtime_concurrency_limit_exhausted]
  defp legacy_exhaustion_reasons(_slots), do: []

  defp empty_evaluation(reasons) do
    %{
      effective_limit: 0,
      dispatch_headroom: 0,
      aggregate_slots: 0,
      temporary_legacy_slots: nil,
      legacy_limit: nil,
      legacy_reported_allocation: nil,
      legacy_claim_count: nil,
      capacity_established?: false,
      reasons: reasons
    }
  end

  defp common_reasons(input, decision, placement) do
    []
    |> add_reason(
      decision == :fail_closed and input.policy_presence != :present,
      :controller_dispatch_ceiling_missing
    )
    |> add_reason(input.trusted_identity? != true, :runtime_endpoint_identity_untrusted)
    |> add_reason(input.lifecycle_state != :active, :node_lifecycle_not_active)
    |> add_health_reason(input.health, decision)
    |> add_reason(input.heartbeat_fresh? != true, :node_heartbeat_stale)
    |> add_reason(input.capacity_observation_fresh? != true, :runtime_capacity_observation_stale)
    |> add_reason(input.pool_eligible? != true, :pool_not_allowed)
    |> add_reason(input.format_eligible? != true, :model_format_unsupported)
    |> add_reason(input.memory_eligible? != true, :memory_headroom_insufficient)
    |> add_reason(input.breaker_eligible? != true, :circuit_breaker_open)
    |> add_placement_reason(placement)
  end

  defp add_health_reason(reasons, :healthy, _decision), do: reasons

  defp add_health_reason(reasons, :degraded, :f11_enforcing),
    do: [:node_health_not_healthy | reasons]

  defp add_health_reason(reasons, :degraded, decision)
       when decision in [
              :legacy_pre_cutover,
              :unmanaged_source_development,
              :unmanaged_compatibility
            ],
       do: [:node_health_degraded | reasons]

  defp add_health_reason(reasons, :degraded, :fail_closed), do: reasons

  defp add_health_reason(reasons, health, _decision)
       when health in [:unhealthy, :unreachable],
       do: [:node_health_unhealthy | reasons]

  defp add_health_reason(reasons, _health, _decision), do: [:node_health_invalid | reasons]

  defp add_placement_reason(reasons, :unknown), do: [:placement_capacity_unknown | reasons]
  defp add_placement_reason(reasons, :invalid), do: [:placement_capacity_invalid | reasons]
  defp add_placement_reason(reasons, _placement), do: reasons

  defp f11_capacity_blockers(input, runtime_limit, allocation) do
    []
    |> add_reason(input.trusted_identity? != true, :runtime_endpoint_identity_untrusted)
    |> add_reason(input.lifecycle_state != :active, :node_lifecycle_not_active)
    |> add_reason(input.health != :healthy, health_blocker(input.health))
    |> add_reason(input.heartbeat_fresh? != true, :node_heartbeat_stale)
    |> add_reason(input.capacity_observation_fresh? != true, :runtime_capacity_observation_stale)
    |> add_reason(is_nil(runtime_limit), :runtime_concurrency_limit_unknown)
    |> add_reason(is_nil(allocation), :controller_accounted_allocation_invalid)
    |> Enum.reject(&is_nil/1)
  end

  defp health_blocker(:degraded), do: :node_health_not_healthy

  defp health_blocker(health) when health in [:unhealthy, :unreachable],
    do: :node_health_unhealthy

  defp health_blocker(:healthy), do: nil
  defp health_blocker(_health), do: :node_health_invalid

  defp common_gates_pass?(input, decision, placement) do
    gates = [
      input.trusted_identity? == true,
      input.lifecycle_state == :active,
      input.heartbeat_fresh? == true,
      input.capacity_observation_fresh? == true,
      input.pool_eligible? == true,
      input.format_eligible? == true,
      input.memory_eligible? == true,
      input.breaker_eligible? == true
    ]

    Enum.all?(gates) and health_passes?(input.health, decision) and placement_passes?(placement)
  end

  defp health_passes?(:healthy, _decision), do: true

  defp health_passes?(:degraded, decision),
    do:
      decision in [
        :legacy_pre_cutover,
        :unmanaged_source_development,
        :unmanaged_compatibility
      ]

  defp health_passes?(_health, _decision), do: false

  defp placement_passes?(:not_applicable), do: true
  defp placement_passes?({:valid, _active, _max}), do: true
  defp placement_passes?(_placement), do: false

  defp bound_by_placement(slots, :not_applicable), do: {slots, nil, []}

  defp bound_by_placement(_slots, placement) when placement in [:unknown, :invalid],
    do: {0, nil, []}

  defp bound_by_placement(slots, {:valid, active, maximum}) do
    placement_slots = max(maximum - active, 0)
    reasons = if placement_slots == 0, do: [:placement_capacity_exhausted], else: []
    {min(slots, placement_slots), placement_slots, reasons}
  end

  defp f11_exhaustion_reasons(_runtime_limit, _ceiling, headroom) when headroom > 0, do: []

  defp f11_exhaustion_reasons(runtime_limit, ceiling, 0) when runtime_limit < ceiling do
    [:runtime_concurrency_limit_exhausted, :dispatch_headroom_exhausted]
  end

  defp f11_exhaustion_reasons(_runtime_limit, _ceiling, 0) do
    [:controller_dispatch_ceiling_exhausted, :dispatch_headroom_exhausted]
  end

  defp legacy_fallback_reasons(input) do
    []
    |> add_reason(
      is_nil(valid_positive(input.runtime_concurrency_limit)),
      :runtime_concurrency_limit_unknown
    )
    |> add_reason(
      is_nil(valid_tagged_non_negative(input.aggregate_active_count)),
      :runtime_active_request_count_legacy_fallback
    )
  end

  defp add_reason(reasons, true, reason), do: [reason | reasons]
  defp add_reason(reasons, false, _reason), do: reasons

  defp order_reasons(reasons) do
    reasons
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Map.fetch!(@reason_order, &1))
  end

  defp management_class({:ok, class})
       when class in [
              :production_managed,
              :unmanaged_source_development,
              :unmanaged_compatibility
            ],
       do: class

  defp management_class({:error, :runtime_endpoint_management_class_missing}), do: :missing
  defp management_class(_classification), do: :invalid

  defp normalize_phase(phase) when phase in [:pre_cutover, :enforcing], do: phase
  defp normalize_phase(_phase), do: :invalid

  defp normalize_policy_state(policy)
       when policy in [:shadow_legacy, :approved_explicit, :enforcing, :missing],
       do: policy

  defp normalize_policy_state(nil), do: :missing
  defp normalize_policy_state(_policy), do: :invalid

  defp normalize_placement(:not_applicable), do: :not_applicable
  defp normalize_placement(:unknown), do: :unknown
  defp normalize_placement(:invalid), do: :invalid

  defp normalize_placement({:valid, active, maximum})
       when is_integer(active) and active >= 0 and is_integer(maximum) and maximum > 0,
       do: {:valid, active, maximum}

  defp normalize_placement(_placement), do: :invalid

  defp valid_positive({:valid, value}) when is_integer(value) and value > 0, do: value
  defp valid_positive(_value), do: nil

  defp valid_tagged_non_negative({:valid, value}) when is_integer(value) and value >= 0,
    do: value

  defp valid_tagged_non_negative(_value), do: nil

  defp valid_counter(value) when is_integer(value) and value >= 0, do: value
  defp valid_counter(_value), do: nil

  defp zero_ceiling_reason(0), do: [:controller_dispatch_ceiling_zero]
  defp zero_ceiling_reason(_ceiling), do: []

  defp visible_ceiling(decision, _ceiling)
       when decision in [:unmanaged_source_development, :unmanaged_compatibility],
       do: nil

  defp visible_ceiling(_decision, ceiling), do: ceiling
end
