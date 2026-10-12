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
         listen_port: 50_071,
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
         listen_port: 50_071,
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
         listen_port: 50_071,
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
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.API.Endpoint
  alias Orchard.Governance
  alias Orchard.Repo
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

    previous_mode = Application.get_env(:orchard_controller, :transport_mode)
    previous_cert_source = Application.get_env(:orchard_controller, :transport_cert_source)
    previous_degraded = Application.get_env(:orchard_controller, :transport_degraded)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      Application.put_env(:orchard_controller, :transport_mode, previous_mode)
      Application.put_env(:orchard_controller, :transport_cert_source, previous_cert_source)
      Application.put_env(:orchard_controller, :transport_degraded, previous_degraded)
    end)

    # LiveView runs in a separate process; share the DB sandbox
    Sandbox.mode(Orchard.Repo, {:shared, self()})
    :ok
  end

  describe "GET /console" do
    test "renders overview page with section titles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Operational status"
      assert html =~ "Controller readiness"
      assert html =~ "Default Runtime Endpoint"
      assert html =~ "Catalog lifecycle"
      assert html =~ "Current Request states"
    end

    test "orders operational facts before setup and keeps exactly six scoped metrics", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/console")

      ids =
        ~w(overview-status overview-metrics overview-quickstart overview-requests overview-runtime overview-controller overview-catalog overview-open-playground)

      positions = Enum.map(ids, &:binary.match(html, ~s(id="#{&1}")))
      assert Enum.all?(positions, &match?({_, _}, &1))
      assert positions == Enum.sort(positions)

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#overview-metrics .grid > [id]")
             |> Enum.count() == 6

      assert has_element?(view, ~s(#overview-hero-status-copy[role="status"][aria-live="polite"]))
      refute has_element?(view, "#overview-metric-definitions details[open]")

      for destination <- ~w(playground nodes models requests) do
        assert has_element?(
                 view,
                 ~s(#overview-open-#{destination}[href="/console/#{destination}"])
               )
      end
    end

    test "retains source, scope and refresh qualifications beside independent evidence", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console")

      for {selector, text} <- [
            {"#overview-metric-checks-passing", "Controller readiness"},
            {"#overview-metric-loaded-models", "Default Runtime Endpoint"},
            {"#overview-metric-catalog-models", "Durable catalog"},
            {"#overview-metric-total-requests", "Durable Requests"},
            {"#overview-runtime", "default target only"},
            {"#overview-runtime", "observed at last refresh"},
            {"#overview-runtime", "Not fleet-wide schedulability"},
            {"#overview-controller", "this Controller"},
            {"#overview-controller", "checked at last refresh"},
            {"#overview-catalog", "installation-wide"},
            {"#overview-catalog", "Lifecycle is not loadedness or access"},
            {"#overview-requests", "durable Request rows"},
            {"#overview-requests", "Current distribution, not history"},
            {"#overview-metric-definitions",
             "refresh time does not certify that every source succeeded"}
          ] do
        assert has_element?(view, selector, text)
      end

      # SPEC §3.1: a recorded failing readiness predicate is not an unavailable read.
      assert has_element?(view, "#overview-metric-checks-passing", "Recorded")
      refute has_element?(view, "#overview-metric-checks-passing", "Unavailable")
    end

    test "pre-connect loading never renders missing evidence as zero", %{conn: conn} do
      html = get(conn, "/console").resp_body

      for metric <-
            ~w(checks-passing loaded-models catalog-models total-requests avg-ttft avg-tokens-per-second) do
        text = fragment_text(html, "#overview-metric-#{metric}")
        assert text =~ "—"
        assert text =~ "Loading"
        refute text =~ "Recorded"
      end

      assert fragment_text(html, "#overview-runtime-active-requests") =~ "—"
      assert fragment_text(html, "#overview-runtime-health") =~ "Loading"
      assert fragment_text(html, "#overview-readiness") =~ "Unknown"
      assert fragment_text(html, "#overview-freshness") =~ "Waiting for first live update"
      refute html =~ "Auto-refreshing every"

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#overview-refresh-now[disabled][aria-disabled=true]")
             |> Enum.any?()

      refute html =~ ~s(id="overview-request-counts")
      refute html =~ ~s(id="overview-model-counts")
      assert html =~ ~s(id="overview-quickstart-hydrating")
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

      assert html =~ "orchard-mark.svg"
      assert html =~ "favicon-32x32.png"
    end
  end

  describe "app shell" do
    test "renders sidebar with logo lockup", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "console-sidebar"
      assert html =~ "orchard-logo"
      assert html =~ "orchard-mark"
      assert html =~ "orchard-dot--gold"
      assert html =~ "Orchard"
    end

    test "renders sidebar navigation with all items", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console")

      assert html =~ "Overview"
      assert html =~ "Nodes"
      assert html =~ "Playground"
      assert has_element?(view, ~s(#console-sidebar a[href="/console/models"]), "Models")
      refute has_element?(view, ~s(#console-sidebar a[href="/console/model-hub"]), "Model Hub")
      assert html =~ "Access"
      assert html =~ "Requests"
    end

    test "marks Overview as active nav item", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ ~s(aria-current="page")
    end

    test "all sidebar nav items are enabled", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console")

      refute html =~ ~s(aria-disabled="true")
      refute html =~ "coming soon"
      assert html =~ "/console/nodes"
      assert html =~ "/console/playground"
      assert has_element?(view, ~s(#console-sidebar a[href="/console/models"]), "Models")
      refute has_element?(view, ~s(#console-sidebar a[href="/console/model-hub"]), "Model Hub")
      assert html =~ "/console/requests"
      assert html =~ "/console/access"
    end

    test "renders sidebar toggle button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "sidebar-toggle"
      assert html =~ "Toggle sidebar"
    end

    test "renders sidebar version label", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      assert has_element?(view, "#console-sidebar-version")
      version_html = view |> element("#console-sidebar-version") |> render()
      assert version_html =~ OrchardConsole.display_version()
      assert version_html =~ "sidebar-label"
    end

    test "sidebar mounts theme-toggle component", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ ~s(id="theme-toggle")
      assert html =~ ~s(phx-hook="ThemeToggle")
      assert html =~ ~s(data-theme-mode="system")
      assert html =~ ~s(data-theme-mode="light")
      assert html =~ ~s(data-theme-mode="dark")
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
      {:ok, view, html} = live(conn, "/console")

      assert html =~ "Idle"

      assert element(view, "#overview-primary-model") |> render() |> visible_text() =~
               "mlx-community/phi-3@main"

      assert has_element?(view, "#overview-runtime-active-requests dd", "1")
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

    test "failed runtime observation does not erase catalog or Request facts", %{conn: conn} do
      create_model!(%{state: :active})
      create_request!(%{state: :running})
      create_request!(%{state: :completed})
      create_request!(%{state: :completed})
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)

      {:ok, view, _html} = live(conn, "/console")

      assert has_element?(view, "#overview-metric-loaded-models", "—")
      assert has_element?(view, "#overview-metric-loaded-models", "Unavailable")
      assert has_element?(view, "#overview-runtime-active-requests dd", "—")
      assert has_element?(view, "#overview-metric-catalog-models .font-mono", "1")
      assert has_element?(view, "#overview-metric-total-requests .font-mono", "3")
      assert has_element?(view, "#overview-requests", "1 active")
      assert has_element?(view, "#overview-requests", "2 terminal")
      assert has_element?(view, "#overview-model-counts", "active")
      refute has_element?(view, "#overview-runtime-empty")
    end

    test "degraded runtime health retains the independently observed Worker state", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeDegradedStub)
      {:ok, view, _html} = live(conn, "/console")

      assert has_element?(view, "#overview-runtime-health dd", "Degraded")
      assert has_element?(view, "#overview-worker-state dd", "Busy")
      assert has_element?(view, "#overview-runtime-active-requests dd", "1")
      assert has_element?(view, "#overview-metric-loaded-models .font-mono", "1")
    end

    test "missing runtime health is not healthy and an observed empty model set is zero", %{
      conn: conn
    } do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub)
      {:ok, view, _html} = live(conn, "/console")

      assert has_element?(view, "#overview-runtime-health dd", "Not recorded")
      assert has_element?(view, "#overview-worker-state dd", "Idle")
      assert has_element?(view, "#overview-metric-loaded-models .font-mono", "0")
      assert has_element?(view, "#overview-runtime-active-requests dd", "0")
      assert has_element?(view, "#overview-runtime-empty")
    end

    test "shows node display name from metadata", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      node_html = view |> element("#overview-runtime-node") |> render()
      assert node_html =~ "Observed Node"
      assert node_html =~ "mawarduri"
    end

    test "shows fallback when node metadata is absent", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub)

      {:ok, view, _html} = live(conn, "/console")

      node_html = view |> element("#overview-runtime-node") |> render()
      assert node_html =~ "Not recorded"
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
    test "identifies the staged internal readiness contract without implying public detail", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Internal orchard.readiness.legacy_m0.v1 predicate"
      assert html =~ "public health responses are status-only"
    end

    test "renders readiness checks", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "controller_boot_completed"
      assert html =~ "postgres_reachable"
      assert html =~ "migrations_current"
      assert html =~ "public_api_https_enabled"
    end

    test "renders mode-aware public API transport copy for reverse proxy", %{conn: conn} do
      Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)
      Application.put_env(:orchard_controller, :transport_cert_source, :unknown)
      Application.put_env(:orchard_controller, :transport_degraded, true)

      {:ok, view, _html} = live(conn, "/console")

      readiness = view |> element("#overview-readiness") |> render()
      assert readiness =~ "Public API transport"
      assert readiness =~ "Reverse proxy HTTPS"
      assert readiness =~ "cert source: unknown"
    end

    test "renders degraded local HTTP copy for plain localhost mode", %{conn: conn} do
      Application.put_env(:orchard_controller, :transport_mode, :plain_http_localhost)
      Application.put_env(:orchard_controller, :transport_cert_source, :unknown)
      Application.put_env(:orchard_controller, :transport_degraded, false)

      {:ok, view, _html} = live(conn, "/console")

      readiness = view |> element("#overview-readiness") |> render()
      assert readiness =~ "Plain HTTP localhost"
      assert readiness =~ "local development or break-glass"
      assert readiness =~ "Blocked"
    end
  end

  describe "model and request data" do
    test "renders model catalog counts", %{conn: conn} do
      create_model!(%{model_id: "m1", state: :registered})
      create_model!(%{model_id: "m2", state: :active})

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Catalog lifecycle"
      assert html =~ "registered"
      assert html =~ "active"
    end

    test "renders request summary counts", %{conn: conn} do
      create_request!(%{public_id: "r1", state: :running})
      create_request!(%{public_id: "r2", state: :completed})

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Current Request states"
      assert html =~ "running"
      assert html =~ "completed"
      assert html =~ "1 active"
      assert html =~ "1 terminal"
    end

    test "renders zero counts when no data exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Catalog lifecycle"
      assert html =~ "Current Request states"
      # All states present with zero
      assert html =~ "registered"
      assert html =~ "received"
    end

    test "database read failures leave the independent runtime observation intact" do
      previous_repo = Repo.get_dynamic_repo()

      assigns =
        try do
          Repo.put_dynamic_repo(:overview_unavailable_repo)
          overview_assigns()
        after
          Repo.put_dynamic_repo(previous_repo)
        end

      html = render_component(&OrchardConsole.OverviewLive.render/1, assigns)

      for metric <- ~w(catalog-models total-requests avg-ttft avg-tokens-per-second) do
        assert fragment_text(html, "#overview-metric-#{metric}") =~ "—"
        assert fragment_text(html, "#overview-metric-#{metric}") =~ "Unavailable"
        refute fragment_text(html, "#overview-metric-#{metric}") =~ "Not recorded"
      end

      assert fragment_text(html, "#overview-metric-loaded-models .font-mono") == "1"
      assert fragment_text(html, "#overview-runtime-health dd") == "Healthy"
      assert fragment_text(html, "#overview-worker-state dd") == "Idle"
      assert fragment_text(html, "#overview-model-catalog-error") =~ "unavailable"
      assert fragment_text(html, "#overview-request-summary-error") =~ "unavailable"
    end

    test "a failed catalog projection does not collapse a successful Request projection, or vice versa" do
      create_model!(%{state: :active})
      create_request!(%{state: :running})
      create_request!(%{state: :completed})
      assigns = overview_assigns()

      for {source, missing_metric, retained_metric, retained_value} <- [
            {:model_catalog, "catalog-models", "total-requests", "2"},
            {:request_summary, "total-requests", "catalog-models", "1"}
          ] do
        failed = assigns[source] |> Map.merge(%{status: :error, total: nil, rows: []})

        html =
          render_component(
            &OrchardConsole.OverviewLive.render/1,
            Map.put(assigns, source, failed)
          )

        assert fragment_text(html, "#overview-metric-#{missing_metric}") =~ "Unavailable"
        assert fragment_text(html, "#overview-metric-#{missing_metric} .font-mono") == "—"

        assert fragment_text(html, "#overview-metric-#{retained_metric} .font-mono") ==
                 retained_value

        assert fragment_text(html, "#overview-runtime-health dd") == "Healthy"
        assert fragment_text(html, "#overview-metric-avg-ttft") =~ "Not recorded"
      end
    end

    test "unavailable Controller evidence is neither a zero count nor failing checks" do
      assigns = overview_assigns()

      readiness = %{
        assigns.readiness
        | status: :unavailable,
          passing: 0,
          rows: Enum.map(assigns.readiness.rows, &%{&1 | status: :unknown})
      }

      html =
        render_component(&OrchardConsole.OverviewLive.render/1, %{assigns | readiness: readiness})

      assert fragment_text(html, "#overview-metric-checks-passing .font-mono") == "—"
      assert fragment_text(html, "#overview-metric-checks-passing") =~ "Unavailable"

      assert fragment_text(html, "#overview-hero-status-copy") =~
               "Controller readiness is unavailable"

      refute fragment_text(html, "#overview-hero-status-copy") =~ "checks are failing"
      assert fragment_text(html, "#overview-runtime-health dd") == "Healthy"
      assert fragment_text(html, "#overview-metric-total-requests .font-mono") == "0"
    end
  end

  describe "quickstart state" do
    test "starts in a hydrating state until client quickstart prefs load", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console")

      assert html =~ ~s(id="overview-quickstart")
      assert html =~ ~s(phx-hook="OverviewQuickstart")
      assert_quickstart_hydrating(view)
    end

    test "renders server-derived baseline in default test env after hydration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      assert_quickstart_hydrating(view)
      hydrate_quickstart(view)

      assert_quickstart_visible(view)
      assert_quickstart_status(view, "system-healthy", "current")
      assert_quickstart_status(view, "import-first-model", "pending")
      assert_quickstart_status(view, "run-test-request", "pending")
      assert_quickstart_status(view, "create-api-key", "pending")
      assert_quickstart_status(view, "connect-your-tools", "pending")
    end

    test "Quickstart labels its actual evidence rather than implying runtime or tool qualification",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      hydrate_quickstart(view)

      assert has_element?(
               view,
               "#overview-quickstart-step-system-healthy",
               "Controller checks pass"
             )

      assert has_element?(
               view,
               "#overview-quickstart-step-import-first-model",
               "active catalog Model"
             )

      assert has_element?(
               view,
               "#overview-quickstart-step-run-test-request",
               "completed durable Request"
             )

      assert has_element?(
               view,
               "#overview-quickstart-step-create-api-key",
               "not model-specific access"
             )

      assert has_element?(
               view,
               "#overview-quickstart-step-connect-your-tools",
               "connection not verified"
             )
    end

    test "renders action links for incomplete steps after hydration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      hydrate_quickstart(view)

      # Current system-health row shows automatic note
      assert has_element?(view, "#overview-quickstart-note-system-healthy")
      refute has_element?(view, "#overview-quickstart-action-system-healthy")

      # Pending setup rows show navigation links
      assert has_element?(view, "#overview-quickstart-action-import-first-model")

      assert view |> element("#overview-quickstart-action-import-first-model") |> render() =~
               ~s(href="/console/models/discover")

      assert has_element?(view, "#overview-quickstart-action-run-test-request")

      assert view |> element("#overview-quickstart-action-run-test-request") |> render() =~
               ~s(href="/console/playground")

      assert has_element?(view, "#overview-quickstart-action-create-api-key")

      assert view |> element("#overview-quickstart-action-create-api-key") |> render() =~
               ~s(href="/console/tenants")

      # Pending integration-guide row dispatches the guide-open event, not a navigation link
      assert has_element?(view, "#overview-quickstart-action-connect-your-tools")

      step_5_action =
        view |> element("#overview-quickstart-action-connect-your-tools") |> render()

      assert step_5_action =~ "orchard:quickstart-guide:open"
      assert step_5_action =~ "#overview-quickstart-guide"
      refute step_5_action =~ ~s(data-quickstart-action="open-guide")

      # Pending steps have pending emphasis
      assert view |> element("#overview-quickstart-action-import-first-model") |> render() =~
               ~s(data-quickstart-action-emphasis="pending")
    end

    test "renders rich quickstart guide content after hydration", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      html = hydrate_quickstart(view)

      assert html =~ ~s(id="overview-quickstart-dismiss")
      assert html =~ ~s(data-quickstart-action="dismiss")
      assert_rich_quickstart_guide_content(view)
    end

    test "keeps quickstart visible when client state payload is missing or falsey", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      assert_quickstart_hydrating(view)

      hydrate_quickstart(view)
      assert_quickstart_visible(view)
      assert_quickstart_status(view, "connect-your-tools", "pending")

      hydrate_quickstart(view, %{
        "dismissed" => "0",
        "guide_seen" => "0"
      })

      assert_quickstart_visible(view)
      assert_quickstart_status(view, "connect-your-tools", "pending")

      hydrate_quickstart(view, %{"guide_seen" => "banana"})
      assert_quickstart_status(view, "connect-your-tools", "pending")
    end

    test "marks step 5 complete when guide state loads from client preferences", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      hydrate_quickstart(view, %{"guide_seen" => "1"})

      assert_quickstart_visible(view)
      assert_quickstart_status(view, "connect-your-tools", "completed")
    end

    test "uses checklist copy for dismissed incomplete quickstart state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      hydrate_quickstart(view, %{"dismissed" => "1"})

      assert_quickstart_dismissed(view)
      assert_quickstart_guide_accessible(view)
      assert_rich_quickstart_guide_content(view)
      assert render(view) =~ "You can restore the onboarding checklist at any time."
      assert render(view) =~ "Show checklist"
      assert render(view) =~ "without restoring the checklist"

      render_click(view, "quickstart_recover", %{})
      assert_quickstart_visible(view)

      render_click(view, "quickstart_dismiss", %{})
      assert_quickstart_dismissed(view)
      assert_quickstart_guide_accessible(view)
    end
  end

  describe "quickstart state with passing readiness" do
    setup do
      prev_mode = Application.get_env(:orchard_controller, :transport_mode)
      prev_transport = Application.get_env(:orchard_controller, :transport_degraded)
      prev_db = Application.get_env(:orchard_controller, :enable_db_checks)
      prev_repo = Application.get_env(:orchard_controller, :start_repo)

      Application.put_env(:orchard_controller, :transport_mode, :direct_https)
      Application.put_env(:orchard_controller, :transport_degraded, false)
      Application.put_env(:orchard_controller, :enable_db_checks, true)
      Application.put_env(:orchard_controller, :start_repo, true)

      on_exit(fn ->
        Application.put_env(:orchard_controller, :transport_mode, prev_mode)
        Application.put_env(:orchard_controller, :transport_degraded, prev_transport)
        Application.put_env(:orchard_controller, :enable_db_checks, prev_db)
        Application.put_env(:orchard_controller, :start_repo, prev_repo)
      end)

      :ok
    end

    test "unavailable evidence is not initial completion or an onboarding CTA" do
      previous_repo = Repo.get_dynamic_repo()

      assigns =
        try do
          Repo.put_dynamic_repo(:overview_unavailable_repo)
          overview_assigns()
        after
          Repo.put_dynamic_repo(previous_repo)
        end

      socket = %Phoenix.LiveView.Socket{assigns: assigns}

      {:noreply, socket} =
        OrchardConsole.OverviewLive.handle_event(
          "quickstart_client_state_loaded",
          %{"guide_seen" => true},
          socket
        )

      html = render_component(&OrchardConsole.OverviewLive.render/1, socket.assigns)
      assert socket.assigns.has_active_api_keys == :unavailable
      assert socket.assigns.quickstart.mode == :full

      for step <- ~w(import-first-model run-test-request create-api-key) do
        assert fragment_text(html, "#overview-quickstart-step-#{step}[data-status=unavailable]") =~
                 "Evidence unavailable"

        refute html =~ ~s(id="overview-quickstart-action-#{step}")
      end
    end

    test "recorded completion survives unknown reads but recorded clear reopens setup", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/console")
      complete_quickstart_server_steps(view)
      hydrate_quickstart(view, %{"guide_seen" => true})
      socket = :sys.get_state(view.pid).socket
      assert socket.assigns.quickstart.mode == :compact_completed
      previous_repo = Repo.get_dynamic_repo()

      refreshed =
        try do
          Repo.put_dynamic_repo(:overview_unavailable_repo)

          {:noreply, refreshed} =
            OrchardConsole.OverviewLive.handle_event("refresh_now", %{}, socket)

          Process.cancel_timer(refreshed.assigns.refresh_timer)
          refreshed
        after
          Repo.put_dynamic_repo(previous_repo)
        end

      assert refreshed.assigns.readiness.status == :unavailable
      assert refreshed.assigns.quickstart.mode == :compact_completed
      refute Enum.any?(refreshed.assigns.quickstart.steps, &(&1.status == :current))
      html = render_component(&OrchardConsole.OverviewLive.render/1, refreshed.assigns)

      assert fragment_text(html, "#overview-quickstart-completed") =~
               "Previously observed completion retained"

      assert fragment_text(html, "#overview-catalog") =~ "read failed at last attempt"

      Repo.update_all(Orchard.Models.Model, set: [state: :retired])

      {:noreply, cleared} =
        OrchardConsole.OverviewLive.handle_event("refresh_now", %{}, refreshed)

      Process.cancel_timer(cleared.assigns.refresh_timer)
      assert cleared.assigns.quickstart.mode == :full

      assert Enum.find(cleared.assigns.quickstart.steps, &(&1.id == :import_first_model)).status ==
               :current
    end

    test "orders incomplete steps deterministically when readiness passes", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      assert_quickstart_hydrating(view)
      hydrate_quickstart(view)

      assert_quickstart_status(view, "system-healthy", "completed")
      assert_quickstart_status(view, "import-first-model", "current")
      assert_quickstart_status(view, "run-test-request", "pending")
      assert_quickstart_status(view, "create-api-key", "pending")
      assert_quickstart_status(view, "connect-your-tools", "pending")
    end

    test "current step has prominent CTA and completed steps show checkmark indicator", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console")

      assert_quickstart_hydrating(view)
      hydrate_quickstart(view)

      # Completed system-health row shows checkmark indicator, no action
      assert has_element?(view, "#overview-quickstart-indicator-system-healthy")
      # Checkmark indicator contains the check SVG path
      assert view |> element("#overview-quickstart-indicator-system-healthy") |> render() =~
               "m4.5 12.75 6 6 9-13.5"

      refute has_element?(view, "#overview-quickstart-action-system-healthy")

      # Current import-model row has current emphasis
      assert has_element?(view, "#overview-quickstart-action-import-first-model")

      assert view |> element("#overview-quickstart-action-import-first-model") |> render() =~
               ~s(data-quickstart-action-emphasis="current")

      # Remaining pending rows have pending emphasis
      assert view |> element("#overview-quickstart-action-run-test-request") |> render() =~
               ~s(data-quickstart-action-emphasis="pending")

      assert view |> element("#overview-quickstart-action-create-api-key") |> render() =~
               ~s(data-quickstart-action-emphasis="pending")

      assert view |> element("#overview-quickstart-action-connect-your-tools") |> render() =~
               ~s(data-quickstart-action-emphasis="pending")
    end

    test "makes step 5 current once server-derived steps 1-4 complete", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      complete_quickstart_server_steps(view)
      assert_quickstart_hydrating(view)
      hydrate_quickstart(view)

      assert_quickstart_status(view, "system-healthy", "completed")
      assert_quickstart_status(view, "import-first-model", "completed")
      assert_quickstart_status(view, "run-test-request", "completed")
      assert_quickstart_status(view, "create-api-key", "completed")
      assert_quickstart_status(view, "connect-your-tools", "current")

      # Completed steps show checkmark, no action control
      refute has_element?(view, "#overview-quickstart-action-system-healthy")
      refute has_element?(view, "#overview-quickstart-action-import-first-model")
      refute has_element?(view, "#overview-quickstart-action-run-test-request")
      refute has_element?(view, "#overview-quickstart-action-create-api-key")

      # Current integration-guide row has guide-open dispatch button and current emphasis
      assert has_element?(view, "#overview-quickstart-action-connect-your-tools")

      step_5_action =
        view |> element("#overview-quickstart-action-connect-your-tools") |> render()

      assert step_5_action =~ "orchard:quickstart-guide:open"
      assert step_5_action =~ "#overview-quickstart-guide"
      refute step_5_action =~ ~s(data-quickstart-action="open-guide")

      assert step_5_action =~ ~s(data-quickstart-action-emphasis="current")
    end

    test "expired API Tokens do not complete the create API key quickstart step", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console")

      complete_quickstart_server_steps_with_expired_key(view)
      assert_quickstart_hydrating(view)
      hydrate_quickstart(view)

      assert_quickstart_status(view, "system-healthy", "completed")
      assert_quickstart_status(view, "import-first-model", "completed")
      assert_quickstart_status(view, "run-test-request", "completed")
      assert_quickstart_status(view, "create-api-key", "current")
      assert_quickstart_status(view, "connect-your-tools", "pending")
    end

    test "goes straight from hydrating to compact completed for returning completed users", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console")

      complete_quickstart_server_steps(view)
      assert_quickstart_hydrating(view)
      refute has_element?(view, "#overview-quickstart-full")

      hydrate_quickstart(view, %{"guide_seen" => "1"})

      assert_quickstart_compact_completed(view)
      assert_quickstart_guide_accessible(view)
      assert_rich_quickstart_guide_content(view)
    end

    test "shows compact completed mode after guide open and preserves it across timer refresh", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console")

      complete_quickstart_server_steps(view)
      hydrate_quickstart(view)
      render_click(view, "quickstart_guide_seen", %{})

      assert_quickstart_compact_completed(view)
      assert_quickstart_guide_accessible(view)

      send(view.pid, :refresh_overview)
      render(view)

      assert_quickstart_compact_completed(view)
      assert_quickstart_guide_accessible(view)
    end

    test "preserves compact completed guide access across manual refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      complete_quickstart_server_steps(view)
      hydrate_quickstart(view)
      render_click(view, "quickstart_guide_seen", %{})

      view |> element("#overview-refresh-now") |> render_click()

      assert_quickstart_compact_completed(view)
      assert_quickstart_guide_accessible(view)
    end

    test "uses summary copy for dismissed completed quickstart state and recovers to compact summary",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      complete_quickstart_server_steps(view)

      hydrate_quickstart(view, %{
        "dismissed" => "1",
        "guide_seen" => "1"
      })

      assert_quickstart_dismissed(view)
      assert_quickstart_guide_accessible(view)
      assert render(view) =~ "You can restore the compact quickstart summary at any time."
      assert render(view) =~ "Show quickstart summary"
      assert render(view) =~ "without restoring the quickstart summary"

      send(view.pid, :refresh_overview)
      render(view)
      assert_quickstart_dismissed(view)
      assert_quickstart_guide_accessible(view)

      view |> element("#overview-refresh-now") |> render_click()
      assert_quickstart_dismissed(view)
      assert_quickstart_guide_accessible(view)

      render_click(view, "quickstart_recover", %{})
      assert_quickstart_compact_completed(view)
      assert_quickstart_guide_accessible(view)
    end
  end

  describe "polling refresh" do
    test "manual refresh cancels the old timer and re-arms the configured poll" do
      put_console_config(refresh_interval_ms: 60_000)

      {:ok, socket} =
        OrchardConsole.OverviewLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{
          transport_pid: self(),
          private: %{connect_params: %{}}
        })

      first_timer = socket.assigns.refresh_timer

      put_console_config(refresh_interval_ms: 50)
      {:noreply, refreshed} = OrchardConsole.OverviewLive.handle_event("refresh_now", %{}, socket)
      assert Process.read_timer(first_timer) == false
      assert refreshed.assigns.refresh_timer != first_timer
      assert_receive :refresh_overview, 1_000

      create_request!(%{state: :completed})
      {:noreply, polled} = OrchardConsole.OverviewLive.handle_info(:refresh_overview, refreshed)
      Process.cancel_timer(polled.assigns.refresh_timer)
      assert polled.assigns.request_summary.total == 1
      assert polled.assigns.request_summary.terminal == 1
    end

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

        assert html =~ "Operational status",
               "crashed with refresh_interval_ms: #{inspect(bad_value)}"

        assert html =~ "Auto-refreshing every 5s"
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

      assert html =~ "Operational status"
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
    test "Quickstart identity survives reconnect and connect preferences skip hydration", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console")
      first_id = :sys.get_state(view.pid).socket.assigns.quickstart_client_id
      assert has_element?(view, ~s(##{first_id}[phx-hook="OverviewQuickstart"]))

      hydrate_quickstart(view, %{"dismissed" => true, "guide_seen" => true})
      render_click(view, "refresh_now", %{})
      assert :sys.get_state(view.pid).socket.assigns.quickstart_client_id == first_id
      assert_quickstart_dismissed(view)

      conn =
        put_connect_params(conn, %{
          "overview_quickstart" => %{"dismissed" => true, "guide_seen" => true}
        })

      {:ok, reconnected, _html} = live(conn, "/console")
      next_id = :sys.get_state(reconnected.pid).socket.assigns.quickstart_client_id
      assert next_id == first_id
      assert has_element?(reconnected, ~s(##{next_id}[phx-hook="OverviewQuickstart"]))
      refute has_element?(reconnected, "#overview-quickstart-hydrating")
      assert_quickstart_dismissed(reconnected)
    end

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
      assert html =~ "Last refresh"
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-local-time-format="time_second")
    end

    test "disconnected render shows waiting text without LocalTime hook", %{conn: conn} do
      conn = get(conn, "/console")

      assert conn.status == 200
      body = conn.resp_body
      assert body =~ "overview-freshness"
      assert body =~ "Waiting for first live update"
      refute body =~ ~s(data-local-time-format="time_second")
    end

    test "manual refresh uses focus-preserving availability commands after connection", %{
      conn: conn
    } do
      {:ok, view, html} = live(conn, "/console")

      assert has_element?(view, "#overview-refresh-now[aria-disabled=false]", "Refresh now")
      refute has_element?(view, "#overview-refresh-now[disabled]")

      button = html |> LazyHTML.from_fragment() |> LazyHTML.query("#overview-refresh-now")

      for {binding, available} <- [{"phx-disconnected", "true"}, {"phx-connected", "false"}] do
        [command] = LazyHTML.attribute(button, binding)

        # Connection changes must not hide or natively disable the focused control.
        assert Jason.decode!(command) == [["set_attr", %{"attr" => ["aria-disabled", available]}]]
      end
    end

    test "manual refresh updates overview data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      html_before = render(view)

      create_request!(%{state: :completed})

      view |> element("#overview-refresh-now") |> render_click()
      html_after = render(view)

      assert html_after =~ "Last refresh"
      refute html_before == html_after
    end
  end

  # ===========================================================================
  # Hero polish (Task 5)
  # ===========================================================================

  describe "hero primary model" do
    test "shows loaded model ID and version with correct label", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      field = view |> element("#overview-primary-model") |> render() |> visible_text()

      assert field =~ "mlx-community/phi-3@main"
      assert field =~ "Loaded model"
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
    test "severity never decreases when Controller readiness fails, including empty failed Workers" do
      assigns = overview_assigns()

      for {worker, health, models, color} <- [
            {:failed, nil, [], "text-red-600"},
            {:failed, %{ready: true, health_code: "warning"}, [], "text-red-600"},
            {:stopped, nil, [], "text-amber-700"},
            {:idle, %{ready: false}, [], "text-red-600"},
            {:busy, %{ready: true, health_code: "warning"}, [%{model_id: "m", version: "v1"}],
             "text-amber-700"}
          ],
          readiness_status <- [:ok, :error] do
        runtime = %{
          assigns.runtime
          | worker_state: worker,
            runtime_health: health,
            loaded_models: models
        }

        readiness = %{assigns.readiness | status: readiness_status, passing: 1, total: 4}

        html =
          render_component(&OrchardConsole.OverviewLive.render/1, %{
            assigns
            | readiness: readiness,
              runtime: runtime
          })

        assert html
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#overview-hero-status-copy.#{color}")
               |> Enum.any?()

        if worker == :failed,
          do: assert(fragment_text(html, "#overview-hero-status-copy") =~ "Failed")

        if readiness_status == :error do
          assert fragment_text(html, "#overview-status-readiness") =~ "Not ready"
          assert fragment_text(html, "#overview-hero-status-copy") =~ "3 of 4 blocked"
          assert html =~ ~s(href="#overview-controller")
        else
          refute html =~ ~s(href="#overview-controller")
        end
      end
    end

    # NOTE: In test env, readiness.status is :error because public_api_https_enabled
    # check fails (no HTTPS in test). Hero copy reflects this combined state.

    test "shows readiness-degraded copy when runtime is healthy", %{conn: conn} do
      # Default RuntimeStub: idle + loaded model, but readiness is degraded in test
      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "default Runtime Endpoint is reachable"
      assert copy =~ "readiness checks are failing"
    end

    test "shows fully-degraded copy when runtime is unavailable", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "Controller readiness checks are failing"
      assert copy =~ "default Runtime Endpoint is unavailable"
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
      assert copy =~ "Worker is transitioning"
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

      {:ok, view, _html} = live(conn, "/console")

      assert has_element?(view, "#overview-status-readiness", "Not ready")
      assert has_element?(view, "#overview-status-runtime", "Degraded")

      assert has_element?(
               view,
               "#overview-runtime-health-message",
               "Worker memory usage above threshold"
             )
    end

    test "unsupported health (nil) falls back to worker-state badge", %{conn: conn} do
      # RuntimeNoModelsStub has runtime_health: nil — should show worker-state label
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeNoModelsStub)

      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Idle"
      refute html =~ "Unhealthy"
      refute fragment_text(html, "#overview-status-runtime") =~ "Degraded"

      refute html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#overview-status-runtime .bg-forest-50")
             |> Enum.any?()
    end
  end

  describe "health-aware hero status copy" do
    # NOTE: In test env, readiness.status is :error because public_api_https_enabled
    # check fails. These tests verify health-aware copy with degraded readiness.

    test "shows unhealthy copy when readiness degraded and runtime unhealthy", %{conn: conn} do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnhealthyStub)

      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "readiness checks are failing"
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
      assert copy =~ "default Runtime Endpoint is reachable"
      assert copy =~ "readiness checks are failing"
      refute copy =~ "unhealthy"
      refute copy =~ "degraded health"
    end
  end

  describe "ready+health hero status copy" do
    # Force readiness to :ok with an HTTPS-capable transport mode.
    # This exercises the hero_health_copy/2 and hero_worker_state_copy/2 branches.
    setup do
      # Force all readiness checks to pass so readiness.status == :ok
      prev_mode = Application.get_env(:orchard_controller, :transport_mode)
      prev_transport = Application.get_env(:orchard_controller, :transport_degraded)
      prev_db = Application.get_env(:orchard_controller, :enable_db_checks)
      prev_repo = Application.get_env(:orchard_controller, :start_repo)

      Application.put_env(:orchard_controller, :transport_mode, :direct_https)
      Application.put_env(:orchard_controller, :transport_degraded, false)
      Application.put_env(:orchard_controller, :enable_db_checks, true)
      Application.put_env(:orchard_controller, :start_repo, true)

      on_exit(fn ->
        Application.put_env(:orchard_controller, :transport_mode, prev_mode)
        Application.put_env(:orchard_controller, :transport_degraded, prev_transport)
        Application.put_env(:orchard_controller, :enable_db_checks, prev_db)
        Application.put_env(:orchard_controller, :start_repo, prev_repo)
      end)

      :ok
    end

    test "passing Controller and healthy runtime remain separately scoped", %{conn: conn} do
      # Default RuntimeStub: idle, loaded model, healthy runtime_health
      {:ok, view, _html} = live(conn, "/console")
      copy = view |> element("#overview-hero-status-copy") |> render()

      assert copy =~ "Controller checks are passing"
      assert copy =~ "default Runtime Endpoint is reachable"
      refute copy =~ "System ready"
      assert copy =~ "text-slate-600"
      refute copy =~ "unhealthy"
      refute copy =~ "degraded"
    end

    test "a failed runtime probe never turns passing Controller checks into failed checks", %{
      conn: conn
    } do
      put_console_config(runtime_impl: OrchardConsole.OverviewLiveTest.RuntimeUnavailableStub)
      {:ok, view, _html} = live(conn, "/console")

      assert has_element?(view, "#overview-hero-status-copy", "Controller checks are passing")

      assert has_element?(
               view,
               "#overview-hero-status-copy",
               "default Runtime Endpoint is unavailable"
             )

      refute has_element?(view, "#overview-hero-status-copy", "checks are failing")
      assert has_element?(view, "#overview-metric-checks-passing .font-mono", "4/4")
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
      assert copy =~ "No model is currently loaded"
      assert copy =~ "text-amber-700"
    end
  end

  # ===========================================================================
  # Hero performance tiles
  # ===========================================================================

  describe "hero performance tiles" do
    test "empty DB shows em dash for avg TTFT and avg tok/s", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")

      ttft_html = element(view, "#overview-metric-avg-ttft") |> render()
      assert ttft_html =~ "—"
      assert ttft_html =~ "Not recorded"
      assert ttft_html =~ "Unwindowed Request mean"

      tps_html = element(view, "#overview-metric-avg-tokens-per-second") |> render()
      assert tps_html =~ "—"
      assert tps_html =~ "Not recorded"
      assert tps_html =~ "Unwindowed Request mean"
    end

    test "defines public-output TTFT and arithmetic unwindowed rates without native-rate inference",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console")
      definitions = element(view, "#overview-metric-definitions") |> render() |> visible_text()

      assert definitions =~ "Request creation to first recorded public output"
      assert definitions =~ "including waiting and earlier attempts"
      assert definitions =~ "Not client receipt time"
      assert definitions =~ "unwindowed arithmetic mean"
      assert definitions =~ "Not a provider-native generation rate or throughput trend"
      assert definitions =~ "positive output tokens"
    end

    test "nonqualifying completed rows count as Requests but not zero performance", %{conn: conn} do
      create_request!(%{state: :completed, output_tokens: 0})

      create_request!(%{
        state: :completed,
        output_tokens: 10,
        first_token_at: ~U[2026-03-15 12:00:02.000000Z],
        completed_at: ~U[2026-03-15 12:00:02.000000Z]
      })

      {:ok, view, _html} = live(conn, "/console")
      assert has_element?(view, "#overview-metric-total-requests .font-mono", "2")
      assert has_element?(view, "#overview-metric-avg-ttft", "Not recorded")
      assert has_element?(view, "#overview-metric-avg-tokens-per-second", "Not recorded")
    end

    test "shows formatted average values from completed requests", %{conn: conn} do
      # Row A: TTFT 1s, generation 5s, tok/s 4.0
      a =
        create_request!(%{
          public_id: "ov_perf_a",
          state: :completed,
          input_tokens: 10,
          output_tokens: 20,
          first_token_at: ~U[2026-03-15 12:00:01.000000Z],
          completed_at: ~U[2026-03-15 12:00:06.000000Z]
        })

      patch_inserted_at(a, ~U[2026-03-15 12:00:00.000000Z])

      # Row B: TTFT 2s, generation 8s, tok/s 5.0
      b =
        create_request!(%{
          public_id: "ov_perf_b",
          state: :completed,
          input_tokens: 15,
          output_tokens: 40,
          first_token_at: ~U[2026-03-15 12:00:02.000000Z],
          completed_at: ~U[2026-03-15 12:00:10.000000Z]
        })

      patch_inserted_at(b, ~U[2026-03-15 12:00:00.000000Z])

      {:ok, view, _html} = live(conn, "/console")

      # Avg TTFT: (1000 + 2000) / 2 = 1500 ms = 1.5 s
      ttft_html = element(view, "#overview-metric-avg-ttft") |> render()
      assert ttft_html =~ "1.5 s"

      # Avg tok/s: (4.0 + 5.0) / 2 = 4.5
      tps_html = element(view, "#overview-metric-avg-tokens-per-second") |> render()
      assert tps_html =~ "4.5"
    end

    test "existing 4 hero tiles remain present", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console")

      assert html =~ "Checks passing"
      assert html =~ "Loaded models"
      assert html =~ "Catalog models"
      assert html =~ "Total requests"
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

  defp visible_text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text()

  defp fragment_text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp overview_assigns do
    {:ok, socket} =
      OrchardConsole.OverviewLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{
        transport_pid: self(),
        private: %{connect_params: %{}}
      })

    Process.cancel_timer(socket.assigns.refresh_timer)
    socket.assigns
  end

  defp hydrate_quickstart(view, attrs \\ %{}) do
    render_click(view, "quickstart_client_state_loaded", attrs)
  end

  defp assert_quickstart_hydrating(view) do
    assert has_element?(view, "#overview-quickstart")
    assert has_element?(view, "#overview-quickstart-hydrating")
    refute has_element?(view, "#overview-quickstart-full")
    refute has_element?(view, "#overview-quickstart-dismissed")
    refute has_element?(view, "#overview-quickstart-completed")
  end

  defp assert_quickstart_visible(view) do
    assert has_element?(view, "#overview-quickstart")
    assert has_element?(view, "#overview-quickstart-full")
    assert has_element?(view, "#overview-quickstart-dismiss")
    refute has_element?(view, "#overview-quickstart-hydrating")
    refute has_element?(view, "#overview-quickstart-dismissed")
    refute has_element?(view, "#overview-quickstart-completed")
  end

  defp assert_quickstart_dismissed(view) do
    assert has_element?(view, "#overview-quickstart")
    assert has_element?(view, "#overview-quickstart-dismissed")
    assert has_element?(view, "#overview-quickstart-recover")
    refute has_element?(view, "#overview-quickstart-hydrating")
    refute has_element?(view, "#overview-quickstart-full")
    refute has_element?(view, "#overview-quickstart-completed")
  end

  defp assert_quickstart_compact_completed(view) do
    assert has_element?(view, "#overview-quickstart")
    assert has_element?(view, "#overview-quickstart-completed")
    refute has_element?(view, "#overview-quickstart-hydrating")
    refute has_element?(view, "#overview-quickstart-full")
    refute has_element?(view, "#overview-quickstart-dismissed")
    refute has_element?(view, "#overview-quickstart-recover")
  end

  defp assert_quickstart_guide_accessible(view) do
    assert has_element?(view, "#overview-quickstart-guide")
    assert has_element?(view, "#overview-quickstart-guide-summary")
    assert has_element?(view, "#overview-quickstart-guide-disclosure")
  end

  defp assert_rich_quickstart_guide_content(view) do
    assert_quickstart_guide_accessible(view)

    assert view |> element("#overview-quickstart-guide") |> render() =~
             ~s(phx-hook="QuickstartGuide")

    assert view |> element("#overview-quickstart-guide-base-url") |> render() =~
             Endpoint.url() <> "/v1"

    curl = view |> element("#overview-quickstart-guide-curl") |> render()
    assert curl =~ "curl #{Endpoint.url()}/v1/chat/completions \\\n"
    assert curl =~ "Authorization: Bearer &lt;your-api-key&gt;"
    assert curl =~ "&lt;your-model&gt;"

    python = view |> element("#overview-quickstart-guide-python") |> render()
    assert python =~ "from openai import OpenAI"
    assert python =~ "base_url=&quot;#{Endpoint.url()}/v1&quot;"
    assert python =~ "api_key=&quot;&lt;your-api-key&gt;&quot;"
    assert python =~ "model=&quot;&lt;your-model&gt;&quot;"

    tool_config = view |> element("#overview-quickstart-guide-tool-config") |> render()
    assert tool_config =~ "Provider: OpenAI-compatible / Custom OpenAI"
    assert tool_config =~ "Base URL: #{Endpoint.url()}/v1"
    assert tool_config =~ "API Token: &lt;your-api-token&gt;"
    assert tool_config =~ "Model: &lt;your-model&gt;"
  end

  defp assert_quickstart_status(view, step_dom_id, status) do
    assert has_element?(
             view,
             "#overview-quickstart-step-#{step_dom_id}[data-status=\"#{status}\"]"
           )
  end

  defp patch_inserted_at(request, %DateTime{} = dt) do
    {1, _} =
      Repo.update_all(
        from(r in Orchard.Requests.Request, where: r.id == ^request.id),
        set: [inserted_at: dt]
      )
  end

  defp complete_quickstart_server_steps(view), do: complete_quickstart_server_steps(view, [])

  defp complete_quickstart_server_steps_with_expired_key(view) do
    expired_at =
      DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:microsecond)

    complete_quickstart_server_steps(view, expires_at: expired_at)
  end

  defp complete_quickstart_server_steps(view, opts) do
    create_model!(%{state: :active})
    create_request!(%{state: :completed})

    suffix = System.unique_integer([:positive, :monotonic])

    {:ok, tenant} =
      Governance.create_tenant(%{
        slug: "quickstart-tenant-#{suffix}",
        name: "Quickstart Tenant #{suffix}"
      })

    {:ok, %{api_key: api_key}} = Governance.create_api_key(tenant.id, %{name: "Quickstart Key"})

    if expires_at = Keyword.get(opts, :expires_at) do
      patch_api_key_expires_at(api_key, expires_at)
    end

    send(view.pid, :refresh_overview)
    render(view)
  end

  defp patch_api_key_expires_at(api_key, %DateTime{} = expires_at) do
    {1, _} =
      Repo.update_all(
        from(k in Orchard.Governance.ApiKey, where: k.id == ^api_key.id),
        set: [expires_at: expires_at]
      )
  end
end
