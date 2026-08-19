defmodule Orchard.Models.RoutingPolicy do
  @moduledoc """
  Persisted Tenant-scoped or global routing policy.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.Tenant
  alias Orchard.Models.TenantModelAccess

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @residency_preferences [:required_loaded, :prefer_loaded, :allow_cold_load]

  @type t :: %__MODULE__{}

  schema "routing_policies" do
    field(:name, :string)
    field(:allowed_pool_ids, {:array, :binary_id}, default: [])
    field(:preferred_pool_ids, {:array, :binary_id}, default: [])
    field(:residency_preference, Ecto.Enum, values: @residency_preferences)
    field(:max_cold_start_ms, :integer, default: 15_000)
    field(:max_queue_wait_ms, :integer, default: 3_000)
    field(:priority, :integer, default: 100)

    belongs_to(:tenant, Tenant)
    has_many(:model_access, TenantModelAccess)

    timestamps(type: :utc_datetime_usec)
  end

  @spec residency_preferences() :: [atom()]
  def residency_preferences, do: @residency_preferences

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :tenant_id,
      :name,
      :allowed_pool_ids,
      :preferred_pool_ids,
      :residency_preference,
      :max_cold_start_ms,
      :max_queue_wait_ms,
      :priority
    ])
    |> validate_required([
      :name,
      :allowed_pool_ids,
      :preferred_pool_ids,
      :residency_preference,
      :max_cold_start_ms,
      :max_queue_wait_ms,
      :priority
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1)
    |> validate_number(:max_cold_start_ms, greater_than_or_equal_to: 0)
    |> validate_number(:max_queue_wait_ms, greater_than_or_equal_to: 0)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_empty_pool_ids(:allowed_pool_ids)
    |> validate_empty_pool_ids(:preferred_pool_ids)
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint([:tenant_id, :name], name: :idx_routing_policies_tenant_name)
    |> unique_constraint(:name, name: :idx_routing_policies_global_name)
    |> check_constraint(:tenant_id, name: :routing_policies_tenant_immutable)
  end

  defp validate_empty_pool_ids(changeset, field) do
    case get_field(changeset, field) do
      [] ->
        changeset

      _ ->
        add_error(changeset, field, "must be empty until scheduler pool enforcement is available")
    end
  end
end
