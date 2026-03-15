defmodule OrchardConsole.OverviewLiveTest do
  use Orchard.ConnCase

  import Phoenix.LiveViewTest

  @moduletag :live

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
end
