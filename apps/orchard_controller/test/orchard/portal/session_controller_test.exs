defmodule Orchard.Portal.SessionControllerTest do
  use Orchard.ConnCase, async: false

  import Orchard.TestSupport.PortalConn

  alias Orchard.Governance
  alias Orchard.Governance.PortalPasswordVerifier
  alias Orchard.Portal.Auth

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
    {:ok, user} = Governance.redeem_portal_invite(invite.token, @password)
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
end
