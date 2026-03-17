defmodule OrchardConsole.OverviewLiveTest.RuntimeStub do
  @moduledoc false

  def snapshot do
    {:ok,
     %{
       worker_state: :idle,
       loaded_models: [%{model_id: "mlx-community/phi-3", version: "main"}],
       active_request_count: 1
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub do
  @moduledoc false

  def snapshot do
    {:error,
     %{
       status: :unavailable,
       code: "node_unavailable",
       message: "node runtime is unavailable",
       worker_state: :unknown,
       loaded_models: [],
       active_request_count: 0
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub do
  @moduledoc false

  def snapshot do
    {:ok,
     %{
       worker_state: :idle,
       loaded_models: [],
       active_request_count: 0
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest.RuntimeStartingStub do
  @moduledoc false

  def snapshot do
    {:ok,
     %{
       worker_state: :starting,
       loaded_models: [%{model_id: "mlx-community/phi-3", version: "main"}],
       active_request_count: 0
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  import Orchard.TestSupport.ModelRequestFixtures

  @moduletag :live
  @moduletag :db

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeStub,
        refresh_interval_ms: 60_000
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)

    # LiveView runs in a separate process; share the DB sandbox
    Sandbox.mode(Orchard.Repo, {:shared, self()})
    :ok
  end

  describe "GET /console" do
    test "renders overview page with section titles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "System Status"
      assert html =~ "Readiness"
      assert html =~ "Runtime Snapshot"
      assert html =~ "Model Catalog"
      assert html =~ "Request Counts"
    end

    test "has correct page title with suffix", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Overview \u2014 Orchard Console"
    end

    test "includes brand bar", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ ~s(id="brand-bar")
      assert html =~ "brand-bar"
    end

    test "includes favicon meta", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "favicon-32x32.png"
    end
  end

  describe "app shell" do
    test "renders sidebar with logo lockup", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "console-sidebar"
      assert html =~ "icon-192.png"
      assert html =~ "Orchard"
      assert html =~ "font-mono"
    end

    test "renders sidebar navigation with all items", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Overview"
      assert html =~ "Playground"
      assert html =~ "Models"
      assert html =~ "Requests"
    end

    test "marks Overview as active nav item", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ ~s(aria-current="page")
    end

    test "marks future pages as disabled", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      # Only Requests is still disabled
      assert html =~ ~s(aria-disabled="true")
      assert html =~ "Requests \u2014 coming soon"
      # Playground and Models are now enabled
      assert html =~ "/console/playground"
      assert html =~ "/console/models"
      refute html =~ "Playground \u2014 coming soon"
      refute html =~ "Models \u2014 coming soon"
    end

    test "renders sidebar toggle button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "sidebar-toggle"
      assert html =~ "Toggle sidebar"
    end

    test "renders page header with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "<h1"
      assert html =~ "Overview"
    end

    test "sidebar toggle button has JS toggle_class command wired", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "sidebar-toggle"
      assert html =~ "phx-click"
      assert html =~ "sidebar-collapsed"
      assert html =~ "console-shell"
    end
  end

  describe "runtime snapshot" do
    test "renders runtime data from stub", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Idle"
      assert html =~ "mlx-community/phi-3"
      assert html =~ "1 active request"
    end

    test "renders degraded state when runtime is unavailable", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)

      {:ok, view, html} = live(conn, "/console")

      assert html =~ "Unavailable"
      assert html =~ "node runtime is unavailable"

      # Uses shared state_message component
      unavailable = view |> element("#overview-runtime-unavailable") |> render()
      assert unavailable =~ "Runtime unavailable."
      assert unavailable =~ "node runtime is unavailable"
    end
  end

  describe "readiness" do
    test "renders readiness checks", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "controller_boot_completed"
      assert html =~ "postgres_reachable"
      assert html =~ "migrations_current"
      assert html =~ "public_api_https_enabled"
    end
  end

  describe "model and request data" do
    test "renders model catalog counts", %{conn: conn} do
      create_model!(%{model_id: "m1", state: :registered})
      create_model!(%{model_id: "m2", state: :active})

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Model Catalog"
      assert html =~ "registered"
      assert html =~ "active"
    end

    test "renders request summary counts", %{conn: conn} do
      create_request!(%{public_id: "r1", state: :running})
      create_request!(%{public_id: "r2", state: :completed})

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Request Counts"
      assert html =~ "running"
      assert html =~ "completed"
      assert html =~ "1 active"
      assert html =~ "1 terminal"
    end

    test "renders zero counts when no data exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Model Catalog"
      assert html =~ "Request Counts"
      # All states present with zero
      assert html =~ "registered"
      assert html =~ "received"
    end
  end

  describe "polling refresh" do
    test "handle_info(:refresh_overview) updates DOM with new data", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console")

      # Initial state: zero requests
      assert html =~ "0 active"
      assert html =~ "0 terminal"

      # Insert data after mount
      create_request!(%{public_id: "r-refresh-1", state: :running})
      create_request!(%{public_id: "r-refresh-2", state: :completed})

      # Trigger refresh directly
      send(view.pid, :refresh_overview)

      # Re-render and assert updated counts
      html = render(view)
      assert html =~ "1 active"
      assert html =~ "1 terminal"
    end

    test "invalid refresh_interval_ms config does not crash the LiveView", %{conn: conn} do
      for bad_value <- ["5000", 1.5, 0, -1, :fast, nil] do
        put_console_config(refresh_interval_ms: bad_value)
        {:ok, _view, html} = live(conn, "/console")
        assert html =~ "System Status", "crashed with refresh_interval_ms: #{inspect(bad_value)}"
      end
    end
  end

  describe "LiveView mount with basic auth" do
    setup do
      put_console_config(
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

      assert html =~ "System Status"
    end
  end

  describe "on_mount hook denials" do
    test "denies when basic auth marker is missing" do
      put_console_config(
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
      put_console_config(
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
      session = %{}
      socket = %Phoenix.LiveView.Socket{}

      assert {:cont, %Phoenix.LiveView.Socket{}} =
               OrchardConsole.on_mount(:ensure_console_access, %{}, session, socket)
    end
  end

  # ===========================================================================
  # Connection banner and freshness (Task 3)
  # ===========================================================================

  describe "connection banner and freshness" do
    test "shell includes connection banner markup", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "console-connection-banner"
      assert html =~ "Live connection lost"
      assert html =~ "reconnecting"
    end

    test "shell body has connection state data attributes", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ ~s(data-lv-connected-once="false")
      assert html =~ ~s(data-lv-connection-state="connecting")
    end

    test "overview renders freshness row with auto-refresh text", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "overview-freshness"
      assert html =~ "Auto-refreshing every 60s"
      assert html =~ "Last updated"
      assert html =~ "UTC"
    end

    test "overview renders manual refresh button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "overview-refresh-now"
      assert html =~ "Refresh now"
    end

    test "manual refresh updates overview data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      # Capture pre-refresh state
      html_before = render(view)

      # Create a request so counts change
      create_request!(%{state: :completed})

      # Click refresh
      view |> element("#overview-refresh-now") |> render_click()
      html_after = render(view)

      # Total requests count should have changed (pre vs post)
      assert html_after =~ "Last updated"
      # The count changed from the initial render
      refute html_before == html_after
    end
  end

  # ===========================================================================
  # Hero polish (Task 5)
  # ===========================================================================

  describe "hero primary model" do
    test "shows loaded model ID and version with correct label", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      field = view |> element("#overview-primary-model") |> render()

      assert field =~ "mlx-community/phi-3@main"
      assert field =~ "Loaded model:"
      refute field =~ "Primary model:"
    end

    test "shows fallback when no models loaded", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub)

      {:ok, view, _html} = live(conn, "/console")
      field = view |> element("#overview-primary-model") |> render()

      assert field =~ "No model loaded"
    end

    test "shows unavailable when runtime is down", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)

      {:ok, view, _html} = live(conn, "/console")
      field = view |> element("#overview-primary-model") |> render()

      assert field =~ "Runtime unavailable"
    end
  end

  describe "hero status copy" do
    # NOTE: In test env, readiness.status is :error because public_api_https_enabled
    # check fails (no HTTPS in test). Hero copy reflects this combined state.

    test "shows readiness-degraded copy when runtime is healthy", %{conn: conn} do
      # Default RuntimeStub: idle + loaded model, but readiness is degraded in test
      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "Runtime is reachable"
      assert copy =~ "readiness checks are failing"
    end

    test "shows fully-degraded copy when runtime is unavailable", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "System is degraded"
      assert copy =~ "readiness is failing"
      assert copy =~ "runtime is unavailable"
    end

    test "applies severity color class based on state", %{conn: conn} do
      # Readiness degraded + runtime ok → amber warning
      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()
      assert copy =~ "text-amber-700"

      # Both degraded → red
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)
      {:ok, view2, _html} = live(conn, "/console")
      copy2 = view2 |> element("#overview-hero-status-copy") |> render()
      assert copy2 =~ "text-red-600"
    end

    test "shows transitional copy when readiness degraded and runtime is starting", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeStartingStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "readiness checks are failing"
      assert copy =~ "Runtime is transitioning"
      # Must NOT fall through to unavailable/degraded
      refute copy =~ "runtime is unavailable"
      refute copy =~ "System is degraded"
      # Amber warning, not red
      assert copy =~ "text-amber-700"
      refute copy =~ "text-red-600"
    end
  end

  describe "hero CTA links" do
    test "renders Open Playground link to /console/playground", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      link = view |> element("#overview-open-playground") |> render()

      assert link =~ "Open Playground"
      assert link =~ "/console/playground"
    end

    test "renders Open Models link to /console/models", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      link = view |> element("#overview-open-models") |> render()

      assert link =~ "Open Models"
      assert link =~ "/console/models"
    end

    test "CTA links render even when runtime is unavailable", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)

      {:ok, view, _html} = live(conn, "/console")

      assert view |> element("#overview-open-playground") |> render() =~ "Open Playground"
      assert view |> element("#overview-open-models") |> render() =~ "Open Models"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp put_console_config(overrides) do
    current = Application.get_env(:orchard_controller, :console, [])
    Application.put_env(:orchard_controller, :console, Keyword.merge(current, overrides))
  end
end
