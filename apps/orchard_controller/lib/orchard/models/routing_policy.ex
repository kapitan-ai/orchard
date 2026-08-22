defmodule Orchard.Models.RoutingPolicy do
  @moduledoc """
  Persisted Tenant-scoped or global routing policy.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Orchard.Governance.Tenant
  alias Orchard.Inference
  alias Orchard.Inference.AdmissionPolicy
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
    |> validate_effective_deadline()
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

  defp validate_effective_deadline(changeset) do
    residency_preference = get_field(changeset, :residency_preference)
    max_cold_start_ms = get_field(changeset, :max_cold_start_ms)
    max_queue_wait_ms = get_field(changeset, :max_queue_wait_ms)

    if changeset.valid? and
         residency_preference in @residency_preferences and
         is_integer(max_cold_start_ms) and max_cold_start_ms >= 0 and
         is_integer(max_queue_wait_ms) and max_queue_wait_ms >= 0 do
      generation_timeout_ms = Inference.request_timeout_ms() || 30_000

      effective_timeout_ms =
        AdmissionPolicy.effective_timeout_ms(
          generation_timeout_ms,
          max_queue_wait_ms,
          max_cold_start_ms,
          residency_preference
        )

      ceiling = Inference.max_request_deadline_ms()

      if effective_timeout_ms > ceiling do
        add_error(
          changeset,
          :max_cold_start_ms,
          "effective request deadline #{effective_timeout_ms} ms exceeds deployment ceiling #{ceiling} ms"
        )
      else
        changeset
      end
    else
      changeset
    end
  end
end
