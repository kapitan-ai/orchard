defmodule Orchard.Nodes.Lifecycle do
  @moduledoc """
  Node lifecycle action transitions and audit persistence.
  """

  alias Orchard.Governance
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes
  alias Orchard.Nodes.Node
  alias Orchard.Repo
  alias Orchard.SchemaSupport

  @typedoc "Supported operator lifecycle actions for admitted node inventory."
  @type action :: :cordon | :uncordon | :drain | :maintenance | :resume | :decommission

  @actions [:cordon, :uncordon, :drain, :maintenance, :resume, :decommission]

  @action_specs %{
    cordon: %{
      allowed_states: [:active],
      target_state: :cordoned,
      preview_action: "node_lifecycle.cordon",
      audit_action: "node_lifecycle.cordoned",
      confirmation_requirements: [:requires_yes_flag],
      consequence_codes: []
    },
    uncordon: %{
      allowed_states: [:cordoned],
      target_state: :active,
      preview_action: "node_lifecycle.uncordon",
      audit_action: "node_lifecycle.uncordoned",
      confirmation_requirements: [:requires_yes_flag],
      consequence_codes: []
    },
    drain: %{
      allowed_states: [:active, :cordoned],
      target_state: :draining,
      preview_action: "node_lifecycle.drain",
      audit_action: "node_lifecycle.drain_started",
      confirmation_requirements: [
        :requires_yes_flag,
        :requires_drain_consequence_acknowledgement
      ],
      consequence_codes: [:existing_requests_continue_until_deadline]
    },
    maintenance: %{
      allowed_states: [:draining],
      target_state: :maintenance,
      preview_action: "node_lifecycle.maintenance",
      audit_action: "node_lifecycle.maintenance_entered",
      confirmation_requirements: [:requires_yes_flag],
      consequence_codes: []
    },
    resume: %{
      allowed_states: [:maintenance],
      target_state: :active,
      preview_action: "node_lifecycle.resume",
      audit_action: "node_lifecycle.resumed",
      confirmation_requirements: [:requires_yes_flag],
      consequence_codes: []
    },
    decommission: %{
      allowed_states: [:registered, :admitted, :active, :cordoned, :draining, :maintenance],
      target_state: :decommissioning,
      preview_action: "node_lifecycle.decommission",
      audit_action: "node_lifecycle.decommission_started",
      confirmation_requirements: [
        :requires_yes_flag,
        :requires_typed_node_id,
        :requires_decommission_consequence_acknowledgement
      ],
      consequence_codes: [:future_scheduling_revoked, :no_rejoin_with_same_node_id]
    }
  }

  @spec actions() :: [action()]
  def actions, do: @actions

  @spec action?(term()) :: boolean()
  def action?(action), do: action in @actions

  @spec preview_action(action()) :: String.t()
  def preview_action(action), do: fetch_spec!(action).preview_action

  @spec audit_action(action()) :: String.t()
  def audit_action(action), do: fetch_spec!(action).audit_action

  @spec target_state(action()) :: atom()
  def target_state(action), do: fetch_spec!(action).target_state

  @spec confirmation_requirements(action()) :: [atom()]
  def confirmation_requirements(action), do: fetch_spec!(action).confirmation_requirements

  @spec consequence_codes(action()) :: [atom()]
  def consequence_codes(action), do: fetch_spec!(action).consequence_codes

  @spec blocker_codes(action(), Node.t()) :: [atom()]
  def blocker_codes(action, %Node{} = node) do
    action
    |> fetch_spec!()
    |> do_blocker_codes(action, node)
  end

  @spec execute(action(), Ecto.UUID.t(), map() | keyword(), keyword()) ::
          {:ok, %{node: Node.t(), audit_log: AuditLog.t()}} | {:error, term()}
  def execute(action, node_id, attrs \\ %{}, opts \\ [])

  def execute(action, node_id, attrs, opts) when action in @actions do
    attrs = SchemaSupport.normalize_attrs(attrs)

    Repo.transaction(fn ->
      with {:ok, node} <- Nodes.lock_node(node_id),
           [] <- blocker_codes(action, node),
           {:ok, updated_node} <- update_node_state(node, target_state(action)),
           {:ok, audit_log} <-
             insert_lifecycle_audit_log(action, node, updated_node, attrs, opts) do
        {:ok, %{node: updated_node, audit_log: audit_log}}
      else
        {:error, reason} -> Repo.rollback(reason)
        [reason | _rest] -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  def execute(_action, _node_id, _attrs, _opts), do: {:error, :lifecycle_action_unknown}

  defp do_blocker_codes(spec, action, %Node{} = node) do
    []
    |> add_wrong_state_blocker(action, node.state, spec.allowed_states)
    |> add_resume_health_blockers(action, node.health)
    |> add_maintenance_drain_verification_blocker(action, node.state)
    |> Enum.uniq()
  end

  defp add_wrong_state_blocker(blockers, action, state, allowed_states) do
    if state in allowed_states do
      blockers
    else
      add_disallowed_state_blocker(blockers, action, state)
    end
  end

  defp add_disallowed_state_blocker(blockers, :cordon, state)
       when state in [:provisioned, :registered],
       do: blockers ++ [:node_not_admitted]

  defp add_disallowed_state_blocker(blockers, :cordon, _state),
    do: blockers ++ [:node_not_active]

  defp add_disallowed_state_blocker(blockers, :drain, :draining),
    do: blockers ++ [:drain_already_running]

  defp add_disallowed_state_blocker(blockers, :drain, state)
       when state in [:provisioned, :registered, :admitted],
       do: blockers ++ [:node_not_active]

  defp add_disallowed_state_blocker(blockers, :drain, _state),
    do: blockers ++ [:lifecycle_transition_invalid]

  defp add_disallowed_state_blocker(blockers, :maintenance, _state),
    do: blockers ++ [:maintenance_requires_drain]

  defp add_disallowed_state_blocker(blockers, :decommission, :decommissioning),
    do: blockers ++ [:decommission_already_running]

  defp add_disallowed_state_blocker(blockers, :decommission, :provisioned),
    do: blockers ++ [:node_not_registered]

  defp add_disallowed_state_blocker(blockers, _action, _state),
    do: blockers ++ [:lifecycle_transition_invalid]

  defp add_resume_health_blockers(blockers, :resume, :unreachable),
    do: blockers ++ [:node_unreachable]

  defp add_resume_health_blockers(blockers, :resume, :unhealthy),
    do: blockers ++ [:node_unhealthy]

  defp add_resume_health_blockers(blockers, _action, _health), do: blockers

  defp add_maintenance_drain_verification_blocker(blockers, :maintenance, :draining),
    do: blockers ++ [:drain_completion_unverified]

  defp add_maintenance_drain_verification_blocker(blockers, _action, _state), do: blockers

  defp update_node_state(%Node{} = node, state) do
    node
    |> Ecto.Changeset.change(state: state)
    |> Repo.update()
  end

  defp insert_lifecycle_audit_log(action, %Node{} = original, %Node{} = updated, attrs, opts) do
    Governance.insert_cluster_audit_log(%{
      actor_type: opts |> Keyword.get(:actor_type, "operator") |> to_string(),
      actor_id: Keyword.get(opts, :actor_id),
      action: audit_action(action),
      target_type: "node",
      target_id: updated.id,
      occurred_at: SchemaSupport.utc_now(),
      payload: lifecycle_audit_payload(original, updated, attrs)
    })
  end

  defp lifecycle_audit_payload(%Node{} = original, %Node{} = updated, attrs) do
    %{
      "node_id" => updated.id,
      "display_name" => updated.display_name,
      "from_state" => Atom.to_string(original.state),
      "to_state" => Atom.to_string(updated.state)
    }
    |> maybe_put_reason(Map.get(attrs, "reason"))
  end

  defp maybe_put_reason(payload, reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> payload
      trimmed -> Map.put(payload, "reason", String.slice(trimmed, 0, 512))
    end
  end

  defp maybe_put_reason(payload, _reason), do: payload

  defp fetch_spec!(action), do: Map.fetch!(@action_specs, action)

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_transaction_result({:ok, value}), do: value
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}
end
