defmodule Orchard.Models.TenantModelAccess do
  @moduledoc """
  Explicit Tenant authorization for a catalog Model.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.Tenant
  alias Orchard.Models.{Model, RoutingPolicy}

  @primary_key false
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "tenant_model_access" do
    belongs_to(:tenant, Tenant, primary_key: true)
    belongs_to(:model, Model, primary_key: true)
    belongs_to(:routing_policy, RoutingPolicy)

    field(:enabled, :boolean, default: true)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(access, attrs) do
    access
    |> cast(attrs, [:tenant_id, :model_id, :routing_policy_id, :enabled])
    |> validate_required([:tenant_id, :model_id, :enabled])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:model_id)
    |> foreign_key_constraint(:routing_policy_id)
    |> unique_constraint([:tenant_id, :model_id], name: :tenant_model_access_pkey)
    |> check_constraint(:routing_policy_id,
      name: :tenant_model_access_routing_policy_scope,
      message: "must reference a global policy or one owned by the same tenant"
    )
  end
end
