defmodule Orchard.Nodes.AdmissionDecision do
  @moduledoc """
  Ecto schema for append-only node admission decisions.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes.{AdmissionCandidate, Node}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @decisions [:rejected, :rejection_cleared, :admitted]

  @type t :: %__MODULE__{}

  schema "node_admission_decisions" do
    field(:decision, Ecto.Enum, values: @decisions)
    field(:actor_type, :string)
    field(:actor_id, :string)
    field(:reason, :string)
    field(:observed_identity, :map, default: %{})
    field(:target_ref, :string)
    field(:metadata, :map, default: %{})
    field(:decided_at, :utc_datetime_usec)

    belongs_to(:candidate, AdmissionCandidate)
    belongs_to(:node, Node)
    belongs_to(:audit_log, AuditLog, type: :id)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec decisions() :: [atom()]
  def decisions, do: @decisions

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :candidate_id,
      :node_id,
      :decision,
      :actor_type,
      :actor_id,
      :reason,
      :observed_identity,
      :target_ref,
      :audit_log_id,
      :metadata,
      :decided_at
    ])
    |> validate_required([:decision, :actor_type, :observed_identity, :metadata, :decided_at])
    |> validate_rejection_reason()
    |> foreign_key_constraint(:candidate_id)
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:audit_log_id)
  end

  defp validate_rejection_reason(changeset) do
    decision = get_field(changeset, :decision)
    reason = changeset |> get_field(:reason) |> normalize_reason()

    if decision == :rejected and is_nil(reason) do
      add_error(changeset, :reason, "must be present for rejected admission")
    else
      put_change(changeset, :reason, reason)
    end
  end

  @doc """
  Normalizes an operator-supplied reason to a trimmed, non-empty string.

  Every value that is not a non-empty string, including non-binary input,
  normalizes to `nil` so callers reject it before opening a transaction.
  """
  @spec normalize_reason(term()) :: String.t() | nil
  def normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def normalize_reason(_reason), do: nil
end
