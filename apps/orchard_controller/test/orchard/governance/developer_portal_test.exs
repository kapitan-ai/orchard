defmodule Orchard.Governance.DeveloperPortalTest do
  use Orchard.DataCase, async: false

  import Ecto.Query

  alias Orchard.Governance
  alias Orchard.Governance.{AuditLog, PortalPassword, Tenant}

  @password "sixteen-chars-ok"
  @rotated "sixteen-chars-two"

  setup do
    previous_mode = Application.get_env(:orchard_controller, :transport_mode, :__missing__)
    Application.put_env(:orchard_controller, :transport_mode, :direct_https)

    on_exit(fn ->
      case previous_mode do
        :__missing__ -> Application.delete_env(:orchard_controller, :transport_mode)
        mode -> Application.put_env(:orchard_controller, :transport_mode, mode)
      end
    end)

    :ok
  end

  test "set stores only an Argon2id hash, opens the portal, and writes a redacted audit row" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-set", name: "Portal Set"})

    assert {:ok, returned} = Governance.set_tenant_portal_password(tenant, @password)
    persisted = Repo.get!(Tenant, tenant.id)
    audit = tenant_audit_log!(tenant.id, "tenant.portal_password_set")

    assert returned.portal_password_hash == nil
    assert returned.portal_session_epoch == 1
    assert PortalPassword.verify(@password, persisted.portal_password_hash) == :ok
    refute persisted.portal_password_hash == @password
    assert persisted.portal_session_epoch == 1

    assert audit.actor_type == "operator"
    assert audit.payload["portal_enabled"] == true
    assert audit.payload["portal_session_epoch"] == 1
    assert audit.payload["surface"] == "console"
    refute Map.has_key?(audit.payload, "portal_password_hash")
    refute inspect(audit.payload) =~ @password
    refute inspect(audit.payload) =~ persisted.portal_password_hash
  end

  test "rotate increments epoch, replaces the hash, and does not revoke keys" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-rotate", name: "Portal Rotate"})
    {:ok, %{api_key: api_key}} = Governance.create_api_key(tenant.id, %{name: "keep"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    assert {:ok, returned} = Governance.set_tenant_portal_password(tenant, @rotated)
    persisted = Repo.get!(Tenant, tenant.id)
    audit = tenant_audit_log!(tenant.id, "tenant.portal_password_rotated")
    kept = Repo.get!(Orchard.Governance.ApiKey, api_key.id)

    assert returned.portal_session_epoch == 2
    assert persisted.portal_session_epoch == 2
    assert PortalPassword.verify(@rotated, persisted.portal_password_hash) == :ok

    assert PortalPassword.verify(@password, persisted.portal_password_hash) ==
             {:error, :invalid_password}

    assert kept.revoked_at == nil
    assert audit.payload["portal_session_epoch"] == 2
  end

  test "clear nulls the hash, increments epoch, and closes the portal" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-clear", name: "Portal Clear"})
    assert {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    assert {:ok, returned} = Governance.clear_tenant_portal_password(tenant)
    persisted = Repo.get!(Tenant, tenant.id)
    audit = tenant_audit_log!(tenant.id, "tenant.portal_password_cleared")

    assert returned.portal_password_hash == nil
    assert returned.portal_session_epoch == 2
    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 2
    assert audit.payload["portal_enabled"] == false
  end

  test "existing tenants migrate closed with epoch 0" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-closed", name: "Portal Closed"})
    persisted = Repo.get!(Tenant, tenant.id)

    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 0
  end

  test "ordinary tenant changeset ignores portal password fields" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-smuggle", name: "Portal Smuggle"})

    changeset =
      Tenant.changeset(tenant, %{
        name: "Renamed",
        portal_password_hash: "not-a-hash",
        portal_session_epoch: 99
      })

    assert {:ok, updated} = Repo.update(changeset)
    persisted = Repo.get!(Tenant, tenant.id)

    assert updated.name == "Renamed"
    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 0
  end

  test "set rejects short passwords before hashing" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-short", name: "Portal Short"})

    assert {:error, :password_too_short} =
             Governance.set_tenant_portal_password(tenant, "short-password")

    persisted = Repo.get!(Tenant, tenant.id)
    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 0
  end

  test "set and clear reject degraded transport" do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-http", name: "Portal HTTP"})
    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)

    assert {:error, :https_required} =
             Governance.set_tenant_portal_password(tenant, @password)

    assert {:error, :https_required} = Governance.clear_tenant_portal_password(tenant)
    persisted = Repo.get!(Tenant, tenant.id)
    assert persisted.portal_password_hash == nil
    assert persisted.portal_session_epoch == 0
  end

  defp tenant_audit_log!(tenant_id, action) do
    Repo.one!(
      from(audit_log in AuditLog,
        where:
          audit_log.tenant_id == ^tenant_id and audit_log.target_type == "tenant" and
            audit_log.target_id == ^tenant_id and audit_log.action == ^action
      )
    )
  end
end
