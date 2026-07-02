defmodule OrchardConsole.NodeDetailLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}
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

  describe "admission action previews" do
    test "previews and executes node admit with shared blockers and confirmation", %{conn: conn} do
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
