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
      assert html =~ "Workspaces"
      assert html =~ "Orchard Console"
      assert html =~ "A Workspace is the scope for model access"
      refute html =~ "tenant-create-card"
      assert html =~ "tenants-list-card"
    end

    test "Workspaces sidebar item is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ ~s(aria-current="page")
      assert html =~ "/console/access"
      assert html =~ "Workspaces"
    end

    test "shows legacy Workspace in the list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ Governance.legacy_tenant_slug()
      assert html =~ "Default workspace"
    end

    test "renders create Workspace form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/access/workspaces/new")
      assert html =~ "tenant-create-form"
      assert html =~ "Slug"
      assert html =~ "Name"
      assert html =~ "Create Workspace"
      assert html =~ "does not grant model access"
      assert html =~ "issue an API credential"
    end
  end

  describe "create tenant" do
    test "creates tenant and resets form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/access/workspaces/new")

      view
      |> form("#tenant-create-form", tenant: %{slug: "new-tenant", name: "New Tenant"})
      |> render_submit()

      {path, _flash} = assert_redirect(view)
      assert "/console/access/workspaces/" <> id = path
      assert {:ok, tenant} = Governance.get_tenant(id)
      assert tenant.slug == "new-tenant"
    end

    test "shows validation error for blank slug", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/access/workspaces/new")

      html =
        view
        |> form("#tenant-create-form", tenant: %{slug: "", name: "No Slug"})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "shows validation error for duplicate slug", %{conn: conn} do
      {:ok, _} = Governance.create_tenant(%{slug: "dupe-slug", name: "Original"})
      {:ok, view, _html} = live(conn, "/console/access/workspaces/new")

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
      assert has_element?(view, "#tenant-open-#{tenant.id}", "Open workspace")
      html = render(view)
      assert html =~ "/console/access/workspaces/#{tenant.id}"
    end

    test "repeated Access reads preserve a customized default identity and list it first", %{
      conn: conn
    } do
      {:ok, default} = Governance.get_tenant(Governance.legacy_tenant_id())
      custom = default |> Ecto.Changeset.change(name: "Zebra research") |> Orchard.Repo.update!()
      {:ok, other} = Governance.create_tenant(%{slug: "alpha", name: "Alpha research"})
      count = Orchard.Repo.aggregate(Orchard.Governance.Tenant, :count)

      for path <- ["/console/access", "/console/access/workspaces", "/console/tenants"] do
        {:ok, view, _html} = live(conn, path)
        render_click(view, "refresh_workspaces")

        assert has_element?(
                 view,
                 "#tenants-table > tr:first-child#tenant-#{custom.id}",
                 "Zebra research"
               )

        assert has_element?(view, "#tenant-#{other.id}", "Alpha research")
        refute has_element?(view, "#tenant-#{custom.id}", "Default workspace")
        assert {:ok, stored} = Governance.get_tenant(custom.id)

        assert {stored.id, stored.slug, stored.name} ==
                 {default.id, default.slug, "Zebra research"}

        assert Orchard.Repo.aggregate(Orchard.Governance.Tenant, :count) == count
      end
    end

    test "default-only Access handoff opens the existing scope at step two without side effects",
         %{conn: conn} do
      assert [default] = Governance.list_tenants()
      assert default.id == Governance.legacy_tenant_id()

      schemas = [
        Orchard.Governance.Tenant,
        Orchard.Governance.PortalUser,
        Orchard.Governance.ApiKey,
        Orchard.Models.TenantModelAccess
      ]

      before_counts = Enum.map(schemas, &Orchard.Repo.aggregate(&1, :count))
      {:ok, view, _html} = live(conn, "/console/access")
      handoff = "/console/access/workspaces/#{default.id}/handoff"
      assert has_element?(view, "#tenant-#{default.id} a[href='#{handoff}']", "Guide access")

      {:ok, handoff_view, _html} =
        view
        |> element("#tenant-#{default.id} a[href='#{handoff}']")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(handoff_view, "#handoff-scope", "Default workspace")
      assert has_element?(handoff_view, "#handoff-step-2")
      refute has_element?(handoff_view, "#handoff-step-1")
      assert Enum.map(schemas, &Orchard.Repo.aggregate(&1, :count)) == before_counts
      assert {:ok, stored} = Governance.get_tenant(default.id)
      assert {stored.id, stored.slug, stored.name} == {default.id, default.slug, default.name}
    end

    test "shows empty state when only legacy tenant is removed", %{conn: conn} do
      delete_audit_logs!()
      Orchard.Repo.delete_all(Orchard.Governance.ApiKey)
      Orchard.Repo.delete_all(Orchard.Governance.RoleBinding)
      Orchard.Repo.delete_all(Orchard.Governance.ProvisioningBatch)
      Orchard.Repo.delete_all(Orchard.Governance.ServiceAccount)
      Orchard.Repo.delete_all(Orchard.Governance.Tenant)
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ "No Workspaces created yet."
      assert html =~ "workspace-default-missing"
      assert html =~ "Refresh Workspaces"
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
