defmodule Orchard.ClusterManagement.ReasonCodes do
  @moduledoc """
  Fixed cluster-management reason-code vocabularies.
  """

  @scheduler_rejection_codes ~w(
    inventory_missing
    node_not_admitted
    node_not_active
    node_not_registered
    node_health_unreachable
    node_health_unhealthy
    node_observation_stale
    transport_unreachable
    runtime_not_ready
    runtime_identity_mismatch
    version_incompatible
    pool_not_allowed
    model_format_unsupported
    model_not_available_on_node
    insufficient_memory
    node_concurrency_exhausted
    placement_concurrency_exhausted
    placement_suppressed
    node_circuit_breaker_open
    model_load_suppressed
    policy_required
    pool_required
    queue_lane_capacity_unavailable
    trust_not_established
    unknown_capacity
  )

  @scheduler_skip_codes ~w(
    lower_tier_not_considered
    not_scored_after_selection
    not_applicable_to_request
    candidate_limit_reached
  )

  @action_blocker_codes ~w(
    requires_admin
    requires_operator
    node_not_found
    node_not_pending_admission
    node_not_admitted
    node_not_active
    node_not_registered
    node_unreachable
    node_unhealthy
    inventory_missing
    drain_already_running
    drain_not_running
    decommission_already_running
    maintenance_requires_drain
    drain_completion_unverified
    lifecycle_transition_invalid
    ha_standby_write_blocked
    ha_leadership_unproven
    cluster_lock_unavailable
    version_incompatible
    pool_required
    policy_required
    trust_not_established
    invalid_controller_dispatch_ceiling
  )

  @confirmation_requirement_codes ~w(
    requires_yes_flag
    requires_typed_node_id
    requires_reason
    requires_drain_consequence_acknowledgement
    requires_decommission_consequence_acknowledgement
  )

  @consequence_codes ~w(
    active_requests_present
    would_cancel_active_requests
    existing_requests_continue_until_deadline
    future_scheduling_revoked
    no_rejoin_with_same_node_id
  )

  @support_scope_codes ~w(
    cluster
    node
    request
    scheduler_decision
    runtime_endpoint
    control_plane
  )

  @vocabularies %{
    scheduler_rejection: @scheduler_rejection_codes,
    scheduler_skip: @scheduler_skip_codes,
    action_blocker: @action_blocker_codes,
    confirmation_requirement: @confirmation_requirement_codes,
    consequence: @consequence_codes,
    support_scope: @support_scope_codes
  }

  @type vocabulary ::
          :scheduler_rejection
          | :scheduler_skip
          | :action_blocker
          | :confirmation_requirement
          | :consequence
          | :support_scope

  @spec scheduler_rejection_codes() :: [String.t()]
  def scheduler_rejection_codes, do: @scheduler_rejection_codes

  @spec scheduler_skip_codes() :: [String.t()]
  def scheduler_skip_codes, do: @scheduler_skip_codes

  @spec action_blocker_codes() :: [String.t()]
  def action_blocker_codes, do: @action_blocker_codes

  @spec confirmation_requirement_codes() :: [String.t()]
  def confirmation_requirement_codes, do: @confirmation_requirement_codes

  @spec consequence_codes() :: [String.t()]
  def consequence_codes, do: @consequence_codes

  @spec support_scope_codes() :: [String.t()]
  def support_scope_codes, do: @support_scope_codes

  @spec normalize_code(term()) :: String.t() | nil
  def normalize_code(nil), do: nil
  def normalize_code(code) when is_atom(code), do: Atom.to_string(code)

  def normalize_code(code) when is_binary(code) do
    case String.trim(code) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_code(_code), do: nil

  @spec valid?(vocabulary(), term()) :: boolean()
  def valid?(vocabulary, code) do
    normalized = normalize_code(code)
    is_binary(normalized) and normalized in Map.fetch!(@vocabularies, vocabulary)
  end

  @spec normalize_codes([term()] | term()) :: [String.t()]
  def normalize_codes(codes) when is_list(codes) do
    codes
    |> Enum.map(&normalize_code/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_codes(nil), do: []
  def normalize_codes(code), do: normalize_codes([code])

  @spec validate_codes(vocabulary(), [term()] | term()) ::
          {:ok, [String.t()]} | {:error, {:unknown_code, vocabulary(), term()}}
  def validate_codes(vocabulary, codes) do
    normalized_codes = normalize_codes(codes)

    case Enum.find(normalized_codes, &(not valid?(vocabulary, &1))) do
      nil -> {:ok, normalized_codes}
      unknown -> {:error, {:unknown_code, vocabulary, unknown}}
    end
  end
end
