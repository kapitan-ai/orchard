defmodule Orchard.ClusterManagement.ActionPreviewBuilder do
  @moduledoc """
  Builds side-effect-free cluster-management action previews.
  """

  alias Orchard.ClusterManagement.{ActionPreview, StatusBuilder}
  alias Orchard.ControlPlane
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, Lifecycle, Node}

  @spec admit_node(Ecto.UUID.t(), map() | keyword()) :: ActionPreview.t()
  def admit_node(node_id, attrs \\ %{}) do
    attrs = Map.new(attrs)

    case Nodes.fetch_node(node_id) do
      {:ok, %Node{} = node} ->
        blockers =
          []
          |> add_write_path_blocker()
          |> add_blockers(Nodes.admission_blocker_codes(node, attrs))

        action_preview(%{
          action: "node_admission.admit",
          target: %{type: "node", id: node.id},
          current: StatusBuilder.node_status_map(node),
          scheduler_eligibility: scheduler_eligibility(node),
          blockers: blockers,
          confirmation_requirements: [:requires_yes_flag],
          expected_transition: %{from: node.state, to: :admitted},
          audit_action: "node_admission.admitted",
          confirmation_required: true
        })

      {:error, :node_not_found} ->
        missing_target_preview("node_admission.admit", "node", node_id, "node_admission.admitted")
    end
  end

  @spec reject_admission(Ecto.UUID.t(), map() | keyword()) :: ActionPreview.t()
  def reject_admission(candidate_or_node_id, attrs \\ %{}) do
    attrs = Map.new(attrs)

    case admission_rejection_target(candidate_or_node_id) do
      {:candidate, %AdmissionCandidate{} = candidate} ->
        reject_candidate_preview(candidate, attrs)

      {:node, %Node{} = node} ->
        reject_node_preview(node, attrs)

      :not_found ->
        missing_target_preview(
          "node_admission.reject",
          "node",
          candidate_or_node_id,
          "node_admission.rejected"
        )
    end
  end

  @spec node_lifecycle(Lifecycle.action(), Ecto.UUID.t(), map() | keyword()) :: ActionPreview.t()
  def node_lifecycle(action, node_id, attrs \\ %{})
      when action in [
             :cordon,
             :uncordon,
             :drain,
             :maintenance,
             :resume,
             :decommission
           ] do
    _attrs = Map.new(attrs)

    case Nodes.fetch_node(node_id) do
      {:ok, %Node{} = node} ->
        blockers =
          []
          |> add_write_path_blocker()
          |> add_blockers(Lifecycle.blocker_codes(action, node))

        action_preview(%{
          action: Lifecycle.preview_action(action),
          target: %{type: "node", id: node.id},
          current: StatusBuilder.node_status_map(node),
          active_request_count: nil,
          scheduler_eligibility: scheduler_eligibility(node),
          blockers: blockers,
          warnings: [],
          consequence_codes: Lifecycle.consequence_codes(action),
          confirmation_requirements: Lifecycle.confirmation_requirements(action),
          expected_transition: %{from: node.state, to: Lifecycle.target_state(action)},
          audit_action: Lifecycle.audit_action(action),
          confirmation_required: true
        })

      {:error, :node_not_found} ->
        missing_target_preview(
          Lifecycle.preview_action(action),
          "node",
          node_id,
          Lifecycle.audit_action(action)
        )
    end
  end

  @spec not_found_preview(:admit | :reject | Lifecycle.action(), Ecto.UUID.t()) ::
          ActionPreview.t()
  def not_found_preview(:admit, node_id) do
    missing_target_preview("node_admission.admit", "node", node_id, "node_admission.admitted")
  end

  def not_found_preview(:reject, target_id) do
    missing_target_preview("node_admission.reject", "node", target_id, "node_admission.rejected")
  end

  def not_found_preview(action, node_id)
      when action in [
             :cordon,
             :uncordon,
             :drain,
             :maintenance,
             :resume,
             :decommission
           ] do
    missing_target_preview(
      Lifecycle.preview_action(action),
      "node",
      node_id,
      Lifecycle.audit_action(action)
    )
  end

  defp reject_candidate_preview(%AdmissionCandidate{} = candidate, attrs) do
    blockers =
      []
      |> add_write_path_blocker()
      |> add_blockers(candidate_rejection_blockers(candidate))

    action_preview(%{
      action: "node_admission.reject",
      target: %{type: "admission_candidate", id: candidate.id},
      current: StatusBuilder.candidate_status_map(candidate),
      scheduler_eligibility: %{eligible: false, reason_codes: [:node_not_admitted]},
      blockers: blockers,
      confirmation_requirements: rejection_confirmation_requirements(attrs),
      expected_transition: %{from: candidate.admission_category, to: :rejected},
      audit_action: "node_admission.rejected",
      confirmation_required: true
    })
  end

  defp reject_node_preview(%Node{} = node, attrs) do
    blockers =
      []
      |> add_write_path_blocker()
      |> add_blockers(node_rejection_blockers(node))

    action_preview(%{
      action: "node_admission.reject",
      target: %{type: "node", id: node.id},
      current: StatusBuilder.node_status_map(node),
      scheduler_eligibility: scheduler_eligibility(node),
      blockers: blockers,
      confirmation_requirements: rejection_confirmation_requirements(attrs),
      expected_transition: %{from: node.state, to: :rejected},
      audit_action: "node_admission.rejected",
      confirmation_required: true
    })
  end

  defp missing_target_preview(action, target_type, target_id, audit_action) do
    action_preview(%{
      action: action,
      target: %{type: target_type, id: target_id},
      current: %{},
      scheduler_eligibility: %{eligible: false, reason_codes: []},
      blockers: [:node_not_found],
      confirmation_requirements: [:requires_yes_flag],
      expected_transition: %{from: nil, to: nil},
      audit_action: audit_action,
      confirmation_required: true
    })
  end

  defp admission_rejection_target(candidate_or_node_id) do
    case Nodes.fetch_admission_candidate(candidate_or_node_id) do
      {:ok, %AdmissionCandidate{} = candidate} ->
        {:candidate, candidate}

      {:error, :candidate_not_found} ->
        case Nodes.fetch_node(candidate_or_node_id) do
          {:ok, %Node{} = node} -> {:node, node}
          {:error, :node_not_found} -> :not_found
        end
    end
  end

  defp candidate_rejection_blockers(%AdmissionCandidate{admission_category: category})
       when category in [:pending_observed, :pending_provisioned, :pending_registered],
       do: []

  defp candidate_rejection_blockers(%AdmissionCandidate{}), do: [:node_not_pending_admission]

  defp node_rejection_blockers(%Node{state: state}) when state in [:provisioned, :registered],
    do: []

  defp node_rejection_blockers(%Node{}), do: [:node_not_pending_admission]

  defp rejection_confirmation_requirements(attrs) do
    [:requires_yes_flag]
    |> add_confirmation_requirement(:requires_reason, blank?(Map.get(attrs, "reason")))
  end

  defp add_confirmation_requirement(requirements, requirement, true),
    do: requirements ++ [requirement]

  defp add_confirmation_requirement(requirements, _requirement, false), do: requirements

  defp scheduler_eligibility(%Node{} = node) do
    node
    |> StatusBuilder.node_status()
    |> then(& &1.scheduling)
  end

  defp add_write_path_blocker(blockers) do
    case ControlPlane.authorize_write_path(:node_admission) do
      :ok -> blockers
      {:error, :controller_standby} -> blockers ++ [:ha_standby_write_blocked]
    end
  end

  defp add_blockers(blockers, more_blockers), do: blockers ++ List.wrap(more_blockers)

  defp action_preview(attrs) do
    attrs
    |> Map.update!(:blockers, &blocker_entries/1)
    |> ActionPreview.new!()
  end

  defp blocker_entries(blockers) do
    blockers
    |> Enum.uniq()
    |> Enum.map(&%{code: &1, message: blocker_message(&1), metadata: %{}})
  end

  defp blocker_message(:ha_standby_write_blocked), do: "This controller is in standby mode."
  defp blocker_message(:inventory_missing), do: "Registered node inventory is missing."
  defp blocker_message(:decommission_already_running), do: "Node decommission is already running."
  defp blocker_message(:drain_already_running), do: "Node drain is already running."

  defp blocker_message(:lifecycle_transition_invalid),
    do: "Node lifecycle state does not allow this action."

  defp blocker_message(:maintenance_requires_drain),
    do: "Node must be draining before maintenance."

  defp blocker_message(:node_not_found), do: "Node was not found."
  defp blocker_message(:node_not_active), do: "Node is not active."
  defp blocker_message(:node_not_admitted), do: "Node is not admitted."
  defp blocker_message(:node_not_pending_admission), do: "Node is not pending admission."
  defp blocker_message(:node_not_registered), do: "Node is not registered."
  defp blocker_message(:node_unhealthy), do: "Node health is unhealthy."
  defp blocker_message(:node_unreachable), do: "Node is unreachable."
  defp blocker_message(:policy_required), do: "Required policy inputs are missing."
  defp blocker_message(:pool_required), do: "Node pool assignment is required."
  defp blocker_message(:trust_not_established), do: "Node trust evidence is required."

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false
end
