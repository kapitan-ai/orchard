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
