defmodule Orchard.CircuitBreakers.Breaker do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "circuit_breakers" do
    field(:kind, Ecto.Enum, values: [:node, :placement])
    field(:model_id, :binary_id)
    field(:state, Ecto.Enum, values: [:closed, :open])
    field(:generation, :integer, default: 0)
    field(:opened_at, :utc_datetime_usec)
    field(:suppressed_until, :utc_datetime_usec)
    field(:last_cleared_at, :utc_datetime_usec)
    belongs_to(:node, Orchard.Nodes.Node)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(breaker, attrs) do
    breaker
    |> cast(attrs, [:kind, :node_id, :model_id, :state, :generation])
    |> validate_required([:kind, :node_id, :state, :generation])
    |> check_constraint(:model_id, name: :circuit_breakers_identity_valid)
  end
end
