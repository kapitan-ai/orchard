defmodule Orchard.Portal.KeysLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Orchard.TestSupport.PortalConn

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
  alias Orchard.Governance.PortalPasswordVerifier
  alias Orchard.Portal.Auth
  alias Orchard.Repo

  @moduletag :live
  @moduletag :db
  @password "sixteen-chars-ok"

  setup do
    enable_https_proxy!()
    Sandbox.mode(Repo, {:shared, self()})
    start_verifier!()

    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-keys", name: "Portal Keys"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)
    {:ok, user} = Governance.redeem_portal_invite(invite.token, @password)

    {:ok, session} =
      Governance.create_portal_session(
        "portal-keys",
        user.email,
        @password,
        "203.0.113.50"
      )

    %{tenant: tenant, user: user, token: session.token}
  end

  test "empty org shows a create action, not only a table", %{conn: conn, token: token} do
    {:ok, view, html} = live(authed(conn, token), "/portal/portal-keys/keys")

    assert html =~ "No API keys yet"
    assert html =~ "Mint your first key"
    assert html =~ "0 / 10"
    refute html =~ "console-sidebar"
    refute html =~ "theme-toggle"
    refute html =~ "href=\"/console"
    assert has_element?(view, "#portal-mint-button")
  end

  test "mint shows the secret once and list then shows prefix only", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")

    view |> element("#portal-mint-button") |> render_click()

    html =
      view
      |> form("#portal-mint-modal form", key: %{name: "laptop"})
      |> render_submit()

    assert html =~ "Copy your key now"
    assert html =~ "orchard_sk_"
    assert html =~ "portal-secret-value"
    refute html =~ "data-secret="
    assert html =~ "No test curl is available"

    view
    |> element("#portal-secret-modal form")
    |> render_change(%{"ack" => "true"})

    html = view |> element("#portal-secret-done") |> render_click()
    refute html =~ "orchard_sk_"
    assert html =~ "laptop"
    assert html =~ "orchard_kp_"
  end

  test "reconnect after mint does not restore the plaintext token", %{
    conn: conn,
    token: token
  } do
    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-mint-button") |> render_click()

    view
    |> form("#portal-mint-modal form", key: %{name: "ephemeral"})
    |> render_submit()

    assert render(view) =~ "orchard_sk_"

    {:ok, _view, html} = live(authed(conn, token), "/portal/portal-keys/keys")
    refute html =~ "orchard_sk_"
    assert html =~ "ephemeral"
  end

  test "clipboard failure keeps the secret visible", %{conn: conn, token: token} do
    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-mint-button") |> render_click()

    html =
      view
      |> form("#portal-mint-modal form", key: %{name: "copy-fail"})
      |> render_submit()

    assert html =~ "orchard_sk_"
    [_, api_key_id] = Regex.run(~r/data-api-key-id="([^"]+)"/, html)

    html = render_hook(view, "generated_secret_copy_failed", %{"api_key_id" => api_key_id})
    assert html =~ "Copy failed"
    assert html =~ "orchard_sk_"
    assert html =~ "portal-secret-value"
  end

  test "revoke requires typing the key name", %{conn: conn, token: token} do
    {:ok, minted} =
      Governance.create_portal_api_key(token, "portal-keys", %{name: "typed-revoke"})

    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    view |> element("#portal-revoke-#{minted.api_key.id}") |> render_click()

    html =
      view
      |> form("#portal-revoke-modal form", confirmation: "wrong-name")
      |> render_change()

    assert html =~ "disabled"
    assert Repo.get!(Orchard.Governance.ApiKey, minted.api_key.id).revoked_at == nil

    view
    |> form("#portal-revoke-modal form", confirmation: "typed-revoke")
    |> render_change()

    html = view |> form("#portal-revoke-modal form") |> render_submit()
    assert html =~ "Revoked"
    assert Repo.get!(Orchard.Governance.ApiKey, minted.api_key.id).revoked_at
  end

  test "Portal User disable fails revoke on a standing keys socket", %{
    conn: conn,
    token: token,
    tenant: tenant,
    user: user
  } do
    {:ok, minted} =
      Governance.create_portal_api_key(token, "portal-keys", %{name: "standing-revoke"})

    {:ok, view, _html} = live(authed(conn, token), "/portal/portal-keys/keys")
    assert {:ok, _} = Governance.disable_portal_user(tenant, user)

    view |> element("#portal-revoke-#{minted.api_key.id}") |> render_click()

    view
    |> form("#portal-revoke-modal form", confirmation: "standing-revoke")
    |> render_change()

    assert {:error, {:redirect, %{to: "/portal/portal-keys"}}} =
             view |> form("#portal-revoke-modal form") |> render_submit()

    assert Repo.get!(Orchard.Governance.ApiKey, minted.api_key.id).revoked_at == nil
  end

  defp authed(conn, token) do
    conn
    |> https_conn()
    |> Phoenix.ConnTest.init_test_session(%{Auth.session_token_key() => token})
  end

  defp start_verifier! do
    case Process.whereis(PortalPasswordVerifier) do
      nil -> start_supervised!(PortalPasswordVerifier)
      _pid -> :ok
    end
  end
end
