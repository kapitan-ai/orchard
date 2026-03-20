defmodule Orchard.Governance do
  @moduledoc """
  Governance constants shared across the controller's current M1 compatibility
  path and the future M2 governance surface.
  """

  @legacy_tenant_id "00000000-0000-0000-0000-000000000000"
  @legacy_tenant_slug "legacy"
  @legacy_tenant_name "Legacy Single Tenant"

  @spec legacy_tenant_id() :: Ecto.UUID.t()
  def legacy_tenant_id, do: @legacy_tenant_id

  @spec legacy_tenant_slug() :: String.t()
  def legacy_tenant_slug, do: @legacy_tenant_slug

  @spec legacy_tenant_name() :: String.t()
  def legacy_tenant_name, do: @legacy_tenant_name
end
