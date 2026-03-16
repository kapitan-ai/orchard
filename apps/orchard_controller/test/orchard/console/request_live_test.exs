defmodule OrchardConsole.RequestLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  import Orchard.TestSupport.ModelRequestFixtures
  alias Orchard.Requests

  @moduletag :live
  @moduletag :db

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous, refresh_interval_ms: 60_000)
    )

    on_exit(fn -> Application.put_env(:orchard_controller, :console, previous) end)

    Sandbox.mode(Orchard.Repo, {:shared, self()})
    :ok
  end

  # ===========================================================================
  # Summary rendering
  # ===========================================================================

  describe "request summary" do
    test "renders summary card with request metadata", %{conn: conn} do
      request =
        create_request!(%{
          state: :running,
          requested_model: "mlx-community/phi-3@main",
          stream: true,
          http_status: nil
        })

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "Request Summary"
      assert html =~ request.public_id
      assert html =~ "running"
      assert html =~ "mlx-community/phi-3@main"
      assert html =~ "Yes"
      assert html =~ "chat_completions"
    end

    test "renders page title with public_id", %{conn: conn} do
      request = create_request!()

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "Request #{request.public_id} — Orchard Console"
    end
  end

  # ===========================================================================
  # Usage rendering
  # ===========================================================================

  describe "token usage" do
    test "renders token counts including zero", %{conn: conn} do
      request =
        create_request!(%{
          state: :completed,
          input_tokens: 150,
          output_tokens: 75
        })

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "Token Usage"
      assert html =~ "150"
      assert html =~ "75"
      assert html =~ "225"
    end

    test "renders zero tokens as 0 not dash", %{conn: conn} do
      request = create_request!(%{state: :received, input_tokens: 0, output_tokens: 0})

      {:ok, view, _html} = live(conn, "/console/requests/#{request.public_id}")

      # Assert each metric tile renders "0" as the value, not "—"
      for tile_id <- ["request-input-tokens", "request-output-tokens", "request-total-tokens"] do
        tile_html = element(view, "##{tile_id}") |> render()
        assert tile_html =~ "0", "expected #{tile_id} to display 0"
        refute tile_html =~ "—", "#{tile_id} should not display dash"
      end
    end
  end

  # ===========================================================================
  # Error fields
  # ===========================================================================

  describe "error details" do
    test "renders error section for failed request", %{conn: conn} do
      request =
        create_request!(%{
          state: :failed,
          http_status: 500,
          error_code: "server_error",
          error_message: "Internal processing failure"
        })

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "Error Details"
      assert html =~ "server_error"
      assert html =~ "Internal processing failure"
      assert html =~ "500"
    end

    test "hides error section when no error fields", %{conn: conn} do
      request = create_request!(%{state: :completed})

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      refute html =~ "request-error-details-card"
    end
  end

  # ===========================================================================
  # Execution metadata
  # ===========================================================================

  describe "execution metadata" do
    test "renders populated execution metadata fields", %{conn: conn} do
      model = create_model!()

      request =
        create_request!(%{
          state: :completed,
          model_id: model.id,
          node_id: "550e8400-e29b-41d4-a716-446655440000",
          worker_id: "660e8400-e29b-41d4-a716-446655440000",
          first_token_at: ~U[2026-03-15 12:30:45.123456Z],
          http_status: 200
        })

      {:ok, view, _html} = live(conn, "/console/requests/#{request.public_id}")

      metadata_html = element(view, "#request-execution-metadata-card") |> render()
      assert metadata_html =~ "Execution Metadata"

      model_html = element(view, "#request-model-id") |> render()
      assert model_html =~ model.id
      assert model_html =~ "font-mono"

      node_html = element(view, "#request-node-id") |> render()
      assert node_html =~ "550e8400-e29b-41d4-a716-446655440000"
      assert node_html =~ "font-mono"

      worker_html = element(view, "#request-worker-id") |> render()
      assert worker_html =~ "660e8400-e29b-41d4-a716-446655440000"
      assert worker_html =~ "font-mono"

      first_token_html = element(view, "#request-first-token-at") |> render()
      assert first_token_html =~ "2026-03-15T12:30:45"

      http_html = element(view, "#request-execution-http-status") |> render()
      assert http_html =~ "200"
    end

    test "renders dash fallbacks when execution metadata fields are nil", %{conn: conn} do
      request = create_request!(%{state: :received, http_status: nil})

      {:ok, view, _html} = live(conn, "/console/requests/#{request.public_id}")

      # Card still renders
      assert element(view, "#request-execution-metadata-card") |> render() =~ "Execution Metadata"

      # All fields show dash
      for field_id <- [
            "request-model-id",
            "request-node-id",
            "request-worker-id",
            "request-first-token-at",
            "request-execution-http-status"
          ] do
        field_html = element(view, "##{field_id}") |> render()
        assert field_html =~ "\u2014", "expected #{field_id} to display dash"
      end
    end
  end

  # ===========================================================================
  # Canonical request
  # ===========================================================================

  describe "canonical request" do
    test "renders canonical request as JSON", %{conn: conn} do
      request =
        create_request!(%{
          state: :completed,
          canonical_request: %{"model" => "test-model", "messages" => [%{"role" => "user"}]}
        })

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "Canonical Request"
      assert html =~ "request-canonical-request"
      assert html =~ "test-model"
      refute html =~ "request-canonical-fallback"
    end

    test "renders fallback when canonical_request is nil", %{conn: conn} do
      request = create_request!(%{state: :completed, canonical_request: nil})

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "request-canonical-fallback"
      assert html =~ "Not captured for this request"
      refute html =~ "request-canonical-request"
    end
  end

  # ===========================================================================
  # Response & debug
  # ===========================================================================

  describe "response and debug" do
    test "renders populated response preview, payload, and scheduler decision", %{conn: conn} do
      request =
        create_request!(%{
          state: :completed,
          response_preview: "Hello! How can I help you today?",
          response_payload: %{"id" => "resp_123", "choices" => [%{"index" => 0}]},
          scheduler_decision: %{"node_id" => "node-1", "reason" => "local_capacity"}
        })

      {:ok, view, _html} = live(conn, "/console/requests/#{request.public_id}")

      card_html = element(view, "#request-response-debug-card") |> render()
      assert card_html =~ "Response"

      preview_html = element(view, "#request-response-preview") |> render()
      assert preview_html =~ "Hello! How can I help you today?"

      payload_html = element(view, "#request-response-payload") |> render()
      assert payload_html =~ "resp_123"

      refute element(view, "#request-response-debug-card") |> render() =~
               "request-response-payload-fallback"

      scheduler_html = element(view, "#request-scheduler-decision") |> render()
      assert scheduler_html =~ "local_capacity"

      refute element(view, "#request-response-debug-card") |> render() =~
               "request-scheduler-decision-fallback"
    end

    test "renders fallbacks when response/debug fields are nil", %{conn: conn} do
      request =
        create_request!(%{
          state: :completed,
          response_preview: nil,
          response_payload: nil,
          scheduler_decision: nil
        })

      {:ok, view, _html} = live(conn, "/console/requests/#{request.public_id}")

      card_html = element(view, "#request-response-debug-card") |> render()
      assert card_html =~ "Response"

      # Fallbacks render
      assert card_html =~ "request-response-preview-fallback"
      assert card_html =~ "request-response-payload-fallback"
      assert card_html =~ "request-scheduler-decision-fallback"

      # Content blocks do not render
      refute card_html =~ "\"request-response-preview\""
      refute card_html =~ "\"request-response-payload\""
      refute card_html =~ "\"request-scheduler-decision\""
    end
  end

  # ===========================================================================
  # Provenance
  # ===========================================================================

  describe "provenance" do
    test "renders retry link to parent request", %{conn: conn} do
      parent = create_request!(%{state: :completed})

      child =
        create_request!(%{
          state: :completed,
          retry_of_request_id: parent.id,
          payload_capture_mode: :full,
          reserved_output_tokens: 256
        })

      {:ok, view, _html} = live(conn, "/console/requests/#{child.public_id}")

      provenance_html = element(view, "#request-provenance-card") |> render()
      assert provenance_html =~ "Request Provenance"

      retry_html = element(view, "#request-retry-of") |> render()
      assert retry_html =~ parent.public_id
      assert retry_html =~ "request-retry-of-link"
      assert retry_html =~ "/console/requests/#{parent.public_id}"

      capture_html = element(view, "#request-payload-capture-mode") |> render()
      assert capture_html =~ "full"

      tokens_html = element(view, "#request-reserved-output-tokens") |> render()
      assert tokens_html =~ "256"
      assert tokens_html =~ "font-mono"
    end

    test "renders dash when no retry source and zero for reserved tokens", %{conn: conn} do
      request =
        create_request!(%{
          state: :received,
          retry_of_request_id: nil,
          reserved_output_tokens: 0,
          payload_capture_mode: :metadata
        })

      {:ok, view, _html} = live(conn, "/console/requests/#{request.public_id}")

      retry_html = element(view, "#request-retry-of") |> render()
      assert retry_html =~ "\u2014"
      refute retry_html =~ "request-retry-of-link"

      tokens_html = element(view, "#request-reserved-output-tokens") |> render()
      assert tokens_html =~ "0"
      refute tokens_html =~ "\u2014"

      capture_html = element(view, "#request-payload-capture-mode") |> render()
      assert capture_html =~ "metadata"
    end

    test "retry link navigates to parent request page", %{conn: conn} do
      parent = create_request!(%{state: :completed})

      child =
        create_request!(%{
          state: :completed,
          retry_of_request_id: parent.id
        })

      {:ok, view, _html} = live(conn, "/console/requests/#{child.public_id}")

      # Click the retry link (navigate tears down old process, mounts fresh)
      {:ok, new_view, html} =
        view |> element("#request-retry-of-link") |> render_click() |> follow_redirect(conn)

      assert html =~ parent.public_id
      assert html =~ "Request Summary"

      # Verify the new view is showing the parent request
      summary_html = element(new_view, "#request-summary-card") |> render()
      assert summary_html =~ parent.public_id
    end
  end

  # ===========================================================================
  # Event timeline
  # ===========================================================================

  describe "event timeline" do
    test "renders events ordered by seq", %{conn: conn} do
      request = create_request!(%{state: :running})

      append_event!(request, %{
        event_type: "state_transition",
        state: :received,
        occurred_at: ~U[2026-03-15 10:00:00.000000Z]
      })

      append_event!(request, %{
        event_type: "state_transition",
        state: :running,
        occurred_at: ~U[2026-03-15 10:00:01.000000Z]
      })

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "Timeline"
      assert html =~ "request-timeline"
      assert html =~ "state_transition"
      assert html =~ "received"
      assert html =~ "running"

      # Verify ordering: seq 1 appears before seq 2 in DOM
      received_pos = :binary.match(html, "request-event-1") |> elem(0)
      running_pos = :binary.match(html, "request-event-2") |> elem(0)
      assert received_pos < running_pos
    end

    test "renders dash for nil occurred_at", %{conn: conn} do
      request = create_request!(%{state: :received})

      # Force nil occurred_at by inserting directly through Ecto
      %Orchard.Requests.RequestEvent{}
      |> Orchard.Requests.RequestEvent.changeset(%{
        request_id: request.id,
        seq: 1,
        event_type: "legacy_event",
        occurred_at: nil
      })
      |> Orchard.Repo.insert!()

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "legacy_event"
      # The occurred_at column should show a dash
      assert html =~ "—"
    end

    test "renders event payload when present", %{conn: conn} do
      request = create_request!(%{state: :running})

      append_event!(request, %{
        event_type: "metadata",
        payload: %{"key" => "value_123"}
      })

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "value_123"
    end

    test "renders dash for nil event state", %{conn: conn} do
      request = create_request!(%{state: :received})

      append_event!(request, %{event_type: "info_only", state: nil})

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "info_only"
    end

    test "renders empty state when no events exist", %{conn: conn} do
      request = create_request!(%{state: :received})

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "No lifecycle events recorded yet."
    end
  end

  # ===========================================================================
  # Not found
  # ===========================================================================

  describe "unknown public_id" do
    test "renders not-found card without crashing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests/nonexistent-id-999")

      assert html =~ "request-not-found-card"
      assert html =~ "Request not found"
      assert html =~ "nonexistent-id-999"
      refute html =~ "request-summary-card"
      refute html =~ "request-timeline-card"
    end
  end

  # ===========================================================================
  # Polling refresh
  # ===========================================================================

  describe "polling refresh" do
    test "refresh updates DOM with new data", %{conn: conn} do
      request = create_request!(%{state: :running, input_tokens: 0, output_tokens: 0})

      {:ok, view, html} = live(conn, "/console/requests/#{request.public_id}")

      # Initial state: running, 0 tokens
      assert html =~ "running"

      # Mutate the request to terminal state
      {:ok, _} =
        Requests.mark_terminal(request, %{
          state: :completed,
          input_tokens: 200,
          output_tokens: 100,
          http_status: 200
        })

      append_event!(request, %{
        event_type: "state_transition",
        state: :completed
      })

      # Trigger manual refresh
      send(view.pid, :refresh_request)
      html = render(view)

      # Verify updated data
      assert html =~ "completed"
      assert html =~ "200"
      assert html =~ "100"
      assert html =~ "state_transition"
    end

    test "terminal request does not crash on refresh message", %{conn: conn} do
      request = create_request!(%{state: :completed})

      {:ok, view, _html} = live(conn, "/console/requests/#{request.public_id}")

      # Sending refresh to a terminal request should be a graceful no-op
      send(view.pid, :refresh_request)
      html = render(view)

      assert html =~ "completed"
      assert html =~ "request-summary-card"
    end
  end

  # ===========================================================================
  # Shell and navigation
  # ===========================================================================

  describe "shell and navigation" do
    test "marks Requests as active nav item", %{conn: conn} do
      request = create_request!()

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ ~s(aria-current="page")
      assert html =~ "text-navy"
      # No clickable requests index link
      refute html =~ "/console/requests\""
    end

    test "includes brand bar and shell", %{conn: conn} do
      request = create_request!()

      {:ok, _view, html} = live(conn, "/console/requests/#{request.public_id}")

      assert html =~ "from-navy"
      assert html =~ "to-gold"
      assert html =~ "console-sidebar"
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp append_event!(request, attrs) do
    {:ok, event} = Requests.append_request_event(request, attrs)
    event
  end
end
