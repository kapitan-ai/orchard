defmodule OrchardConsole.NodeEnrollmentLiveTest.Tracker do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          calls: [],
          enrollment_state: :issued,
          expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
          issue_result: :default,
          mark_issued_result: :default,
          mark_output_failed_result: :default,
          node_state: :provisioned,
          surface: "console"
        }
      end,
      name: __MODULE__
    )
  end

  def record(call),
    do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn calls -> [call | calls] end))

  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def issue_result, do: Agent.get(__MODULE__, & &1.issue_result)
  def set_issue_result(result), do: Agent.update(__MODULE__, &Map.put(&1, :issue_result, result))
  def node_state, do: Agent.get(__MODULE__, & &1.node_state)
  def set_node_state(state), do: Agent.update(__MODULE__, &Map.put(&1, :node_state, state))
  def enrollment_state, do: Agent.get(__MODULE__, & &1.enrollment_state)

  def set_enrollment_state(state),
    do: Agent.update(__MODULE__, &Map.put(&1, :enrollment_state, state))

  def mark_issued_result, do: Agent.get(__MODULE__, & &1.mark_issued_result)

  def set_mark_issued_result(result),
    do: Agent.update(__MODULE__, &Map.put(&1, :mark_issued_result, result))

  def mark_output_failed_result, do: Agent.get(__MODULE__, & &1.mark_output_failed_result)

  def set_mark_output_failed_result(result),
    do: Agent.update(__MODULE__, &Map.put(&1, :mark_output_failed_result, result))

  def expires_at, do: Agent.get(__MODULE__, & &1.expires_at)
  def set_expires_at(value), do: Agent.update(__MODULE__, &Map.put(&1, :expires_at, value))
  def surface, do: Agent.get(__MODULE__, & &1.surface)
  def set_surface(value), do: Agent.update(__MODULE__, &Map.put(&1, :surface, value))
end

defmodule OrchardConsole.NodeEnrollmentLiveTest.IssuerStub do
  @moduledoc false

  alias Orchard.Nodes.{Enrollment, Node}
  alias OrchardConsole.NodeEnrollmentLiveTest.Tracker

  @enrollment_id "11111111-1111-4111-8111-111111111111"
  @node_id "22222222-2222-4222-8222-222222222222"

  def issue(attrs) do
    Tracker.record({:issue, attrs})

    case Tracker.issue_result() do
      :default -> issue_bundle(attrs)
      result -> result
    end
  end

  defp issue_bundle(attrs) do
    enrollment = %Enrollment{
      id: @enrollment_id,
      node_id: @node_id,
      node: node(attrs.display_name, :provisioned),
      state: :pending_publication,
      expires_at: DateTime.add(DateTime.utc_now(), attrs.expiry_seconds, :second)
    }

    {:ok,
     %{
       contents: ~s({"token":"orch_enr_one_time_secret"}) <> "\n",
       enrollment: enrollment,
       filename: "orchard-render-node-03-enrollment.json"
     }}
  end

  def node(display_name, state) do
    %Node{id: @node_id, display_name: display_name, state: state, health: :unreachable}
  end
end

defmodule OrchardConsole.NodeEnrollmentLiveTest.EnrollmentsStub do
  @moduledoc false

  alias Orchard.Nodes.Enrollment
  alias OrchardConsole.NodeEnrollmentLiveTest.{IssuerStub, Tracker}

  @enrollment_id "11111111-1111-4111-8111-111111111111"
  @node_id "22222222-2222-4222-8222-222222222222"

  def mark_issued(@enrollment_id, opts) do
    Tracker.record({:mark_issued, @enrollment_id, opts})

    case Tracker.mark_issued_result() do
      :default -> {:ok, enrollment(:issued)}
      result -> result
    end
  end

  def mark_output_failed(@enrollment_id, opts) do
    Tracker.record({:mark_output_failed, @enrollment_id, opts})

    case Tracker.mark_output_failed_result() do
      :default ->
        {:ok, enrollment(:output_failed)}

      {:error_after_state, state, reason} ->
        Tracker.set_enrollment_state(state)
        {:error, reason}

      result ->
        result
    end
  end

  def fetch(@enrollment_id) do
    Tracker.record({:fetch, @enrollment_id})
    {:ok, enrollment(Tracker.enrollment_state())}
  end

  defp enrollment(state) do
    %Enrollment{
      id: @enrollment_id,
      node_id: @node_id,
      node: IssuerStub.node("render-node-03", Tracker.node_state()),
      state: state,
      expires_at: Tracker.expires_at(),
      audit_metadata: %{"surface" => Tracker.surface()}
    }
  end
end

defmodule OrchardConsole.NodeEnrollmentLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias __MODULE__.{EnrollmentsStub, IssuerStub, Tracker}

  @enrollment_id "11111111-1111-4111-8111-111111111111"

  @moduletag :live

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])
    start_supervised!(Tracker)

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous,
        node_enrollment_bundle_issuer_impl: IssuerStub,
        node_enrollments_impl: EnrollmentsStub,
        refresh_interval_ms: 60_000
      )
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)

    :ok
  end

  test "renders the ordered new-machine setup journey", %{conn: conn} do
    {:ok, view, html} = live(conn, "/console/nodes/new")

    assert html =~ "Add a Node"
    assert html =~ "Prepare the target Mac"
    assert html =~ "Install Orchard on the target Mac"
    assert html =~ "Node Agent Install Role"
    assert html =~ "packaged multi-Mac rehearsal"
    assert html =~ "source-development split-role path"
    assert html =~ "shared BEAM cookie"
    assert html =~ "Runtime Endpoint targets"
    assert html =~ "On the Controller Mac"
    assert html =~ "The target Mac does not connect to Postgres"
    assert html =~ "sudo orchardctl start"
    assert html =~ "orchardctl status"
    assert html =~ "confirm the Node Agent"
    assert html =~ "service is running"
    assert html =~ "Continue to Enrollment"
    assert html =~ ~s(id="node-enrollment-live-announcer")
    assert html =~ ~s(aria-live="polite")
    assert html =~ ~s(aria-current="step")
    assert html =~ "current step"
    refute html =~ "another machine"

    html = view |> element("#node-preparation-complete") |> render_click()

    assert has_element?(view, "#node-enrollment-heading[tabindex='-1'][phx-mounted]")
    refute has_element?(view, "#node-preparation-complete")
    assert html =~ "Create a one-time enrollment"
    assert html =~ "Initial pool intent"
    assert html =~ "A Pool is an existing scheduling group"
    assert html =~ "you can change it before admitting the node"
  end

  test "disconnected status render shows loading instead of a stale wizard step", %{conn: conn} do
    html =
      conn
      |> get("/console/nodes/new/#{@enrollment_id}")
      |> html_response(200)

    assert html =~ "Loading enrollment status"
    refute html =~ "Prepare the target Mac"
    refute Tracker.calls() |> Enum.any?(&match?({:fetch, @enrollment_id}, &1))
  end

  test "validates enrollment input before calling the issuer", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    html =
      render_submit(view, "issue_enrollment", %{
        "enrollment" => %{"display_name" => "", "expiry_seconds" => "999", "pool_id" => ""}
      })

    assert html =~ "must not be empty"
    assert html =~ "must be one of the available periods"
    assert Tracker.calls() == []
  end

  test "uses the shared bundle limits before calling the issuer", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    html =
      render_submit(view, "issue_enrollment", %{
        "enrollment" => %{
          "display_name" => String.duplicate("é", 65),
          "expiry_seconds" => "3600",
          "pool_id" => "general pool"
        }
      })

    assert html =~ "must be 128 bytes or fewer"
    assert html =~ "may contain only letters, numbers, dots, underscores, and hyphens"
    assert Tracker.calls() == []
  end

  test "reports a post-create reconciliation failure with its durable Enrollment identity", %{
    conn: conn
  } do
    Tracker.set_issue_result(
      {:error,
       {:bundle_publication_reconciliation_failed, @enrollment_id, :bundle_too_large,
        :database_unavailable}}
    )

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    html =
      view
      |> form("#node-enrollment-form",
        enrollment: %{
          display_name: "render-node-03",
          expiry_seconds: "3600",
          pool_id: "general"
        }
      )
      |> render_submit()

    assert html =~ @enrollment_id
    assert html =~ "No bundle was published"
    assert html =~ "remains non-redeemable pending reconciliation"
    assert html =~ "provisioned Node name remains reserved"
    assert html =~ "distinct Node name"
    refute html =~ "Verify Controller trust and HTTPS settings, then try again"
  end

  test "delivers the one-time bundle without rendering its secret and confirms issuance", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    html =
      view
      |> form("#node-enrollment-form",
        enrollment: %{
          display_name: "render-node-03",
          expiry_seconds: "3600",
          pool_id: "general"
        }
      )
      |> render_submit()

    assert_push_event(view, "node_enrollment_bundle", %{
      "contents" => contents,
      "enrollment_id" => @enrollment_id,
      "filename" => "orchard-render-node-03-enrollment.json"
    })

    assert_patch(view, "/console/nodes/new/#{@enrollment_id}")

    assert contents =~ "orch_enr_one_time_secret"
    refute html =~ "orch_enr_one_time_secret"
    refute html =~ "data-copy-text"
    assert html =~ "Starting the one-time enrollment download"

    html =
      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "orchardctl node join --enrollment-bundle"
    assert html =~ "/secure/path/on-target/orchard-render-node-03-enrollment.json"
    assert html =~ "Replace the example path with the bundle"
    refute html =~ "~/Downloads/orchard-render-node-03-enrollment.json"
    assert html =~ "Keep the bundle out of chat"
    assert html =~ "tickets, logs, and shell history"
    assert html =~ "Browser accepted the one-time file download; target custody is not verified"
    assert html =~ ~s(aria-live="polite")
    assert html =~ "Waiting for orchardctl node join on the target Mac"

    assert {:issue, attrs} = Enum.at(Tracker.calls(), 0)
    assert attrs.display_name == "render-node-03"
    assert attrs.pool_id == "general"
    assert attrs.expiry_seconds == 3_600
    assert Enum.any?(Tracker.calls(), &match?({:mark_issued, @enrollment_id, _opts}, &1))
  end

  test "preparation completion cannot bypass an in-progress delivery stage", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html = render_click(view, "preparation_complete", %{})

    assert html =~ "Starting the one-time enrollment download"
    refute html =~ "Create a one-time enrollment"
  end

  test "surfaces registration automatically and hands off to admission review", %{conn: conn} do
    Tracker.set_node_state(:registered)
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "Registered - awaiting admission"
    assert html =~ "The node agent registered successfully"
    assert html =~ "Review and Admit Node"

    assert has_element?(
             view,
             "#review-node-admission[href='/console/nodes/22222222-2222-4222-8222-222222222222?section=actions&from=admissions']"
           )
  end

  test "polling advances a waiting enrollment to registered without an operator status action", %{
    conn: conn
  } do
    console = Application.fetch_env!(:orchard_controller, :console)

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.put(console, :refresh_interval_ms, 10)
    )

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    waiting_html =
      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

    assert waiting_html =~ "Waiting for orchardctl node join on the target Mac"
    Tracker.set_node_state(:registered)

    Process.sleep(25)
    registered_html = render(view)

    refute has_element?(view, "#node-enrollment-monitor-step [phx-mounted]")
    assert registered_html =~ "Registered - awaiting admission"
    assert registered_html =~ "Review and Admit Node"
  end

  test "fails closed when the browser reports that download failed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_download_failed", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "No redeemable enrollment was left behind"
    assert html =~ "did not establish Node identity or trust"
    assert html =~ "Enrollment download failed. No Node identity or trust was established."
    assert html =~ "Create New Enrollment"

    assert Enum.any?(
             Tracker.calls(),
             &match?({:mark_output_failed, @enrollment_id, _opts}, &1)
           )
  end

  test "ignores a stale failure acknowledgement after successful issuance", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    assert render_hook(view, "node_enrollment_bundle_downloaded", %{
             "enrollment_id" => @enrollment_id
           }) =~ "orchardctl node join --enrollment-bundle"

    html =
      render_hook(view, "node_enrollment_bundle_download_failed", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "orchardctl node join --enrollment-bundle"
    refute html =~ "No redeemable enrollment was left behind"

    refute Enum.any?(
             Tracker.calls(),
             &match?({:mark_output_failed, @enrollment_id, _opts}, &1)
           )
  end

  test "recovers when issuance committed but its response was lost", %{conn: conn} do
    Tracker.set_mark_issued_result({:error, :simulated_response_loss})
    Tracker.set_enrollment_state(:issued)

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "orchardctl node join --enrollment-bundle"
    refute html =~ "could not activate this enrollment"
    assert Enum.any?(Tracker.calls(), &match?({:fetch, @enrollment_id}, &1))

    refute Enum.any?(
             Tracker.calls(),
             &match?({:mark_output_failed, @enrollment_id, _opts}, &1)
           )
  end

  test "explains a downloaded bundle invalidated by confirmation failure", %{conn: conn} do
    Tracker.set_mark_issued_result({:error, :simulated_confirmation_failure})
    Tracker.set_enrollment_state(:pending_publication)

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "browser accepted the download"
    assert html =~ "downloaded bundle is not redeemable"
    assert html =~ "did not establish Node identity or trust"
    refute html =~ "browser could not download"
  end

  test "preserves successful browser acknowledgement when issuance reconciles to output failure",
       %{
         conn: conn
       } do
    Tracker.set_mark_issued_result({:error, :simulated_response_loss})
    Tracker.set_enrollment_state(:output_failed)

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "browser accepted the download"
    assert html =~ "downloaded bundle is not redeemable"
    refute html =~ "browser could not download"
  end

  test "preserves successful browser acknowledgement when invalidation commits but its response is lost",
       %{
         conn: conn
       } do
    Tracker.set_mark_issued_result({:error, :simulated_confirmation_failure})
    Tracker.set_enrollment_state(:pending_publication)

    Tracker.set_mark_output_failed_result(
      {:error_after_state, :output_failed, :simulated_response_loss}
    )

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "browser accepted the download"
    assert html =~ "downloaded bundle is not redeemable"
    refute html =~ "browser could not download"
  end

  test "does not claim output failure when durable state became issued", %{conn: conn} do
    Tracker.set_mark_output_failed_result({:error, :invalid_enrollment_state})
    Tracker.set_enrollment_state(:issued)

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_download_failed", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "orchardctl node join --enrollment-bundle"
    refute html =~ "No redeemable enrollment was left behind"
    assert Enum.any?(Tracker.calls(), &match?({:fetch, @enrollment_id}, &1))
  end

  test "keeps a failed acknowledgement uncertain while durable publication is pending", %{
    conn: conn
  } do
    Tracker.set_mark_output_failed_result({:error, :simulated_transition_failure})
    Tracker.set_enrollment_state(:pending_publication)

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_download_failed", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "Waiting for download confirmation"
    assert html =~ "could not confirm the bundle delivery result"
    assert html =~ "No Node identity or trust has been established"
    refute html =~ "No redeemable enrollment was left behind"
  end

  test "ignores duplicate issue events after the first bundle is created", %{conn: conn} do
    params = %{
      "enrollment" => %{
        "display_name" => "render-node-03",
        "expiry_seconds" => "3600",
        "pool_id" => "general"
      }
    }

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    render_submit(view, "issue_enrollment", params)
    render_submit(view, "issue_enrollment", params)

    assert Enum.count(Tracker.calls(), &match?({:issue, _attrs}, &1)) == 1
  end

  test "does not issue or redisplay a bundle when delivery acknowledgement is lost", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    html =
      view
      |> form("#node-enrollment-form",
        enrollment: %{
          display_name: "render-node-03",
          expiry_seconds: "3600",
          pool_id: "general"
        }
      )
      |> render_submit()

    assert html =~ "Starting the one-time enrollment download"
    refute html =~ "orch_enr_one_time_secret"
    refute Enum.any?(Tracker.calls(), &match?({:mark_issued, _, _}, &1))

    Tracker.set_enrollment_state(:pending_publication)

    {:ok, _reconnected_view, reconnected_html} =
      live(conn, "/console/nodes/new/#{@enrollment_id}")

    assert reconnected_html =~ "Waiting for download confirmation"
    refute reconnected_html =~ "orchardctl node join --enrollment-bundle"
    refute reconnected_html =~ "orch_enr_one_time_secret"
  end

  test "shows only terminal recovery for an expired pending publication", %{conn: conn} do
    Tracker.set_enrollment_state(:pending_publication)
    Tracker.set_expires_at(DateTime.add(DateTime.utc_now(), -1, :second))

    {:ok, _view, html} = live(conn, "/console/nodes/new/#{@enrollment_id}")

    assert html =~ "This enrollment can no longer register a node"
    assert html =~ "The enrollment expired"
    assert html =~ "Create New Enrollment"
    refute html =~ "Waiting for download confirmation"
    refute html =~ "Confirm the enrollment download"
  end

  test "restores an issued enrollment monitor from its non-secret URL", %{conn: conn} do
    Tracker.set_enrollment_state(:issued)

    {:ok, _view, html} = live(conn, "/console/nodes/new/#{@enrollment_id}")

    assert html =~ "Install and register render-node-03"
    assert html =~ "orchardctl node join --enrollment-bundle"
    assert html =~ "orchard-render-node-03-enrollment.json"
    refute html =~ "orch_enr_one_time_secret"
    assert Enum.any?(Tracker.calls(), &match?({:fetch, @enrollment_id}, &1))
  end

  test "does not make browser publication claims for a CLI-created enrollment", %{conn: conn} do
    Tracker.set_enrollment_state(:issued)
    Tracker.set_surface("local_orchardctl")

    {:ok, _view, html} = live(conn, "/console/nodes/new/#{@enrollment_id}")

    assert html =~ "Enrollment cannot be resumed here"
    assert html =~ "created outside this Console flow"
    refute html =~ "Enrollment download attempt accepted"
    refute html =~ "orchardctl node join --enrollment-bundle"
  end

  test "browser back to the base route resets durable status to the enrollment form", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    assert_patch(view, "/console/nodes/new/#{@enrollment_id}")

    html = render_patch(view, "/console/nodes/new")

    assert html =~ "Create a one-time enrollment"
    refute html =~ "Starting the one-time enrollment download"
    assert Enum.count(Tracker.calls(), &match?({:issue, _attrs}, &1)) == 1
  end

  test "names revoked and expired terminal states and offers a new enrollment", %{conn: conn} do
    for {state, expires_at, expected} <- [
          {:revoked, DateTime.add(DateTime.utc_now(), 3_600, :second), "was revoked"},
          {:issued, DateTime.add(DateTime.utc_now(), -1, :second), "expired"}
        ] do
      Tracker.set_enrollment_state(state)
      Tracker.set_expires_at(expires_at)

      {:ok, view, _html} = live(conn, "/console/nodes/new")
      view |> element("#node-preparation-complete") |> render_click()

      view
      |> form("#node-enrollment-form",
        enrollment: %{
          display_name: "render-node-03",
          expiry_seconds: "3600",
          pool_id: "general"
        }
      )
      |> render_submit()

      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

      html = view |> element("#node-enrollment-refresh") |> render_click()

      assert html =~ "can no longer register a node"
      assert html =~ expected
      assert html =~ "Create New Enrollment"
      assert html =~ "distinct Node name"
      assert html =~ "Automatic checks have stopped"
      refute html =~ "Orchard checks registration automatically"

      html = view |> element("#replace-terminal-node-enrollment") |> render_click()
      assert_patch(view, "/console/nodes/new")
      assert html =~ "Create a one-time enrollment"
    end
  end

  test "keeps a consumed enrollment visible after its token expiry", %{conn: conn} do
    Tracker.set_enrollment_state(:consumed)
    Tracker.set_node_state(:registered)
    Tracker.set_expires_at(DateTime.add(DateTime.utc_now(), -1, :second))

    {:ok, view, _html} = live(conn, "/console/nodes/new")
    view |> element("#node-preparation-complete") |> render_click()

    view
    |> form("#node-enrollment-form",
      enrollment: %{
        display_name: "render-node-03",
        expiry_seconds: "3600",
        pool_id: "general"
      }
    )
    |> render_submit()

    html =
      render_hook(view, "node_enrollment_bundle_downloaded", %{
        "enrollment_id" => @enrollment_id
      })

    assert html =~ "Registered - awaiting admission"
    assert html =~ "Review and Admit Node"
    refute html =~ "orchardctl node join --enrollment-bundle"
    refute html =~ "Move orchard-render-node-03-enrollment.json to the target Mac"
    refute html =~ "can no longer register a node"
    refute html =~ "Create New Enrollment"
  end

  test "renders post-registration lifecycle states without returning to join guidance", %{
    conn: conn
  } do
    Tracker.set_enrollment_state(:consumed)

    for {state, title, detail} <- [
          {:registered, "Review and admit render-node-03",
           "Available after registration and trust evidence review"},
          {:admitted, "Await activation for render-node-03",
           "Activation follows admission and a fresh runtime observation"},
          {:active, "render-node-03 is active", "The node may receive scheduled work"},
          {:cordoned, "render-node-03 is cordoned", "No new work will be scheduled"},
          {:draining, "render-node-03 is draining", "Waiting for active requests to finish"},
          {:maintenance, "render-node-03 is in maintenance",
           "Unschedulable while upgrades or diagnostics run"},
          {:decommissioning, "render-node-03 is being decommissioned",
           "Trust revocation and cleanup are in progress"},
          {:removed, "render-node-03 has been removed", "This Node is a terminal tombstone"}
        ] do
      Tracker.set_node_state(state)

      {:ok, _view, html} = live(conn, "/console/nodes/new/#{@enrollment_id}")

      assert html =~ title
      assert html =~ detail
      assert html =~ "The node agent registered successfully"
      refute html =~ "Waiting for orchardctl node join on the target Mac"

      if state == :registered do
        assert html =~ "Review and Admit Node"
      else
        refute html =~ "Review and Admit Node"
      end

      if state in [:decommissioning, :removed] do
        assert html =~ "Terminal lifecycle state"
        refute html =~ "Step 5 of 5"
        refute html =~ ~r/Review and Admit\s*<span class="sr-only">, complete/
        assert html =~ ~r/Review and Admit\s*<span class="sr-only">, unavailable/
      else
        refute html =~ "Terminal lifecycle state"
      end

      if state == :removed do
        assert html =~ "Automatic checks have stopped"
        refute html =~ "Orchard checks registration automatically"
      else
        assert html =~ "Orchard checks registration automatically"
      end

      if state in [:cordoned, :draining, :maintenance] do
        assert html =~ "Post-activation lifecycle state"
        refute html =~ ~r/Node Active\s*<span class="sr-only">, current step/
        assert html =~ ~r/Node Active\s*<span class="sr-only">, unavailable/
      end
    end
  end
end
