defmodule OrchardConsole.RequestsLive do
  @moduledoc """
  Console requests index page — recent requests with summary strip,
  table with cluster attribution, and auto-refresh.
  """

  use OrchardConsole, :live_view

  alias Orchard.Requests

  @default_refresh_interval_ms 5_000

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Requests", active_nav: :requests)
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

      <div id="requests-summary" class="grid grid-cols-4 gap-3">
        <.summary_tile id="requests-summary-total" label="Total" value={@requests_summary.total} tone={:neutral} />
        <.summary_tile id="requests-summary-active" label="Active" value={@requests_summary.active} tone={:info} />
        <.summary_tile id="requests-summary-terminal" label="Terminal" value={@requests_summary.terminal} tone={:neutral} />
        <.summary_tile id="requests-summary-failed" label="Failed" value={@requests_summary.failed} tone={:error} />
      </div>

      <div id="requests-list-card">
        <.card>
          <:title>Recent Requests</:title>
          <:subtitle>Last 50 requests, newest first.</:subtitle>

          <.table id="requests-table" rows={@requests} row_id={&"request-#{&1.public_id}"}>
            <:col :let={req} label="Created" mono>{format_datetime(req.inserted_at)}</:col>
            <:col :let={req} label="Public ID" mono>
              <.link
                navigate={~p"/console/requests/#{req.public_id}"}
                class="text-navy-600 hover:text-navy-800 dark:text-sky-400 dark:hover:text-sky-300 underline"
              >
                {req.public_id}
              </.link>
            </:col>
            <:col :let={req} label="State">
              <.badge tone={state_tone(req.state)}>{req.state}</.badge>
            </:col>
            <:col :let={req} label="Endpoint">{format_endpoint(req.endpoint)}</:col>
            <:col :let={req} label="Model" mono>{req.requested_model || "\u2014"}</:col>
            <:col :let={req} label="Node" mono>{req.node_id || "\u2014"}</:col>
            <:col :let={req} label="HTTP" mono>{format_http_status(req.http_status)}</:col>
            <:col :let={req} label="Tokens" mono>{format_tokens(req.input_tokens, req.output_tokens)}</:col>

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
        {freshness_text(@last_checked_at)}
      </span>

      <.button id="requests-refresh-now" variant={:secondary} size={:sm} phx-click="refresh_now">
        Refresh
      </.button>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:tone, :atom, values: [:neutral, :info, :success, :warning, :error])

  defp summary_tile(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-lg border px-3 py-2 text-center",
        tile_tone_classes(@tone)
      ]}
    >
      <p class="text-lg font-semibold font-mono">{format_integer(@value)}</p>
      <p class="text-xs text-slate-500 dark:text-slate-400">{@label}</p>
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

  defp tile_tone_classes(:neutral), do: "border-slate-200 dark:border-slate-700"
  defp tile_tone_classes(:info), do: "border-sky-200 dark:border-sky-800"
  defp tile_tone_classes(:success), do: "border-forest-200 dark:border-emerald-800"
  defp tile_tone_classes(:warning), do: "border-amber-200 dark:border-amber-800"
  defp tile_tone_classes(:error), do: "border-red-200 dark:border-red-800"

  defp freshness_text(nil), do: "Loading\u2026"

  defp freshness_text(%DateTime{} = dt) do
    "Last checked #{Calendar.strftime(dt, "%H:%M:%S UTC")} \u00b7 Auto-refreshing"
  end

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(_), do: "\u2014"

  defp format_integer(nil), do: "\u2014"
  defp format_integer(n) when is_integer(n), do: Integer.to_string(n)

  defp format_endpoint(nil), do: "\u2014"
  defp format_endpoint(endpoint) when is_atom(endpoint), do: Atom.to_string(endpoint)
  defp format_endpoint(endpoint) when is_binary(endpoint), do: endpoint

  defp format_http_status(nil), do: "\u2014"
  defp format_http_status(status), do: to_string(status)

  defp format_tokens(nil, nil), do: "\u2014"
  defp format_tokens(input, output) when is_integer(input) and is_integer(output) do
    Integer.to_string(input + output)
  end
  defp format_tokens(_, _), do: "\u2014"
end
