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

defmodule OrchardConsole.NodesLiveTest.RuntimeBeamTargetStub do
  @moduledoc false
  @node_id "550e8400-e29b-41d4-a716-446655440000"
  @target Orchard.RuntimeEndpoint.Target.beam(@node_id,
            address: :"orchard_node_agent@127.0.0.1"
          )

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: @target,
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [%{model_id: "model-beam", version: "v1"}],
        active_request_count: 0,
        node_metadata: %{
          node_id: @node_id,
          display_name: "beam-node",
          hostname: "mawarduri.local",
          listen_host: "100.70.81.109",
          listen_port: 50_071,
          agent_version: "0.2.0",
          worker_backend: "stub"
        },
        runtime_health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil},
        supports_prompt_token_ids: true
      }
    ]
  end
end

defmodule OrchardConsole.NodesLiveTest.RuntimeGrpcMapTargetStub do
  @moduledoc false

  @target %Orchard.RuntimeEndpoint.Target{
    id: "grpc_compat:127.0.0.9:50071",
    transport: :grpc_compat,
    address: %{host: "127.0.0.9", port: 50_071, metadata: %{token: "must-not-render"}},
    metadata: %{}
  }

  def cluster_snapshot(_opts \\ []) do
    [
      %{
        target: @target,
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: %{ready: true, health_code: nil, health_message: nil, affected_model: nil},
        supports_prompt_token_ids: false
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

defmodule OrchardConsole.NodesLiveTest.TelemetryCountersZeroStub do
  @moduledoc false

  def snapshot do
    %{
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      control_token_in_user_content: %{count: 0, last_seen_at: nil},
      detector_error: %{count: 0, last_seen_at: nil},
      prompt_token_ids_dispatched: %{count: 0, token_count: 0, last_seen_at: nil},
      unsafe_mode_active: %{count: 0, last_seen_at: nil},
      parity_drift: %{count: 0, last_seen_at: nil},
      catalog_drift: %{count: 0, last_seen_at: nil},
      degraded_no_manifest_catalog: %{count: 0, last_seen_at: nil}
    }
  end
end

defmodule OrchardConsole.NodesLiveTest.TelemetryCountersNonZeroStub do
  @moduledoc false

  def snapshot do
    %{
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      control_token_in_user_content: %{count: 4, last_seen_at: DateTime.utc_now()},
      detector_error: %{count: 5, last_seen_at: DateTime.utc_now()},
      prompt_token_ids_dispatched: %{count: 7, token_count: 42, last_seen_at: DateTime.utc_now()},
      unsafe_mode_active: %{count: 1, last_seen_at: DateTime.utc_now()},
      parity_drift: %{count: 2, last_seen_at: DateTime.utc_now()},
      catalog_drift: %{count: 3, last_seen_at: DateTime.utc_now()},
      degraded_no_manifest_catalog: %{count: 6, last_seen_at: DateTime.utc_now()}
    }
  end
end

defmodule OrchardConsole.NodesLiveTest.TelemetryCountersPartialPromptStub do
  @moduledoc false

  def snapshot do
    %{
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      prompt_token_ids_dispatched: %{count: 3}
    }
  end
end

defmodule OrchardConsole.NodesLiveTest.TelemetryCountersMalformedStub do
  @moduledoc false

  def snapshot do
    %{
      started_at: "not a datetime",
      prompt_token_ids_dispatched: %{count: "many", token_count: :unknown},
      unsafe_mode_active: "bad",
      unknown_counter: %{count: 99}
    }
  end
end

defmodule OrchardConsole.NodesLiveTest.TelemetryCountersRaiseStub do
  @moduledoc false

  def snapshot do
    raise RuntimeError, "counter provider crashed"
  end
end

defmodule OrchardConsole.NodesLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias __MODULE__.RuntimeOversizedMemoryBudgetRowsStub
  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.ClusterManagement.StatusBuilder
  alias Orchard.Nodes
  alias Orchard.Nodes.AdmissionCandidate
  alias Orchard.Repo
  alias OrchardConsole.NodesPageData

  @moduletag :live
  @moduletag :db

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])
    previous_control_plane = Application.get_env(:orchard_controller, :control_plane)

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        runtime_impl: OrchardConsole.NodesLiveTest.RuntimeFullStub,
        telemetry_counters_impl: OrchardConsole.NodesLiveTest.TelemetryCountersZeroStub,
        refresh_interval_ms: 60_000
      )
    )

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)

      if is_nil(previous_control_plane) do
        Application.delete_env(:orchard_controller, :control_plane)
      else
        Application.put_env(:orchard_controller, :control_plane, previous_control_plane)
      end
    end)

    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Route and page rendering
  # ---------------------------------------------------------------------------

  describe "GET /console/nodes" do
    test "a queued refresh cancels the currently scheduled inventory timer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")
      timer = Process.send_after(self(), :unexpected_inventory_timer, 60_000)
      socket = Phoenix.Component.assign(:sys.get_state(view.pid).socket, refresh_timer: timer)
      {:noreply, refreshed} = OrchardConsole.NodesLive.handle_info(:refresh_nodes, socket)
      assert Process.read_timer(timer) == false
      assert is_reference(refreshed.assigns.refresh_timer)
      Process.cancel_timer(refreshed.assigns.refresh_timer)
    end

    test "unavailable inventory reports unknown counts rather than an empty fleet", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")
      socket = :sys.get_state(view.pid).socket
      parent = self()

      ExUnit.CaptureLog.capture_log(fn ->
        spawn(fn ->
          Repo.put_dynamic_repo(:unavailable_inventory_repo)

          send(
            parent,
            {:inventory_refresh,
             OrchardConsole.NodesLive.handle_event("refresh_now", %{}, socket)}
          )
        end)

        assert_receive {:inventory_refresh, {:noreply, failed}}, 2000
        Process.cancel_timer(failed.assigns.refresh_timer)
        assert failed.assigns.inventory.status == :error
        assert failed.assigns.inventory.summary.total == nil

        assert Enum.all?(failed.assigns.inventory.summary.by_health, fn {_health, count} ->
                 is_nil(count)
               end)
      end)
    end

    test "section navigation replaces visible content and survives refresh", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")
      assert has_element?(view, "#nodes-inventory-card:not([hidden])")
      assert has_element?(view, "#nodes-pending-admissions-card[hidden]")
      view |> element("#nodes-section-admissions") |> render_click()
      assert_patch(view, "/console/nodes?section=admissions")
      assert has_element?(view, "#nodes-pending-admissions-card:not([hidden])")
      assert has_element?(view, "#nodes-inventory-card[hidden]")
      view |> element("#nodes-refresh-now") |> render_click()
      assert has_element?(view, "#nodes-section-admissions[aria-current='page']")
      view |> element("#nodes-section-runtime") |> render_click()
      assert has_element?(view, "#nodes-live-cluster-card:not([hidden])")
      assert has_element?(view, "#nodes-control-plane-status-card[hidden]")
      view |> element("#nodes-section-diagnostics") |> render_click()
      assert has_element?(view, "#nodes-safe-tokenization-telemetry-card:not([hidden])")
      assert has_element?(view, "#nodes-runtime-targets[hidden]")
    end

    test "Add Node remains a shared destination across all Nodes sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")

      for section <- ~w(inventory admissions runtime diagnostics) do
        render_patch(view, "/console/nodes?section=#{section}")
        assert has_element?(view, "#add-node[href='/console/nodes/new']", "Add Node")
        refute has_element?(view, "[hidden] #add-node")
        assert has_element?(view, "#nodes-section-#{section}[aria-current='page']")
      end
    end

    test "unknown section falls back to Inventory", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes?section=not-a-section")
      assert has_element?(view, "#nodes-section-inventory[aria-current='page']")
    end

    test "renders nodes page with section titles", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "Add Node"
      assert html =~ "/console/nodes/new"
      assert html =~ "Inventory Summary"
      assert html =~ "Registered Nodes"
      assert html =~ "Lifecycle and health are separate"
      assert html =~ "Live Cluster"
      assert html =~ "Control Plane"
    end

    test "opts into workspace shell while keeping registered nodes primary", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/nodes")

      assert html =~ ~s(class="text-xl font-semibold text-slate-900 dark:text-slate-100")
      assert html =~ ~s(class="max-w-none px-6 sm:px-8 lg:px-10 py-6")
      assert has_element?(view, "#nodes-sections[aria-label=\"Nodes sections\"]")
      assert has_element?(view, "#nodes-inventory-card:not([hidden])")
      assert has_element?(view, "#nodes-live-cluster-card[hidden]")

      cluster = element(view, "#nodes-live-cluster-card") |> render()
      assert cluster =~ "bg-slate-100/70"
      assert cluster =~ ~s(id="nodes-cluster-summary")
      assert cluster =~ "xl:grid-cols-2"
      refute cluster =~ "xl:grid-cols-6"

      control_plane = element(view, "#nodes-control-plane-status-card") |> render()
      assert control_plane =~ "bg-slate-100/70"
      assert control_plane =~ "Control Plane"
      refute control_plane =~ "nodes-cluster-summary"

      counters = element(view, "#nodes-safe-tokenization-telemetry-card") |> render()
      assert counters =~ "bg-slate-50"
      assert counters =~ ~s(id="nodes-safe-tokenization-counters")
      assert counters =~ "xl:grid-cols-4"
      refute counters =~ "xl:grid-cols-2"
    end

    test "has correct page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "Nodes \u2014 Orchard Console"
    end

    test "renders pending admission candidates above registered inventory", %{conn: conn} do
      candidate =
        insert_candidate!(
          observed_identity: %{
            "display_name" => "join-review-candidate",
            "hostname" => "join-review.local"
          },
          target_ref: "10.10.10.44:50071"
        )

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "nodes-pending-admissions-card"
      assert html =~ "join-review-candidate"
      assert html =~ "Pending observed"
      assert html =~ "10.10.10.44:50071"
      assert html =~ "/console/nodes/pending/#{candidate.id}"
    end

    test "renders registered nodes awaiting admission in the pending queue", %{conn: conn} do
      node =
        insert_node!(%{
          display_name: "registered-review-node",
          state: :registered,
          health: :healthy
        })

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "registered-review-node"
      assert html =~ "Pending registered"
      assert html =~ "/console/nodes/#{node.id}"
    end

    test "labels provisioned-placeholder candidates with the short source badge", %{conn: conn} do
      insert_candidate!(
        source: :provisioned_placeholder,
        admission_category: :pending_provisioned,
        observed_identity: %{"display_name" => "provisioned-review-candidate"}
      )

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "provisioned-review-candidate"
      assert html =~ "Pending provisioned"
      refute html =~ "Provisioned placeholder"
    end

    test "keeps rejected admission records visible as audit records", %{conn: conn} do
      candidate =
        insert_candidate!(
          admission_category: :rejected,
          observed_identity: %{"display_name" => "rejected-review-candidate"}
        )

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ "Admission Review"
      assert html =~ "No pending decisions."
      assert html =~ "1 rejected record visible for audit."
      assert html =~ "rejected-review-candidate"
      assert html =~ "Rejected"
      assert html =~ "/console/nodes/pending/#{candidate.id}"
    end
  end

  describe "pending admission page data" do
    test "combines candidates and pending lifecycle nodes with shared status maps" do
      candidate = insert_candidate!(admission_category: :pending_observed)

      node =
        insert_node!(%{
          display_name: "pending-node-page-data",
          state: :registered,
          health: :healthy
        })

      page = NodesPageData.pending_admissions([candidate], [node])

      assert page.status == :ok
      assert page.count == 2
      assert page.pending_count == 2
      assert page.rejected_count == 0
      assert Enum.map(page.rows, & &1.kind) |> Enum.sort() == [:candidate, :node]

      candidate_row = Enum.find(page.rows, &(&1.kind == :candidate))
      node_row = Enum.find(page.rows, &(&1.kind == :node))

      assert candidate_row.status.admission.category == "pending_observed"
      assert candidate_row.status.resource.type == "admission_candidate"
      assert node_row.status.admission.category == "pending_registered"
      assert node_row.status.resource.type == "node"
    end

    test "dispatch-capacity reads do not scale with the pending node count" do
      single = [insert_node!(%{state: :registered, health: :healthy})]

      many =
        Enum.map(1..3, fn _index -> insert_node!(%{state: :registered, health: :healthy}) end)

      assert repo_query_count(fn -> NodesPageData.pending_admissions([], single) end) ==
               repo_query_count(fn -> NodesPageData.pending_admissions([], many) end)
    end

    test "separates pending and rejected review counts" do
      pending_candidate = insert_candidate!(admission_category: :pending_observed)
      rejected_candidate = insert_candidate!(admission_category: :rejected)

      page = NodesPageData.pending_admissions([pending_candidate, rejected_candidate], [])

      assert page.count == 2
      assert page.pending_count == 1
      assert page.rejected_count == 1
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
      assert html =~ "Inspect Node"
      assert html =~ "test.local"
      assert html =~ "192.168.1.10:50071"
      assert html =~ "active"
      assert html =~ "healthy"
      assert html =~ "0.1.0"
    end

    test "page data derives inventory statuses from shared cluster management structures" do
      node =
        insert_node!(
          display_name: "console-status-node",
          state: :registered,
          health: :healthy,
          last_heartbeat_at: DateTime.utc_now()
        )

      page_data = NodesPageData.inventory([node], Nodes.summary())

      assert page_data.statuses == [StatusBuilder.node_status_map(node)]

      assert get_in(page_data.statuses, [Access.at(0), :scheduling, :reason_codes]) == [
               "node_not_admitted"
             ]
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
      assert html =~ "Registered nodes appear after Node Enrollment and a successful node join."
      assert html =~ "A runtime status read only creates an admission candidate for review."
      refute html =~ "after a successful status read"
    end
  end

  # ---------------------------------------------------------------------------
  # Control-plane status
  # ---------------------------------------------------------------------------

  describe "control-plane status" do
    test "SPEC Control Plane Is Read-Only renders directly addressed standby behavior", %{
      conn: conn
    } do
      Application.put_env(:orchard_controller, :control_plane,
        role: :standby,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          %{
            leader_identity: "controller-b",
            advisory_lock_status: :not_held,
            lock_age_ms: 1_200,
            last_renewed_at: ~U[2026-07-01 00:00:00Z]
          }
        end
      )

      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-control-plane-status-card") |> render()

      assert card =~ "Control Plane"
      assert card =~ "Standby"
      assert card =~ "Active/Standby control plane"
      assert card =~ "Active/Standby"
      refute card =~ "Ha lite"
      assert card =~ "Not held"
      assert card =~ "controller-a"
      assert card =~ "controller-b"
      assert card =~ "1200 ms"
      assert card =~ "writes return 503 controller standby"
      refute card =~ "Failover"
      refute card =~ "Transfer"
    end

    test "SPEC Leadership status is unavailable does not infer leadership from local role", %{
      conn: conn
    } do
      Application.put_env(:orchard_controller, :control_plane,
        role: :leader,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          raise DBConnection.ConnectionError,
            message: "password authentication failed for user orchard_admin at db.internal:5432"
        end
      )

      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-control-plane-status-card") |> render()

      assert card =~ "Unknown"
      assert card =~ "Unavailable"
      assert card =~ ~r/<dt[^>]*>Leader identity<\/dt>\s*<dd[^>]*>\s*unknown\s*<\/dd>/
      assert card =~ "Leadership error"
      assert card =~ "advisory_lock_read_failed: db_connection_error"
      refute card =~ "orchard_admin"
      refute card =~ "db.internal"
      refute card =~ "Held"
      refute card =~ "writes allowed when authorized"
    end

    test "SPEC Leadership status sanitizes provider-returned leadership error", %{conn: conn} do
      Application.put_env(:orchard_controller, :control_plane,
        role: :standby,
        this_controller_identity: "controller-a",
        control_plane_status_provider: fn ->
          %{
            leader_identity: "controller-b",
            advisory_lock_status: :not_held,
            last_observed_leadership_error:
              "password authentication failed for user orchard_admin at db.internal:5432"
          }
        end
      )

      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-control-plane-status-card") |> render()

      assert card =~ "Leadership error"
      assert card =~ "advisory_lock_read_failed: provider_reported_error"
      refute card =~ "orchard_admin"
      refute card =~ "db.internal"
    end

    test "single-controller subtitle does not duplicate role copy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-control-plane-status-card") |> render()

      assert card =~ "Single controller control plane"
      refute card =~ "Single controller control plane, Single controller"
    end

    test "disconnected render defers control-plane status until LiveView connects", %{conn: conn} do
      conn = get(conn, "/console/nodes")
      body = html_response(conn, 200)

      assert body =~ "nodes-control-plane-status-card"
      assert body =~ "Loading control-plane status."
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

    test "renders source-dev BEAM Runtime Endpoint targets with readable labels and stable DOM ids",
         %{
           conn: conn
         } do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeBeamTargetStub)

      {:ok, view, html} = live(conn, "/console/nodes")

      assert html =~ ~s(id="nodes-runtime-card-beam-orchard-node-agent-127-0-0-1")
      assert html =~ "beam-node"
      assert html =~ "orchard_node_agent@127.0.0.1"

      summary = element(view, "#nodes-live-cluster-card") |> render()
      assert summary =~ "1 target(s) configured"
      assert summary =~ "1 reachable"
    end

    test "renders map-backed gRPC Runtime Endpoint targets without leaking metadata", %{
      conn: conn
    } do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeGrpcMapTargetStub)

      {:ok, _view, html} = live(conn, "/console/nodes")

      assert html =~ ~s(id="nodes-runtime-card-127-0-0-9-50071")
      assert html =~ "127.0.0.9:50071"
      refute html =~ "must-not-render"
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

  describe "safe tokenization telemetry counters" do
    test "renders process-local observe-only zero counters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-safe-tokenization-telemetry-card") |> render()

      assert card =~ "Safe Tokenization Counters"
      assert card =~ "Process-local observe-only counters since counter process start."
      assert card =~ "Prompt IDs Dispatched"
      assert card =~ "Unsafe Fallback"
      assert card =~ "Parity Drift"
      assert card =~ "Catalog Drift"
      assert card =~ "Control Token Hits"
      assert card =~ "Detector Errors"
      assert card =~ "No Manifest Catalog"
      assert card =~ "0 events · 0 tokens"
      assert card =~ "0"
    end

    test "renders non-zero unsafe signals with warning and error tones", %{conn: conn} do
      put_telemetry_counters_stub(OrchardConsole.NodesLiveTest.TelemetryCountersNonZeroStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      assert element(view, "#nodes-safe-tokenization-counter-prompt-token-ids-dispatched")
             |> render() =~ "7 events · 42 tokens"

      assert element(view, "#nodes-safe-tokenization-counter-unsafe-mode-active")
             |> render() =~ "bg-amber-50/50"

      assert element(view, "#nodes-safe-tokenization-counter-parity-drift")
             |> render() =~ "bg-red-50/50"

      for id <- [
            "catalog-drift",
            "control-token-in-user-content",
            "detector-error",
            "degraded-no-manifest-catalog"
          ] do
        assert element(view, "#nodes-safe-tokenization-counter-#{id}")
               |> render() =~ "bg-amber-50/50"
      end
    end

    test "HTTP dead mount renders non-zero safe tokenization counters", %{conn: conn} do
      put_telemetry_counters_stub(OrchardConsole.NodesLiveTest.TelemetryCountersNonZeroStub)

      conn = get(conn, "/console/nodes")
      body = html_response(conn, 200)

      assert body =~ ~s(id="nodes-safe-tokenization-telemetry-card")

      assert counter_text(body, "nodes-safe-tokenization-counter-prompt-token-ids-dispatched") =~
               "7 events · 42 tokens"

      assert counter_text(body, "nodes-safe-tokenization-counter-unsafe-mode-active") =~
               ~r/Unsafe Fallback\s+1\b/

      assert counter_text(body, "nodes-safe-tokenization-counter-parity-drift") =~
               ~r/Parity Drift\s+2\b/

      assert counter_text(body, "nodes-safe-tokenization-counter-catalog-drift") =~
               ~r/Catalog Drift\s+3\b/

      assert counter_text(body, "nodes-safe-tokenization-counter-control-token-in-user-content") =~
               ~r/Control Token Hits\s+4\b/
    end

    test "partial prompt-token counter preserves valid count and defaults token count", %{
      conn: conn
    } do
      put_telemetry_counters_stub(OrchardConsole.NodesLiveTest.TelemetryCountersPartialPromptStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      assert element(view, "#nodes-safe-tokenization-counter-prompt-token-ids-dispatched")
             |> render() =~ "3 events · 0 tokens"
    end

    test "malformed counter provider fails open without changing cluster diagnostics", %{
      conn: conn
    } do
      put_telemetry_counters_stub(OrchardConsole.NodesLiveTest.TelemetryCountersMalformedStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-safe-tokenization-telemetry-card") |> render()
      cluster = element(view, "#nodes-live-cluster-card") |> render()
      capable_tile = element(view, "#cluster-prompt-token-capable") |> render()

      assert card =~ "0 events · 0 tokens"
      assert cluster =~ "1 target(s) configured"
      assert cluster =~ "1 reachable"
      assert capable_tile =~ "1/1"
      assert capable_tile =~ "bg-forest-50/50"
    end

    test "raising counter provider fails open and keeps Live Cluster rendering", %{conn: conn} do
      put_telemetry_counters_stub(OrchardConsole.NodesLiveTest.TelemetryCountersRaiseStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      card = element(view, "#nodes-safe-tokenization-telemetry-card") |> render()
      cluster = element(view, "#nodes-live-cluster-card") |> render()

      assert card =~ "0 events · 0 tokens"
      assert cluster =~ "Live Cluster"
      assert cluster =~ "1 reachable"
    end

    test "counters do not affect health, compatibility, or prompt-token summaries", %{conn: conn} do
      put_runtime_stub(OrchardConsole.NodesLiveTest.RuntimeMixedCompatibilityStub)
      put_telemetry_counters_stub(OrchardConsole.NodesLiveTest.TelemetryCountersNonZeroStub)

      {:ok, view, _html} = live(conn, "/console/nodes")

      cluster = element(view, "#nodes-live-cluster-card") |> render()
      capable_tile = element(view, "#cluster-prompt-token-capable") |> render()

      assert cluster =~ "2 target(s) configured"
      assert cluster =~ "2 reachable"
      assert capable_tile =~ "1/2"
      assert capable_tile =~ "bg-slate-50"

      assert element(view, "#nodes-runtime-compat-10-0-0-5-50061")
             |> render() =~ "does not report metadata or health"
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
      assert html =~ "Last refresh attempt"
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

  defp put_telemetry_counters_stub(stub_module) do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.put(previous, :telemetry_counters_impl, stub_module)
    )
  end

  defp counter_text(html, id) do
    # The summary_tile currently renders each counter as a flat tile; this helper
    # intentionally scopes assertions to that tile's HTML for the HTTP dead mount.
    escaped_id = Regex.escape(id)
    pattern = ~r/<div id="#{escaped_id}"[^>]*>(?<content>.*?)<\/div>/s

    case Regex.named_captures(pattern, html) do
      %{"content" => content} ->
        content
        |> String.replace(~r/<[^>]+>/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      nil ->
        ""
    end
  end

  defp assert_no_memory_policy_terms(html) do
    refute html =~ "eligible"
    refute html =~ "capacity OK"
    refute html =~ "admittable"
    refute html =~ "fits"
    refute html =~ "can admit"
  end

  defp repo_query_count(fun) do
    handler_id = {:repo_query_count, System.unique_integer([:positive])}
    test = self()

    :telemetry.attach(
      handler_id,
      [:orchard, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(test, {handler_id, :query}) end,
      nil
    )

    try do
      fun.()
      drain_repo_queries(handler_id, 0)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_queries(handler_id, count) do
    receive do
      {^handler_id, :query} -> drain_repo_queries(handler_id, count + 1)
    after
      0 -> count
    end
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

  defp insert_candidate!(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      source: :runtime_endpoint_observation,
      admission_category: :pending_observed,
      observed_identity: %{
        "claimed_node_id" => Ecto.UUID.generate(),
        "display_name" => "candidate-#{unique}",
        "hostname" => "candidate-#{unique}.local"
      },
      target_ref: "10.0.0.#{rem(unique, 200) + 1}:50071",
      endpoint_transport: :grpc,
      endpoint_target: "10.0.0.#{rem(unique, 200) + 1}:50071",
      inventory: %{"capabilities" => %{}},
      compatibility_evidence: %{"metadata" => "partial"},
      last_observed_at: DateTime.utc_now()
    }

    merged = Map.merge(defaults, Map.new(attrs))

    %AdmissionCandidate{}
    |> AdmissionCandidate.changeset(merged)
    |> Repo.insert!()
  end
end
