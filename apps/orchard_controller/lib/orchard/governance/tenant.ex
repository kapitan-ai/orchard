defmodule Orchard.Governance.Tenant do
  @moduledoc """
  Ecto schema for governance tenants.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.{ApiKey, AuditLog}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tenants" do
    field(:slug, :string)
    field(:name, :string)

    has_many(:api_keys, ApiKey)
    has_many(:audit_logs, AuditLog)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name])
    |> validate_required([:slug, :name])
    |> unique_constraint(:slug)
  end
end
