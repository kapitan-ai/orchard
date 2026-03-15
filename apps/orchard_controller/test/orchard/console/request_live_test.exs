defmodule OrchardConsole.RequestLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :live
  @moduletag :db

  setup do
    Sandbox.mode(Orchard.Repo, {:shared, self()})
    :ok
  end

  describe "GET /console/requests/:public_id" do
    test "renders placeholder page with public_id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests/req_test_123")

      assert html =~ "Request req_test_123 \u2014 Orchard Console"
      assert html =~ "Coming soon"
      assert html =~ "Request detail view is not implemented yet."
      assert html =~ "Public ID"
      assert html =~ "req_test_123"
    end

    test "has correct page header with public_id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests/req_test_123")

      assert html =~ "<h1"
      assert html =~ "Request req_test_123"
    end

    test "marks Requests as active nav item with disabled-active styling", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests/req_test_123")

      # Requests is visually active
      assert html =~ ~s(aria-current="page")
      assert html =~ "text-navy"
      # Active item drops disabled semantics (no aria-disabled, no "coming soon")
      refute html =~ "Requests \u2014 coming soon"
      # But still no clickable link to a requests index
      refute html =~ "/console/requests\""
    end

    test "includes brand bar and shell", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests/req_test_123")

      assert html =~ "from-navy"
      assert html =~ "to-gold"
      assert html =~ "console-sidebar"
    end

    test "handles different public_id values", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests/another-request-456")

      assert html =~ "another-request-456"
      assert html =~ "Request another-request-456 \u2014 Orchard Console"
    end
  end
end
