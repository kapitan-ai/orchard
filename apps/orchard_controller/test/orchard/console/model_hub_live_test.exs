defmodule OrchardConsole.ModelHubLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :live

  describe "GET /console/model-hub" do
    test "renders page title with console suffix", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/model-hub")

      assert html =~ "Model Hub \u2014 Orchard Console"
    end

    test "renders placeholder scaffold under the console shell", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/model-hub")

      assert html =~ "console-sidebar"

      placeholder = view |> element("#model-hub-placeholder-card") |> render()
      assert placeholder =~ "Model Hub"
      assert placeholder =~ "Browse Hugging Face MLX text-generation models from the console."

      copy = view |> element("#model-hub-placeholder-copy") |> render()
      assert copy =~ "Search, results, and detail browsing arrive in the next task."
      assert copy =~ "Download and import actions"
      assert copy =~ "intentionally out of scope"
    end

    test "marks Model Hub as the active nav item", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/model-hub")

      assert has_element?(view, ~s(a[aria-current="page"][href="/console/model-hub"]))
      assert html =~ "/console/models"
      refute html =~ "Model Hub \u2014 coming soon"
    end
  end
end
