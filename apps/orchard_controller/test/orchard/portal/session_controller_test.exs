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
    start_verifier!()
    :ok
  end

  test "GET login is indistinguishable for open, closed, and unknown slugs", %{conn: conn} do
    {:ok, open} = Governance.create_tenant(%{slug: "portal-open", name: "Open Org"})
    {:ok, _} = Governance.set_tenant_portal_password(open, @password)
    {:ok, _closed} = Governance.create_tenant(%{slug: "portal-shut", name: "Shut Org"})

    open_html = login_html(conn, "portal-open")
    closed_html = login_html(conn, "portal-shut")
    missing_html = login_html(conn, "portal-missing")

    for html <- [open_html, closed_html, missing_html] do
      assert html.status == 200
      assert html.body =~ "Developer portal"
      assert html.body =~ "Portal password"
      assert html.body =~ "Sign in"
      refute html.body =~ "console-sidebar"
      refute html.body =~ "console-license-badge"
      refute html.body =~ "href=\"/console"
      refute html.body =~ "Open Org"
      refute html.body =~ "Shut Org"
    end
  end

  test "HTTPS login stores the portal token and redirects to keys", %{conn: conn} do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-login-ok", name: "Login"})
    {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    conn = post_login(conn, "portal-login-ok", @password)

    assert redirected_to(conn) == "/portal/portal-login-ok/keys"
    assert get_session(conn, Auth.session_token_key())
  end

  test "throttled login is visually distinct from wrong password", %{conn: conn} do
    {:ok, tenant} = Governance.create_tenant(%{slug: "portal-throttle-ui", name: "Throttle"})
    {:ok, _} = Governance.set_tenant_portal_password(tenant, @password)

    for _ <- 1..5 do
      post_login(conn, "portal-throttle-ui", "sixteen-chars-bad")
    end

    wrong = post_login(conn, "portal-throttle-ui", "sixteen-chars-bad")
    assert wrong.status == 429
    assert html_response(wrong, 429) =~ "Too many sign-in attempts"
    refute html_response(wrong, 429) =~ "Sign-in failed."
  end

  test "login POST without a CSRF token is rejected" do
    secret =
      :orchard_controller
      |> Application.get_env(Orchard.API.Endpoint, [])
      |> Keyword.fetch!(:secret_key_base)

    assert_raise Plug.Conn.WrapperError, fn ->
      Plug.Test.conn(:post, "/portal/csrf-check/session", "session[password]=x")
      |> Map.put(:scheme, :https)
      |> Map.put(:secret_key_base, secret)
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Plug.Session.call(
        Plug.Session.init(
          store: :cookie,
          key: "_orchard_console_key",
          signing_salt: "orchard_console"
        )
      )
      |> Plug.Conn.fetch_session()
      |> Router.call(Router.init([]))
    end
  end

  test "degraded transport returns 404 for portal routes", %{conn: conn} do
    Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)

    conn = get(https_conn(conn), "/portal/any-org")
    assert conn.status == 404
    refute conn.resp_body =~ "Developer portal"
  end

  test "untrusted forwarded proto does not open the portal", %{conn: conn} do
    Application.put_env(:orchard_controller, :transport_mode, :direct_https)

    conn =
      conn
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
      |> get("/portal/forwarded")

    assert conn.status == 404
  end

  defp login_html(conn, slug) do
    conn = get(https_conn(conn), "/portal/#{slug}")
    %{status: conn.status, body: html_response(conn, 200)}
  end

  defp post_login(conn, slug, password) do
    conn
    |> https_conn()
    |> get("/portal/#{slug}")
    |> recycle()
    |> https_conn()
    |> post("/portal/#{slug}/session", %{"session" => %{"password" => password}})
  end

  defp start_verifier! do
    case Process.whereis(PortalPasswordVerifier) do
      nil -> start_supervised!(PortalPasswordVerifier)
      _pid -> :ok
    end
  end
end
