defmodule OrchardConsole.TenantsLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Orchard.TestSupport.LicenseGateHelpers

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
      assert html =~ "Tenants \u2014 Orchard Console"
      assert html =~ "tenant-create-card"
      assert html =~ "tenants-list-card"
    end

    test "Tenants sidebar item is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      # Tenants link should have aria-current="page"
      assert html =~ ~s(aria-current="page")
      assert html =~ "/console/tenants"
    end

    test "shows legacy tenant in the list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ Governance.legacy_tenant_slug()
      assert html =~ Governance.legacy_tenant_name()
    end

    test "renders create tenant form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ "tenant-create-form"
      assert html =~ "Slug"
      assert html =~ "Name"
      assert html =~ "Create Tenant"
    end
  end

  describe "create tenant" do
    test "hard mode denies tenant creation", %{conn: conn} do
      set_license_enforcement(:hard)
      {:ok, view, _html} = live(conn, "/console/tenants")

      html =
        view
        |> form("#tenant-create-form", tenant: %{slug: "blocked-tenant", name: "Blocked"})
        |> render_submit()

      assert_license_denial(html)
      assert has_element?(view, "#tenant-create-card")
      refute Enum.any?(Governance.list_tenants(), &(&1.slug == "blocked-tenant"))
    end

    test "warn mode permits tenant creation", %{conn: conn} do
      set_license_enforcement(:warn)
      {:ok, view, _html} = live(conn, "/console/tenants")

      view
      |> form("#tenant-create-form", tenant: %{slug: "warn-tenant", name: "Warn Tenant"})
      |> render_submit()

      assert Enum.any?(Governance.list_tenants(), &(&1.slug == "warn-tenant"))
    end

    test "creates tenant and resets form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/tenants")

      html =
        view
        |> form("#tenant-create-form", tenant: %{slug: "new-tenant", name: "New Tenant"})
        |> render_submit()

      assert html =~ "Created tenant new-tenant."
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
      # Delete all tenants for clean empty state
      Orchard.Repo.delete_all(Orchard.Governance.Tenant)
      {:ok, _view, html} = live(conn, "/console/tenants")
      assert html =~ "No tenants created yet."
    end
  end
end
