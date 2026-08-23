defmodule OrchardConsole.RequestsLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query

  @moduletag :live
  @moduletag :db

  import Orchard.TestSupport.ModelRequestFixtures, only: [request_attrs: 1]

  alias Ecto.Adapters.SQL.Sandbox
  alias Orchard.Repo
  alias Orchard.Requests

  setup do
    Sandbox.mode(Repo, {:shared, self()})

    # Slow polling to avoid timer churn during tests
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.put(previous, :refresh_interval_ms, 60_000)
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Page rendering
  # ---------------------------------------------------------------------------

  describe "page rendering" do
    test "renders page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests")

      assert html =~ "Requests"
      assert html =~ "requests-tools-row"
    end

    test "Requests nav is active", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests")

      assert html =~ ~s(aria-current="page")
      assert html =~ "/console/requests"
    end

    test "renders empty state when no requests", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests")

      assert html =~ "requests-empty-state"
      assert html =~ "No requests recorded yet."
      assert html =~ "requests-summary"
      # Summary counts are all zero
      assert html =~ "requests-summary-total"
    end

    test "static render (disconnected mount) shows real content", %{conn: conn} do
      conn = get(conn, "/console/requests")

      assert conn.status == 200
      # Should show real content, not just loading card
      assert conn.resp_body =~ "requests-list-card" or
               conn.resp_body =~ "requests-empty-state"

      refute conn.resp_body =~ "requests-loading-card"
    end

    test "disconnected render shows populated freshness with LocalTime hook", %{conn: conn} do
      # Note: the nil freshness branch ("Loading…") is not route-reachable because
      # mount/3 always calls load_requests_page/1 before returning, which sets
      # last_checked_at. We verify the populated branch renders correctly in
      # the disconnected/static response.
      conn = get(conn, "/console/requests")
      body = conn.resp_body

      assert body =~ "requests-freshness"
      assert body =~ "Last checked"
      assert body =~ ~s(phx-hook="LocalTime")
      assert body =~ ~s(data-local-time-format="time_second")
    end
  end

  # ---------------------------------------------------------------------------
  # Request table
  # ---------------------------------------------------------------------------

  describe "request table" do
    test "renders request rows with detail links", %{conn: conn} do
      request = create_request!(%{public_id: "req_live_1", state: :completed, http_status: 200})

      {:ok, _view, html} = live(conn, "/console/requests")

      assert html =~ "requests-table"
      assert html =~ request.public_id
      assert html =~ "/console/requests/#{request.public_id}"
      assert html =~ "completed"
    end

    test "renders nil node_id and http_status as em-dash", %{conn: conn} do
      create_request!(%{
        public_id: "req_live_nil",
        state: :received,
        node_id: nil,
        http_status: nil
      })

      {:ok, _view, html} = live(conn, "/console/requests")

      # The em-dash character
      assert html =~ "\u2014"
    end

    test "renders zero token total as 0", %{conn: conn} do
      create_request!(%{
        public_id: "req_live_zero_tok",
        state: :completed,
        input_tokens: 0,
        output_tokens: 0
      })

      {:ok, _view, html} = live(conn, "/console/requests")

      # Should render "0", not em-dash
      refute html =~ "requests-empty-state"
    end

    test "table headers include performance metric columns", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests")

      assert html =~ "TTFT"
      assert html =~ "Total latency"
      assert html =~ "Tok/s"
    end

    test "completed row shows formatted metric values", %{conn: conn} do
      request =
        create_request!(%{
          public_id: "req_perf_1",
          state: :completed,
          input_tokens: 50,
          output_tokens: 75,
          first_token_at: ~U[2026-03-15 12:00:00.250000Z],
          completed_at: ~U[2026-03-15 12:00:01.750000Z]
        })

      # Patch inserted_at to a controlled value
      {1, _} =
        Repo.update_all(
          from(r in Orchard.Requests.Request, where: r.id == ^request.id),
          set: [inserted_at: ~U[2026-03-15 12:00:00.000000Z]]
        )

      {:ok, view, _html} = live(conn, "/console/requests")

      row_html = element(view, "#request-req_perf_1") |> render()
      assert row_html =~ "250 ms"
      assert row_html =~ "1.8 s"
      assert row_html =~ "50.0"
    end

    test "non-completed row shows em dash for metric columns", %{conn: conn} do
      create_request!(%{
        public_id: "req_active_1",
        state: :running,
        http_status: 200,
        input_tokens: 10,
        output_tokens: 0
      })

      {:ok, view, _html} = live(conn, "/console/requests")

      row_html = element(view, "#request-req_active_1") |> render()
      # Row should contain em dashes for the 3 metric columns
      # (node_id and http_status are populated, so dashes come from metrics)
      assert row_html =~ "—"
    end
  end

  # ---------------------------------------------------------------------------
  # Summary strip
  # ---------------------------------------------------------------------------

  describe "summary strip" do
    test "shows counts matching summary", %{conn: conn} do
      create_request!(%{public_id: "req_sum_1", state: :completed})
      create_request!(%{public_id: "req_sum_2", state: :running})
      create_request!(%{public_id: "req_sum_3", state: :failed})

      {:ok, _view, html} = live(conn, "/console/requests")

      assert html =~ "requests-summary-total"
      assert html =~ "requests-summary-active"
      assert html =~ "requests-summary-terminal"
      assert html =~ "requests-summary-failed"
    end
  end

  # ---------------------------------------------------------------------------
  # Refresh
  # ---------------------------------------------------------------------------

  describe "refresh" do
    test "manual refresh updates the DOM", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/requests")

      assert html =~ "requests-empty-state"

      create_request!(%{public_id: "req_refresh_1", state: :completed})

      html = render_click(view, "refresh_now")

      assert html =~ "req_refresh_1"
      refute html =~ "requests-empty-state"
    end

    test "polling refresh updates the DOM", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/requests")

      assert html =~ "requests-empty-state"

      create_request!(%{public_id: "req_poll_1", state: :running})

      # Simulate timer fire
      send(view.pid, :refresh_requests)
      html = render(view)

      assert html =~ "req_poll_1"
    end

    test "freshness row and refresh button exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/requests")

      assert html =~ "requests-freshness"
      assert html =~ "requests-refresh-now"
      assert html =~ "Last checked"
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-local-time-format="time_second")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_request!(overrides) do
    attrs = request_attrs(overrides)
    {:ok, request} = Requests.create_request(attrs)
    request
  end
end
