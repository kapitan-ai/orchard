defmodule Orchard.Nodes.AdmissionPreauthorization do
  @moduledoc """
  Immutable admission intent and its closed one-use outcome for one Enrollment.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes.{Enrollment, Node}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @states [:authorized, :consumed_admitted, :consumed_pending_review, :revoked, :expired]

  @type state ::
          :authorized | :consumed_admitted | :consumed_pending_review | :revoked | :expired
  @type t :: %__MODULE__{}

  schema "node_admission_preauthorizations" do
    field(:contract_version, :integer, default: 1)
    field(:cluster_id, :binary_id)
    belongs_to(:enrollment, Enrollment)
    belongs_to(:node, Node)
    belongs_to(:issuing_controller, ControllerInstance)
    field(:issuing_actor_type, :string)
    field(:issuing_actor_id, :string)
    field(:issued_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:state, Ecto.Enum, values: @states, default: :authorized)
    field(:pool_id, :string)
    field(:pool_revision, :string)
    field(:routing_policy_id, :string)
    field(:routing_policy_revision, :string)
    field(:controller_dispatch_ceiling, :integer)
    field(:capacity_policy_reason, :string)
    field(:dispatch_capacity_phase, Ecto.Enum, values: [:pre_cutover, :enforcing])
    field(:dispatch_capacity_revision, :integer)
    field(:admission_mode_revision, :integer)
    field(:bound_predicates, :map, default: %{})
    field(:preview_digest, :string)
    field(:confirmation_evidence, :map, default: %{})
    belongs_to(:issuance_audit_log, AuditLog, type: :id)
    field(:consumed_at, :utc_datetime_usec)
    field(:outcome_reason, :string)
    field(:executing_controller_id, :binary_id)
    field(:redemption_csr_fingerprint, :string)
    belongs_to(:terminal_audit_log, AuditLog, type: :id)
    belongs_to(:pending_review_audit_log, AuditLog, type: :id)
    field(:lock_version, :integer, default: 1)
    timestamps(type: :utc_datetime_usec)
  end

  @spec states() :: [state()]
  def states, do: @states

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(preauthorization, attrs) do
    preauthorization
    |> cast(attrs, [
      :id,
      :contract_version,
      :cluster_id,
      :enrollment_id,
      :node_id,
      :issuing_controller_id,
      :issuing_actor_type,
      :issuing_actor_id,
      :issued_at,
      :expires_at,
      :state,
      :pool_id,
      :pool_revision,
      :routing_policy_id,
      :routing_policy_revision,
      :controller_dispatch_ceiling,
      :capacity_policy_reason,
      :dispatch_capacity_phase,
      :dispatch_capacity_revision,
      :admission_mode_revision,
      :bound_predicates,
      :preview_digest,
      :confirmation_evidence,
      :issuance_audit_log_id,
      :consumed_at,
      :outcome_reason,
      :executing_controller_id,
      :redemption_csr_fingerprint,
      :terminal_audit_log_id,
      :pending_review_audit_log_id,
      :lock_version
    ])
    |> validate_required([
      :contract_version,
      :cluster_id,
      :enrollment_id,
      :node_id,
      :issuing_controller_id,
      :issuing_actor_type,
      :issuing_actor_id,
      :issued_at,
      :expires_at,
      :state,
      :pool_id,
      :pool_revision,
      :routing_policy_id,
      :routing_policy_revision,
      :controller_dispatch_ceiling,
      :capacity_policy_reason,
      :dispatch_capacity_phase,
      :dispatch_capacity_revision,
      :admission_mode_revision,
      :bound_predicates,
      :preview_digest,
      :confirmation_evidence,
      :issuance_audit_log_id,
      :lock_version
    ])
    |> validate_number(:contract_version, equal_to: 1)
    |> validate_number(:controller_dispatch_ceiling, greater_than_or_equal_to: 0)
    |> validate_number(:dispatch_capacity_revision, greater_than: 0)
    |> validate_number(:admission_mode_revision, greater_than: 0)
    |> unique_constraint(:enrollment_id)
    |> unique_constraint(:node_id)
    |> foreign_key_constraint(:enrollment_id)
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:issuing_controller_id)
    |> foreign_key_constraint(:issuance_audit_log_id)
    |> foreign_key_constraint(:terminal_audit_log_id)
    |> foreign_key_constraint(:pending_review_audit_log_id)
    |> check_constraint(:contract_version,
      name: :node_admission_preauthorizations_contract_version
    )
    |> check_constraint(:state, name: :node_admission_preauthorizations_state)
    |> check_constraint(:controller_dispatch_ceiling,
      name: :node_admission_preauthorizations_values
    )
    |> check_constraint(:state,
      name: :node_admission_preauthorizations_terminal_evidence
    )
  end
end
