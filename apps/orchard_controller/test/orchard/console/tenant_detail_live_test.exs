defmodule OrchardConsole.TenantDetailLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance

  @moduletag :live
  @moduletag :db

  setup do
    Sandbox.mode(Orchard.Repo, {:shared, self()})
    {:ok, tenant} = Governance.create_tenant(%{slug: "detail-t", name: "Detail Tenant"})
    %{tenant: tenant}
  end

  describe "page rendering" do
    test "renders tenant summary and key management UI", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, "/console/tenants/#{tenant.id}")

      # Initial title before connected mount sets slug-specific title
      assert html =~ "Orchard Console"
      assert html =~ "tenant-summary-card"
      assert html =~ "tenant-api-key-create-card"
      assert html =~ "tenant-api-keys-card"
      assert html =~ "Detail Tenant"
      assert html =~ "detail-t"
      assert html =~ tenant.id
      # Tenant Created timestamp uses LocalTime hook
      assert html =~ "tenant-detail-created-at"
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-local-time-format="datetime_minute")
    end

    test "shows not-found state for unknown tenant ID", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants/#{Ecto.UUID.generate()}")
      assert html =~ "Tenant not found"
      assert html =~ "tenant-back-to-list"
    end

    test "shows not-found state for malformed ID", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants/not-a-uuid")
      assert html =~ "Tenant not found"
    end

    test "shows empty API keys state", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, "/console/tenants/#{tenant.id}")
      assert html =~ "No API keys created yet."
      assert html =~ "tenant-api-keys-empty-state"
    end

    test "back link navigates to tenants list", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, "/console/tenants/#{tenant.id}")
      assert html =~ "/console/tenants"
      assert html =~ "Back to Tenants"
    end
  end

  describe "create API key" do
    test "creates key, shows secret card, and resets form", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html =
        view
        |> form("#tenant-api-key-create-form", api_key: %{name: "prod-key"})
        |> render_submit()

      # Flash and key in table
      assert html =~ "Created API key prod-key."
      assert html =~ "prod-key"

      # Secret card shown
      assert html =~ "tenant-api-key-secret-card"
      assert html =~ "API Key Created"
      assert html =~ "orch_"
      assert html =~ "only once"
      assert html =~ "Not yet copied"
    end

    test "API key row timestamps use LocalTime hook and nil last_used_at shows placeholder", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, %{api_key: key}} = Governance.create_api_key(tenant.id, %{name: "ts-test"})
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      key_row = view |> element("#api-key-#{key.id}") |> render()
      # Created column uses LocalTime
      assert key_row =~ ~s(phx-hook="LocalTime")
      assert key_row =~ ~s(data-local-time-format="datetime_minute")
      # Last Used is nil — should show placeholder without hook
      assert key_row =~ "—"
    end

    test "secret card is NOT shown on fresh page visit", %{conn: conn, tenant: tenant} do
      # Create key through governance directly
      {:ok, _} = Governance.create_api_key(tenant.id, %{name: "pre-existing"})
      {:ok, _view, html} = live(conn, "/console/tenants/#{tenant.id}")

      refute html =~ "tenant-api-key-secret-card"
      # But the key should be in the table
      assert html =~ "pre-existing"
    end

    test "shows validation error for blank name", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html =
        view
        |> form("#tenant-api-key-create-form", api_key: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  describe "dismiss secret" do
    test "dismiss hides secret card", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      # Create key to show secret card
      view
      |> form("#tenant-api-key-create-form", api_key: %{name: "dismiss-test"})
      |> render_submit()

      assert has_element?(view, "#tenant-api-key-secret-card")

      # Dismiss
      html = render_click(view, "dismiss_generated_secret")
      refute html =~ "tenant-api-key-secret-card"
    end
  end

  describe "revoke API key" do
    test "revokes key and updates table", %{conn: conn, tenant: tenant} do
      {:ok, %{api_key: key}} = Governance.create_api_key(tenant.id, %{name: "revoke-me"})
      {:ok, view, html} = live(conn, "/console/tenants/#{tenant.id}")

      assert html =~ "Active"
      assert has_element?(view, "#tenant-api-key-revoke-#{key.id}")

      html = render_click(view, "revoke_api_key", %{"id" => key.id})

      assert html =~ "Revoked API key revoke-me."
      assert html =~ "Revoked"
      refute has_element?(view, "#tenant-api-key-revoke-#{key.id}")
    end

    test "shows error for cross-tenant revoke attempt", %{conn: conn, tenant: tenant} do
      {:ok, other_tenant} = Governance.create_tenant(%{slug: "other-t", name: "Other"})
      {:ok, %{api_key: other_key}} = Governance.create_api_key(other_tenant.id, %{name: "k1"})

      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html = render_click(view, "revoke_api_key", %{"id" => other_key.id})
      assert html =~ "API key not found."
    end
  end

  describe "copy hook wiring" do
    test "copy button has hook and data attributes", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      view
      |> form("#tenant-api-key-create-form", api_key: %{name: "copy-test"})
      |> render_submit()

      assert has_element?(view, "#tenant-api-key-secret-copy")
      copy_html = view |> element("#tenant-api-key-secret-copy") |> render()
      assert copy_html =~ "phx-hook=\"CopyGeneratedSecret\""
      assert copy_html =~ "data-secret-source"
      assert copy_html =~ "data-api-key-id"
    end

    test "generated_secret_copied event updates status", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      view
      |> form("#tenant-api-key-create-form", api_key: %{name: "copy-event-test"})
      |> render_submit()

      # Extract the api_key_id from the secret card
      secret_html = view |> element("#tenant-api-key-secret-copy") |> render()
      [_, api_key_id] = Regex.run(~r/data-api-key-id="([^"]+)"/, secret_html)

      html = render_click(view, "generated_secret_copied", %{"api_key_id" => api_key_id})
      assert html =~ "Copied to clipboard"
    end

    test "generated_secret_copy_failed event updates status", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      view
      |> form("#tenant-api-key-create-form", api_key: %{name: "fail-event-test"})
      |> render_submit()

      secret_html = view |> element("#tenant-api-key-secret-copy") |> render()
      [_, api_key_id] = Regex.run(~r/data-api-key-id="([^"]+)"/, secret_html)

      html = render_click(view, "generated_secret_copy_failed", %{"api_key_id" => api_key_id})
      assert html =~ "Copy failed"
    end
  end
end
