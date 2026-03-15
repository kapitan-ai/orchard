defmodule OrchardConsole.OverviewLiveTest do
  use Orchard.ConnCase

  import Phoenix.LiveViewTest

  @endpoint Orchard.API.Endpoint

  setup do
    start_supervised!(Orchard.API.Endpoint)
    :ok
  end

  describe "GET /console" do
    test "renders overview page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Orchard Console"
      assert html =~ "Overview"
      assert html =~ "Console Online"
    end

    test "has correct page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "<title>Orchard Console</title>"
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
end
