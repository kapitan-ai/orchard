defmodule Orchard.Nodes.ClusterIdentity do
  @moduledoc """
  Stable cluster and logical runtime Controller identity.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}

  @type t :: %__MODULE__{}

  schema "cluster_identities" do
    field(:singleton, :boolean, default: true)
    field(:name, :string)
    field(:runtime_controller_id, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:id, :singleton, :name, :runtime_controller_id])
    |> validate_required([:id, :singleton, :runtime_controller_id])
    |> validate_acceptance(:singleton)
    |> unique_constraint(:singleton)
    |> unique_constraint(:runtime_controller_id)
    |> check_constraint(:singleton, name: :cluster_identities_singleton)
  end
end
