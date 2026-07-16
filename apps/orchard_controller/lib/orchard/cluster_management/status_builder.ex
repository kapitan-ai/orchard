defmodule Orchard.ClusterManagement.StatusBuilder do
  @moduledoc """
  Controller-owned translation into shared cluster-management status structures.
  """

  alias Orchard.ClusterManagement.NodeStatus
  alias Orchard.DispatchCapacity.Diagnostics
  alias Orchard.DispatchCapacity.Diagnostics.Snapshot, as: CapacitySnapshot
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}

  @admitted_states [:admitted, :active, :cordoned, :draining, :maintenance, :decommissioning]
  @unschedulable_states [
    :admitted,
    :cordoned,
    :draining,
    :maintenance,
    :decommissioning,
    :removed
  ]

  @spec node_status(Node.t() | map(), keyword()) :: NodeStatus.t()
  def node_status(node, opts \\ [])

  def node_status(%Node{} = node, opts) do
    latest_decision =
      Keyword.get_lazy(opts, :latest_decision, fn ->
        Nodes.latest_admission_decision_for_node(node.id)
      end)

    NodeStatus.new!(%{
      resource: %{type: :node, id: node.id},
      lifecycle: %{state: node.state},
      admission: %{
        category: node_admission_category(node, latest_decision),
        source: :registered_node,
        latest_decision: decision_name(latest_decision)
      },
      health: %{status: node.health || :unreachable},
      freshness: %{
        status: freshness(node.last_heartbeat_at),
        observed_at: node.last_heartbeat_at,
        source: :heartbeat
      },
      transport: %{status: :unknown},
      runtime: %{status: :unknown, health_code: nil, health_message: nil},
      compatibility: %{status: :unknown},
      scheduling: scheduling(node),
      dispatch_capacity: dispatch_capacity(node, opts),
      warnings: []
    })
  end

  def node_status(%{} = node, opts) do
    NodeStatus.new!(%{
      resource: %{type: :node, id: node_field(node, :id)},
      lifecycle: %{state: node_field(node, :state)},
      admission: %{
        category: node_admission_category(node, Keyword.get(opts, :latest_decision)),
        source: :registered_node,
        latest_decision: decision_name(Keyword.get(opts, :latest_decision))
      },
      health: %{status: node_field(node, :health) || :unreachable},
      freshness: %{
        status: freshness(node_field(node, :last_heartbeat_at)),
        observed_at: node_field(node, :last_heartbeat_at),
        source: :heartbeat
      },
      transport: %{status: :unknown},
      runtime: %{status: :unknown, health_code: nil, health_message: nil},
      compatibility: %{status: :unknown},
      scheduling: scheduling(node),
      dispatch_capacity: dispatch_capacity(node, opts),
      warnings: []
    })
  end

  @spec node_status_map(Node.t() | map(), keyword()) :: map()
  def node_status_map(node, opts \\ []) do
    node
    |> node_status(opts)
    |> NodeStatus.to_map()
  end

  @spec candidate_status(AdmissionCandidate.t(), keyword()) :: NodeStatus.t()
  def candidate_status(%AdmissionCandidate{} = candidate, opts \\ []) do
    latest_decision =
      Keyword.get_lazy(opts, :latest_decision, fn ->
        Nodes.latest_admission_decision_for_candidate(candidate.id)
      end)

    NodeStatus.new!(%{
      resource: %{type: :admission_candidate, id: candidate.id},
      lifecycle: %{state: nil},
      admission: %{
        category: candidate.admission_category,
        source: candidate.source,
        latest_decision: decision_name(latest_decision)
      },
      health: %{status: :unknown},
      freshness: %{
        status: freshness(candidate.last_observed_at),
        observed_at: candidate.last_observed_at,
        source: :runtime_endpoint_observation
      },
      transport: candidate_transport(candidate),
      runtime: %{status: :unknown, health_code: nil, health_message: nil},
      compatibility: candidate_compatibility(candidate),
      scheduling: candidate_scheduling(candidate),
      dispatch_capacity: nil,
      warnings: []
    })
  end

  @spec candidate_status_map(AdmissionCandidate.t(), keyword()) :: map()
  def candidate_status_map(%AdmissionCandidate{} = candidate, opts \\ []) do
    candidate
    |> candidate_status(opts)
    |> NodeStatus.to_map()
  end

  @spec runtime_target_status(map()) :: NodeStatus.t()
  def runtime_target_status(%{} = target) do
    NodeStatus.new!(%{
      resource: %{type: :runtime_target, id: target_ref(target)},
      lifecycle: %{state: nil},
      admission: %{category: nil, source: nil, latest_decision: nil},
      health: %{status: runtime_health_status(target)},
      freshness: %{status: :unknown, observed_at: nil, source: nil},
      transport: runtime_transport(target),
      runtime: runtime_readiness(target),
      compatibility: runtime_compatibility(target),
      scheduling: %{eligible: false, reason_codes: []},
      dispatch_capacity: nil,
      warnings: runtime_warnings(target)
    })
  end

  @spec runtime_target_status_map(map()) :: map()
  def runtime_target_status_map(%{} = target) do
    target
    |> runtime_target_status()
    |> NodeStatus.to_map()
  end

  @spec node_status_maps([Node.t() | map()]) :: [map()]
  def node_status_maps(nodes) do
    decisions =
      nodes
      |> Enum.map(&node_id/1)
      |> Enum.reject(&is_nil/1)
      |> Nodes.latest_admission_decisions_for_nodes()

    capacity_snapshots = Diagnostics.snapshots(nodes)

    Enum.map(nodes, fn node ->
      node_status_map(node,
        latest_decision: Map.get(decisions, node_id(node)),
        dispatch_capacity_snapshot: Map.get(capacity_snapshots, node_id(node))
      )
    end)
  end

  defp node_id(%Node{id: id}), do: id
  defp node_id(%{} = node), do: node_field(node, :id)

  defp dispatch_capacity(node, opts) do
    case Keyword.fetch(opts, :dispatch_capacity_snapshot) do
      {:ok, %CapacitySnapshot{} = snapshot} -> CapacitySnapshot.to_map(snapshot)
      {:ok, nil} -> nil
      :error -> node |> Diagnostics.snapshot(opts) |> CapacitySnapshot.to_map()
    end
  end

  defp node_admission_category(_node, %AdmissionDecision{decision: :rejected}), do: :rejected
  defp node_admission_category(%Node{state: :provisioned}, _decision), do: :pending_provisioned
  defp node_admission_category(%Node{state: :registered}, _decision), do: :pending_registered

  defp node_admission_category(%Node{state: state}, _decision) when state in @admitted_states,
    do: :admitted

  defp node_admission_category(%Node{state: :removed}, _decision), do: :removed

  defp node_admission_category(%Node{}, _decision), do: :pending_registered

  defp node_admission_category(%{} = node, decision) do
    node_admission_category(%Node{state: node_field(node, :state)}, decision)
  end

  defp decision_name(%AdmissionDecision{decision: decision}), do: decision
  defp decision_name(_decision), do: nil

  defp scheduling(%Node{} = node) do
    reason_codes = scheduling_reason_codes(node)
    %{eligible: reason_codes == [], reason_codes: reason_codes}
  end

  defp scheduling(%{} = node) do
    reason_codes = scheduling_reason_codes(node)
    %{eligible: reason_codes == [], reason_codes: reason_codes}
  end

  defp scheduling_reason_codes(%Node{} = node) do
    []
    |> add_state_reason(node.state)
    |> add_health_reason(node.health)
    |> add_freshness_reason(node.last_heartbeat_at)
    |> Enum.uniq()
    |> Enum.reverse()
  end

  defp scheduling_reason_codes(%{} = node) do
    []
    |> add_state_reason(node_field(node, :state))
    |> add_health_reason(node_field(node, :health))
    |> add_freshness_reason(node_field(node, :last_heartbeat_at))
    |> Enum.uniq()
    |> Enum.reverse()
  end

  defp add_state_reason(reasons, :active), do: reasons
  defp add_state_reason(reasons, :provisioned), do: [:node_not_registered | reasons]
  defp add_state_reason(reasons, :registered), do: [:node_not_admitted | reasons]

  defp add_state_reason(reasons, state) when state in @unschedulable_states,
    do: [:node_not_active | reasons]

  defp add_state_reason(reasons, _state), do: [:inventory_missing | reasons]

  defp add_health_reason(reasons, :healthy), do: reasons
  defp add_health_reason(reasons, :degraded), do: reasons
  defp add_health_reason(reasons, :unreachable), do: [:node_health_unreachable | reasons]
  defp add_health_reason(reasons, :unhealthy), do: [:node_health_unhealthy | reasons]
  defp add_health_reason(reasons, _health), do: [:node_health_unhealthy | reasons]

  defp add_freshness_reason(reasons, last_heartbeat_at) do
    if schedulable_observation?(last_heartbeat_at) do
      reasons
    else
      [:node_observation_stale | reasons]
    end
  end

  defp schedulable_observation?(%DateTime{} = observed_at) do
    age_ms = DateTime.diff(DateTime.utc_now(), observed_at, :millisecond)
    age_ms <= Orchard.Inference.node_freshness_threshold_ms()
  end

  defp schedulable_observation?(_observed_at), do: false

  defp candidate_scheduling(%AdmissionCandidate{admission_category: :pending_observed}) do
    %{eligible: false, reason_codes: [:node_not_registered, :trust_not_established]}
  end

  defp candidate_scheduling(%AdmissionCandidate{admission_category: :pending_provisioned}) do
    %{eligible: false, reason_codes: [:node_not_registered]}
  end

  defp candidate_scheduling(%AdmissionCandidate{admission_category: :pending_registered}) do
    %{eligible: false, reason_codes: [:node_not_admitted]}
  end

  defp candidate_scheduling(%AdmissionCandidate{admission_category: :rejected}) do
    %{eligible: false, reason_codes: [:node_not_admitted]}
  end

  defp candidate_scheduling(_candidate),
    do: %{eligible: false, reason_codes: [:node_not_admitted]}

  defp candidate_transport(%AdmissionCandidate{endpoint_transport: nil}) do
    %{status: :target_unconfigured}
  end

  defp candidate_transport(%AdmissionCandidate{source: :runtime_endpoint_observation}) do
    %{status: :reachable}
  end

  defp candidate_transport(_candidate), do: %{status: :unknown}

  defp candidate_compatibility(%AdmissionCandidate{compatibility_evidence: evidence})
       when is_map(evidence) and map_size(evidence) > 0 do
    %{status: :partial_metadata}
  end

  defp candidate_compatibility(_candidate), do: %{status: :unknown}

  defp freshness(nil), do: :unknown

  defp freshness(%DateTime{} = observed_at) do
    age_ms = DateTime.diff(DateTime.utc_now(), observed_at, :millisecond)
    freshness_ms = Orchard.Inference.node_freshness_threshold_ms()
    unreachable_ms = Orchard.Inference.node_unreachable_threshold_ms()

    cond do
      age_ms <= min(freshness_ms, unreachable_ms) -> :fresh
      age_ms <= max(freshness_ms, unreachable_ms) -> :stale
      true -> :unreachable
    end
  end

  defp freshness(_observed_at), do: :unknown

  defp runtime_transport(%{status: :ok}), do: %{status: :reachable}
  defp runtime_transport(%{status: :timeout}), do: %{status: :timeout}

  defp runtime_transport(%{code: code})
       when code in ["identity_mismatch", "runtime_identity_mismatch"],
       do: %{status: :identity_mismatch}

  defp runtime_transport(%{status: :unavailable}), do: %{status: :connect_failed}
  defp runtime_transport(%{target: nil}), do: %{status: :target_unconfigured}
  defp runtime_transport(_target), do: %{status: :unknown}

  defp runtime_readiness(%{
         runtime_health: %{ready: true, health_code: code, health_message: message}
       }) do
    %{status: :ready, health_code: code, health_message: message}
  end

  defp runtime_readiness(%{
         runtime_health: %{ready: false, health_code: code, health_message: message}
       }) do
    %{status: :not_ready, health_code: code, health_message: message}
  end

  defp runtime_readiness(_target), do: %{status: :unknown, health_code: nil, health_message: nil}

  defp runtime_compatibility(%{status: status}) when status != :ok, do: %{status: :unknown}

  defp runtime_compatibility(%{node_metadata: nil, runtime_health: nil}) do
    %{status: :legacy_metadata}
  end

  defp runtime_compatibility(%{node_metadata: nil}), do: %{status: :partial_metadata}
  defp runtime_compatibility(%{runtime_health: nil}), do: %{status: :partial_metadata}
  defp runtime_compatibility(_target), do: %{status: :compatible}

  defp runtime_health_status(%{runtime_health: %{ready: true}}), do: :healthy
  defp runtime_health_status(%{runtime_health: %{ready: false}}), do: :unhealthy
  defp runtime_health_status(%{status: :unavailable}), do: :unreachable
  defp runtime_health_status(_target), do: :unknown

  defp runtime_warnings(%{status: :ok} = target) do
    case runtime_compatibility(target) do
      %{status: status} when status in [:legacy_metadata, :partial_metadata] ->
        [%{code: Atom.to_string(status), message: nil, metadata: %{}}]

      _compatibility ->
        []
    end
  end

  defp runtime_warnings(_target), do: []

  defp target_ref(%{target_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp target_ref(%{target_label: label}) when is_binary(label) and label != "", do: label
  defp target_ref(%{target_dom_id: id}) when is_binary(id) and id != "", do: id
  defp target_ref(_target), do: nil

  defp node_field(%{} = node, key), do: Map.get(node, key) || Map.get(node, Atom.to_string(key))
end
