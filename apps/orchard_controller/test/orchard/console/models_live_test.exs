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
    test "Catalog combines session imports with durable models and preserves their distinction",
         %{conn: conn} do
      create_model!(%{model_id: "stored/model", state: :active})
      {:ok, view, _html} = live(conn, "/console/models/catalog")

      for status <- [:downloading, :paused, :cancelled, :completed] do
        repo = "publisher/#{status}"

        send(
          view.pid,
          {:model_hub_download,
           %{
             key: {repo, "pinned"},
             repo_id: repo,
             status: status,
             progress: %{bytes_downloaded: 256},
             result: nil,
             error: nil
           }}
        )
      end

      assert has_element?(
               view,
               "#catalog-import-activity",
               "Transfer history lasts until this Controller restarts"
             )

      for label <- ["Downloading", "Paused", "Cancelled", "Imported"] do
        assert has_element?(view, "#catalog-imports-list", label)
      end

      assert has_element?(view, "#models-catalog", "stored/model")

      assert has_element?(
               view,
               "#catalog-imports-list a[href*='/console/models/catalog/import?']"
             )

      send(view.pid, {:model_hub_download_removed, {"publisher/cancelled", "pinned"}})
      refute has_element?(view, "#catalog-imports-list", "publisher/cancelled")
      assert has_element?(view, "#models-catalog", "stored/model")
      assert has_element?(view, "#models-navigation a[aria-current=page]", "Catalog")
      refute has_element?(view, "#models-navigation", "Your models")
    end

    test "Catalog alias provides direct access to the empty Catalog and discovery", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/models/catalog")
      assert has_element?(view, "#catalog-imports-empty")
      assert has_element?(view, "#models-empty-state")

      assert has_element?(
               view,
               "#models-navigation a[href='/console/models/discover']",
               "Discover"
             )
    end

    test "renders page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/models")
      assert html =~ "Catalog \u2014 Orchard Console"
    end

    test "empty catalog offers Discover and retains the offline bundle path", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/models")
      assert html =~ "No models imported yet."
      assert html =~ "orchardctl models import"
      assert html =~ "bundle-path"

      assert has_element?(
               view,
               ~s(#models-empty-state a[href="/console/models/discover"]),
               "Discover models"
             )

      # Uses shared state_message component
      empty = view |> element("#models-empty-state") |> render()
      assert empty =~ "No models imported yet."
    end

    test "renders catalog table with model data", %{conn: conn} do
      digest = String.duplicate("d", 64)

      create_model!(%{
        model_id: "mlx-community/phi-3",
        version: "revision-phi-3",
        artifact_sha256: digest,
        state: :active,
        format: "mlx"
      })

      create_model!(%{model_id: "mlx-community/llama-2", state: :registered, format: "mlx"})

      {:ok, _view, html} = live(conn, "/console/models")

      assert html =~ "Catalog"
      assert html =~ "mlx-community/phi-3"
      assert html =~ "mlx-community/llama-2"
      assert html =~ "revision-phi-3"
      assert html =~ "Bundle SHA-256"
      assert html =~ digest
      assert html =~ "Catalog state"
      assert html =~ "Manage catalog visibility"
      assert html =~ "Active models still need access authorization and a ready Node"
      # Imported column uses LocalTime hook
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-local-time-format="datetime_minute")
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

    test "renders one Models sidebar item with Catalog and Discover subnavigation", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console/models")

      assert has_element?(view, ~s(a[aria-current="page"][href="/console/models"]))

      assert has_element?(
               view,
               ~s(#models-navigation a[aria-current="page"][href="/console/models"]),
               "Catalog"
             )

      assert has_element?(
               view,
               ~s(#models-navigation a[href="/console/models/discover"]),
               "Discover"
             )

      refute render(view) =~ "Model Hub"
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

    test "shows Delete action for retired model", %{conn: conn} do
      model = create_model!(%{model_id: "retired-model", state: :retired})

      {:ok, view, _html} = live(conn, "/console/models")
      row = view |> element("#model-#{model.id}") |> render()

      # Delete is shown, lifecycle transitions are not
      assert row =~ "Delete"
      refute row =~ "Activate"
      refute row =~ "Deprecate"
      refute row =~ "Retire"
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

    test "retire transitions model and shows Delete action", %{conn: conn} do
      model = create_model!(%{model_id: "retirable", state: :active})

      {:ok, view, _html} = live(conn, "/console/models")

      view
      |> element("#model-#{model.id} button", "Retire")
      |> render_click()

      html = render(view)
      assert html =~ "Retired retirable@main."

      row = view |> element("#model-#{model.id}") |> render()
      assert row =~ "retired"
      assert row =~ "Delete"
      refute row =~ "Activate"
      refute row =~ "Deprecate"
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

  describe "delete actions" do
    test "clicking Delete on retired model with no requests removes row and shows flash", %{
      conn: conn
    } do
      model = create_model!(%{model_id: "delete-me", state: :retired})
      _keeper = create_model!(%{model_id: "keep-me", state: :active})

      {:ok, view, _html} = live(conn, "/console/models")

      # Retired row shows Delete button
      assert has_element?(view, "#model-#{model.id} button", "Delete")

      view
      |> element("#model-#{model.id} button", "Delete")
      |> render_click()

      html = render(view)
      assert html =~ "Deleted delete-me@main."
      refute has_element?(view, "#model-#{model.id}")

      # Summary updated
      retired_tile = view |> element("#models-summary-retired") |> render()
      assert retired_tile =~ "0"
    end

    test "clicking Delete on retired model with non-terminal requests shows error", %{conn: conn} do
      model = create_model!(%{model_id: "in-use-model", state: :retired})

      _running_req =
        create_request!(%{
          model_id: model.id,
          requested_model: "in-use-model@main",
          state: :running
        })

      {:ok, view, _html} = live(conn, "/console/models")

      view
      |> element("#model-#{model.id} button", "Delete")
      |> render_click()

      html = render(view)
      assert html =~ "Cannot delete: 1 non-terminal request(s) still reference it."

      # Row remains
      assert has_element?(view, "#model-#{model.id}")
      assert has_element?(view, "#model-#{model.id} button", "Delete")
    end

    test "stale Delete after model un-retired shows not-retired error", %{conn: conn} do
      model = create_model!(%{model_id: "stale-delete", state: :retired})

      {:ok, view, _html} = live(conn, "/console/models")

      # Model is still showing Delete button
      assert has_element?(view, "#model-#{model.id} button", "Delete")

      # Direct DB update to simulate state change behind the LiveView
      # (retired is terminal, so normal API can't un-retire)
      import Ecto.Query

      Orchard.Repo.update_all(
        from(m in Orchard.Models.Model, where: m.id == ^model.id),
        set: [state: :active]
      )

      # Click the now-stale Delete button
      view
      |> element("#model-#{model.id} button", "Delete")
      |> render_click()

      html = render(view)
      assert html =~ "Only retired models can be deleted."

      # Row reloaded with current state
      row = view |> element("#model-#{model.id}") |> render()
      assert row =~ "active"
      refute row =~ "Delete"
      assert row =~ "Deprecate"
    end

    test "summary counts update after delete", %{conn: conn} do
      model = create_model!(%{model_id: "summary-delete", state: :retired})
      _other = create_model!(%{model_id: "summary-keep", state: :registered})

      {:ok, view, _html} = live(conn, "/console/models")

      # Before: total 2, retired 1
      total_tile = view |> element("#models-summary-total") |> render()
      assert total_tile =~ "2"

      view
      |> element("#model-#{model.id} button", "Delete")
      |> render_click()

      # After: total 1, retired 0
      total_tile = view |> element("#models-summary-total") |> render()
      assert total_tile =~ "1"
      retired_tile = view |> element("#models-summary-retired") |> render()
      assert retired_tile =~ "0"
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
