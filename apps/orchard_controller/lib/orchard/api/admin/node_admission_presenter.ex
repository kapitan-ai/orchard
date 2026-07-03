defmodule Orchard.API.Admin.NodeAdmissionPresenter do
  @moduledoc """
  JSON presenters for Admin API node admission resources.
  """

  alias Orchard.ClusterManagement.{ActionPreview, StatusBuilder}
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}

  @spec list_candidates([AdmissionCandidate.t()]) :: map()
  def list_candidates(candidates) do
    latest_decisions =
      candidates
      |> Enum.map(& &1.id)
      |> Nodes.latest_admission_decisions_for_candidates()

    %{
      object: "list",
      data: Enum.map(candidates, &candidate(&1, Map.get(latest_decisions, &1.id)))
    }
  end

  @spec candidate(AdmissionCandidate.t()) :: map()
  def candidate(%AdmissionCandidate{} = candidate) do
    candidate(candidate, Nodes.latest_admission_decision_for_candidate(candidate.id))
  end

  @spec node(Node.t()) :: map()
  def node(%Node{} = node), do: present_node(node)

  @spec action_preview(ActionPreview.t()) :: map()
  def action_preview(%ActionPreview{} = preview), do: ActionPreview.to_map(preview)

  defp candidate(%AdmissionCandidate{} = candidate, latest_decision) do
    %{
      object: "node_admission_candidate",
      id: candidate.id,
      node_id: candidate.node_id,
      source: atom_string(candidate.source),
      admission_category: atom_string(candidate.admission_category),
      observed_identity: candidate.observed_identity || %{},
      target_ref: candidate.target_ref,
      endpoint: %{
        transport: atom_string(candidate.endpoint_transport),
        target: candidate.endpoint_target
      },
      inventory: candidate.inventory || %{},
      compatibility_evidence: candidate.compatibility_evidence || %{},
      last_observed_at: iso8601(candidate.last_observed_at),
      inserted_at: iso8601(candidate.inserted_at),
      updated_at: iso8601(candidate.updated_at),
      status: StatusBuilder.candidate_status_map(candidate, latest_decision: latest_decision),
      latest_decision: decision(latest_decision)
    }
  end

  @spec reject_result(map()) :: map()
  def reject_result(result), do: candidate_action_result("node_admission.rejected", result)

  @spec clear_rejection_result(map()) :: map()
  def clear_rejection_result(result),
    do: candidate_action_result("node_admission.rejection_cleared", result)

  @spec admit_result(map()) :: map()
  def admit_result(%{node: %Node{} = node, decision: decision, audit_log: audit_log}) do
    %{
      object: "node_admission_action_result",
      action: "node_admission.admitted",
      node: present_node(node),
      decision: decision(decision),
      audit_log: audit_log(audit_log)
    }
  end

  @spec lifecycle_result(String.t(), %{node: Node.t(), audit_log: AuditLog.t()}) :: map()
  def lifecycle_result(action, %{node: %Node{} = node, audit_log: audit_log}) do
    %{
      object: "node_lifecycle_action_result",
      action: action,
      node: present_node(node),
      audit_log: audit_log(audit_log)
    }
  end

  defp candidate_action_result(action, %{
         candidate: %AdmissionCandidate{} = candidate,
         decision: decision,
         audit_log: audit_log
       }) do
    %{
      object: "node_admission_action_result",
      action: action,
      candidate: candidate(candidate, decision),
      decision: decision(decision),
      audit_log: audit_log(audit_log)
    }
  end

  defp present_node(%Node{} = node) do
    latest_decision = Nodes.latest_admission_decision_for_node(node.id)

    %{
      object: "node",
      id: node.id,
      hostname: node.hostname,
      display_name: node.display_name,
      advertise_addr: node.advertise_addr,
      rpc_port: node.rpc_port,
      connect_host: node.connect_host,
      connect_port: node.connect_port,
      state: atom_string(node.state),
      health: atom_string(node.health),
      capabilities: node.capabilities || %{},
      tool_readiness: node.tool_readiness || %{},
      agent_version: node.agent_version,
      last_heartbeat_at: iso8601(node.last_heartbeat_at),
      inserted_at: iso8601(node.inserted_at),
      updated_at: iso8601(node.updated_at),
      status: StatusBuilder.node_status_map(node, latest_decision: latest_decision),
      latest_decision: decision(latest_decision)
    }
  end

  defp decision(nil), do: nil

  defp decision(%AdmissionDecision{} = decision) do
    %{
      object: "node_admission_decision",
      id: decision.id,
      candidate_id: decision.candidate_id,
      node_id: decision.node_id,
      decision: atom_string(decision.decision),
      actor_type: decision.actor_type,
      actor_id: decision.actor_id,
      reason: decision.reason,
      observed_identity: decision.observed_identity || %{},
      target_ref: decision.target_ref,
      audit_log_id: decision.audit_log_id,
      metadata: decision.metadata || %{},
      decided_at: iso8601(decision.decided_at),
      inserted_at: iso8601(decision.inserted_at)
    }
  end

  defp audit_log(%AuditLog{} = audit_log) do
    %{
      id: audit_log.id,
      scope: audit_log.scope,
      action: audit_log.action
    }
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: value

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
