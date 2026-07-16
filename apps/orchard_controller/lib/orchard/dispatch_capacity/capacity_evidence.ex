defmodule Orchard.DispatchCapacity.CapacityEvidence do
  @moduledoc """
  Latest bounded aggregate runtime capacity evidence for one admitted Node.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Nodes.Node

  @primary_key false
  @foreign_key_type :binary_id
  @validity_values [:valid, :missing, :invalid]

  @type validity :: :valid | :missing | :invalid
  @type t :: %__MODULE__{
          node_id: Ecto.UUID.t(),
          runtime_concurrency_limit: integer() | nil,
          active_request_count: integer() | nil,
          validity: validity(),
          observed_at: DateTime.t()
        }

  schema "node_runtime_capacity_evidence" do
    belongs_to(:node, Node, primary_key: true)
    field(:runtime_concurrency_limit, :integer)
    field(:active_request_count, :integer)
    field(:validity, Ecto.Enum, values: @validity_values)
    field(:observed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Validates normalized aggregate evidence without substituting fallback values.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(evidence, attrs) do
    evidence
    |> cast(attrs, [
      :node_id,
      :runtime_concurrency_limit,
      :active_request_count,
      :validity,
      :observed_at
    ])
    |> validate_required([:node_id, :validity, :observed_at])
    |> validate_values_for_validity()
    |> foreign_key_constraint(:node_id)
    |> unique_constraint(:node_id)
    |> check_constraint(:validity, name: :node_runtime_capacity_evidence_validity)
    |> check_constraint(:validity, name: :node_runtime_capacity_evidence_value_validity)
  end

  defp validate_values_for_validity(changeset) do
    case get_field(changeset, :validity) do
      :valid ->
        changeset
        |> validate_required([:runtime_concurrency_limit, :active_request_count])
        |> validate_number(:runtime_concurrency_limit, greater_than: 0)
        |> validate_number(:active_request_count, greater_than_or_equal_to: 0)

      :missing ->
        changeset
        |> validate_optional_positive(:runtime_concurrency_limit)
        |> validate_optional_non_negative(:active_request_count)
        |> require_missing_value()

      _invalid_or_unset ->
        changeset
    end
  end

  defp validate_optional_positive(changeset, field) do
    if is_nil(get_field(changeset, field)) do
      changeset
    else
      validate_number(changeset, field, greater_than: 0)
    end
  end

  defp validate_optional_non_negative(changeset, field) do
    if is_nil(get_field(changeset, field)) do
      changeset
    else
      validate_number(changeset, field, greater_than_or_equal_to: 0)
    end
  end

  defp require_missing_value(changeset) do
    if is_nil(get_field(changeset, :runtime_concurrency_limit)) or
         is_nil(get_field(changeset, :active_request_count)) do
      changeset
    else
      add_error(changeset, :validity, "requires at least one missing aggregate value")
    end
  end
end
