defmodule OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub do
  @moduledoc false

  def cluster_snapshot(_opts \\ []) do
    node_id = :persistent_term.get({__MODULE__, :node_id})

    recommended_context_tokens =
      :persistent_term.get({__MODULE__, :recommended_context_tokens}, 24_576)

    truncated_count = :persistent_term.get({__MODULE__, :truncated_count}, 0)

    [
      %{
        target: [host: "127.0.0.1", port: 50_071],
        status: :ok,
        message: nil,
        worker_state: :idle,
        loaded_models: [%{model_id: "test-model", version: "v1"}],
        active_request_count: 0,
        node_metadata: %{node_id: node_id, display_name: "detail-budget-node"},
        runtime_health: %{ready: true, health_code: "ok", health_message: nil},
        supports_prompt_token_ids: true,
        runtime_memory_budgets: [
          %{
            display_state: :observed,
            model_ref: "test-model@v1",
            mode: "observe",
            budget_available: true,
            headroom_available: true,
            status_code: "ok",
            status_message: "within budget",
            target_working_set_bytes: 12_884_901_888,
            resident_memory_bytes: 8_589_934_592,
            kv_cache_bytes_per_token: 16_384,
            prefill_workspace_bytes_per_token: 2_048,
            recommended_context_tokens: recommended_context_tokens
          }
        ],
        runtime_memory_budgets_truncated_count: truncated_count,
        runtime_prefix_cache_statuses: []
      }
    ]
  end
end

defmodule OrchardConsole.NodeDetailLiveTest do
  use Orchard.ConnCase, async: false

  import Orchard.TestSupport.ModelRequestFixtures, only: [create_model!: 1]
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}
  alias Orchard.NodeTrust
  alias Orchard.Repo

  @moduletag :live
  @moduletag :db

  setup do
    previous_console = Application.get_env(:orchard_controller, :console, [])
    previous_control_plane = Application.get_env(:orchard_controller, :control_plane, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.put(previous_console, :refresh_interval_ms, 60_000)
    )

    Application.put_env(:orchard_controller, :control_plane, role: :single_controller)

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous_console)

      :persistent_term.erase(
        {OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub, :node_id}
      )

      :persistent_term.erase(
        {OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub, :recommended_context_tokens}
      )

      :persistent_term.erase(
        {OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub, :truncated_count}
      )

      Application.put_env(:orchard_controller, :control_plane, previous_control_plane)
    end)

    Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "node detail drill-in" do
    test "renders separated status groups and pending actions", %{conn: conn} do
      node =
        insert_node!(%{
          display_name: "registered-detail-node",
          state: :registered,
          health: :healthy
        })

      {:ok, _view, html} = live(conn, "/console/nodes/#{node.id}")

      assert html =~ "registered-detail-node"
      assert html =~ "node-detail-lifecycle"
      assert html =~ "node-detail-admission"
      assert html =~ "node-detail-health"
      assert html =~ "node-detail-freshness"
      assert html =~ "node-detail-transport"
      assert html =~ "node-detail-runtime"
      assert html =~ "node-detail-compatibility"
      assert html =~ "node-detail-scheduling"
      assert html =~ "Blocked"
      assert html =~ "node_not_admitted"
      assert html =~ "Preview admit"
      assert html =~ "Preview reject"
    end

    test "renders SPEC.md §7.5.3 memory budget telemetry for node detail", %{conn: conn} do
      node =
        insert_node!(%{
          display_name: "detail-budget-node",
          state: :active,
          health: :healthy
        })

      create_model!(%{model_id: "test-model", version: "v1", max_context_tokens: 32_768})

      :persistent_term.put(
        {OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub, :node_id},
        node.id
      )

      :persistent_term.put(
        {OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub, :recommended_context_tokens},
        0
      )

      put_runtime_stub(OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub)

      {:ok, _view, html} = live(conn, "/console/nodes/#{node.id}")

      assert html =~ "node-detail-memory-budget"
      assert html =~ "Memory Telemetry"
      assert html =~ "test-model@v1"
      assert html =~ "ok"
      assert html =~ "within budget"
      assert html =~ "Max Context"
      assert html =~ "32768"
      assert html =~ "Recommended Context"
      assert html =~ "unknown"
      refute html =~ "Recommended Context</span><span class=\"font-mono\">0"
    end

    test "surfaces truncated memory budget rows in the telemetry card", %{conn: conn} do
      node =
        insert_node!(%{
          display_name: "detail-budget-node",
          state: :active,
          health: :healthy
        })

      create_model!(%{model_id: "test-model", version: "v1", max_context_tokens: 32_768})

      :persistent_term.put(
        {OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub, :node_id},
        node.id
      )

      :persistent_term.put(
        {OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub, :truncated_count},
        2
      )

      put_runtime_stub(OrchardConsole.NodeDetailLiveTest.RuntimeMemoryBudgetStub)

      {:ok, _view, html} = live(conn, "/console/nodes/#{node.id}")

      assert html =~ "node-detail-memory-budget-truncation"
      assert html =~ "2 additional memory budget row(s) truncated upstream."
    end

    test "renders candidate evidence without exposing direct admit", %{conn: conn} do
      candidate =
        insert_candidate!(
          observed_identity: %{
            "display_name" => "candidate-detail-row",
            "hostname" => "candidate-detail.local"
          },
          inventory: %{"capabilities" => %{"mlx" => true}},
          compatibility_evidence: %{"metadata" => "partial"}
        )

      {:ok, _view, html} = live(conn, "/console/nodes/pending/#{candidate.id}")

      assert html =~ "candidate-detail-row"
      assert html =~ "Candidate Evidence"
      assert html =~ "node-detail-observed-identity"
      assert html =~ "node-detail-inventory-evidence"
      assert html =~ "node-detail-compatibility-evidence"
      assert html =~ "Preview reject"
      refute html =~ "Preview admit"
    end

    test "renders not found state for missing candidates", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/nodes/pending/#{Ecto.UUID.generate()}")

      assert html =~ "node-detail-not-found"
      assert html =~ "The requested admission candidate was not found."
    end
  end

  describe "observed candidate enrollment guidance" do
    test "renders full read-only guidance and preserves rejection-only controls", %{conn: conn} do
      candidate = insert_candidate!(%{})

      {:ok, _view, html} = live(conn, "/console/nodes/pending/#{candidate.id}")

      assert html =~ ~s(id="node-detail-enrollment-guidance-card")
      assert html =~ "Observation does not enroll or register the node."
      assert html =~ "Enrollment bundle creation requires a configured Controller HTTPS endpoint."
      assert html =~ "orchardctl nodes trust init"

      assert html =~
               "orchardctl nodes enrollment create --output PATH [--expires-in DURATION]"

      assert html =~ "orchardctl node join --enrollment-bundle PATH"

      assert html =~
               "the node appears under Admission Review as a separate pending registered entry"

      assert html =~
               "This observed candidate is a separate review row that the join does not close."

      assert html =~ "It stays listed until an operator rejects or otherwise clears it."
      assert html =~ "Preview reject"
      refute html =~ "Preview admit"
    end

    test "renders command sequence as a visibly numbered recessed code well", %{conn: conn} do
      candidate = insert_candidate!(%{})

      {:ok, _view, html} = live(conn, "/console/nodes/pending/#{candidate.id}")

      [_, ol_attrs | _] = String.split(html, ~s(id="node-detail-enrollment-commands"), parts: 2)
      [ol_tag | _] = String.split(ol_attrs, ">", parts: 2)

      assert ol_tag =~ "list-decimal"
      assert ol_tag =~ "pl-5"

      code_classes =
        html
        |> String.split(~s(<code class="block rounded))
        |> tl()
        |> Enum.map(&(&1 |> String.split(~s("), parts: 2) |> hd()))

      assert length(code_classes) == 3
      assert Enum.all?(code_classes, &String.contains?(&1, "bg-slate-50"))
      assert Enum.all?(code_classes, &String.contains?(&1, "dark:bg-slate-900/60"))
      refute Enum.any?(code_classes, &String.contains?(&1, "bg-white"))
      refute Enum.any?(code_classes, &String.contains?(&1, "dark:bg-slate-950"))
    end

    test "renders guidance before Candidate Evidence", %{conn: conn} do
      candidate = insert_candidate!(%{})

      {:ok, _view, html} = live(conn, "/console/nodes/pending/#{candidate.id}")

      {guidance_index, _length} =
        :binary.match(html, ~s(id="node-detail-enrollment-guidance-card"))

      {evidence_index, _length} =
        :binary.match(html, ~s(id="node-detail-candidate-evidence-card"))

      assert guidance_index < evidence_index
    end

    test "does not render guidance for non-observed candidates", %{conn: conn} do
      candidate =
        insert_candidate!(%{
          source: :provisioned_placeholder,
          admission_category: :pending_provisioned
        })

      {:ok, _view, html} = live(conn, "/console/nodes/pending/#{candidate.id}")

      assert html =~ "Candidate Evidence"
      refute html =~ "node-detail-enrollment-guidance-card"
    end

    test "does not render guidance for registered node details", %{conn: conn} do
      node = insert_node!(%{state: :registered})

      {:ok, _view, html} = live(conn, "/console/nodes/#{node.id}")

      refute html =~ "node-detail-enrollment-guidance-card"
    end
  end

  describe "admission action previews" do
    test "previews and executes node admit with shared blockers and confirmation", %{conn: conn} do
      trust = establish_local_controller_identity!()

      node =
        insert_node!(%{
          display_name: "admit-detail-node",
          state: :registered,
          health: :healthy
        })

      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")

      view
      |> element("#node-detail-open-admit")
      |> render_click()

      html = render(view)
      assert html =~ "Admit Node Preview"
      assert html =~ "Blocked"
      assert html =~ "trust_not_established"
      assert html =~ "requires_yes_flag"

      admission_attrs = %{
        "action" => %{
          "trust_evidence_ref" => "registration-audit:test",
          "pool_id" => Ecto.UUID.generate(),
          "routing_policy_id" => Ecto.UUID.generate(),
          "capacity_policy_reason" => "approved from Console admission review",
          "controller_dispatch_ceiling" => "1",
          "confirmed" => "true"
        }
      }

      view
      |> form("#admission-action-form", admission_attrs)
      |> render_change()

      view
      |> form("#admission-action-form", admission_attrs)
      |> render_submit()

      assert Repo.get!(Node, node.id).state == :admitted

      policy = Repo.get!(Policy, node.id)
      assert policy.approved_by_actor_type == "operator"
      assert policy.approved_by_actor_id == trust.controller_uri_san

      assert %AdmissionDecision{decision: :admitted} =
               Nodes.latest_admission_decision_for_node(node.id)

      assert render(view) =~ "Admitted"
    end

    test "previews and executes candidate reject with required reason", %{conn: conn} do
      candidate = insert_candidate!(target_ref: "10.4.0.22:50071")

      {:ok, view, _html} = live(conn, "/console/nodes/pending/#{candidate.id}")

      view
      |> element("#node-detail-open-reject")
      |> render_click()

      html = render(view)
      assert html =~ "Reject Admission Preview"
      assert html =~ "requires_reason"
      assert html =~ "A nonblank rejection reason is required."

      reject_attrs = %{
        "action" => %{
          "reason" => "untrusted bootstrap source",
          "confirmed" => "true"
        }
      }

      view
      |> form("#admission-action-form", reject_attrs)
      |> render_change()

      view
      |> form("#admission-action-form", reject_attrs)
      |> render_submit()

      assert Repo.get!(AdmissionCandidate, candidate.id).admission_category == :rejected

      assert %AdmissionDecision{decision: :rejected, reason: "untrusted bootstrap source"} =
               Nodes.latest_admission_decision_for_candidate(candidate.id)

      assert render(view) =~ "Rejected"
      refute render(view) =~ "Preview reject"
    end

    test "preserves execute-action error across periodic refresh", %{conn: conn} do
      candidate = insert_candidate!(target_ref: "10.4.0.44:50071")

      {:ok, view, _html} = live(conn, "/console/nodes/pending/#{candidate.id}")

      view
      |> element("#node-detail-open-reject")
      |> render_click()

      view
      |> form("#admission-action-form", %{"action" => %{"reason" => "", "confirmed" => "true"}})
      |> render_submit()

      assert has_element?(
               view,
               "#action-preview-error",
               "Resolve blockers and confirm the preview before executing."
             )

      send(view.pid, :refresh_node_detail)
      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#action-preview-error",
               "Resolve blockers and confirm the preview before executing."
             )
    end
  end

  describe "lifecycle action previews" do
    test "renders lifecycle preview affordances for node rows only", %{conn: conn} do
      node = insert_node!(state: :active, display_name: "lifecycle-affordance-node")
      candidate = insert_candidate!(target_ref: "10.4.0.88:50071")

      {:ok, _view, node_html} = live(conn, "/console/nodes/#{node.id}")

      assert node_html =~ "Preview cordon"
      assert node_html =~ "Preview uncordon"
      assert node_html =~ "Preview drain"
      assert node_html =~ "Preview maintenance"
      assert node_html =~ "Preview resume"
      assert node_html =~ "Preview decommission"

      {:ok, _view, candidate_html} = live(conn, "/console/nodes/pending/#{candidate.id}")

      refute candidate_html =~ "Preview cordon"
      refute candidate_html =~ "Preview uncordon"
      refute candidate_html =~ "Preview drain"
      refute candidate_html =~ "Preview maintenance"
      refute candidate_html =~ "Preview resume"
      refute candidate_html =~ "Preview decommission"
    end

    test "previews and executes node cordon through the shared action preview", %{conn: conn} do
      node =
        insert_node!(%{
          display_name: "cordon-detail-node",
          state: :active,
          health: :healthy
        })

      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")

      view
      |> element("#node-detail-open-lifecycle-cordon")
      |> render_click()

      html = render(view)
      assert html =~ "Cordon Node Preview"
      assert html =~ "node_lifecycle.cordon"
      assert html =~ "requires_yes_flag"
      assert html =~ "Active"
      assert html =~ "Cordoned"

      view
      |> form("#node-action-form", %{"action" => %{"confirmed" => "true"}})
      |> render_change()

      view
      |> form("#node-action-form", %{"action" => %{"confirmed" => "true"}})
      |> render_submit()

      assert Repo.get!(Node, node.id).state == :cordoned
      assert render(view) =~ "Cordoned"
    end

    test "gates decommission execution on typed node id and consequence acknowledgement", %{
      conn: conn
    } do
      node =
        insert_node!(%{
          display_name: "decommission-detail-node",
          state: :active,
          health: :healthy
        })

      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")

      view
      |> element("#node-detail-open-lifecycle-decommission")
      |> render_click()

      html = render(view)
      assert html =~ "Decommission Node Preview"
      assert html =~ "requires_typed_node_id"
      assert html =~ "requires_decommission_consequence_acknowledgement"
      assert html =~ "future_scheduling_revoked"
      assert html =~ "no_rejoin_with_same_node_id"
      assert has_element?(view, "#action-submit[disabled]")

      decommission_attrs = %{
        "action" => %{
          "node_id_confirmation" => node.id,
          "acknowledged" => "true",
          "confirmed" => "true"
        }
      }

      view
      |> form("#node-action-form", decommission_attrs)
      |> render_change()

      view
      |> form("#node-action-form", decommission_attrs)
      |> render_submit()

      assert Repo.get!(Node, node.id).state == :decommissioning
      assert render(view) =~ "Decommissioning"
    end

    test "gates drain execution on consequence acknowledgement", %{conn: conn} do
      node =
        insert_node!(%{
          display_name: "drain-detail-node",
          state: :active,
          health: :healthy
        })

      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")

      view
      |> element("#node-detail-open-lifecycle-drain")
      |> render_click()

      html = render(view)
      assert html =~ "Drain Node Preview"
      assert html =~ "node_lifecycle.drain"
      assert html =~ "existing_requests_continue_until_deadline"
      assert html =~ "requires_drain_consequence_acknowledgement"
      assert has_element?(view, "#action-submit[disabled]")

      view
      |> form("#node-action-form", %{"action" => %{"confirmed" => "true"}})
      |> render_change()

      assert has_element?(view, "#action-submit[disabled]")

      drain_attrs = %{
        "action" => %{
          "acknowledged" => "true",
          "confirmed" => "true"
        }
      }

      view
      |> form("#node-action-form", drain_attrs)
      |> render_change()

      view
      |> form("#node-action-form", drain_attrs)
      |> render_submit()

      assert Repo.get!(Node, node.id).state == :draining
      assert render(view) =~ "Draining"
    end

    test "shows invalid-state lifecycle blockers without allowing execution", %{conn: conn} do
      node =
        insert_node!(%{
          display_name: "blocked-cordon-detail-node",
          state: :registered,
          health: :healthy
        })

      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")

      view
      |> element("#node-detail-open-lifecycle-cordon")
      |> render_click()

      html = render(view)
      assert html =~ "Cordon Node Preview"
      assert html =~ "node_not_admitted"
      assert has_element?(view, "#action-submit[disabled]")

      view
      |> form("#node-action-form", %{"action" => %{"confirmed" => "true"}})
      |> render_submit()

      assert Repo.get!(Node, node.id).state == :registered
      assert render(view) =~ "Resolve blockers and confirm the preview before executing."
    end

    test "OpenSpec cancel drain preview executes to cordoned", %{conn: conn} do
      node =
        insert_node!(%{
          display_name: "cancel-drain-detail-node",
          state: :draining,
          health: :healthy
        })

      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")

      view
      |> element("#node-detail-open-lifecycle-cancel_drain")
      |> render_click()

      html = render(view)
      assert html =~ "Cancel Drain Preview"
      assert html =~ "node_lifecycle.drain_cancelled"
      assert html =~ "Draining"
      assert html =~ "Cordoned"
      assert has_element?(view, "#action-submit[disabled]")

      attrs = %{"action" => %{"confirmed" => "true"}}

      view
      |> form("#node-action-form", attrs)
      |> render_change()

      view
      |> form("#node-action-form", attrs)
      |> render_submit()

      assert Repo.get!(Node, node.id).state == :cordoned
      assert render(view) =~ "Node drain cancelled."
    end

    test "previews maintenance but keeps execution blocked until drain completion is verified", %{
      conn: conn
    } do
      node =
        insert_node!(%{
          display_name: "maintenance-detail-node",
          state: :draining,
          health: :healthy
        })

      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")

      view
      |> element("#node-detail-open-lifecycle-maintenance")
      |> render_click()

      html = render(view)
      assert html =~ "Maintenance Node Preview"
      assert html =~ "node_lifecycle.maintenance"
      assert html =~ "drain_completion_unverified"
      assert html =~ "Draining"
      assert html =~ "Maintenance"
      assert has_element?(view, "#action-submit[disabled]")

      view
      |> form("#node-action-form", %{"action" => %{"confirmed" => "true"}})
      |> render_submit()

      assert Repo.get!(Node, node.id).state == :draining
      assert render(view) =~ "Resolve blockers and confirm the preview before executing."
    end
  end

  defp establish_local_controller_identity! do
    previous_trust = Application.get_env(:orchard_controller, :node_trust)

    root =
      Path.join(
        System.tmp_dir!(),
        "orchard-console-node-trust-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    trust_root = Path.join(root, "node-trust")
    Application.put_env(:orchard_controller, :node_trust, root: trust_root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous_trust do
        Application.put_env(:orchard_controller, :node_trust, previous_trust)
      else
        Application.delete_env(:orchard_controller, :node_trust)
      end
    end)

    {:ok, trust} = NodeTrust.initialize(root: trust_root)
    trust
  end

  defp insert_node!(attrs) do
    unique = System.unique_integer([:positive])

    defaults = %{
      id: Ecto.UUID.generate(),
      hostname: "detail-node-#{unique}.local",
      display_name: "detail-node-#{unique}",
      advertise_addr: "10.30.#{rem(unique, 200)}.#{rem(unique, 250) + 1}",
      rpc_port: 50_071,
      state: :active,
      health: :healthy,
      capabilities: %{},
      tool_readiness: %{},
      agent_version: "0.1.0",
      last_heartbeat_at: DateTime.utc_now()
    }

    merged = Map.merge(defaults, Map.new(attrs))

    %Node{}
    |> Node.changeset(merged)
    |> Repo.insert!()
  end

  defp put_runtime_stub(stub) do
    Application.put_env(
      :orchard_controller,
      :console,
      Application.get_env(:orchard_controller, :console, [])
      |> Keyword.put(:runtime_impl, stub)
    )
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
      target_ref: "10.5.0.#{rem(unique, 200) + 1}:50071",
      endpoint_transport: :grpc,
      endpoint_target: "10.5.0.#{rem(unique, 200) + 1}:50071",
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
