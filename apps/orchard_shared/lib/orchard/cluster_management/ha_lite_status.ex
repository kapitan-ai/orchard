defmodule Orchard.ClusterManagement.HALiteStatus do
  @moduledoc """
  Read-only HA-lite control-plane status contract.

  `advisory_lock_status` is evidence about the controller advisory lock.
  A local controller may report `controller_role` as `leader` only when the lock is `held` and `leader_identity` is absent or matches `this_controller_identity`.
  When lock evidence is missing, unavailable, not held, or names a different leader, operator surfaces must present local leadership as `unknown`.
  """

  @object "cluster_management.ha_lite_status"
  @contract_version "orchard.cluster_management.ha_lite_status.v1"

  @deployment_modes ~w(single_controller ha_lite unknown)
  @controller_roles ~w(leader standby single_controller unknown)
  @lock_statuses ~w(held not_held unavailable unknown)

  alias Orchard.ClusterManagement.Value

  defstruct object: @object,
            contract_version: @contract_version,
            deployment_mode: "unknown",
            this_controller_identity: nil,
            controller_role: "unknown",
            leader_identity: nil,
            advisory_lock_status: "unknown",
            lock_age_ms: nil,
            last_renewed_at: nil,
            standby_write_path_behavior: "unknown",
            last_observed_leadership_error: nil

  @type t :: %__MODULE__{}

  @spec object() :: String.t()
  def object, do: @object

  @spec contract_version() :: String.t()
  def contract_version, do: @contract_version

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with {:ok, deployment_mode} <-
           status_value(attrs, :deployment_mode, @deployment_modes, "unknown"),
         {:ok, controller_role} <-
           status_value(attrs, :controller_role, @controller_roles, "unknown"),
         {:ok, advisory_lock_status} <-
           status_value(attrs, :advisory_lock_status, @lock_statuses, "unknown") do
      {:ok,
       %__MODULE__{
         deployment_mode: deployment_mode,
         this_controller_identity:
           Value.normalize_string(value(attrs, :this_controller_identity)),
         controller_role: controller_role,
         leader_identity: Value.normalize_string(value(attrs, :leader_identity)),
         advisory_lock_status: advisory_lock_status,
         lock_age_ms: lock_age_ms(value(attrs, :lock_age_ms)),
         last_renewed_at: value(attrs, :last_renewed_at),
         standby_write_path_behavior:
           Value.normalize_string(value(attrs, :standby_write_path_behavior)) || "unknown",
         last_observed_leadership_error:
           Value.normalize_string(value(attrs, :last_observed_leadership_error))
       }}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, status} -> status
      {:error, reason} -> raise ArgumentError, "invalid HA-lite status: #{inspect(reason)}"
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = status) do
    %{
      object: status.object,
      contract_version: status.contract_version,
      deployment_mode: status.deployment_mode,
      this_controller_identity: status.this_controller_identity,
      controller_role: status.controller_role,
      leader_identity: status.leader_identity,
      advisory_lock_status: status.advisory_lock_status,
      lock_age_ms: status.lock_age_ms,
      last_renewed_at: Value.json_value(status.last_renewed_at),
      standby_write_path_behavior: status.standby_write_path_behavior,
      last_observed_leadership_error: status.last_observed_leadership_error
    }
  end

  defp status_value(attrs, key, allowed_values, default) do
    value = Value.normalize_string(value(attrs, key)) || default

    if value in allowed_values do
      {:ok, value}
    else
      {:error, {:unknown_status, key, value}}
    end
  end

  defp lock_age_ms(value) when is_integer(value) and value >= 0, do: value
  defp lock_age_ms(_value), do: nil

  defp value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end
