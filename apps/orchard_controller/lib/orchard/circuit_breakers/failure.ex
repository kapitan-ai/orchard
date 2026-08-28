defmodule Orchard.CircuitBreakers.Failure do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "circuit_breaker_failures" do
    field(:node_id, :binary_id)
    field(:model_id, :binary_id)
    field(:failure_class, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:decision_at, :utc_datetime_usec)
    field(:disposition, Ecto.Enum, values: [:contributed, :fenced])
    field(:transition, Ecto.Enum, values: [:none, :opened])
    field(:generation, :integer)
    belongs_to(:breaker, Orchard.CircuitBreakers.Breaker)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(failure, attrs) do
    failure
    |> cast(attrs, [
      :id,
      :breaker_id,
      :node_id,
      :model_id,
      :failure_class,
      :occurred_at,
      :decision_at,
      :disposition,
      :transition,
      :generation
    ])
    |> validate_required([
      :id,
      :breaker_id,
      :node_id,
      :failure_class,
      :occurred_at,
      :decision_at,
      :disposition,
      :transition,
      :generation
    ])
    |> unique_constraint(:id, name: :circuit_breaker_failures_pkey)
    |> check_constraint(:model_id, name: :circuit_breaker_failures_target_valid)
  end
end
