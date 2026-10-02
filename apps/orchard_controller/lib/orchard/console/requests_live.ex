defmodule OrchardConsole.RequestsLive do
  @moduledoc """
  Console requests index page — recent requests with summary strip,
  table with cluster attribution, and auto-refresh.
  """

  use OrchardConsole, :live_view

  alias Orchard.Requests
  alias Orchard.Requests.Request
  alias OrchardConsole.RequestEvidence
  alias OrchardConsole.TimeHelpers

  @default_refresh_interval_ms 5_000

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Requests", active_nav: :requests, page_mode: :wide)
      |> assign_loading_state()
      |> load_requests_page()

    if connected?(socket) do
      {:ok, schedule_refresh(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_info(:refresh_requests, socket) do
    {:noreply, socket |> load_requests_page() |> schedule_refresh()}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    {:noreply, socket |> cancel_refresh() |> load_requests_page() |> schedule_refresh()}
  end

  # ===========================================================================
  # Render
  # ===========================================================================

  @impl true
  def render(%{requests_status: :loading} = assigns) do
    ~H"""
    <.state_message
      id="requests-loading-card"
      kind={:loading}
      layout={:panel}
      title="Requests"
      body="Loading recent requests\u2026"
    />
    """
  end

  def render(%{requests_status: :error} = assigns) do
    ~H"""
    <.state_message
      id="requests-error-card"
      kind={:error}
      layout={:panel}
      title="Requests unavailable"
      body={@load_error}
    />
    """
  end

  def render(%{requests_status: :ok} = assigns) do
    ~H"""
    <div class="space-y-6">
      <.requests_tools_row last_checked_at={@last_checked_at} />

      <.metric_grid id="requests-summary" class="grid-cols-2 sm:grid-cols-4">
        <.metric_tile id="requests-summary-total" label="Total" value={format_integer(@requests_summary.total)} tone={:neutral} density={:compact} />
        <.metric_tile id="requests-summary-active" label="Active" value={format_integer(@requests_summary.active)} tone={:info} density={:compact} />
        <.metric_tile id="requests-summary-terminal" label="Terminal" value={format_integer(@requests_summary.terminal)} tone={:neutral} density={:compact} />
        <.metric_tile id="requests-summary-failed" label="Failed" value={format_integer(@requests_summary.failed)} tone={:error} density={:compact} />
      </.metric_grid>

      <div id="requests-list-card">
        <.card>
          <:title>Recent Requests</:title>
          <:subtitle>Last 50 requests, newest first.</:subtitle>

          <details id="requests-evidence-help" class="mb-4 max-w-prose">
            <summary class="cursor-pointer rounded-md text-sm text-slate-700 dark:text-slate-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy focus-visible:ring-offset-2 dark:focus-visible:ring-sky-400 dark:focus-visible:ring-offset-slate-800">About usage and timings</summary>
            <div class="mt-2 space-y-2 text-sm text-slate-500 dark:text-slate-400">
              <p>Input and output are stored Request token counts, not a sum of retry attempts.
                Lower bound means at least the recorded output count. Accuracy unknown means
                output-usage classification was not recorded; it does not mean exact.</p>
              <p>TTFT starts at Request creation and ends at the first recorded public output,
                not client receipt. Total time ends at the persisted final outcome.
                Pending timing on active requests is In progress. Missing or inconsistent
                retained timing is Not recorded, not zero.</p>
            </div>
          </details>

          <div id="requests-table-region" role="region" aria-label="Recent requests" tabindex="0"
            class="overflow-x-auto rounded [&_th]:px-3 [&_td]:px-3 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy focus-visible:ring-offset-2 dark:focus-visible:ring-sky-400 dark:focus-visible:ring-offset-slate-800">
          <.table id="requests-table" rows={@requests} row_id={&"request-#{&1.public_id}"} class="contents">
            <:col :let={req} label="Created" mono class="whitespace-nowrap"><.local_time value={req.inserted_at} format={:datetime_minute} /></:col>
            <:col :let={req} label="Public ID" mono>
              <.link
                navigate={~p"/console/requests/#{req.public_id}"}
                class="rounded text-navy-600 hover:text-navy-800 dark:text-sky-400 dark:hover:text-sky-300 underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy focus-visible:ring-offset-2 dark:focus-visible:ring-sky-400 dark:focus-visible:ring-offset-slate-800"
              >
                {req.public_id}
              </.link>
            </:col>
            <:col :let={req} label="State">
              <.badge tone={state_tone(req.state)}>{req.state}</.badge>
            </:col>
            <:col :let={req} label="Endpoint">{format_endpoint(req.endpoint)}</:col>
            <:col :let={req} label="Model">
              <span :if={req.requested_model} class="font-mono text-xs"><.model_identity value={req.requested_model} /></span>
              <span :if={is_nil(req.requested_model)}>Not recorded</span>
            </:col>
            <:col :let={req} label="Node">
              <span :if={req.node_id} title={req.node_id} class="font-mono text-xs">
                <span aria-hidden="true">{String.slice(req.node_id, 0, 8)}</span>
                <span class="sr-only">{req.node_id}</span>
              </span>
              <span :if={is_nil(req.node_id)}>—</span>
            </:col>
            <:col :let={req} label="HTTP" mono>{format_http_status(req.http_status)}</:col>
            <:col :let={req} label="Input tokens">
              <span class={is_integer(req.input_tokens) && "font-mono text-xs"}>{format_count(req.input_tokens)}</span>
            </:col>
            <:col :let={req} label="Output tokens">
              <span class={is_integer(req.output_tokens) && "font-mono text-xs"}>{format_count(req.output_tokens)}</span>
              <span class="block text-xs text-slate-500 dark:text-slate-400">{" "}{format_output_accuracy(req.output_usage_status)}</span>
            </:col>
            <:col :let={req} label="TTFT">
              <% ms = RequestEvidence.ttft_ms(req) %>
              <span class={is_integer(ms) && "font-mono text-xs"}>{format_timing(req, :first_token_at, ms)}</span>
            </:col>
            <:col :let={req} label="Total time">
              <% ms = TimeHelpers.elapsed_ms(req.inserted_at, req.completed_at) %>
              <span class={is_integer(ms) && "font-mono text-xs"}>{format_timing(req, :completed_at, ms)}</span>
            </:col>

            <:empty>
              <.state_message
                id="requests-empty-state"
                kind={:empty}
                layout={:compact}
                title="No requests recorded yet."
              >
                <:action>
                  Use the <.link navigate={~p"/console/playground"} class="underline">Playground</.link> or the API to create your first request.
                </:action>
              </.state_message>
            </:empty>
          </.table>
          </div>
        </.card>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # Private components
  # ===========================================================================

  attr(:last_checked_at, :any, default: nil)

  defp requests_tools_row(assigns) do
    ~H"""
    <div id="requests-tools-row" class="flex flex-wrap items-center justify-between gap-3">
      <span id="requests-freshness" class="text-xs text-slate-500 dark:text-slate-400 font-mono">
        <span :if={@last_checked_at == nil}>Loading…</span>
        <span :if={@last_checked_at != nil}>
          Last checked <.local_time value={@last_checked_at} format={:time_second} /> · Auto-refreshing
        </span>
      </span>

      <.button id="requests-refresh-now" variant={:secondary} size={:sm} phx-click="refresh_now">
        Refresh
      </.button>
    </div>
    """
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  defp assign_loading_state(socket) do
    assign(socket,
      requests_status: :loading,
      requests: [],
      requests_summary: nil,
      load_error: nil,
      last_checked_at: nil,
      refresh_timer: nil
    )
  end

  defp load_requests_page(socket) do
    summary = Requests.summary()
    rows = Requests.list_recent_requests()
    failed = Map.get(summary.by_state, :failed, 0)

    assign(socket,
      requests_status: :ok,
      requests: rows,
      requests_summary: Map.put(summary, :failed, failed),
      load_error: nil,
      last_checked_at: DateTime.utc_now()
    )
  rescue
    _ ->
      assign(socket,
        requests_status: :error,
        requests: [],
        requests_summary: nil,
        load_error: "Request data unavailable.",
        last_checked_at: DateTime.utc_now()
      )
  end

  # -- Polling --

  defp schedule_refresh(socket) do
    ref = Process.send_after(self(), :refresh_requests, refresh_interval_ms())
    assign(socket, refresh_timer: ref)
  end

  defp cancel_refresh(socket) do
    case socket.assigns[:refresh_timer] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    assign(socket, refresh_timer: nil)
  end

  defp refresh_interval_ms do
    case console_config()[:refresh_interval_ms] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_refresh_interval_ms
    end
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  # -- Formatting --

  defp state_tone(:completed), do: :success
  defp state_tone(:failed), do: :error
  defp state_tone(:interrupted), do: :error
  defp state_tone(:cancelled), do: :warning
  defp state_tone(:timed_out), do: :warning
  defp state_tone(:running), do: :processing
  defp state_tone(:streaming), do: :processing
  defp state_tone(:dispatching), do: :processing
  defp state_tone(_), do: :info

  defp format_integer(nil), do: "\u2014"
  defp format_integer(n) when is_integer(n), do: Integer.to_string(n)

  defp format_endpoint(nil), do: "\u2014"
  defp format_endpoint(endpoint) when is_atom(endpoint), do: Atom.to_string(endpoint)
  defp format_endpoint(endpoint) when is_binary(endpoint), do: endpoint

  defp format_http_status(nil), do: "\u2014"
  defp format_http_status(status), do: to_string(status)

  defp format_count(nil), do: "Not recorded"
  defp format_count(n) when is_integer(n), do: Integer.to_string(n)

  defp format_output_accuracy(:exact), do: "Exact"
  defp format_output_accuracy(:lower_bound), do: "Lower bound"
  defp format_output_accuracy(nil), do: "Accuracy unknown"

  defp format_timing(request, field, ms) do
    pending? =
      request.state in Request.active_states() and
        match?(%DateTime{}, request.inserted_at) and is_nil(request.completed_at) and
        (is_nil(request.first_token_at) or is_integer(RequestEvidence.ttft_ms(request)))

    if is_nil(Map.fetch!(request, field)) and pending? do
      "In progress"
    else
      RequestEvidence.duration(ms)
    end
  end
end
