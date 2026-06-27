defmodule Orchard.Governance.ProvisioningBatch do
  @moduledoc """
  Ecto schema for non-secret bulk API Client provisioning metadata.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.Tenant

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [
    applying: "applying",
    applied: "applied",
    failed: "failed",
    output_failed: "output_failed"
  ]

  @type status :: :applying | :applied | :failed | :output_failed
  @type t :: %__MODULE__{}

  schema "provisioning_batches" do
    field(:actor_type, :string, default: "operator")
    field(:actor_id, :string)
    field(:status, Ecto.Enum, values: @statuses)
    field(:row_count, :integer, default: 0)
    field(:api_clients_created_count, :integer, default: 0)
    field(:api_clients_updated_count, :integer, default: 0)
    field(:api_tokens_created_count, :integer, default: 0)
    field(:api_tokens_rotated_count, :integer, default: 0)
    field(:api_tokens_revoked_count, :integer, default: 0)
    field(:input_sha256, :string)
    field(:error_summary, :map, default: %{})
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    belongs_to(:tenant, Tenant)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(provisioning_batch, attrs) do
    provisioning_batch
    |> cast(attrs, [
      :tenant_id,
      :actor_type,
      :actor_id,
      :status,
      :row_count,
      :api_clients_created_count,
      :api_clients_updated_count,
      :api_tokens_created_count,
      :api_tokens_rotated_count,
      :api_tokens_revoked_count,
      :input_sha256,
      :error_summary,
      :started_at,
      :completed_at
    ])
    |> validate_required([:tenant_id, :actor_type, :status, :row_count, :started_at])
    |> validate_number(:row_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_clients_created_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_clients_updated_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_tokens_created_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_tokens_rotated_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_tokens_revoked_count, greater_than_or_equal_to: 0)
    |> check_constraint(:status, name: :provisioning_batches_status_check)
    |> check_constraint(:row_count, name: :provisioning_batches_counts_non_negative)
    |> foreign_key_constraint(:tenant_id)
  end
end
