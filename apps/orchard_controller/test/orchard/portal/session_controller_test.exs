defmodule Orchard.Portal.SessionControllerTest do
  use Orchard.ConnCase, async: false

  import Orchard.TestSupport.PortalConn

  alias Ecto.Changeset
  alias Orchard.Governance
  alias Orchard.Governance.PortalInviteToken
  alias Orchard.Governance.PortalPasswordVerifier
  alias Orchard.Portal.Auth
  alias Orchard.Repo

  @moduletag :live
  @moduletag :db
  @password "sixteen-chars-ok"

  setup do
    enable_https_proxy!()

    case Process.whereis(PortalPasswordVerifier) do
      nil -> start_supervised!(PortalPasswordVerifier)
      _pid -> :ok
    end

    :ok
  end

  test "GET login is indistinguishable and has email plus password without Console chrome", %{
    conn: conn
  } do
    {:ok, _tenant} = Governance.create_tenant(%{slug: "portal-known", name: "Known Org"})

    for slug <- ["portal-known", "portal-missing"] do
      response = conn |> https_conn() |> get("/portal/#{slug}")
      body = html_response(response, 200)
      assert body =~ "Developer portal"
      assert body =~ "Email"
      assert body =~ "Password"
      refute body =~ "Portal password"
      refute body =~ "console-sidebar"
      refute body =~ "href=\"/console"
      refute body =~ "Known Org"
    end
  end

  test "named HTTPS login stores the portal token and redirects to own keys", %{conn: conn} do
    {tenant, user} = active_user!("portal-login-ok")

    conn = post_login(conn, tenant.slug, user.email, @password)

    assert redirected_to(conn) == "/portal/portal-login-ok/keys"
    assert get_session(conn, Auth.session_token_key())
  end

  test "invite redemption sets password once and redirects to login", %{conn: conn} do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-redeem", name: "Redeem"})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)

    page = conn |> https_conn() |> get("/portal/#{tenant.slug}/invites/#{invite.token}")
    assert html_response(page, 200) =~ "Set your password"
    csrf_token = csrf_token(page)

    redeemed =
      post_form(page, "/portal/#{tenant.slug}/invites/#{invite.token}", %{
        "_csrf_token" => csrf_token,
        "invite[password]" => @password,
        "invite[password_confirmation]" => @password
      })

    assert redirected_to(redeemed) == "/portal/#{tenant.slug}"

    again =
      post_form(page, "/portal/#{tenant.slug}/invites/#{invite.token}", %{
        "_csrf_token" => csrf_token,
        "invite[password]" => @password,
        "invite[password_confirmation]" => @password
      })

    assert again.status == 422
  end

  test "SPEC 7.4a invite redemption is bound to the Organization route", %{conn: conn} do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-route-owner", name: "Route Owner"})

    {:ok, _other} =
      Governance.create_tenant(%{slug: "portal-route-other", name: "Route Other"})

    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)

    page = conn |> https_conn() |> get("/portal/portal-route-other/invites/#{invite.token}")

    wrong_organization =
      post_form(page, "/portal/portal-route-other/invites/#{invite.token}", %{
        "_csrf_token" => csrf_token(page),
        "invite[password]" => @password,
        "invite[password_confirmation]" => @password
      })

    assert wrong_organization.status == 422
    assert invalid_invite_response?(wrong_organization)

    correct_organization =
      post_form(wrong_organization, "/portal/#{tenant.slug}/invites/#{invite.token}", %{
        "_csrf_token" => csrf_token(wrong_organization),
        "invite[password]" => @password,
        "invite[password_confirmation]" => @password
      })

    assert redirected_to(correct_organization) == "/portal/#{tenant.slug}"
  end

  test "SPEC 7.4a invalid invite cases share one generic mutation-free response", %{conn: conn} do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-invalid", name: "Invalid Cases"})

    {:ok, invalidated_user} =
      Governance.create_portal_invite(tenant, %{email: "invalidated@example.com"})

    {:ok, invalidated} = Governance.copy_portal_invite(tenant, invalidated_user)
    {:ok, replacement} = Governance.copy_portal_invite(tenant, invalidated_user)

    {:ok, expired_user} =
      Governance.create_portal_invite(tenant, %{email: "expired@example.com"})

    {:ok, expired} = Governance.copy_portal_invite(tenant, expired_user)

    PortalInviteToken
    |> Repo.get_by!(portal_user_id: expired_user.id)
    |> Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    {:ok, disabled_user} =
      Governance.create_portal_invite(tenant, %{email: "disabled@example.com"})

    {:ok, disabled} = Governance.copy_portal_invite(tenant, disabled_user)
    {:ok, _disabled_user} = Governance.disable_portal_user(tenant, disabled_user)

    {:ok, redeemed_user} =
      Governance.create_portal_invite(tenant, %{email: "redeemed@example.com"})

    {:ok, redeemed} = Governance.copy_portal_invite(tenant, redeemed_user)

    {:ok, _active_user} =
      Governance.redeem_portal_invite(tenant.slug, redeemed.token, @password)

    responses = [
      redeem_attempt(conn, tenant.slug, invalidated.token),
      redeem_attempt(conn, tenant.slug, expired.token),
      redeem_attempt(conn, tenant.slug, disabled.token),
      redeem_attempt(conn, tenant.slug, redeemed.token),
      redeem_attempt(conn, tenant.slug, "orchard_pi_unknown")
    ]

    assert Enum.map(responses, &invalid_invite_response_signature/1)
           |> Enum.uniq() ==
             [
               {422, ["text/html; charset=utf-8"], ["no-store"], true}
             ]

    assert {:ok, _active_user} =
             Governance.redeem_portal_invite(tenant.slug, replacement.token, @password)

    assert {:ok, users} = Governance.list_portal_users(tenant)
    statuses = Map.new(users, &{&1.email, &1.status})
    assert statuses["expired@example.com"] == "invited"
    assert statuses["disabled@example.com"] == "disabled"
    assert statuses["redeemed@example.com"] == "active"
  end

  test "login POST without a CSRF token is rejected", %{conn: conn} do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post_form(conn, "/portal/csrf-check/session", %{
        "session[email]" => "a@b.com",
        "session[password]" => "x"
      })
    end
  end

  test "login POST with an invalid CSRF token is rejected", %{conn: conn} do
    page = conn |> https_conn() |> get("/portal/csrf-check")

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post_form(page, "/portal/csrf-check/session", %{
        "_csrf_token" => "invalid-token",
        "session[email]" => "a@b.com",
        "session[password]" => "x"
      })
    end
  end

  test "logout accepts an encoded browser form and clears the portal session", %{conn: conn} do
    {tenant, user} = active_user!("portal-logout")
    logged_in = post_login(conn, tenant.slug, user.email, @password)
    assert get_session(logged_in, Auth.session_token_key())

    page =
      logged_in
      |> recycle()
      |> https_conn()
      |> get("/portal/#{tenant.slug}/keys")

    logged_out =
      post_form(page, "/portal/#{tenant.slug}/logout", %{
        "_csrf_token" => csrf_token(page)
      })

    assert redirected_to(logged_out) == "/portal/#{tenant.slug}"
    refute get_session(logged_out, Auth.session_token_key())
  end

  test "degraded transport returns 404 for every portal route", %{conn: conn} do
    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
    assert (conn |> https_conn() |> get("/portal/any-org")).status == 404
    assert (conn |> https_conn() |> get("/portal/any-org/invites/token")).status == 404
  end

  defp active_user!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: slug})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)
    {:ok, user} = Governance.redeem_portal_invite(tenant.slug, invite.token, @password)
    {tenant, user}
  end

  defp post_login(conn, slug, email, password) do
    page =
      conn
      |> https_conn()
      |> get("/portal/#{slug}")

    post_form(page, "/portal/#{slug}/session", %{
      "_csrf_token" => csrf_token(page),
      "session[email]" => email,
      "session[password]" => password
    })
  end

  defp post_form(conn, path, params) do
    conn
    |> recycle()
    |> https_conn()
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(params))
  end

  defp csrf_token(conn) do
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, conn.resp_body)
    token
  end

  defp invalid_invite_response?(conn) do
    conn.status == 422 and
      String.contains?(conn.resp_body, "This invite is invalid, expired, or already used.")
  end

  defp invalid_invite_response_signature(conn) do
    {
      conn.status,
      get_resp_header(conn, "content-type"),
      get_resp_header(conn, "cache-control"),
      invalid_invite_response?(conn)
    }
  end

  defp redeem_attempt(conn, slug, token) do
    page = conn |> https_conn() |> get("/portal/#{slug}/invites/#{token}")

    post_form(page, "/portal/#{slug}/invites/#{token}", %{
      "_csrf_token" => csrf_token(page),
      "invite[password]" => @password,
      "invite[password_confirmation]" => @password
    })
  end
end
