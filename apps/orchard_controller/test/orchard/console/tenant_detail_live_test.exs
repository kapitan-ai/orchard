defmodule OrchardConsole.TenantDetailLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Orchard.TestSupport.LicenseGateHelpers

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
      assert html =~ "tenant-api-clients-card"
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
      assert html =~ "Organization not found"
      assert html =~ "tenant-back-to-list"
    end

    test "shows not-found state for malformed ID", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/tenants/not-a-uuid")
      assert html =~ "Organization not found"
    end

    test "shows empty API keys state", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, "/console/tenants/#{tenant.id}")
      assert html =~ "No API Tokens created yet."
      assert html =~ "tenant-api-keys-empty-state"
    end

    test "shows empty API Clients state", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, "/console/tenants/#{tenant.id}")
      assert html =~ "No API Clients provisioned yet."
      assert html =~ "tenant-api-clients-empty-state"
    end

    test "back link navigates to tenants list", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, "/console/tenants/#{tenant.id}")
      assert html =~ "/console/tenants"
      assert html =~ "Back to Organizations"
    end
  end

  describe "create API key" do
    test "hard mode denies API key creation without issuing a secret", %{
      conn: conn,
      tenant: tenant
    } do
      set_license_enforcement(:hard)
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html =
        view
        |> form("#tenant-api-key-create-form", api_key: %{name: "blocked-key"})
        |> render_submit()

      assert_license_denial(html)
      assert has_element?(view, "#tenant-api-key-create-card")
      refute html =~ "tenant-api-key-secret-card"
      assert {:ok, []} = Governance.list_api_keys_for_tenant(tenant)
    end

    test "warn mode permits API key creation", %{conn: conn, tenant: tenant} do
      set_license_enforcement(:warn)
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      view
      |> form("#tenant-api-key-create-form", api_key: %{name: "warn-key"})
      |> render_submit()

      assert {:ok, [api_key]} = Governance.list_api_keys_for_tenant(tenant)
      assert api_key.name == "warn-key"
    end

    test "creates key, shows secret card, and resets form", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html =
        view
        |> form("#tenant-api-key-create-form", api_key: %{name: "prod-key"})
        |> render_submit()

      # Flash and key in table
      assert html =~ "Created API Token prod-key."
      assert html =~ "prod-key"

      # Secret card shown
      assert html =~ "tenant-api-key-secret-card"
      assert html =~ "API Token Created"
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

      assert html =~ "Revoked API Token revoke-me."
      assert html =~ "Revoked"
      refute has_element?(view, "#tenant-api-key-revoke-#{key.id}")
    end

    test "shows error for cross-tenant revoke attempt", %{conn: conn, tenant: tenant} do
      {:ok, other_tenant} = Governance.create_tenant(%{slug: "other-t", name: "Other"})
      {:ok, %{api_key: other_key}} = Governance.create_api_key(other_tenant.id, %{name: "k1"})

      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html = render_click(view, "revoke_api_key", %{"id" => other_key.id})
      assert html =~ "API Token not found."
    end
  end

  describe "API Clients" do
    test "renders API Clients, access levels, and owned API Tokens without plaintext secrets", %{
      conn: conn,
      tenant: tenant
    } do
      %{api_client: api_client, api_key: api_key, token: token} =
        create_api_client_with_token!(tenant, "console-client")

      :ok = Governance.touch_api_key_last_used(api_key.id)

      {:ok, view, html} = live(conn, "/console/tenants/#{tenant.id}")

      assert html =~ "console-client"
      assert html =~ "owner@example.com"
      assert html =~ "Inference Client"
      assert html =~ api_key.token_prefix
      refute html =~ token

      token_html = view |> element("#api-client-token-#{api_key.id}") |> render()
      assert token_html =~ "Created"
      assert token_html =~ "Last Used"
      assert token_html =~ "api-client-token-created-at-#{api_key.id}"
      assert token_html =~ "api-client-token-last-used-at-#{api_key.id}"
      assert token_html =~ ~s(data-local-time-format="datetime_minute")

      assert has_element?(view, "#tenant-api-client-disable-#{api_client.id}")
      assert has_element?(view, "#tenant-api-client-token-revoke-#{api_key.id}")
    end

    test "revokes API Client-owned API Tokens from the Organization detail page", %{
      conn: conn,
      tenant: tenant
    } do
      %{api_key: api_key} = create_api_client_with_token!(tenant, "console-client-revoke")
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html = render_click(view, "revoke_api_key", %{"id" => api_key.id})

      assert html =~ "Revoked API Token prod."
      assert html =~ "Revoked"
      refute has_element?(view, "#tenant-api-client-token-revoke-#{api_key.id}")
    end

    test "revokes expired API Client-owned API Tokens from the Organization detail page", %{
      conn: conn,
      tenant: tenant
    } do
      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      %{api_key: api_key} =
        create_api_client_with_token!(tenant, "console-client-expired-revoke", %{
          expires_at: expired_at
        })

      {:ok, view, html} = live(conn, "/console/tenants/#{tenant.id}")

      assert html =~ "Expired"
      assert has_element?(view, "#tenant-api-client-token-revoke-#{api_key.id}")

      html = render_click(view, "revoke_api_key", %{"id" => api_key.id})

      assert html =~ "Revoked API Token prod."
      assert html =~ "Revoked"
      refute has_element?(view, "#tenant-api-client-token-revoke-#{api_key.id}")
    end

    test "disables API Clients from the Organization detail page", %{
      conn: conn,
      tenant: tenant
    } do
      %{api_client: api_client} = create_api_client_with_token!(tenant, "console-client-disable")
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html = render_click(view, "disable_api_client", %{"id" => api_client.id})

      assert html =~ "Disabled API Client console-client-disable."
      assert html =~ "Disabled"
      refute has_element?(view, "#tenant-api-client-disable-#{api_client.id}")
    end

    test "shows error for cross-Organization API Client disable attempt", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, other_tenant} = Governance.create_tenant(%{slug: "other-client-t", name: "Other"})
      %{api_client: other_client} = create_api_client_with_token!(other_tenant, "other-client")

      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html = render_click(view, "disable_api_client", %{"id" => other_client.id})
      assert html =~ "API Client not found."
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

      # Use the rendered ID so the event matches the copy hook payload.
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

  defp create_api_client_with_token!(tenant, name, token_attrs \\ %{}) do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: name,
        owner_contact: "owner@example.com",
        team: "Inference"
      })

    {:ok, _role_binding} = Governance.ensure_inference_client_access(api_client, tenant)

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_client_api_token(api_client, Map.merge(%{name: "prod"}, token_attrs))

    %{api_client: api_client, api_key: api_key, token: token}
  end
end
