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
  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.DispatchCapacity.Policy
  alias Orchard.NodeEnrollments
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}
  alias Orchard.NodeTrust
  alias Orchard.Repo
  alias Phoenix.HTML.Safe

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
    test "refresh after deletion clears the old title and refresh timestamp", %{conn: conn} do
      node = insert_node!(%{display_name: "deleted-node-detail", state: :registered})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")
      assert has_element?(view, "#node-detail-last-success")
      Repo.delete!(node)
      view |> element("#node-detail-refresh") |> render_click()
      assert has_element?(view, "#node-detail-not-found")
      refute has_element?(view, "#node-detail-last-success")
      refute has_element?(view, "#node-detail-content")
      assert :sys.get_state(view.pid).socket.assigns.page_title == "Node Detail"
    end

    test "detail sections replace visible evidence and preserve an open action", %{conn: conn} do
      node = insert_node!(%{state: :registered, health: :healthy})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")
      assert has_element?(view, "#node-detail-lifecycle:not([hidden])")
      assert has_element?(view, "#node-detail-runtime[hidden]")
      view |> element("#node-detail-section-evidence") |> render_click()
      assert has_element?(view, "#node-detail-runtime:not([hidden])")
      assert has_element?(view, "#node-detail-lifecycle[hidden]")
      view |> element("#node-detail-section-actions") |> render_click()
      assert has_element?(view, "#node-detail-actions-section:not([hidden])")
      view |> element("#node-detail-open-admit") |> render_click()
      assert has_element?(view, "#node-action-preview")
      view |> element("#node-detail-section-overview") |> render_click()
      assert has_element?(view, "#node-detail-actions-section[hidden]")
      view |> element("#node-detail-section-actions") |> render_click()
      assert has_element?(view, "#node-action-preview")
      view |> element("#action-close-preview") |> render_click()
      refute has_element?(view, "#node-action-preview")
      assert Repo.get!(Node, node.id).state == :registered
    end

    test "deep linked Actions retains Admission Review return context", %{conn: conn} do
      node = insert_node!(%{state: :registered, health: :healthy})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}?section=actions&from=admissions")
      assert has_element?(view, "#node-detail-section-actions[aria-current='page']")
      assert has_element?(view, "a[href='/console/nodes?section=admissions']")
      view |> element("#node-detail-section-evidence") |> render_click()
      assert has_element?(view, "a[href='/console/nodes?section=admissions']")
    end

    test "candidate evidence labels historical transport and keeps Admission Review through the linked Node",
         %{conn: conn} do
      node = insert_node!(%{state: :registered, health: :healthy})
      observed_at = DateTime.add(DateTime.utc_now(), -120, :second)

      candidate =
        insert_candidate!(%{
          node_id: node.id,
          compatibility_evidence: %{"health" => "healthy"},
          last_observed_at: observed_at
        })

      {:ok, view, html} =
        live(conn, "/console/nodes/pending/#{candidate.id}?section=evidence&from=admissions")

      assert html =~ "Observation: Unreachable"

      assert has_element?(
               view,
               "#node-detail-transport:not([hidden])",
               "Transport at last observation"
             )

      assert has_element?(view, "#node-detail-transport-status", "Observed transport")
      assert has_element?(view, "#node-detail-transport-observed-at")

      expected_time = observed_at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      assert has_element?(
               view,
               ~s(#node-detail-transport-observed-at time[datetime="#{expected_time}"])
             )

      linked_path = "/console/nodes/#{node.id}?from=admissions"
      assert has_element?(view, "#node-detail-review-linked-node[href='#{linked_path}']")

      {:ok, linked_view, _html} =
        view
        |> element("#node-detail-review-linked-node")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(linked_view, "a[href='/console/nodes?section=admissions']")
    end

    test "manual refresh reloads inventory detail without a lifecycle action", %{conn: conn} do
      node = insert_node!(%{display_name: "before-refresh", state: :registered, health: :healthy})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")
      node |> Ecto.Changeset.change(display_name: "after-refresh") |> Repo.update!()
      html = view |> element("#node-detail-refresh") |> render_click()
      assert html =~ "after-refresh"
      assert html =~ "Last successful page refresh"
      assert Repo.get!(Node, node.id).state == :registered
    end

    test "failed refresh retains labeled evidence and blocks actions until recovery", %{
      conn: conn
    } do
      node = insert_node!(%{display_name: "retained-node", state: :registered, health: :healthy})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")
      socket = :sys.get_state(view.pid).socket

      ExUnit.CaptureLog.capture_log(fn ->
        parent = self()

        spawn(fn ->
          Repo.put_dynamic_repo(:unavailable_node_detail_repo)
          result = OrchardConsole.NodeDetailLive.handle_event("refresh_detail", %{}, socket)
          send(parent, {:unavailable_refresh, result})
        end)

        assert_receive {:unavailable_refresh, {:noreply, stale}}, 2000

        Process.cancel_timer(stale.assigns.refresh_timer)
        assert stale.assigns.load_status == :stale
        assert stale.assigns.record.id == node.id
        assert stale.assigns.last_successful_refresh == socket.assigns.last_successful_refresh
        assert stale.assigns.action == nil

        html =
          stale.assigns
          |> OrchardConsole.NodeDetailLive.render()
          |> Safe.to_iodata()
          |> IO.iodata_to_binary()

        assert html =~ "Showing the last successful detail"
        refute html =~ "id=\"node-detail-actions\""

        {:noreply, blocked} =
          OrchardConsole.NodeDetailLive.handle_event(
            "open_lifecycle",
            %{"action" => "cordon"},
            stale
          )

        assert blocked.assigns.action == nil
        assert blocked.assigns.flash["error"] =~ "Refresh Node detail successfully"

        {:noreply, recovered} =
          OrchardConsole.NodeDetailLive.handle_event(
            "refresh_detail",
            %{},
            stale
          )

        Process.cancel_timer(recovered.assigns.refresh_timer)
        assert recovered.assigns.load_status == :ok
        assert recovered.assigns.record.id == node.id
      end)
    end

    test "action preview opens before evidence and closes without executing", %{conn: conn} do
      node = insert_node!(%{state: :registered, health: :healthy})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")
      html = view |> element("#node-detail-open-admit") |> render_click()
      {header, _} = :binary.match(html, "id=\"node-detail-header-card\"")
      {preview, _} = :binary.match(html, "id=\"node-action-preview\"")
      {evidence, _} = :binary.match(html, "id=\"node-detail-status-groups\"")
      assert header < preview
      assert preview < evidence
      assert has_element?(view, "#node-action-preview-heading[tabindex='-1'][phx-mounted]")
      view |> element("#action-close-preview") |> render_click()
      refute has_element?(view, "#node-action-preview")
      assert Repo.get!(Node, node.id).state == :registered
    end

    test "a queued refresh cancels the currently scheduled detail timer", %{conn: conn} do
      node = insert_node!(%{state: :registered, health: :healthy})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")
      timer = Process.send_after(self(), :unexpected_detail_timer, 60_000)
      socket = Phoenix.Component.assign(:sys.get_state(view.pid).socket, refresh_timer: timer)

      {:noreply, refreshed} =
        OrchardConsole.NodeDetailLive.handle_info(:refresh_node_detail, socket)

      assert Process.read_timer(timer) == false
      assert is_reference(refreshed.assigns.refresh_timer)
      Process.cancel_timer(refreshed.assigns.refresh_timer)
    end

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
      assert html =~ "Admit Node"
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
      refute html =~ "Admit Node"
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
               "This observed candidate remains a separate Admission Review record that the join does not close."

      refute html =~ "otherwise clears it"
      assert html =~ "Preview reject"
      refute html =~ "Admit Node"
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
      assert Enum.all?(code_classes, &String.contains?(&1, "shadow-inner"))
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
    test "pre-fills the non-authoritative pool intent from Node Enrollment", %{conn: conn} do
      trust = establish_local_controller_identity!()
      now = DateTime.utc_now()

      assert {:ok, result} =
               NodeEnrollments.create(
                 %{
                   cluster_id: trust.cluster_id,
                   expected_controller_id: trust.controller_id,
                   trust_authority_id: trust.trust_authority_id,
                   creator_type: "operator",
                   expires_at: DateTime.add(now, 3_600, :second),
                   node: %{display_name: "pool-intent-node"},
                   audit_metadata: %{
                     "surface" => "console",
                     "initial_pool_id" => "general"
                   }
                 },
                 now: now
               )

      from(node in Node, where: node.id == ^result.enrollment.node_id)
      |> Repo.update_all(
        set: [
          state: :registered,
          hostname: "pool-intent-node.local",
          advertise_addr: "10.40.0.20",
          rpc_port: 50_071,
          connect_host: "10.40.0.20",
          connect_port: 50_071
        ]
      )

      {:ok, view, _html} = live(conn, "/console/nodes/#{result.enrollment.node_id}")
      view |> element("#node-detail-open-admit") |> render_click()

      assert has_element?(view, "#action-pool-id[value='general']")
      assert render(view) =~ "Admit Node Preview"
    end

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

    test "retains confirmation when a refresh leaves the action preview unchanged", %{conn: conn} do
      node = insert_node!(%{state: :active, health: :healthy})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}?section=actions")

      view |> element("#node-detail-open-lifecycle-cordon") |> render_click()

      view
      |> form("#node-action-form", %{"action" => %{"confirmed" => "true"}})
      |> render_change()

      assert :sys.get_state(view.pid).socket.assigns.action.confirmed

      send(view.pid, :refresh_node_detail)
      _ = :sys.get_state(view.pid)

      assert :sys.get_state(view.pid).socket.assigns.action.confirmed
      assert has_element?(view, "#action-confirmed[checked]")
    end

    test "clears confirmation when refreshed authoritative preview facts change", %{conn: conn} do
      node = insert_node!(%{state: :active, health: :healthy})
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}?section=actions")

      view |> element("#node-detail-open-lifecycle-cordon") |> render_click()

      view
      |> form("#node-action-form", %{"action" => %{"confirmed" => "true"}})
      |> render_change()

      assert :sys.get_state(view.pid).socket.assigns.action.confirmed

      node
      |> Ecto.Changeset.change(health: :degraded)
      |> Repo.update!()

      send(view.pid, :refresh_node_detail)
      _ = :sys.get_state(view.pid)

      refute :sys.get_state(view.pid).socket.assigns.action.confirmed
      refute has_element?(view, "#action-confirmed[checked]")
      assert has_element?(view, "#action-submit[disabled]")
      assert has_element?(view, "#node-detail-header-card", "Health: Degraded")
    end
  end

  describe "lifecycle action previews" do
    test "Current reports Node lifecycle and stays unknown when current evidence is absent", %{
      conn: conn
    } do
      node = insert_node!(state: :cordoned, health: :healthy)
      {:ok, view, _html} = live(conn, "/console/nodes/#{node.id}")
      view |> element("#node-detail-open-lifecycle-uncordon") |> render_click()
      assert has_element?(view, "#action-preview-current-state", "Cordoned")
      socket = :sys.get_state(view.pid).socket
      action = Map.update!(socket.assigns.action, :preview, &Map.put(&1, :current, %{}))
      assigns = Phoenix.Component.assign(socket, :action, action).assigns
      html = render_component(&OrchardConsole.NodeDetailLive.render/1, assigns)

      assert html
             |> LazyHTML.from_document()
             |> LazyHTML.query("#action-preview-current-state")
             |> LazyHTML.text() =~ "unknown"
    end

    test "Current reports the candidate admission category before rejection", %{conn: conn} do
      candidate = insert_candidate!(target_ref: "10.4.0.92:50071")
      {:ok, view, _html} = live(conn, "/console/nodes/pending/#{candidate.id}")
      view |> element("#node-detail-open-reject") |> render_click()
      assert has_element?(view, "#action-preview-current-state", "Pending observed")
    end

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
