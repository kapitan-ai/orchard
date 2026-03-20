defmodule Orchard.Governance.ApiKey do
  @moduledoc """
  Ecto schema for governance API-key metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.{AuditLog, Tenant}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "api_keys" do
    field(:name, :string)
    field(:token_prefix, :string)
    field(:secret_hash, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    belongs_to(:tenant, Tenant)
    has_many(:audit_logs, AuditLog)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [:tenant_id, :name, :token_prefix, :secret_hash, :last_used_at, :revoked_at])
    |> validate_required([:tenant_id, :name, :token_prefix, :secret_hash])
    |> unique_constraint(:token_prefix)
    |> foreign_key_constraint(:tenant_id)
  end
end
