defmodule Orchard.DispatchCapacity.Policy do
  @moduledoc """
  Durable Controller-owned dispatch-capacity policy for one admitted Node.

  The foundation supports legacy migration rows and explicit pre-cutover
  approvals. It intentionally exposes no transition to `enforcing`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Nodes.{AdmissionDecision, Node}

  @primary_key false
  @foreign_key_type :binary_id
  @states [:shadow_legacy, :approved_explicit, :enforcing]

  @type state :: :shadow_legacy | :approved_explicit | :enforcing
  @type t :: %__MODULE__{
          node_id: Ecto.UUID.t(),
          admission_decision_id: Ecto.UUID.t(),
          policy_state: state(),
          controller_dispatch_ceiling: non_neg_integer() | nil,
          approved_by_actor_type: String.t() | nil,
          approved_by_actor_id: String.t() | nil,
          approved_at: DateTime.t() | nil,
          approval_reason: String.t() | nil,
          legacy_admitted_at: DateTime.t() | nil,
          version: pos_integer()
        }

  schema "node_dispatch_capacity_policies" do
    belongs_to(:node, Node, primary_key: true)
    belongs_to(:admission_decision, AdmissionDecision)
    field(:policy_state, Ecto.Enum, values: @states)
    field(:controller_dispatch_ceiling, :integer)
    field(:approved_by_actor_type, :string)
    field(:approved_by_actor_id, :string)
    field(:approved_at, :utc_datetime_usec)
    field(:approval_reason, :string)
    field(:legacy_admitted_at, :utc_datetime_usec)
    field(:version, :integer, default: 1)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds an explicit policy approval for use while the authority is pre-cutover.
  """
  @spec approved_explicit_changeset(struct(), map()) :: Ecto.Changeset.t()
  def approved_explicit_changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :node_id,
      :admission_decision_id,
      :controller_dispatch_ceiling,
      :approved_by_actor_type,
      :approved_by_actor_id,
      :approved_at,
      :approval_reason,
      :version
    ])
    |> put_change(:policy_state, :approved_explicit)
    |> update_change(:approval_reason, &String.trim/1)
    |> validate_common()
    |> validate_required([
      :controller_dispatch_ceiling,
      :approved_by_actor_type,
      :approved_by_actor_id,
      :approved_at,
      :approval_reason
    ])
    |> validate_number(:controller_dispatch_ceiling, greater_than_or_equal_to: 0)
    |> apply_constraints()
  end

  defp validate_common(changeset) do
    changeset
    |> validate_required([:node_id, :admission_decision_id, :policy_state, :version])
    |> validate_number(:version, greater_than: 0)
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:admission_decision_id)
    |> foreign_key_constraint(:admission_decision_id,
      name: :node_dispatch_capacity_policies_admitted_decision
    )
    |> unique_constraint(:node_id, name: :node_dispatch_capacity_policies_pkey)
    |> unique_constraint(:admission_decision_id)
    |> check_constraint(:version, name: :node_dispatch_capacity_policies_version)
    |> check_constraint(:policy_state,
      name: :node_dispatch_capacity_policies_state_provenance
    )
  end
end
