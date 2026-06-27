defmodule Orchard.Governance.RoleBinding do
  @moduledoc """
  Ecto schema for governance access-level assignments.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.Tenant

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @principal_types [tenant: "tenant", service_account: "service_account", api_key: "api_key"]
  @roles [
    admin: "admin",
    operator: "operator",
    tenant_admin: "tenant_admin",
    inference_client: "inference_client"
  ]

  @type principal_type :: :tenant | :service_account | :api_key
  @type role :: :admin | :operator | :tenant_admin | :inference_client
  @type t :: %__MODULE__{}

  schema "role_bindings" do
    field(:principal_type, Ecto.Enum, values: @principal_types)
    field(:principal_id, Ecto.UUID)
    field(:role, Ecto.Enum, values: @roles)

    belongs_to(:tenant_scope, Tenant)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(role_binding, attrs) do
    role_binding
    |> cast(attrs, [:principal_type, :principal_id, :role, :tenant_scope_id])
    |> validate_required([:principal_type, :principal_id, :role])
    |> check_constraint(:principal_type, name: :role_bindings_principal_type_check)
    |> check_constraint(:role, name: :role_bindings_role_check)
    |> check_constraint(:tenant_scope_id, name: :role_bindings_inference_client_tenant_scope)
    |> unique_constraint(:role, name: :idx_role_bindings_unique_assignment)
    |> foreign_key_constraint(:tenant_scope_id)
  end
end
