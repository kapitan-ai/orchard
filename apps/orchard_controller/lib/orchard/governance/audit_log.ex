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

  @type t :: %__MODULE__{}

  schema "audit_logs" do
    field(:scope, :string, default: "tenant")
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
      :scope,
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
    |> put_default_scope()
    |> validate_required([:scope, :actor_type, :action, :target_type])
    |> validate_inclusion(:scope, ["tenant", "cluster"])
    |> validate_scope()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:api_key_id)
    |> check_constraint(:scope, name: :audit_logs_scope_tenant_consistency)
  end

  defp put_default_scope(changeset) do
    case get_field(changeset, :scope) do
      nil -> put_change(changeset, :scope, "tenant")
      _scope -> changeset
    end
  end

  defp validate_scope(changeset) do
    scope = get_field(changeset, :scope)
    tenant_id = get_field(changeset, :tenant_id)

    case {scope, tenant_id} do
      {"tenant", nil} ->
        add_error(changeset, :tenant_id, "can't be blank")

      {"cluster", tenant_id} when not is_nil(tenant_id) ->
        add_error(changeset, :tenant_id, "must be blank")

      _valid ->
        changeset
    end
  end
end
