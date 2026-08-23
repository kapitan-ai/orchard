defmodule OrchardConsole.TenantsLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance

  @moduletag :live
  @moduletag :db

  setup do
    Sandbox.mode(Orchard.Repo, {:shared, self()})
    :ok
  end

  describe "page rendering" do
    test "renders page title and nav", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ "Organizations"
      assert html =~ "Orchard Console"
      assert html =~ "tenant-create-card"
      assert html =~ "tenants-list-card"
    end

    test "Organizations sidebar item is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ ~s(aria-current="page")
      assert html =~ "/console/tenants"
      assert html =~ "Organizations"
    end

    test "shows legacy Organization in the list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ Governance.legacy_tenant_slug()
      assert html =~ Governance.legacy_tenant_name()
    end

    test "renders create Organization form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ "tenant-create-form"
      assert html =~ "Slug"
      assert html =~ "Name"
      assert html =~ "Create Organization"
    end
  end

  describe "create tenant" do
    test "creates tenant and resets form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/tenants")

      html =
        view
        |> form("#tenant-create-form", tenant: %{slug: "new-tenant", name: "New Tenant"})
        |> render_submit()

      assert html =~ "Created Organization new-tenant."
      assert html =~ "new-tenant"
      assert html =~ "New Tenant"
      # Created column uses LocalTime hook
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-local-time-format="datetime_minute")
    end

    test "shows validation error for blank slug", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/tenants")

      html =
        view
        |> form("#tenant-create-form", tenant: %{slug: "", name: "No Slug"})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "shows validation error for duplicate slug", %{conn: conn} do
      {:ok, _} = Governance.create_tenant(%{slug: "dupe-slug", name: "Original"})
      {:ok, view, _html} = live(conn, "/console/tenants")

      html =
        view
        |> form("#tenant-create-form", tenant: %{slug: "dupe-slug", name: "Duplicate"})
        |> render_submit()

      assert html =~ "has already been taken"
    end
  end

  describe "tenant list" do
    test "Open link navigates to tenant detail", %{conn: conn} do
      {:ok, tenant} = Governance.create_tenant(%{slug: "detail-test", name: "Detail Test"})
      {:ok, view, _html} = live(conn, "/console/tenants")

      assert has_element?(view, "#tenant-open-#{tenant.id}")
      html = render(view)
      assert html =~ "/console/tenants/#{tenant.id}"
    end

    test "shows empty state when only legacy tenant is removed", %{conn: conn} do
      delete_audit_logs!()
      Orchard.Repo.delete_all(Orchard.Governance.ApiKey)
      Orchard.Repo.delete_all(Orchard.Governance.RoleBinding)
      Orchard.Repo.delete_all(Orchard.Governance.ProvisioningBatch)
      Orchard.Repo.delete_all(Orchard.Governance.ServiceAccount)
      Orchard.Repo.delete_all(Orchard.Governance.Tenant)
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ "No Organizations created yet."
    end
  end

  defp delete_audit_logs! do
    Orchard.Repo.query!("ALTER TABLE audit_logs DISABLE TRIGGER audit_logs_append_only")

    try do
      Orchard.Repo.delete_all(Orchard.Governance.AuditLog)
    after
      Orchard.Repo.query!("ALTER TABLE audit_logs ENABLE TRIGGER audit_logs_append_only")
    end
  end
end
