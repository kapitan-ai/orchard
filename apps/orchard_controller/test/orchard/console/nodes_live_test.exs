# Runtime stubs defined before the test module (same pattern as OverviewLiveTest)

defmodule OrchardConsole.NodesLiveTest.RuntimeFullStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50_071]

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
          listen_port: 50_071,
          agent_version: "0.1.0",
          worker_backend: "mlx"
        },
        runtime_health: %{
          ready: true,
          health_code: nil,
          health_message: nil,
          affected_model: nil
        },
        supports_prompt_token_ids: true
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeMemoryBudgetStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50_071]

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
          listen_port: 50_071,
          agent_version: "0.1.0",
          worker_backend: "mlx"
        },
        runtime_health: %{
          ready: true,
          health_code: nil,
          health_message: nil,
          affected_model: nil
        },
        runtime_memory_budgets: [
          %{
            display_state: :observed,
            model_ref: "mlx-community/phi-3@main",
            mode: "observe",
            budget_available: true,
            headroom_available: false,
            status_code: "ok",
            status_message: "observe-only snapshot",
            target_working_set_bytes: 45_000,
            resident_memory_bytes: 0,
            kv_cache_bytes_per_token: 16,
            prefill_workspace_bytes_per_token: 8
          }
        ],
        runtime_memory_budgets_truncated_count: 1
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeLegacyStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50_071]

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
  @default_target [host: "127.0.0.1", port: 50_071]

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
          listen_port: 50_071,
          agent_version: "0.1.0",
          worker_backend: "mlx"
        },
        runtime_health: nil
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeBudgetCompatibilityStub do
  @moduledoc false

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: [host: "127.0.0.1", port: 50_071],
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: %{
          node_id: "full-node",
          display_name: "full-budget-node",
          hostname: "full.local",
          listen_host: "127.0.0.1",
          listen_port: 50_071,
          agent_version: "0.2.0",
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil},
        runtime_memory_budgets: [
          %{
            display_state: :observed,
            model_ref: "full-model@main",
            mode: "observe",
            budget_available: true,
            headroom_available: false,
            status_code: "compute_failed",
            status_message: "diagnostic only",
            target_working_set_bytes: 1,
            resident_memory_bytes: 0,
            kv_cache_bytes_per_token: 0,
            prefill_workspace_bytes_per_token: 0
          }
        ],
        runtime_memory_budgets_truncated_count: 0
      },
      %{
        target: [host: "10.0.0.2", port: 50_061],
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: %{
          node_id: "partial-node",
          display_name: "partial-budget-node",
          hostname: "partial.local",
          listen_host: "10.0.0.2",
          listen_port: 50_061,
          agent_version: "0.2.0",
          worker_backend: "mlx"
        },
        runtime_health: nil,
        runtime_memory_budgets: [],
        runtime_memory_budgets_truncated_count: 0
      },
      %{
        target: [host: "10.0.0.3", port: 50_061],
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil,
        runtime_memory_budgets: :malformed,
        runtime_memory_budgets_truncated_count: :malformed
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeMalformedMemoryBudgetRowsStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50_071]

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
          node_id: "malformed-budget-node",
          display_name: "malformed-budget-node",
          hostname: "malformed.local",
          listen_host: "127.0.0.1",
          listen_port: 50_071,
          agent_version: "0.2.0",
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil},
        runtime_memory_budgets: [
          %{},
          %{
            "model_ref" => "string-key-model",
            "budget_available" => true,
            "target_working_set_bytes" => -5,
            "status_code" => "ok"
          },
          "not a budget row"
        ],
        runtime_memory_budgets_truncated_count: 0
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeOversizedMemoryBudgetRowsStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50_071]
  @trimmed_model_suffix "MODEL-TRIMMED-SUFFIX"
  @trimmed_message_suffix "MESSAGE-TRIMMED-SUFFIX"

  def cluster_snapshot(_opts \\ []) do
    oversized_budgets =
      [
        %{
          display_state: :observed,
          model_ref: String.duplicate("m", 160) <> @trimmed_model_suffix,
          mode: "observe",
          budget_available: true,
          headroom_available: false,
          status_code: "ok",
          status_message: String.duplicate("s", 240) <> @trimmed_message_suffix,
          target_working_set_bytes: 45_000,
          resident_memory_bytes: 0,
          kv_cache_bytes_per_token: 16,
          prefill_workspace_bytes_per_token: 8
        }
      ] ++
        Enum.map(2..25, fn index ->
          %{
            display_state: :observed,
            model_ref: "model-#{index}@main",
            mode: "observe",
            budget_available: true,
            headroom_available: false,
            status_code: "ok",
            status_message: nil,
            target_working_set_bytes: index,
            resident_memory_bytes: 0,
            kv_cache_bytes_per_token: 0,
            prefill_workspace_bytes_per_token: 0
          }
        end)

    [
      %{
        target: @default_target,
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: %{
          node_id: "oversized-budget-node",
          display_name: "oversized-budget-node",
          hostname: "oversized.local",
          listen_host: "127.0.0.1",
          listen_port: 50_071,
          agent_version: "0.2.0",
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil},
        runtime_memory_budgets: oversized_budgets,
        runtime_memory_budgets_truncated_count: 0
      }
    ]
  end

  def trimmed_model_suffix, do: @trimmed_model_suffix
  def trimmed_message_suffix, do: @trimmed_message_suffix
end

defmodule OrchardConsole.NodesLiveTest.RuntimeUnavailableStub do
  @moduledoc false
  @default_target [host: "127.0.0.1", port: 50_071]

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
        target: [host: "127.0.0.1", port: 50_071],
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
          listen_port: 50_071,
          agent_version: "0.1.0",
          worker_backend: "mlx"
        },
        runtime_health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil},
        supports_prompt_token_ids: true
      },
      %{
        target: [host: "10.0.0.2", port: 50_061],
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

  def disconnect(_channel), do: :ok

  def uuid, do: @discovery_uuid
end

defmodule OrchardConsole.NodesLiveTest.RuntimeMixedCompatibilityStub do
  @moduledoc "Mixed cluster: one modern target with full metadata, one legacy target without."

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: [host: "127.0.0.1", port: 50_071],
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
          listen_port: 50_071,
          agent_version: "0.2.0",
          worker_backend: "mlx"
        },
        runtime_health: %{
          ready: true,
          health_code: nil,
          health_message: nil,
          affected_model: nil
        },
        supports_prompt_token_ids: true
      },
      %{
        target: [host: "10.0.0.5", port: 50_061],
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

defmodule OrchardConsole.NodesLiveTest.RuntimeClusterExitStub do
  @moduledoc "Stub whose cluster_snapshot/1 exits — simulates gRPC GenServer death."

  def cluster_snapshot(_opts \\ []) do
    exit(:econnrefused)
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeClusterRaiseStub do
  @moduledoc "Stub whose cluster_snapshot/1 raises — simulates unexpected exception."

  def cluster_snapshot(_opts \\ []) do
    raise RuntimeError, "gRPC client crashed"
  end
end

defmodule OrchardConsole.NodesLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Orchard.TestSupport.LicenseGateHelpers

  alias __MODULE__.RuntimeOversizedMemoryBudgetRowsStub
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
    test "hard mode keeps nodes diagnostics reachable", %{conn: conn} do
      set_license_enforcement(:hard)

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "Inventory Summary"
      assert html =~ "Registered Nodes"
      assert html =~ "Live Cluster"
    end

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

    test "all sidebar nav items are enabled", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      refute html =~ ~s(aria-disabled="true")
      refute html =~ "coming soon"
      assert html =~ "/console/requests"
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
        rpc_port: 50_071,
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
      capable_tile = element(view, "#cluster-prompt-token-capable") |> render()

      assert summary =~ "1 target(s) configured"
      assert summary =~ "1 reachable"
      assert capable_tile =~ "Prompt-ID Capable"
      assert capable_tile =~ "1/1"
      assert capable_tile =~ "bg-forest-50/50"
    end

    test "per-target card renders with stable DOM id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      # DOM id based on target host:port
      assert html =~ ~s(id="nodes-runtime-card-127-0-0-1-50071")
    end

    test "renders prompt-token capability badge for capable target", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-runtime-card-127-0-0-1-50071") |> render()

      assert card =~ ~s(id="nodes-tokenizer-capability-127-0-0-1-50071")
      assert card =~ "Prompt IDs: capable"
      refute card =~ "Prompt IDs: legacy"
    end

    test "renders prompt-token legacy badge for reachable target without capability", %{
      conn: conn
    } do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeLegacyStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-runtime-card-127-0-0-1-50071") |> render()

      assert card =~ ~s(id="nodes-tokenizer-capability-127-0-0-1-50071")
      assert card =~ "Prompt IDs: legacy"
      refute card =~ "Prompt IDs: capable"
    end

    test "does not render prompt-token capability badge for unavailable target", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeUnavailableStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "nodes-runtime-unavailable-127-0-0-1-50071"
      refute html =~ "nodes-tokenizer-capability-127-0-0-1-50071"
      refute html =~ "Prompt IDs: capable"
      refute html =~ "Prompt IDs: legacy"
    end

    test "renders observe-only memory telemetry empty state when budgets are absent", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console/nodes")

      telemetry = element(view, "#nodes-memory-telemetry-127-0-0-1-50071") |> render()

      assert telemetry =~ "Memory Telemetry"
      assert telemetry =~ "Observe-only memory-budget diagnostics"
      assert telemetry =~ "non-gating"
      assert telemetry =~ "No memory-budget observation reported by this target."
      assert_no_memory_policy_terms(telemetry)
    end

    test "renders advisory memory telemetry details when budgets are present", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMemoryBudgetStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      telemetry = element(view, "#nodes-memory-telemetry-127-0-0-1-50071") |> render()

      assert telemetry =~ "mlx-community/phi-3@main"
      assert telemetry =~ "ok — observe-only snapshot"
      assert telemetry =~ "reported · 45000 bytes"
      assert telemetry =~ "estimate unavailable"
      assert telemetry =~ "resident unreported"
      assert telemetry =~ "KV reported"
      assert telemetry =~ "prefill reported"
      assert telemetry =~ "1 additional row(s) omitted"
      assert_no_memory_policy_terms(telemetry)
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

    test "prompt-token summary denominator excludes unavailable targets", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMultiTargetStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      capable_tile = element(view, "#cluster-prompt-token-capable") |> render()
      assert capable_tile =~ "1/1"
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

    test "memory telemetry does not change compatibility classification", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeBudgetCompatibilityStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      refute html =~ "nodes-runtime-compat-127-0-0-1-50071"
      assert html =~ "nodes-runtime-compat-10-0-0-2-50061"
      assert html =~ "partial status metadata"
      assert html =~ "nodes-runtime-compat-10-0-0-3-50061"
      assert html =~ "does not report metadata or health"
    end
  end

  describe "memory telemetry guardrails" do
    test "memory telemetry alone does not change health labels or summary counts", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeBudgetCompatibilityStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      cluster = element(view, "#nodes-live-cluster-card") |> render()
      unhealthy = element(view, "#cluster-unhealthy") |> render()

      assert cluster =~ "3 target(s) configured"
      assert cluster =~ "3 reachable"
      assert unhealthy =~ "0"

      full_card = element(view, "#nodes-runtime-card-127-0-0-1-50071") |> render()
      assert full_card =~ "Healthy"
      assert full_card =~ "compute_failed"
    end

    test "runtime unavailable without memory budgets still renders safely", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeUnavailableStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "nodes-runtime-unavailable-"
      assert html =~ "Unavailable"
      refute html =~ "nodes-memory-telemetry-127-0-0-1-50071"
    end

    test "malformed memory telemetry rows fail open as advisory rows", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMalformedMemoryBudgetRowsStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      telemetry = element(view, "#nodes-memory-telemetry-127-0-0-1-50071") |> render()

      assert telemetry =~ "unknown model"
      assert telemetry =~ "string-key-model"
      assert telemetry =~ "invalid telemetry"
      assert telemetry =~ "unreported"
      assert_no_memory_policy_terms(telemetry)
    end

    test "oversized memory telemetry stays bounded at the LiveView seam", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeOversizedMemoryBudgetRowsStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      telemetry = element(view, "#nodes-memory-telemetry-127-0-0-1-50071") |> render()

      assert telemetry =~ "5 additional row(s) omitted"
      assert telemetry =~ "model-20@main"
      refute telemetry =~ "model-21@main"

      refute telemetry =~ RuntimeOversizedMemoryBudgetRowsStub.trimmed_model_suffix()
      refute telemetry =~ RuntimeOversizedMemoryBudgetRowsStub.trimmed_message_suffix()

      assert_no_memory_policy_terms(telemetry)
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

    test "cluster summary counts prompt-token-capable reachable workers", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMixedCompatibilityStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      summary = element(view, "#nodes-live-cluster-card") |> render()
      capable_tile = element(view, "#cluster-prompt-token-capable") |> render()

      assert summary =~ "2 target(s) configured"
      assert summary =~ "2 reachable"
      assert capable_tile =~ "Prompt-ID Capable"
      assert capable_tile =~ "1/2"
      assert capable_tile =~ "bg-slate-50"
      refute capable_tile =~ "bg-forest-50/50"
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
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-local-time-format="time_second")
    end

    test "disconnected render shows waiting text without LocalTime hook", %{conn: conn} do
      conn = get(conn, "/console/nodes")

      assert conn.status == 200
      body = conn.resp_body
      assert body =~ "nodes-freshness"
      assert body =~ "Waiting for first live update"
      refute body =~ ~s(data-local-time-format="time_second")
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
  # Crash-loop resilience (B4 regression)
  # ---------------------------------------------------------------------------

  describe "cluster_snapshot exit does not crash LiveView" do
    test "mount succeeds and renders cluster error state", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeClusterExitStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      # Cluster section shows error state
      assert html =~ "nodes-cluster-error"
      assert html =~ "Cluster status unavailable"

      # Inventory section still renders (not crashed)
      assert html =~ "nodes-inventory-card"
    end

    test "refresh after exit does not crash LiveView", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeClusterExitStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      # Simulate periodic refresh
      send(view.pid, :refresh_nodes)
      html = render(view)

      # View is still alive and rendering
      assert html =~ "nodes-cluster-error"
      assert html =~ "nodes-inventory-card"
    end

    test "inventory renders correctly despite cluster exit", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeClusterExitStub)
      insert_node!(%{display_name: "survivor-node", state: :active, health: :healthy})

      {:ok, _view, html} = live(conn, "/console/nodes")

      # Cluster is degraded, but inventory shows the node
      assert html =~ "nodes-cluster-error"
      assert html =~ "survivor-node"
    end
  end

  describe "cluster_snapshot raise does not crash LiveView" do
    test "mount succeeds and renders cluster error state", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeClusterRaiseStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "nodes-cluster-error"
      assert html =~ "Cluster status unavailable"
      assert html =~ "nodes-inventory-card"
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

  defp assert_no_memory_policy_terms(html) do
    refute html =~ "eligible"
    refute html =~ "capacity OK"
    refute html =~ "admittable"
    refute html =~ "fits"
    refute html =~ "can admit"
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
