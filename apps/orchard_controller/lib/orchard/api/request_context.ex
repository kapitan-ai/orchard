defmodule Orchard.API.RequestContext do
  @moduledoc """
  Plug that attaches caller-context fields to the connection.

  Provides a single integration point for M2 auth/RBAC to slot into.
  In M1, runs in implicit single-tenant mode with hardcoded defaults:

    * `tenant_id` — `"default"`
    * `principal_id` — `nil`
    * `api_key_id` — `nil`

  M2 will replace the body of `call/2` with real auth resolution:
  extract `Authorization: Bearer <api_key>`, look up the key, resolve
  tenant/principal, and return 401/403 on failure.

  ## Usage

  Add to a router pipeline:

      pipeline :authenticated_api do
        plug Orchard.API.RequestContext
      end

  Downstream controllers read context via `conn.assigns`:

      conn.assigns.tenant_id
      conn.assigns.principal_id
      conn.assigns.api_key_id

  Note: `principal_id` is transient — used for in-flight RBAC checks
  but not persisted on the `requests` table. The durable identity
  fields are `api_key_id` and `service_account_id` (resolved from
  the API key in M2). `principal_id` maps to the owning entity
  (tenant or service account) for authorization decisions.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  # M1 sentinel UUID for single-tenant mode. Not a real tenant row — M2
  # will create a tenants table and resolve real UUIDs from Bearer tokens.
  @m1_default_tenant "00000000-0000-0000-0000-000000000000"

  @impl Plug
  def call(conn, _opts) do
    # M1: implicit single-tenant mode — no auth required.
    # M2 will replace this with real Bearer token resolution.
    conn
    |> Plug.Conn.assign(:tenant_id, @m1_default_tenant)
    |> Plug.Conn.assign(:principal_id, nil)
    |> Plug.Conn.assign(:api_key_id, nil)
  end
end
