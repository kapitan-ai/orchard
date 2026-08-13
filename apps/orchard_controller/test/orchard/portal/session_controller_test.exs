defmodule Orchard.Portal.SessionControllerTest do
  use Orchard.ConnCase, async: false

  import Orchard.TestSupport.PortalConn

  alias Orchard.API.Router
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

  test "GET login is indistinguishable and has email plus password without Console chrome", %{conn: conn} do
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

    page = conn |> https_conn() |> get("/portal/#{tenant.slug}/invite/#{invite.token}")
    assert html_response(page, 200) =~ "Set your password"

    redeemed =
      page
      |> recycle()
      |> https_conn()
      |> post("/portal/#{tenant.slug}/invite/#{invite.token}", %{
        "invite" => %{"password" => @password, "password_confirmation" => @password}
      })

    assert redirected_to(redeemed) == "/portal/#{tenant.slug}"

    again =
      page
      |> recycle()
      |> https_conn()
      |> post("/portal/#{tenant.slug}/invite/#{invite.token}", %{
        "invite" => %{"password" => @password, "password_confirmation" => @password}
      })

    assert again.status == 422
  end

  test "login POST without a CSRF token is rejected" do
    secret = Application.get_env(:orchard_controller, Orchard.API.Endpoint, []) |> Keyword.fetch!(:secret_key_base)

    assert_raise Plug.Conn.WrapperError, fn ->
      Plug.Test.conn(:post, "/portal/csrf-check/session", "session[email]=a%40b.com&session[password]=x")
      |> Map.put(:scheme, :https)
      |> Map.put(:secret_key_base, secret)
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Session.call(Plug.Session.init(store: :cookie, key: "_orchard_console_key", signing_salt: "orchard_console"))
      |> Plug.Conn.fetch_session()
      |> Router.call(Router.init([]))
    end
  end

  test "degraded transport returns 404 for every portal route", %{conn: conn} do
    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
    assert (conn |> https_conn() |> get("/portal/any-org")).status == 404
    assert (conn |> https_conn() |> get("/portal/any-org/invite/token")).status == 404
  end

  defp active_user!(slug) do
    {:ok, tenant} = Governance.create_tenant(%{slug: slug, name: slug})
    {:ok, user} = Governance.create_portal_invite(tenant, %{email: "dev@example.com"})
    {:ok, invite} = Governance.copy_portal_invite(tenant, user)
    {:ok, user} = Governance.redeem_portal_invite(invite.token, @password)
    {tenant, user}
  end

  defp post_login(conn, slug, email, password) do
    conn
    |> https_conn()
    |> get("/portal/#{slug}")
    |> recycle()
    |> https_conn()
    |> post("/portal/#{slug}/session", %{"session" => %{"email" => email, "password" => password}})
  end
end
