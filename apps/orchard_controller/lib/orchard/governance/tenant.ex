defmodule Orchard.Governance.Tenant do
  @moduledoc """
  Ecto schema for governance tenants.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.{ApiKey, AuditLog, ProvisioningBatch, ServiceAccount}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @request_body_capture_modes [none: "none", metadata: "metadata", full: "full"]

  @type t :: %__MODULE__{}

  schema "tenants" do
    field(:slug, :string)
    field(:name, :string)

    field(:request_body_capture_mode, Ecto.Enum,
      values: @request_body_capture_modes,
      default: :metadata
    )

    field(:portal_password_hash, :string)
    field(:portal_session_epoch, :integer, default: 0)

    has_many(:api_keys, ApiKey)
    has_many(:audit_logs, AuditLog)
    has_many(:service_accounts, ServiceAccount)
    has_many(:provisioning_batches, ProvisioningBatch)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :request_body_capture_mode])
    |> validate_required([:slug, :name, :request_body_capture_mode])
    |> unique_constraint(:slug)
  end

  @spec portal_access_changeset(t(), map()) :: Ecto.Changeset.t()
  def portal_access_changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:portal_password_hash, :portal_session_epoch])
    |> validate_required([:portal_session_epoch])
    |> validate_number(:portal_session_epoch, greater_than_or_equal_to: 0)
    |> check_constraint(:portal_password_hash, name: :tenants_portal_password_hash_present)
    |> check_constraint(:portal_session_epoch, name: :tenants_portal_session_epoch_non_negative)
  end
end
