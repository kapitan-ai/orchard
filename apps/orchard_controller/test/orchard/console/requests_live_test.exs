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
  alias Orchard.Requests.Request
  alias OrchardConsole.RequestsLive

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

    test "DESIGN §16 shows stored usage and timings without a generation-rate claim", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, "/console/requests")

      assert html =~ "Input tokens"
      assert html =~ "Output tokens"
      assert html =~ "Output accuracy"
      assert html =~ "TTFT"
      assert html =~ "Total time"
      assert html =~ "first recorded public output"
      assert html =~ "not client receipt"
      refute html =~ "Tok/s"
      refute html =~ "tokens per second"
      refute html =~ "generation rate"
    end

    test "SPEC §5.3 and §8 preserve stored counts and nullable output classification", %{
      conn: conn
    } do
      cases = [
        {"exact", 13, 7, :exact, ["13", "7", "Exact"]},
        {"lower", 13, 7, :lower_bound, ["13", "7", "Lower bound"]},
        {"unknown", 13, 7, nil, ["13", "7", "Accuracy unknown"]},
        {"zero_exact", 0, 0, :exact, ["0", "0", "Exact"]},
        {"zero_lower", 0, 0, :lower_bound, ["0", "0", "Lower bound"]},
        {"zero_unknown", 0, 0, nil, ["0", "0", "Accuracy unknown"]}
      ]

      for {id, input, output, quality, _expected} <- cases do
        create_request!(%{
          public_id: "req_usage_#{id}",
          state: :completed,
          input_tokens: input,
          output_tokens: output,
          output_usage_status: quality
        })
      end

      {:ok, view, _html} = live(conn, "/console/requests")

      for {id, _input, _output, _quality, expected} <- cases do
        assert Enum.slice(row_cells(view, "req_usage_#{id}"), 7, 3) == expected
      end
    end

    test "absent counts remain distinct from stored zero at the renderer boundary" do
      # Persisted counts are non-nullable; nil is a presentation fallback, not a migration.
      request = create_request!(%{public_id: "req_missing", input_tokens: 0, output_tokens: 0})
      {:ok, socket} = RequestsLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

      for {input, output, expected} <- [
            {nil, 0, ["Not recorded", "0", "Accuracy unknown"]},
            {0, nil, ["0", "Not recorded", "Accuracy unknown"]},
            {nil, nil, ["Not recorded", "Not recorded", "Accuracy unknown"]}
          ] do
        assigns =
          Map.put(socket.assigns, :requests, [
            %{request | input_tokens: input, output_tokens: output}
          ])

        html = render_component(&RequestsLive.render/1, assigns)
        assert Enum.slice(row_cells(html, "req_missing"), 7, 3) == expected
      end
    end

    test "DESIGN §16 preserves usage and bounded timing for every terminal outcome", %{conn: conn} do
      for state <- [:completed, :failed, :cancelled, :timed_out, :interrupted] do
        create_timed_request!(%{
          public_id: "req_terminal_#{state}",
          state: state,
          input_tokens: 13,
          output_tokens: 7,
          output_usage_status: :lower_bound,
          first_token_at: ~U[2026-03-15 12:00:00.250000Z],
          completed_at: ~U[2026-03-15 12:00:01.750000Z]
        })
      end

      {:ok, view, _html} = live(conn, "/console/requests")

      for state <- [:completed, :failed, :cancelled, :timed_out, :interrupted] do
        cells = row_cells(view, "req_terminal_#{state}")
        assert Enum.at(cells, 2) == to_string(state)
        assert Enum.drop(cells, 7) == ["13", "7", "Lower bound", "250 ms", "1.75 s"]
      end
    end

    test "active states show recorded TTFT but never invent a final duration", %{conn: conn} do
      for state <- [
            :received,
            :validated,
            :admitted,
            :queued,
            :scheduled,
            :dispatching,
            :running,
            :streaming
          ] do
        create_timed_request!(%{
          public_id: "req_active_#{state}",
          state: state,
          input_tokens: 13,
          output_tokens: 0,
          first_token_at: if(state == :streaming, do: ~U[2026-03-15 12:00:00.250000Z])
        })
      end

      {:ok, view, _html} = live(conn, "/console/requests")

      for state <- Request.active_states() do
        ttft = if state == :streaming, do: "250 ms", else: "Not recorded"
        cells = row_cells(view, "req_active_#{state}")
        assert Enum.at(cells, 2) == to_string(state)
        assert Enum.drop(cells, 7) == ["13", "0", "Accuracy unknown", ttft, "Not recorded"]
      end
    end

    test "SPEC §5.8 rejects conflicting timing and distinguishes missing evidence from zero", %{
      conn: conn
    } do
      cases = [
        {"absent", nil, nil, ["Not recorded", "Not recorded"]},
        {"before_creation", ~U[2026-03-15 11:59:59.000000Z], ~U[2026-03-15 12:00:01.750000Z],
         ["Not recorded", "1.75 s"]},
        {"after_completion", ~U[2026-03-15 12:00:02.000000Z], ~U[2026-03-15 12:00:01.750000Z],
         ["Not recorded", "1.75 s"]},
        {"negative_duration", nil, ~U[2026-03-15 11:59:59.000000Z],
         ["Not recorded", "Not recorded"]},
        {"no_public_output", nil, ~U[2026-03-15 12:00:01.750000Z], ["Not recorded", "1.75 s"]},
        {"zero", ~U[2026-03-15 12:00:00.000000Z], ~U[2026-03-15 12:00:00.000000Z],
         ["0 ms", "0 ms"]}
      ]

      for {id, first, completed, _expected} <- cases do
        create_timed_request!(%{
          public_id: "req_timing_#{id}",
          state: :failed,
          first_token_at: first,
          completed_at: completed
        })
      end

      {:ok, view, _html} = live(conn, "/console/requests")

      for {id, _first, _completed, expected} <- cases do
        assert Enum.drop(row_cells(view, "req_timing_#{id}"), 10) == expected
      end
    end

    test "keeps exact model identity and public RequestID navigation", %{conn: conn} do
      model = "publisher/a-very-long-model-identity@0123456789abcdef"
      create_request!(%{public_id: "req_identity", requested_model: model})
      {:ok, view, _html} = live(conn, "/console/requests")

      assert Enum.at(row_cells(view, "req_identity"), 4) == model
      assert has_element?(view, "#request-req_identity a[href='/console/requests/req_identity']")

      assert {:error, {:live_redirect, %{to: "/console/requests/req_identity"}}} =
               view |> element("#request-req_identity a") |> render_click()
    end

    test "retains newest-first recent-50 limit without changing the summary scope", %{conn: conn} do
      for n <- 0..50 do
        request = create_request!(%{public_id: "req_recent_#{n}"})
        set_created_at(request, DateTime.add(~U[2026-03-15 12:00:00.000000Z], n, :second))
      end

      {:ok, view, _html} = live(conn, "/console/requests")

      ids =
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#requests-table > tr")
        |> LazyHTML.attribute("id")

      assert ids == Enum.map(50..1//-1, &"request-req_recent_#{&1}")
      assert has_element?(view, "#requests-summary-total", "51")
      assert has_element?(view, "#requests-summary-active", "51")
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

    test "failed refresh discards stale rows and recovers through the existing poll" do
      create_request!(%{public_id: "req_before_failure"})
      {:ok, socket} = RequestsLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})
      assert length(socket.assigns.requests) == 1

      previous_repo = Repo.put_dynamic_repo(:requests_unavailable_test)

      failed =
        try do
          {:noreply, failed} = RequestsLive.handle_event("refresh_now", %{}, socket)
          failed
        after
          Repo.put_dynamic_repo(previous_repo)
        end

      assert failed.assigns.requests_status == :error
      assert failed.assigns.requests == []
      assert failed.assigns.requests_summary == nil
      html = render_component(&RequestsLive.render/1, failed.assigns)
      assert html =~ "Requests unavailable"
      assert html =~ "Request data unavailable."
      refute html =~ "req_before_failure"
      refute html =~ "Last checked"
      Process.cancel_timer(failed.assigns.refresh_timer)

      {:noreply, recovered} = RequestsLive.handle_info(:refresh_requests, failed)
      Process.cancel_timer(recovered.assigns.refresh_timer)
      assert recovered.assigns.requests_status == :ok
      assert render_component(&RequestsLive.render/1, recovered.assigns) =~ "req_before_failure"
    end

    test "loading remains explicit without empty or zero evidence" do
      html = render_component(&RequestsLive.render/1, %{requests_status: :loading})
      assert html =~ "Loading recent requests"
      refute html =~ "requests-summary"
      refute html =~ "requests-empty-state"
    end

    test "narrow layout and keyboard controls retain semantic navigation", %{conn: conn} do
      create_request!(%{public_id: "req_keyboard"})
      {:ok, view, _html} = live(conn, "/console/requests")

      assert has_element?(view, "#requests-summary.grid-cols-2.sm\\:grid-cols-4")

      assert has_element?(
               view,
               "#requests-table-region.overflow-x-auto[role='region'][tabindex='0'][aria-label='Recent requests'] > .contents > table > #requests-table"
             )

      summary = element(view, "#requests-evidence-help > summary") |> render()
      assert summary =~ "focus-visible:ring-2"
      assert summary =~ "focus-visible:ring-offset-2"
      assert has_element?(view, "button#requests-refresh-now[phx-click='refresh_now']")
      link = element(view, "#request-req_keyboard a") |> render()
      assert link =~ "focus-visible:ring-2"
      assert link =~ "focus-visible:ring-offset-2"
      refute link =~ "tabindex"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp row_cells(view, public_id) do
    html = if is_binary(view), do: view, else: render(view)

    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#request-#{public_id} td")
    |> Enum.map(&(LazyHTML.text(&1) |> String.trim()))
  end

  defp create_timed_request!(overrides) do
    request = create_request!(overrides)
    set_created_at(request, ~U[2026-03-15 12:00:00.000000Z])
    request
  end

  defp set_created_at(request, inserted_at) do
    {1, _} =
      Repo.update_all(from(r in Request, where: r.id == ^request.id),
        set: [inserted_at: inserted_at]
      )
  end

  defp create_request!(overrides) do
    attrs = request_attrs(overrides)
    {:ok, request} = Requests.create_request(attrs)
    request
  end
end
