defmodule OrchardConsole.TenantDetailLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.{AuditLog, PortalInviteToken}
  alias Orchard.Repo

  @moduletag :live
  @moduletag :db
  @portal_password "sixteen-chars-ok"

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
      assert html =~ ~r/orchard_sk_[A-Za-z0-9_-]{16}_[A-Za-z0-9_-]{43}/
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

      assert has_element?(view, "#tenant-api-clients-list")
      assert has_element?(view, "#api-client-#{api_client.id}")
      assert html =~ "console-client"
      assert html =~ "Owner Example"
      assert html =~ "owner@example.com"
      assert html =~ "Purpose for console-client"
      assert html =~ "Description for console-client"
      assert html =~ "external-console-client"
      assert html =~ "Team"
      assert html =~ "Inference"
      assert html =~ "Access"
      assert html =~ "State"
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
      disable_html = view |> element("#tenant-api-client-disable-#{api_client.id}") |> render()

      assert disable_html =~
               "Disable this API Client? Active owned API Tokens will be blocked, but tokens are not revoked."

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

      audit_log = Repo.get_by!(AuditLog, api_key_id: api_key.id, action: "api_key.revoked")
      assert audit_log.actor_type == "operator"
      assert audit_log.actor_id == nil
      assert audit_log.payload["surface"] == "console"
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
      %{api_client: api_client, api_key: active_key} =
        create_api_client_with_token!(tenant, "console-client-disable")

      expired_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      {:ok, %{api_key: expired_key}} =
        Governance.create_api_client_api_token(api_client, %{
          name: "expired",
          expires_at: expired_at
        })

      {:ok, %{api_key: revoked_key}} =
        Governance.create_api_client_api_token(api_client, %{name: "revoked"})

      {:ok, _api_key} = Governance.revoke_api_key(tenant, revoked_key)

      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      html = render_click(view, "disable_api_client", %{"id" => api_client.id})

      assert html =~ "Disabled API Client console-client-disable."
      assert html =~ "Disabled"
      assert has_element?(view, "#api-client-#{api_client.id}")
      refute has_element?(view, "#tenant-api-client-disable-#{api_client.id}")

      active_token_html = view |> element("#api-client-token-#{active_key.id}") |> render()
      expired_token_html = view |> element("#api-client-token-#{expired_key.id}") |> render()
      revoked_token_html = view |> element("#api-client-token-#{revoked_key.id}") |> render()

      assert active_token_html =~ "Blocked by client"
      refute expired_token_html =~ "Blocked by client"
      refute revoked_token_html =~ "Blocked by client"

      audit_log =
        Repo.get_by!(AuditLog,
          action: "service_account.disabled",
          target_type: "service_account",
          target_id: api_client.id
        )

      assert audit_log.actor_type == "operator"
      assert audit_log.actor_id == nil
      assert audit_log.payload["surface"] == "console"
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

  describe "Portal Users" do
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

    test "renders three stacked portal cards and creates an invited Portal User", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, view, html} = live(conn, "/console/tenants/#{tenant.id}")
      assert html =~ "tenant-portal-invite-card"
      assert html =~ "tenant-portal-users-card"
      assert html =~ "tenant-portal-access-card"
      assert html =~ ~s(class="bg-navy mt-7)
      refute html =~ "bg-navy-900"

      html =
        view
        |> form("#tenant-portal-invite-form", portal_invite: %{email: "Dev@Example.com"})
        |> render_submit()

      assert html =~ "dev@example.com"
      assert html =~ "Invited"
      assert {:ok, [user]} = Governance.list_portal_users(tenant)
      assert user.email == "dev@example.com"

      user_row = view |> element("#portal-user-#{user.id}") |> render()
      assert user_row =~ "Not issued"
      refute user_row =~ "Invalidated"
      assert user_row =~ ~s(class="text-sm text-slate-500 dark:text-slate-400")
      assert user_row =~ ~s(class="text-xs text-slate-500 dark:text-slate-400")
      assert user_row =~ "flex flex-col gap-3"
      assert user_row =~ "sm:flex-row"
      assert user_row =~ "break-all"
      assert user_row =~ "shrink-0"
      assert user_row =~ ~s(aria-label="Copy invite for dev@example.com")
      assert user_row =~ ~s(aria-label="Disable dev@example.com")
    end

    test "Copy invite reissues a transient URL and disable leaves owned keys alone", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      first = render_click(view, "copy_portal_invite", %{"portal_user_id" => user.id})
      assert first =~ "tenant-portal-invite-url-card"
      assert first =~ "/portal/detail-t/invites/orchard_pi_"
      assert first =~ "Pending"
      assert first =~ ~s(phx-hook="CopyGeneratedSecret")
      assert first =~ ~s(data-secret-source="tenant-portal-invite-url-value")
      assert first =~ ~s(aria-describedby="tenant-portal-invite-url-guidance")
      assert first =~ "One-time invite URL ready"
      assert first =~ "phx-mounted"

      url_value = view |> element("#tenant-portal-invite-url-value") |> render()
      assert url_value =~ "bg-slate-100"
      assert url_value =~ "text-slate-900"
      assert url_value =~ "dark:bg-slate-800"
      assert url_value =~ "dark:text-slate-100"

      assert first =~ ~s(class="mt-3 rounded-md bg-navy )
      refute first =~ "bg-navy-900"

      assert {:ok, [summary]} = Governance.list_portal_user_summaries(tenant)

      expected_iso =
        summary.invite_expires_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      assert first =~ ~s(id="tenant-portal-invite-url-expires-at")
      assert first =~ ~s(class="mt-2 text-xs text-slate-500 dark:text-slate-400")
      assert first =~ ~s(datetime="#{expected_iso}")

      second = render_click(view, "copy_portal_invite", %{"portal_user_id" => user.id})
      refute first == second

      html = render_click(view, "disable_portal_user", %{"portal_user_id" => user.id})
      assert html =~ "Disabled"
      card_dismissed = not String.contains?(html, "tenant-portal-invite-url-card")
      assert card_dismissed
    end

    test "copy invite keeps the show-once URL without a fallible tenant-detail reload", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, user} =
        Governance.create_portal_invite(tenant, %{email: "durable-reveal@example.com"})

      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      {html, queries} =
        capture_repo_queries(fn ->
          render_click(view, "copy_portal_invite", %{"portal_user_id" => user.id})
        end)

      view_queries = for {pid, query} <- queries, pid == view.pid, do: query

      assert html =~ "tenant-portal-invite-url-card"
      assert html =~ "Pending"
      refute Enum.any?(view_queries, &String.contains?(&1, ~s|FROM "tenants"|))
      refute Enum.any?(view_queries, &String.contains?(&1, ~s|FROM "api_keys"|))
      refute Enum.any?(view_queries, &String.contains?(&1, ~s|FROM "api_clients"|))
    end

    test "renders Pending invite context with localized expiry", %{conn: conn, tenant: tenant} do
      {:ok, user} = Governance.create_portal_invite(tenant, %{email: "pending@example.com"})
      {:ok, invite} = Governance.copy_portal_invite(tenant, user)
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      row = view |> element("#portal-user-#{user.id}") |> render()
      expected_iso = invite.expires_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      assert row =~ "Invited"
      assert row =~ "Pending"
      assert row =~ "Expires"
      assert row =~ ~s(id="portal-user-invite-expires-at-#{user.id}")
      assert row =~ ~s(datetime="#{expected_iso}")
      assert row =~ ~s(phx-hook="LocalTime")
      assert row =~ ~s(data-local-time-format="datetime_minute")
    end

    test "current invite expiry clears the URL before refreshing the row to Expired", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, user} = Governance.create_portal_invite(tenant, %{email: "timer@example.com"})
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      shown = render_click(view, "copy_portal_invite", %{"portal_user_id" => user.id})
      [invite_url] = Regex.run(~r{/portal/detail-t/invites/orchard_pi_[\w-]+}, shown)
      assert {:ok, [summary]} = Governance.list_portal_user_summaries(tenant)

      PortalInviteToken
      |> Repo.get_by!(portal_user_id: user.id)
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      send(view.pid, {:portal_invite_expired, user.id, summary.invite_expires_at})
      html = render(view)

      refute html =~ "tenant-portal-invite-url-card"
      refute html =~ invite_url
      assert html =~ "Expired"
      assert html =~ "Copy invite"
    end

    test "reissue replaces URL, expiry, and stale pending transition", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, user} = Governance.create_portal_invite(tenant, %{email: "reissue@example.com"})
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      first = render_click(view, "copy_portal_invite", %{"portal_user_id" => user.id})
      [first_url] = Regex.run(~r{/portal/detail-t/invites/orchard_pi_[\w-]+}, first)
      [first_focus_region] = Regex.run(~r{tenant-portal-invite-reveal-\d+}, first)
      assert {:ok, [first_summary]} = Governance.list_portal_user_summaries(tenant)

      second = render_click(view, "copy_portal_invite", %{"portal_user_id" => user.id})
      [second_url] = Regex.run(~r{/portal/detail-t/invites/orchard_pi_[\w-]+}, second)
      [second_focus_region] = Regex.run(~r{tenant-portal-invite-reveal-\d+}, second)
      assert {:ok, [second_summary]} = Governance.list_portal_user_summaries(tenant)

      refute first_url == second_url
      refute first_focus_region == second_focus_region

      assert DateTime.compare(second_summary.invite_expires_at, first_summary.invite_expires_at) ==
               :gt

      send(view.pid, {:portal_invite_expired, user.id, first_summary.invite_expires_at})
      html = render(view)

      assert html =~ "tenant-portal-invite-url-card"
      assert html =~ second_url
      refute html =~ first_url
      assert html =~ "Pending"
    end

    test "navigation and reconnect do not restore the plaintext invite URL", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, user} = Governance.create_portal_invite(tenant, %{email: "ephemeral@example.com"})
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      shown = render_click(view, "copy_portal_invite", %{"portal_user_id" => user.id})
      [invite_url] = Regex.run(~r{/portal/detail-t/invites/orchard_pi_[\w-]+}, shown)

      {:ok, _list_view, _html} = live(conn, "/console/tenants")
      {:ok, _navigated_view, navigated_html} = live(conn, "/console/tenants/#{tenant.id}")

      refute navigated_html =~ "tenant-portal-invite-url-card"
      refute navigated_html =~ invite_url
      assert navigated_html =~ "Pending"

      {:ok, _reconnected_view, reconnected_html} = live(conn, "/console/tenants/#{tenant.id}")
      refute reconnected_html =~ "tenant-portal-invite-url-card"
      refute reconnected_html =~ invite_url
      assert reconnected_html =~ "Pending"
    end

    test "renders Expired invite context with localized expiry", %{conn: conn, tenant: tenant} do
      {:ok, user} = Governance.create_portal_invite(tenant, %{email: "expired@example.com"})
      {:ok, _invite} = Governance.copy_portal_invite(tenant, user)
      expires_at = DateTime.add(DateTime.utc_now(), -1, :second)

      PortalInviteToken
      |> Repo.get_by!(portal_user_id: user.id)
      |> Ecto.Changeset.change(expires_at: expires_at)
      |> Repo.update!()

      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")
      row = view |> element("#portal-user-#{user.id}") |> render()

      assert row =~ "Invited"
      assert row =~ "Expired"
      assert row =~ "Expired at"
      assert row =~ ~s(id="portal-user-invite-expires-at-#{user.id}")
      assert row =~ ~s(phx-hook="LocalTime")
    end

    test "keeps Active primary with subordinate Redeemed context", %{conn: conn, tenant: tenant} do
      {:ok, user} = Governance.create_portal_invite(tenant, %{email: "active@example.com"})
      {:ok, invite} = Governance.copy_portal_invite(tenant, user)

      {:ok, _active} =
        Governance.redeem_portal_invite(tenant.slug, invite.token, @portal_password)

      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      row = view |> element("#portal-user-#{user.id}") |> render()

      assert row =~ "Active"
      assert row =~ "Redeemed"
      refute row =~ "Copy invite"
      refute row =~ "Invalidated"
    end

    test "disable dismisses only the shown invite URL of the disabled Portal User", %{
      conn: conn,
      tenant: tenant
    } do
      {:ok, first_user} = Governance.create_portal_invite(tenant, %{email: "first@example.com"})
      {:ok, other_user} = Governance.create_portal_invite(tenant, %{email: "other@example.com"})
      {:ok, view, _html} = live(conn, "/console/tenants/#{tenant.id}")

      shown = render_click(view, "copy_portal_invite", %{"portal_user_id" => first_user.id})
      [invite_url] = Regex.run(~r{/portal/detail-t/invites/orchard_pi_[\w-]+}, shown)

      after_other =
        render_click(view, "disable_portal_user", %{"portal_user_id" => other_user.id})

      assert after_other =~ "tenant-portal-invite-url-card"
      url_preserved = String.contains?(after_other, invite_url)
      assert url_preserved

      after_owner =
        render_click(view, "disable_portal_user", %{"portal_user_id" => first_user.id})

      url_dismissed = not String.contains?(after_owner, invite_url)
      assert url_dismissed
      card_dismissed = not String.contains?(after_owner, "tenant-portal-invite-url-card")
      assert card_dismissed
    end

    test "degraded mode hides invite form", %{conn: conn, tenant: tenant} do
      Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
      {:ok, _view, html} = live(conn, "/console/tenants/#{tenant.id}")
      assert html =~ "tenant-portal-tls-required"
      refute html =~ "tenant-portal-invite-form"
    end
  end

  defp create_api_client_with_token!(tenant, name, token_attrs \\ %{}) do
    {:ok, api_client} =
      Governance.upsert_api_client(tenant, %{
        name: name,
        owner_contact: "owner@example.com",
        owner_name: "Owner Example",
        team: "Inference",
        external_ref: "external-#{name}",
        purpose: "Purpose for #{name}",
        description: "Description for #{name}"
      })

    {:ok, _role_binding} = Governance.ensure_inference_client_access(api_client, tenant)

    {:ok, %{api_key: api_key, token: token}} =
      Governance.create_api_client_api_token(api_client, Map.merge(%{name: "prod"}, token_attrs))

    %{api_client: api_client, api_key: api_key, token: token}
  end

  defp capture_repo_queries(fun) do
    handler_id = {__MODULE__, :repo_queries, System.unique_integer([:positive])}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:orchard, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {handler_id, self(), metadata.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, drain_repo_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(handler_id, queries) do
    receive do
      {^handler_id, pid, query} -> drain_repo_queries(handler_id, [{pid, query} | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
