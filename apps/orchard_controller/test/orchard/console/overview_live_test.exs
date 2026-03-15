defmodule OrchardConsole.OverviewLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :live

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])
    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)
    :ok
  end

  describe "GET /console" do
    test "renders overview page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Orchard Console"
      assert html =~ "Overview"
      assert html =~ "Console Online"
    end

    test "has correct page title with suffix", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Overview \u2014 Orchard Console"
    end

    test "includes brand bar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "from-navy"
      assert html =~ "to-gold"
    end

    test "includes favicon meta", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "favicon-32x32.png"
    end
  end

  describe "LiveView mount with basic auth" do
    setup do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: "secret"
      )

      :ok
    end

    test "mounts successfully with session marker", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          OrchardConsole.Auth.session_marker_key() => true
        })

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Orchard Console"
    end
  end

  describe "on_mount hook denials" do
    test "denies when basic auth marker is missing" do
      Application.put_env(:orchard_controller, :console,
        enabled: true,
        auth: :basic,
        username: "operator",
        password: "secret"
      )

      session = %{}
      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: "/console"}}}} =
               OrchardConsole.on_mount(:ensure_console_access, %{}, session, socket)
    end

    test "denies when feature flag is disabled even with marker" do
      Application.put_env(:orchard_controller, :console,
        enabled: false,
        auth: :basic,
        username: "operator",
        password: "secret"
      )

      session = %{OrchardConsole.Auth.session_marker_key() => true}
      socket = %Phoenix.LiveView.Socket{}

      assert {:halt, %Phoenix.LiveView.Socket{redirected: {:redirect, %{to: "/console"}}}} =
               OrchardConsole.on_mount(:ensure_console_access, %{}, session, socket)
    end

    test "allows when auth is :none and enabled" do
      # Default test config: enabled: true, auth: :none
      session = %{}
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, %Phoenix.LiveView.Socket{}} =
               OrchardConsole.on_mount(:ensure_console_access, %{}, session, socket)
    end
  end
end
