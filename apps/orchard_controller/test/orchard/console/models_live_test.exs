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

    test "renders empty state when no models exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/models")
      assert html =~ "No models imported yet."
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
