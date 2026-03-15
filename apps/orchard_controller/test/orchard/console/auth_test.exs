defmodule OrchardConsole.AuthTest do
  use Orchard.ConnCase, async: false

  @moduletag :live

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
    end)

    :ok
  end

  describe "feature flag disabled" do
    test "returns 404 when console is disabled", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: false,
        auth: :none,
        username: nil,
        password: nil
      )

      conn = get(conn, "/console")

      assert conn.status == 404
    end
  end

  describe "basic auth" do
    setup do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: "secret"
      )

      :ok
    end

    test "returns 401 without credentials", %{conn: conn} do
      conn = get(conn, "/console")

      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") |> hd() =~ "Basic"
    end

    test "returns 401 with invalid credentials", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("wrong", "creds"))
        |> get("/console")

      assert conn.status == 401
    end

    test "returns 200 with valid credentials and sets session marker", %{conn: conn} do
      conn =
        conn
        |> put_req_header(
          "authorization",
          Plug.BasicAuth.encode_basic_auth("operator", "secret")
        )
        |> get("/console")

      assert conn.status == 200
      assert conn.resp_body =~ "Orchard Console"
      assert get_session(conn, OrchardConsole.Auth.session_marker_key()) == true
    end

    test "allows access with session marker without Authorization header", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          OrchardConsole.Auth.session_marker_key() => true
        })
        |> get("/console")

      assert conn.status == 200
      assert conn.resp_body =~ "Orchard Console"
    end
  end

  describe "no auth in test env" do
    test "default test config has console enabled with no auth" do
      config = Application.fetch_env!(:orchard_controller, :console)

      assert config[:enabled] == true
      assert config[:auth] == :none
    end

    test "returns 200 without credentials when auth is :none", %{conn: conn} do
      # Relies on default test.exs config: enabled: true, auth: :none
      conn = get(conn, "/console")

      assert conn.status == 200
      assert conn.resp_body =~ "Orchard Console"
    end
  end

  describe "basic auth misconfigured credentials" do
    test "raises when username is nil", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: nil,
        password: "secret"
      )

      assert_raise ArgumentError, ~r/non-blank :username/, fn ->
        get(conn, "/console")
      end
    end

    test "raises when password is nil", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: nil
      )

      assert_raise ArgumentError, ~r/non-blank :password/, fn ->
        get(conn, "/console")
      end
    end

    test "raises when username is empty string", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "",
        password: "secret"
      )

      assert_raise ArgumentError, ~r/non-blank :username/, fn ->
        get(conn, "/console")
      end
    end

    test "raises when password is whitespace-only", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: "   "
      )

      assert_raise ArgumentError, ~r/non-blank :password/, fn ->
        get(conn, "/console")
      end
    end
  end

  describe "console subpaths" do
    test "returns 404 for /console/playground when console is disabled", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: false,
        auth: :none,
        username: nil,
        password: nil
      )

      conn = get(conn, "/console/playground")
      assert conn.status == 404
    end

    test "returns 404 for /console/requests/:id when console is disabled", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: false,
        auth: :none,
        username: nil,
        password: nil
      )

      conn = get(conn, "/console/requests/req_auth_test")
      assert conn.status == 404
    end

    test "returns 401 for /console/playground in basic auth without credentials", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: "secret"
      )

      conn = get(conn, "/console/playground")
      assert conn.status == 401
    end

    test "returns 401 for /console/requests/:id in basic auth without credentials", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: "secret"
      )

      conn = get(conn, "/console/requests/req_auth_test")
      assert conn.status == 401
    end

    test "returns 200 for subpaths with valid basic auth credentials", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: "secret"
      )

      conn =
        conn
        |> put_req_header(
          "authorization",
          Plug.BasicAuth.encode_basic_auth("operator", "secret")
        )
        |> get("/console/playground")

      assert conn.status == 200
      assert conn.resp_body =~ "Playground"
    end

    test "returns 200 for request detail with valid basic auth credentials", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: "secret"
      )

      conn =
        conn
        |> put_req_header(
          "authorization",
          Plug.BasicAuth.encode_basic_auth("operator", "secret")
        )
        |> get("/console/requests/req_auth_test")

      assert conn.status == 200
      assert conn.resp_body =~ "req_auth_test"
    end
  end

  describe "non-console paths" do
    test "does not affect API routes", %{conn: conn} do
      Application.put_env(:orchard_controller, :console,
        enabled: false,
        auth: :none,
        username: nil,
        password: nil
      )

      conn = get(conn, "/health/live")

      assert conn.status == 200
    end
  end
end
