defmodule OrchardConsole.PlaygroundLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :live
  @moduletag :db

  setup do
    Sandbox.mode(Orchard.Repo, {:shared, self()})
    :ok
  end

  describe "GET /console/playground" do
    test "renders placeholder page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ "Playground \u2014 Orchard Console"
      assert html =~ "Coming soon"
      assert html =~ "The console playground is not implemented yet."
    end

    test "has correct page header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ "<h1"
      assert html =~ "Playground"
    end

    test "marks Playground as active nav item", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ ~s(aria-current="page")
      assert html =~ "bg-navy/10"
    end

    test "includes brand bar and shell", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/playground")

      assert html =~ "from-navy"
      assert html =~ "to-gold"
      assert html =~ "console-sidebar"
    end
  end
end
