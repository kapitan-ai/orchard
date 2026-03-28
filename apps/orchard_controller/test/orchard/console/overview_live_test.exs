defmodule OrchardConsole.OverviewLiveTest.RuntimeStub do
  @moduledoc false

  def snapshot(_opts \\ []) do
    {:ok,
     %{
       worker_state: :idle,
       loaded_models: [%{model_id: "mlx-community/phi-3", version: "main"}],
       active_request_count: 1,
       node_metadata: %{
         node_id: "550e8400-e29b-41d4-a716-446655440000",
         display_name: "mawarduri",
         hostname: "mawarduri.local",
         listen_host: "127.0.0.1",
         listen_port: 50071,
         agent_version: "0.1.0",
         worker_backend: "mlx"
       },
       runtime_health: %{
         ready: true,
         health_code: nil,
         health_message: nil,
         affected_model: nil
       }
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub do
  @moduledoc false

  def snapshot(_opts \\ []) do
    {:error,
     %{
       status: :unavailable,
       code: "node_unavailable",
       message: "node runtime is unavailable",
       worker_state: :unknown,
       loaded_models: [],
       active_request_count: 0,
       node_metadata: nil,
       runtime_health: nil
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub do
  @moduledoc false

  def snapshot(_opts \\ []) do
    {:ok,
     %{
       worker_state: :idle,
       loaded_models: [],
       active_request_count: 0,
       node_metadata: nil,
       runtime_health: nil
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest.RuntimeStartingStub do
  @moduledoc false

  def snapshot(_opts \\ []) do
    {:ok,
     %{
       worker_state: :starting,
       loaded_models: [%{model_id: "mlx-community/phi-3", version: "main"}],
       active_request_count: 0,
       node_metadata: nil,
       runtime_health: nil
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest.RuntimeUnhealthyStub do
  @moduledoc false

  def snapshot(_opts \\ []) do
    {:ok,
     %{
       worker_state: :idle,
       loaded_models: [%{model_id: "mlx-community/phi-3", version: "main"}],
       active_request_count: 0,
       node_metadata: %{
         node_id: "550e8400-e29b-41d4-a716-446655440000",
         display_name: "mawarduri",
         hostname: "mawarduri.local",
         listen_host: "127.0.0.1",
         listen_port: 50071,
         agent_version: "0.1.0",
         worker_backend: "mlx"
       },
       runtime_health: %{
         ready: false,
         health_code: "worker_error",
         health_message: "Worker process crashed",
         affected_model: "mlx-community/phi-3@main"
       }
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest.RuntimeDegradedStub do
  @moduledoc false

  def snapshot(_opts \\ []) do
    {:ok,
     %{
       worker_state: :busy,
       loaded_models: [%{model_id: "mlx-community/phi-3", version: "main"}],
       active_request_count: 1,
       node_metadata: %{
         node_id: "550e8400-e29b-41d4-a716-446655440000",
         display_name: "mawarduri",
         hostname: "mawarduri.local",
         listen_host: "127.0.0.1",
         listen_port: 50071,
         agent_version: "0.1.0",
         worker_backend: "mlx"
       },
       runtime_health: %{
         ready: true,
         health_code: "high_memory",
         health_message: "Worker memory usage above threshold",
         affected_model: nil
       }
     }}
  end
end

defmodule OrchardConsole.OverviewLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Governance
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
      assert html =~ "Nodes"
      assert html =~ "Playground"
      assert html =~ "Models"
      assert html =~ "Model Hub"
      assert html =~ "Tenants"
      assert html =~ "Requests"
    end

    test "marks Overview as active nav item", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ ~s(aria-current="page")
    end

    test "all sidebar nav items are enabled", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      refute html =~ ~s(aria-disabled="true")
      refute html =~ "coming soon"
      assert html =~ "/console/nodes"
      assert html =~ "/console/playground"
      assert html =~ "/console/models"
      assert html =~ "/console/model-hub"
      assert html =~ "/console/requests"
      assert html =~ "/console/tenants"
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

    test "shows node display name from metadata", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      node_html = view |> element("#overview-runtime-node") |> render()
      assert node_html =~ "Connected node:"
      assert node_html =~ "mawarduri"
    end

    test "shows fallback when node metadata is absent", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub)

      {:ok, view, _html} = live(conn, "/console")

      node_html = view |> element("#overview-runtime-node") |> render()
      assert node_html =~ "Metadata unavailable"
    end

    test "shows 'Runtime unavailable' for node when runtime is down", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)

      {:ok, view, _html} = live(conn, "/console")

      node_html = view |> element("#overview-runtime-node") |> render()
      assert node_html =~ "Runtime unavailable"
    end

    test "Open Nodes CTA links to /console/nodes", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ ~s(id="overview-open-nodes")
      assert html =~ "/console/nodes"
      assert html =~ "Open Nodes"
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

  describe "quickstart state" do
    test "renders server-derived baseline in default test env", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      assert has_element?(view, "#overview-quickstart")
      assert_quickstart_status(view, "system-healthy", "current")
      assert_quickstart_status(view, "import-first-model", "pending")
      assert_quickstart_status(view, "run-test-request", "pending")
      assert_quickstart_status(view, "create-api-key", "pending")
    end
  end

  describe "quickstart state with passing readiness" do
    setup do
      prev_transport = Application.get_env(:orchard_controller, :transport_degraded)
      prev_db = Application.get_env(:orchard_controller, :enable_db_checks)
      prev_repo = Application.get_env(:orchard_controller, :start_repo)

      Application.put_env(:orchard_controller, :transport_degraded, false)
      Application.put_env(:orchard_controller, :enable_db_checks, true)
      Application.put_env(:orchard_controller, :start_repo, true)

      on_exit(fn ->
        Application.put_env(:orchard_controller, :transport_degraded, prev_transport)
        Application.put_env(:orchard_controller, :enable_db_checks, prev_db)
        Application.put_env(:orchard_controller, :start_repo, prev_repo)
      end)

      :ok
    end

    test "orders incomplete steps deterministically when readiness passes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      assert_quickstart_status(view, "system-healthy", "completed")
      assert_quickstart_status(view, "import-first-model", "current")
      assert_quickstart_status(view, "run-test-request", "pending")
      assert_quickstart_status(view, "create-api-key", "pending")
    end

    test "recomputes quickstart progression after refresh-driven model, request, and api key updates",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      create_model!(%{state: :active})
      send(view.pid, :refresh_overview)
      render(view)

      assert_quickstart_status(view, "system-healthy", "completed")
      assert_quickstart_status(view, "import-first-model", "completed")
      assert_quickstart_status(view, "run-test-request", "current")
      assert_quickstart_status(view, "create-api-key", "pending")

      create_request!(%{state: :completed})
      send(view.pid, :refresh_overview)
      render(view)

      assert_quickstart_status(view, "run-test-request", "completed")
      assert_quickstart_status(view, "create-api-key", "current")

      suffix = System.unique_integer([:positive, :monotonic])

      {:ok, tenant} =
        Governance.create_tenant(%{
          slug: "quickstart-tenant-#{suffix}",
          name: "Quickstart Tenant #{suffix}"
        })

      {:ok, _api_key} = Governance.create_api_key(tenant.id, %{name: "Quickstart Key"})
      send(view.pid, :refresh_overview)
      render(view)

      assert_quickstart_status(view, "create-api-key", "completed")
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

      html_before = render(view)

      create_request!(%{state: :completed})

      view |> element("#overview-refresh-now") |> render_click()
      html_after = render(view)

      assert html_after =~ "Last updated"
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

  describe "runtime health badges" do
    test "shows Unhealthy badge when runtime_health.ready is false", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnhealthyStub)

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Unhealthy"
    end

    test "shows Degraded badge when health_code is present", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeDegradedStub)

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Degraded"
    end

    test "unsupported health (nil) falls back to worker-state badge", %{conn: conn} do
      # RuntimeNoModelsStub has runtime_health: nil — should show worker-state label
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub)

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Idle"
      refute html =~ "Unhealthy"
      # NOTE: "Degraded" appears in the readiness badge (test env has :error readiness),
      # so we only check that "Unhealthy" is absent — the Idle assertion proves fallback.
    end
  end

  describe "health-aware hero status copy" do
    # NOTE: In test env, readiness.status is :error because public_api_https_enabled
    # check fails. These tests verify health-aware copy with degraded readiness.

    test "shows unhealthy copy when readiness degraded and runtime unhealthy", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnhealthyStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "readiness is failing"
      assert copy =~ "unhealthy"
      assert copy =~ "text-red-600"
    end

    test "shows degraded copy when readiness degraded and runtime health degraded", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeDegradedStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "readiness checks are failing"
      assert copy =~ "degraded health"
      assert copy =~ "text-amber-700"
    end

    test "healthy runtime_health does not change existing behavior", %{conn: conn} do
      # Default RuntimeStub has ready: true, no health_code/health_message
      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      # Should fall through to worker-state copy (readiness degraded + runtime ok + idle)
      assert copy =~ "Runtime is reachable"
      assert copy =~ "readiness checks are failing"
      refute copy =~ "unhealthy"
      refute copy =~ "degraded health"
    end
  end

  describe "ready+health hero status copy" do
    # Force readiness to :ok by disabling transport_degraded.
    # This exercises the hero_health_copy/2 and hero_worker_state_copy/2 branches.
    setup do
      # Force all readiness checks to pass so readiness.status == :ok
      prev_transport = Application.get_env(:orchard_controller, :transport_degraded)
      prev_db = Application.get_env(:orchard_controller, :enable_db_checks)
      prev_repo = Application.get_env(:orchard_controller, :start_repo)

      Application.put_env(:orchard_controller, :transport_degraded, false)
      Application.put_env(:orchard_controller, :enable_db_checks, true)
      Application.put_env(:orchard_controller, :start_repo, true)

      on_exit(fn ->
        Application.put_env(:orchard_controller, :transport_degraded, prev_transport)
        Application.put_env(:orchard_controller, :enable_db_checks, prev_db)
        Application.put_env(:orchard_controller, :start_repo, prev_repo)
      end)

      :ok
    end

    test "ready + healthy runtime shows system-ready copy", %{conn: conn} do
      # Default RuntimeStub: idle, loaded model, healthy runtime_health
      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "System ready"
      assert copy =~ "text-slate-600"
      refute copy =~ "unhealthy"
      refute copy =~ "degraded"
    end

    test "ready + unhealthy runtime shows health warning", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnhealthyStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "passing"
      assert copy =~ "unhealthy"
      assert copy =~ "text-red-600"
    end

    test "ready + degraded runtime shows degraded warning", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeDegradedStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "passing"
      assert copy =~ "degraded health"
      assert copy =~ "text-amber-700"
    end

    test "ready + unsupported health falls back to worker-state copy", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      # runtime_health is nil -> falls through to worker-state
      assert copy =~ "no model is currently loaded"
      assert copy =~ "text-amber-700"
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

  defp assert_quickstart_status(view, step_dom_id, status) do
    assert has_element?(
             view,
             "#overview-quickstart-step-#{step_dom_id}[data-status=\"#{status}\"]"
           )
  end
end
