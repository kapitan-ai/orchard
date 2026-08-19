defmodule Orchard.Governance.Tenant do
  @moduledoc """
  Ecto schema for governance tenants.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.{ApiKey, AuditLog, ProvisioningBatch, ServiceAccount}
  alias Orchard.Models.{RoutingPolicy, TenantModelAccess}

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

    has_many(:api_keys, ApiKey)
    has_many(:audit_logs, AuditLog)
    has_many(:service_accounts, ServiceAccount)
    has_many(:provisioning_batches, ProvisioningBatch)
    has_many(:model_access, TenantModelAccess)
    has_many(:routing_policies, RoutingPolicy)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:slug, :name, :request_body_capture_mode])
    |> validate_required([:slug, :name, :request_body_capture_mode])
    |> unique_constraint(:slug)
  end
end
