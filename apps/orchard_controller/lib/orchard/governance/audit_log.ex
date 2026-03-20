defmodule Orchard.Governance.AuditLog do
  @moduledoc """
  Ecto schema for append-only governance audit records.

  The backing table omits `updated_at`, and the migration installs a trigger that
  rejects `UPDATE` and `DELETE` statements so rows remain append-only.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.{ApiKey, Tenant}

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_logs" do
    field(:actor_type, :string)
    field(:actor_id, :string)
    field(:action, :string)
    field(:target_type, :string)
    field(:target_id, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:payload, :map, default: %{})

    belongs_to(:tenant, Tenant)
    belongs_to(:api_key, ApiKey)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [
      :tenant_id,
      :api_key_id,
      :actor_type,
      :actor_id,
      :action,
      :target_type,
      :target_id,
      :occurred_at,
      :payload
    ])
    |> validate_required([:tenant_id, :actor_type, :action, :target_type])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:api_key_id)
  end
end
