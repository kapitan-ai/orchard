defmodule OrchardConsole.ModelsLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Orchard.TestSupport.ModelRequestFixtures

  alias Ecto.Adapters.SQL.Sandbox

  @moduletag :live
  @moduletag :db

  setup do
    Sandbox.mode(Orchard.Repo, {:shared, self()})
    :ok
  end

  describe "page rendering" do
    test "renders page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/models")
      assert html =~ "Models \u2014 Orchard Console"
    end

    test "renders empty state with CLI hint when no models exist", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/models")
      assert html =~ "No models imported yet."
      assert html =~ "orchardctl models import"
      assert html =~ "bundle-path"

      # Uses shared state_message component
      empty = view |> element("#models-empty-state") |> render()
      assert empty =~ "No models imported yet."
    end

    test "renders catalog table with model data", %{conn: conn} do
      create_model!(%{model_id: "mlx-community/phi-3", state: :active, format: "mlx"})
      create_model!(%{model_id: "mlx-community/llama-2", state: :registered, format: "mlx"})

      {:ok, _view, html} = live(conn, "/console/models")

      assert html =~ "Model Catalog"
      assert html =~ "mlx-community/phi-3"
      assert html =~ "mlx-community/llama-2"
      assert html =~ "Manage model visibility"
    end

    test "renders state badges with correct tones", %{conn: conn} do
      create_model!(%{model_id: "active-m", state: :active})
      create_model!(%{model_id: "registered-m", state: :registered})
      create_model!(%{model_id: "deprecated-m", state: :deprecated})
      create_model!(%{model_id: "retired-m", state: :retired})

      {:ok, view, _html} = live(conn, "/console/models")
      html = render(view)

      # Each state should be rendered as text in a badge
      assert html =~ "active"
      assert html =~ "registered"
      assert html =~ "deprecated"
      assert html =~ "retired"
    end
  end

  describe "summary strip" do
    test "renders summary strip with all count tiles when models exist", %{conn: conn} do
      create_model!(%{model_id: "m-active", state: :active})
      create_model!(%{model_id: "m-registered", state: :registered})
      create_model!(%{model_id: "m-deprecated", state: :deprecated})

      {:ok, view, _html} = live(conn, "/console/models")

      # Summary strip exists
      summary = view |> element("#models-summary") |> render()
      assert summary =~ "Total"
      assert summary =~ "Registered"
      assert summary =~ "Active"
      assert summary =~ "Deprecated"
      assert summary =~ "Retired"

      # Check tile counts
      total_tile = view |> element("#models-summary-total") |> render()
      assert total_tile =~ "3"

      active_tile = view |> element("#models-summary-active") |> render()
      assert active_tile =~ "1"

      retired_tile = view |> element("#models-summary-retired") |> render()
      assert retired_tile =~ "0"
    end

    test "renders zero-filled summary strip when no models exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/models")

      summary = view |> element("#models-summary") |> render()
      assert summary =~ "Total"

      total_tile = view |> element("#models-summary-total") |> render()
      assert total_tile =~ "0"

      active_tile = view |> element("#models-summary-active") |> render()
      assert active_tile =~ "0"
    end

    test "summary counts update after lifecycle transition", %{conn: conn} do
      model = create_model!(%{model_id: "trans-model", state: :registered})

      {:ok, view, _html} = live(conn, "/console/models")

      # Before: 1 registered, 0 active
      registered_tile = view |> element("#models-summary-registered") |> render()
      assert registered_tile =~ "1"
      active_tile = view |> element("#models-summary-active") |> render()
      assert active_tile =~ "0"

      # Activate the model
      view
      |> element("#model-#{model.id} button", "Activate")
      |> render_click()

      # After: 0 registered, 1 active
      registered_tile = view |> element("#models-summary-registered") |> render()
      assert registered_tile =~ "0"
      active_tile = view |> element("#models-summary-active") |> render()
      assert active_tile =~ "1"
    end
  end

  describe "active-row highlighting" do
    test "active model row has highlight class", %{conn: conn} do
      model = create_model!(%{model_id: "highlighted", state: :active})

      {:ok, view, _html} = live(conn, "/console/models")
      row = view |> element("#model-#{model.id}") |> render()

      assert row =~ "bg-forest-50/50"
      assert row =~ "dark:bg-emerald-900/20"
    end

    test "non-active model rows do not have highlight class", %{conn: conn} do
      model = create_model!(%{model_id: "not-highlighted", state: :registered})

      {:ok, view, _html} = live(conn, "/console/models")
      row = view |> element("#model-#{model.id}") |> render()

      refute row =~ "bg-forest-50/50"
    end

    test "highlight appears after activating a model", %{conn: conn} do
      model = create_model!(%{model_id: "to-activate", state: :registered})

      {:ok, view, _html} = live(conn, "/console/models")

      # Before: no highlight
      row = view |> element("#model-#{model.id}") |> render()
      refute row =~ "bg-forest-50/50"

      # Activate
      view
      |> element("#model-#{model.id} button", "Activate")
      |> render_click()

      # After: has highlight
      row = view |> element("#model-#{model.id}") |> render()
      assert row =~ "bg-forest-50/50"
    end

    test "highlight disappears after deprecating an active model", %{conn: conn} do
      model = create_model!(%{model_id: "to-deprecate", state: :active})

      {:ok, view, _html} = live(conn, "/console/models")

      # Before: has highlight
      row = view |> element("#model-#{model.id}") |> render()
      assert row =~ "bg-forest-50/50"

      # Deprecate
      view
      |> element("#model-#{model.id} button", "Deprecate")
      |> render_click()

      # After: no highlight
      row = view |> element("#model-#{model.id}") |> render()
      refute row =~ "bg-forest-50/50"
    end
  end

  describe "action buttons" do
    test "shows valid actions for registered model", %{conn: conn} do
      model = create_model!(%{model_id: "reg-model", state: :registered})

      {:ok, view, _html} = live(conn, "/console/models")
      row = view |> element("#model-#{model.id}") |> render()

      assert row =~ "Activate"
      assert row =~ "Retire"
      refute row =~ "Deprecate"
    end

    test "shows valid actions for active model", %{conn: conn} do
      model = create_model!(%{model_id: "active-model", state: :active})

      {:ok, view, _html} = live(conn, "/console/models")
      row = view |> element("#model-#{model.id}") |> render()

      assert row =~ "Deprecate"
      assert row =~ "Retire"
      refute row =~ "Activate"
    end

    test "shows valid actions for deprecated model", %{conn: conn} do
      model = create_model!(%{model_id: "dep-model", state: :deprecated})

      {:ok, view, _html} = live(conn, "/console/models")
      row = view |> element("#model-#{model.id}") |> render()

      assert row =~ "Activate"
      assert row =~ "Retire"
      refute row =~ "Deprecate"
    end

    test "shows no actions for retired model", %{conn: conn} do
      model = create_model!(%{model_id: "retired-model", state: :retired})

      {:ok, view, _html} = live(conn, "/console/models")
      row = view |> element("#model-#{model.id}") |> render()

      refute row =~ "Activate"
      refute row =~ "Deprecate"
      refute row =~ "Retire"
      # Dash placeholder for no actions
      assert row =~ "\u2014"
    end
  end

  describe "lifecycle actions" do
    test "activate transitions model and shows flash", %{conn: conn} do
      model = create_model!(%{model_id: "activatable", state: :registered})

      {:ok, view, _html} = live(conn, "/console/models")

      view
      |> element("#model-#{model.id} button", "Activate")
      |> render_click()

      html = render(view)
      assert html =~ "Activated activatable@main."

      # Row now shows active state actions
      row = view |> element("#model-#{model.id}") |> render()
      assert row =~ "active"
      assert row =~ "Deprecate"
      refute row =~ "Activate"
    end

    test "deprecate transitions model and shows flash", %{conn: conn} do
      model = create_model!(%{model_id: "deprecatable", state: :active})

      {:ok, view, _html} = live(conn, "/console/models")

      view
      |> element("#model-#{model.id} button", "Deprecate")
      |> render_click()

      html = render(view)
      assert html =~ "Deprecated deprecatable@main."

      row = view |> element("#model-#{model.id}") |> render()
      assert row =~ "deprecated"
      assert row =~ "Activate"
    end

    test "retire transitions model and removes all actions", %{conn: conn} do
      model = create_model!(%{model_id: "retirable", state: :active})

      {:ok, view, _html} = live(conn, "/console/models")

      view
      |> element("#model-#{model.id} button", "Retire")
      |> render_click()

      html = render(view)
      assert html =~ "Retired retirable@main."

      row = view |> element("#model-#{model.id}") |> render()
      assert row =~ "retired"
      refute row =~ "Activate"
      refute row =~ "Deprecate"
      refute row =~ "Retire"
    end
  end

  describe "error handling" do
    test "shows error flash when model state changed behind the UI", %{conn: conn} do
      model = create_model!(%{model_id: "stale-model", state: :registered})

      {:ok, view, _html} = live(conn, "/console/models")

      # Mutate state behind the LiveView's back (simulate concurrent operator)
      {:ok, _} = Orchard.Models.retire_model(model.id)

      # Click Activate on the now-stale row
      view
      |> element("#model-#{model.id} button", "Activate")
      |> render_click()

      html = render(view)
      assert html =~ "Unable to update model:"

      # Row should show current (retired) state after reload
      row = view |> element("#model-#{model.id}") |> render()
      assert row =~ "retired"
    end
  end

  describe "navigation" do
    test "marks Models as active nav item", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/models")

      assert html =~ ~s(aria-current="page")
      assert html =~ "text-navy"
    end

    test "renders app shell with sidebar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/models")

      assert html =~ "sidebar-toggle"
      assert html =~ "Orchard"
      assert html =~ "/console/playground"
    end
  end
end
