# Runtime stubs defined before the test module (same pattern as OverviewLiveTest)

defmodule OrchardConsole.NodesLiveTest.RuntimeFullStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50071]

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: @default_target,
        status: :ok,
        message: nil,
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
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeLegacyStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50071]

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: @default_target,
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimePartialStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50071]

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: @default_target,
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: %{
          node_id: "550e8400-e29b-41d4-a716-446655440000",
          display_name: "partial-node",
          hostname: "partial.local",
          listen_host: "127.0.0.1",
          listen_port: 50071,
          agent_version: "0.1.0",
          worker_backend: "mlx"
        },
        runtime_health: nil
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeUnavailableStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50071]

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: @default_target,
        status: :unavailable,
        code: "node_unavailable",
        message: "node runtime is unavailable",
        worker_state: :unknown,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeMultiTargetStub do
  @moduledoc false

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: [host: "127.0.0.1", port: 50071],
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [%{model_id: "model-a", version: "v1"}],
        active_request_count: 0,
        node_metadata: %{
          node_id: "aaaa-0001",
          display_name: "node-alpha",
          hostname: "alpha.local",
          listen_host: "127.0.0.1",
          listen_port: 50071,
          agent_version: "0.1.0",
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil}
      },
      %{
        target: [host: "10.0.0.2", port: 50061],
        status: :unavailable,
        code: "node_unavailable",
        message: "node runtime is unavailable",
        worker_state: :unknown,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.DiscoveryRuntimeClient do
  @moduledoc false
  @discovery_uuid "770fa622-a41c-63f6-c938-668877662222"

  def connect(_target), do: {:ok, :discovery_channel}

  def status(_channel, _opts \\ []) do
    {:ok,
     %{
       worker_state: :WORKER_STATE_IDLE,
       loaded_models: [%{model_id: "mlx-community/phi-3", version: "main"}],
       active_request_count: 0,
       node_metadata: %{
         node_id: @discovery_uuid,
         display_name: "discovered-via-mount",
         hostname: "discovery.local",
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

  def disconnect(_channel), do: :ok

  def uuid, do: @discovery_uuid
end

defmodule OrchardConsole.NodesLiveTest.RuntimeMixedCompatibilityStub do
  @moduledoc "Mixed cluster: one modern target with full metadata, one legacy target without."

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: [host: "127.0.0.1", port: 50071],
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [%{model_id: "model-a", version: "v1"}],
        active_request_count: 1,
        node_metadata: %{
          node_id: "550e8400-e29b-41d4-a716-446655440000",
          display_name: "modern-node",
          hostname: "modern.local",
          listen_host: "127.0.0.1",
          listen_port: 50071,
          agent_version: "0.2.0",
          worker_backend: "mlx"
        },
        runtime_health: %{
          ready: true,
          health_code: nil,
          health_message: nil,
          affected_model: nil
        }
      },
      %{
        target: [host: "10.0.0.5", port: 50061],
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo

  @moduletag :live
  @moduletag :db

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        runtime_impl: OrchardConsole.NodesLiveTest.RuntimeFullStub,
        refresh_interval_ms: 60_000
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)

    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Route and page rendering
  # ---------------------------------------------------------------------------

  describe "GET /console/nodes" do
    test "renders nodes page with section titles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "Inventory Summary"
      assert html =~ "Registered Nodes"
      assert html =~ "Live Cluster"
    end

    test "has correct page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "Nodes \u2014 Orchard Console"
    end
  end

  # ---------------------------------------------------------------------------
  # Sidebar navigation
  # ---------------------------------------------------------------------------

  describe "sidebar" do
    test "Nodes nav item exists and is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "/console/nodes"
      assert html =~ "Nodes"
      # aria-current="page" on active item
      assert html =~ ~s(aria-current="page")
    end

    test "Requests remains the only disabled item", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ ~s(aria-disabled="true")
      assert html =~ "Requests \u2014 coming soon"
      refute html =~ "Nodes \u2014 coming soon"
    end
  end

  # ---------------------------------------------------------------------------
  # Summary strip
  # ---------------------------------------------------------------------------

  describe "summary strip" do
    test "shows zero-filled counts when no nodes exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ ~s(id="nodes-summary-total")
      assert html =~ ~s(id="nodes-summary-healthy")
      assert html =~ ~s(id="nodes-summary-degraded")
      assert html =~ ~s(id="nodes-summary-unhealthy")
      assert html =~ ~s(id="nodes-summary-unreachable")
    end

    test "counts reflect inserted nodes by health", %{conn: conn} do
      insert_node!(health: :healthy, display_name: "node-a")
      insert_node!(health: :degraded, display_name: "node-b")
      insert_node!(health: :unhealthy, display_name: "node-c")

      {:ok, view, _html} = live(conn, "/console/nodes")

      total_html = element(view, "#nodes-summary-total") |> render()
      assert total_html =~ "3"

      healthy_html = element(view, "#nodes-summary-healthy") |> render()
      assert healthy_html =~ "1"

      degraded_html = element(view, "#nodes-summary-degraded") |> render()
      assert degraded_html =~ "1"
    end
  end

  # ---------------------------------------------------------------------------
  # Inventory table
  # ---------------------------------------------------------------------------

  describe "inventory table" do
    test "renders persisted rows", %{conn: conn} do
      insert_node!(
        display_name: "test-node",
        hostname: "test.local",
        advertise_addr: "192.168.1.10",
        rpc_port: 50071,
        state: :active,
        health: :healthy,
        agent_version: "0.1.0"
      )

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "test-node"
      assert html =~ "test.local"
      assert html =~ "192.168.1.10:50071"
      assert html =~ "active"
      assert html =~ "healthy"
      assert html =~ "0.1.0"
    end
  end

  # ---------------------------------------------------------------------------
  # Empty state
  # ---------------------------------------------------------------------------

  describe "empty state" do
    test "shows empty message when no nodes registered", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "No nodes registered yet."
      assert html =~ "nodes-empty-state"
    end
  end

  # ---------------------------------------------------------------------------
  # Live runtime diagnostics
  # ---------------------------------------------------------------------------

  describe "live runtime" do
    test "shows worker state, backend, and loaded models on full snapshot", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "Idle"
      assert html =~ "Healthy"
      assert html =~ "mlx"
      assert html =~ "mawarduri"
      assert html =~ "127.0.0.1:50071"
      assert html =~ "mlx-community/phi-3"
      assert html =~ "1 active"
    end

    test "cluster summary shows counts", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")

      summary = element(view, "#nodes-live-cluster-card") |> render()
      assert summary =~ "1 target(s) configured"
      assert summary =~ "1 reachable"
    end

    test "per-target card renders with stable DOM id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      # DOM id based on target host:port
      assert html =~ ~s(id="nodes-runtime-card-127-0-0-1-50071")
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-target rendering
  # ---------------------------------------------------------------------------

  describe "multi-target cluster" do
    test "renders one card per target, mixed success and failure", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMultiTargetStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      # Both target cards rendered
      assert html =~ ~s(id="nodes-runtime-card-127-0-0-1-50071")
      assert html =~ ~s(id="nodes-runtime-card-10-0-0-2-50061")

      # Success target shows data
      assert html =~ "node-alpha"
      assert html =~ "model-a"

      # Failed target shows error state
      assert html =~ "Unavailable"
    end

    test "cluster summary reflects mixed results", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMultiTargetStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      summary = element(view, "#nodes-live-cluster-card") |> render()
      assert summary =~ "2 target(s) configured"
      assert summary =~ "1 reachable"
    end
  end

  # ---------------------------------------------------------------------------
  # Compatibility warning
  # ---------------------------------------------------------------------------

  describe "compatibility warning" do
    test "shown for legacy snapshot (per-target)", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeLegacyStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "nodes-runtime-compat-"
      assert html =~ "does not report metadata or health"
    end

    test "shown for partial snapshot (per-target)", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimePartialStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "nodes-runtime-compat-"
      assert html =~ "partial status metadata"
    end

    test "not shown for full snapshot", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      refute html =~ "nodes-runtime-compat-"
    end

    test "not shown when runtime is unavailable", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeUnavailableStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      refute html =~ "nodes-runtime-compat-"
    end
  end

  # ---------------------------------------------------------------------------
  # Mixed legacy + modern cluster (M3b Session 4)
  # ---------------------------------------------------------------------------

  describe "mixed legacy and modern cluster" do
    test "both target cards render, only legacy shows compatibility warning", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMixedCompatibilityStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      # Both target cards rendered
      assert html =~ ~s(id="nodes-runtime-card-127-0-0-1-50071")
      assert html =~ ~s(id="nodes-runtime-card-10-0-0-5-50061")

      # Modern target shows metadata and models
      assert html =~ "modern-node"
      assert html =~ "model-a"

      # Legacy target shows compatibility warning
      assert html =~ "nodes-runtime-compat-10-0-0-5-50061"
      assert html =~ "does not report metadata or health"

      # Modern target does NOT show compatibility warning
      refute html =~ "nodes-runtime-compat-127-0-0-1-50071"
    end

    test "cluster summary counts based on reachability not metadata", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMixedCompatibilityStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      summary = element(view, "#nodes-live-cluster-card") |> render()
      # Both targets are reachable (status: :ok), even the legacy one
      assert summary =~ "2 target(s) configured"
      assert summary =~ "2 reachable"
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime unavailable
  # ---------------------------------------------------------------------------

  describe "runtime unavailable" do
    test "shows per-target error while inventory still renders", %{conn: conn} do
      insert_node!(display_name: "persisted-node", health: :healthy)
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeUnavailableStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      # Per-target runtime card shows error
      assert html =~ "nodes-runtime-unavailable-"
      assert html =~ "Unavailable"

      # Inventory still renders
      assert html =~ "persisted-node"
    end
  end

  # ---------------------------------------------------------------------------
  # Manual refresh
  # ---------------------------------------------------------------------------

  describe "refresh" do
    test "clicking refresh_now updates DOM after inserting a node", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/nodes")

      assert html =~ "No nodes registered yet."

      insert_node!(display_name: "new-node", health: :healthy)

      html = view |> element("#nodes-refresh-now") |> render_click()
      assert html =~ "new-node"
    end

    test "polling via :refresh_nodes updates the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")

      insert_node!(display_name: "polled-node", health: :healthy)

      send(view.pid, :refresh_nodes)
      html = render(view)
      assert html =~ "polled-node"
    end
  end

  # ---------------------------------------------------------------------------
  # Freshness
  # ---------------------------------------------------------------------------

  describe "freshness" do
    test "shows freshness row with timestamp after load", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "nodes-freshness"
      assert html =~ "Last refreshed"
      assert html =~ "UTC"
    end
  end

  # ---------------------------------------------------------------------------
  # Same-cycle discovery integration
  # ---------------------------------------------------------------------------

  describe "same-cycle discovery" do
    test "runtime-first load order surfaces newly discovered node on first render", %{conn: conn} do
      # Use real OrchardConsole.Runtime + real Orchard.Nodes with a stub gRPC client.
      # DB starts empty — the node should be discovered via Runtime.snapshot -> observe_status
      # and visible in the inventory table on the same render cycle.
      Application.put_env(
        :orchard_controller,
        :console,
        Application.get_env(:orchard_controller, :console, [])
        |> Keyword.put(:runtime_impl, OrchardConsole.Runtime)
        |> Keyword.put(:runtime_client_impl, OrchardConsole.NodesLiveTest.DiscoveryRuntimeClient)
        |> Keyword.delete(:nodes_impl)
      )

      # Confirm DB is empty
      assert Orchard.Nodes.list_nodes() == []

      {:ok, _view, html} = live(conn, "/console/nodes")

      # The discovered node should appear in the inventory table
      assert html =~ "discovered-via-mount"
      # Inventory summary should show 1 node
      assert html =~ "1"
      # Runtime section should show the live data
      assert html =~ "mlx-community/phi-3"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp put_runtime_stub(stub_module) do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.put(previous, :runtime_impl, stub_module)
    )
  end

  defp insert_node!(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      id: Ecto.UUID.generate(),
      hostname: "host-#{unique}.local",
      display_name: "node-#{unique}",
      advertise_addr: "127.0.0.#{rem(unique, 255)}",
      rpc_port: 50_000 + rem(unique, 15_000),
      state: :active,
      health: :healthy,
      capabilities: %{},
      agent_version: "0.1.0",
      last_heartbeat_at: DateTime.utc_now()
    }

    merged = Map.merge(defaults, Map.new(attrs))

    %Orchard.Nodes.Node{}
    |> Orchard.Nodes.Node.changeset(merged)
    |> Repo.insert!()
  end
end
