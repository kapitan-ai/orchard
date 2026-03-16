defmodule OrchardConsole.RequestLive do
  @moduledoc """
  Console request detail page — shows request summary, usage, errors,
  canonical request JSON, and event timeline for a single inference request.
  """

  use OrchardConsole, :live_view

  alias Orchard.Requests
  alias Orchard.Requests.Request

  @default_refresh_interval_ms 5_000

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl true
  def mount(%{"public_id" => public_id}, _session, socket) do
    socket =
      socket
      |> assign(active_nav: :requests, public_id: public_id)
      |> assign(page_title: "Request #{public_id}")
      |> assign_loading_state()

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"public_id" => public_id}, _uri, socket) do
    socket =
      socket
      |> assign(public_id: public_id, page_title: "Request #{public_id}")

    socket =
      if connected?(socket) do
        socket = load_request(socket)

        if should_poll?(socket.assigns) do
          schedule_refresh(refresh_interval_ms())
        end

        socket
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_request, socket) do
    socket = load_request(socket)

    if should_poll?(socket.assigns) do
      schedule_refresh(refresh_interval_ms())
    end

    {:noreply, socket}
  end

  # ===========================================================================
  # Render
  # ===========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.request_tools_row last_checked_at={@last_checked_at} refresh_mode={@refresh_mode} />

      <%= case @request_status do %>
        <% :loading -> %>
          <div id="request-loading-card">
            <.card>
              <:title>Loading request</:title>
              <p class="text-sm text-slate-500 dark:text-slate-400">
                Request details will appear when the LiveView connects.
              </p>
            </.card>
          </div>

        <% :not_found -> %>
          <div id="request-not-found-card">
            <.card>
              <:title>Request not found</:title>
              <p class="text-sm text-slate-500 dark:text-slate-400">
                No persisted request exists for public ID
                <span class="font-mono">{@public_id}</span>.
              </p>
            </.card>
          </div>

        <% :error -> %>
          <div id="request-error-card">
            <.card>
              <:title>Request unavailable</:title>
              <p class="text-sm text-slate-500 dark:text-slate-400">
                {@load_error}
              </p>
            </.card>
          </div>

        <% :ok -> %>
          <.request_summary request={@request} />
          <.request_usage request={@request} />
          <.request_timeline events={@events} />
          <.request_execution_metadata request={@request} />
          <.request_errors request={@request} />
          <.request_provenance request={@request} />
          <.request_response_debug request={@request} />
          <.request_canonical request={@request} />
      <% end %>
    </div>
    """
  end

  # ===========================================================================
  # Utility row
  # ===========================================================================

  attr(:last_checked_at, :any, default: nil)
  attr(:refresh_mode, :atom, default: :static)

  defp request_tools_row(assigns) do
    ~H"""
    <div id="request-tools-row" class="flex flex-wrap items-center justify-between gap-3">
      <.link
        id="request-back-to-playground"
        navigate={~p"/console/playground"}
        class="inline-flex items-center gap-1.5 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" />
        Back to Playground
      </.link>

      <span id="request-freshness" class="text-xs text-slate-500 dark:text-slate-400 font-mono">
        {request_freshness_text(@last_checked_at, @refresh_mode)}
      </span>
    </div>
    """
  end

  # ===========================================================================
  # Section components
  # ===========================================================================

  attr(:request, :map, required: true)

  defp request_summary(assigns) do
    ~H"""
    <div id="request-summary-card">
      <.card>
        <:title>
          <span class="flex items-center gap-3">
            Request Summary
            <.badge tone={state_tone(@request.state)}>
              {format_state(@request.state)}
            </.badge>
          </span>
        </:title>

        <dl class="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-3 lg:grid-cols-4">
          <.detail_field id="request-public-id" label="Public ID" mono>
            {@request.public_id}
          </.detail_field>
          <.detail_field id="request-endpoint" label="Endpoint">
            {format_atom(@request.endpoint)}
          </.detail_field>
          <.detail_field id="request-requested-model" label="Model" mono>
            {format_text(@request.requested_model)}
          </.detail_field>
          <.detail_field id="request-stream" label="Stream">
            {format_bool(@request.stream)}
          </.detail_field>
          <.detail_field id="request-http-status" label="HTTP Status" mono>
            {format_integer(@request.http_status)}
          </.detail_field>
          <.detail_field id="request-created-at" label="Created" mono>
            {format_datetime(@request.inserted_at)}
          </.detail_field>
          <.detail_field id="request-completed-at" label="Completed" mono>
            {format_datetime(@request.completed_at)}
          </.detail_field>
          <.detail_field id="request-state" label="State">
            {format_state(@request.state)}
          </.detail_field>
        </dl>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp request_execution_metadata(assigns) do
    ~H"""
    <div id="request-execution-metadata-card">
      <.card>
        <:title>Execution Metadata</:title>

        <dl class="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-3 lg:grid-cols-5">
          <.detail_field id="request-model-id" label="Model ID" mono>
            {format_text(@request.model_id)}
          </.detail_field>
          <.detail_field id="request-node-id" label="Node ID" mono>
            {format_text(@request.node_id)}
          </.detail_field>
          <.detail_field id="request-worker-id" label="Worker ID" mono>
            {format_text(@request.worker_id)}
          </.detail_field>
          <.detail_field id="request-first-token-at" label="First Token At" mono>
            {format_datetime(@request.first_token_at)}
          </.detail_field>
          <.detail_field id="request-execution-http-status" label="HTTP Status" mono>
            {format_integer(@request.http_status)}
          </.detail_field>
        </dl>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp request_usage(assigns) do
    ~H"""
    <div id="request-usage-card">
      <.card>
        <:title>Token Usage</:title>

        <div class="grid grid-cols-3 gap-4">
          <.metric_tile
            id="request-input-tokens"
            label="Input Tokens"
            value={format_integer(@request.input_tokens)}
          />
          <.metric_tile
            id="request-output-tokens"
            label="Output Tokens"
            value={format_integer(@request.output_tokens)}
          />
          <.metric_tile
            id="request-total-tokens"
            label="Total"
            value={format_token_total(@request.input_tokens, @request.output_tokens)}
          />
        </div>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp request_errors(assigns) do
    ~H"""
    <div
      :if={present_text?(@request.error_code) || present_text?(@request.error_message)}
      id="request-error-details-card"
    >
      <.card>
        <:title>Error Details</:title>

        <dl class="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <.detail_field id="request-error-code" label="Error Code" mono>
            {format_text(@request.error_code)}
          </.detail_field>
          <.detail_field id="request-error-message" label="Error Message">
            {format_text(@request.error_message)}
          </.detail_field>
        </dl>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp request_response_debug(assigns) do
    assigns = assign(assigns, :default_open, error_terminal_state?(assigns.request.state))

    ~H"""
    <.disclosure_section
      wrapper_id="request-response-debug-card"
      title="Response & Debug"
      default_open={@default_open}
    >
      <div class="space-y-6">
        <div>
          <h4 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400 mb-2">
            Response Preview
          </h4>
          <div :if={present_text?(@request.response_preview)} id="request-response-preview">
            <pre class="overflow-x-auto rounded-md bg-slate-50 p-4 text-sm font-mono text-slate-800 whitespace-pre-wrap dark:bg-slate-900/60 dark:text-slate-200">{format_text(@request.response_preview)}</pre>
          </div>
          <p
            :if={!present_text?(@request.response_preview)}
            id="request-response-preview-fallback"
            class="text-sm text-slate-400 dark:text-slate-500"
          >
            Not captured for this request.
          </p>
        </div>

        <div>
          <h4 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400 mb-2">
            Response Payload
          </h4>
          <.json_block
            data={@request.response_payload}
            content_id="request-response-payload"
            fallback_id="request-response-payload-fallback"
            fallback_text="Not captured for this request."
          />
        </div>

        <div>
          <h4 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400 mb-2">
            Scheduler Decision
          </h4>
          <.json_block
            data={@request.scheduler_decision}
            content_id="request-scheduler-decision"
            fallback_id="request-scheduler-decision-fallback"
            fallback_text="Not recorded for this request."
          />
        </div>
      </div>
    </.disclosure_section>
    """
  end

  attr(:request, :map, required: true)

  defp request_canonical(assigns) do
    ~H"""
    <.disclosure_section
      wrapper_id="request-canonical-card"
      title="Canonical Request"
      default_open={false}
    >
      <.json_block
        data={@request.canonical_request}
        content_id="request-canonical-request"
        fallback_id="request-canonical-fallback"
        fallback_text="Not captured for this request."
      />
    </.disclosure_section>
    """
  end

  attr(:request, :map, required: true)

  defp request_provenance(assigns) do
    ~H"""
    <div id="request-provenance-card">
      <.card>
        <:title>Request Provenance</:title>

        <dl class="grid grid-cols-1 gap-x-6 gap-y-4 sm:grid-cols-3">
          <.detail_field id="request-retry-of" label="Retry Of">
            <%= cond do %>
              <% match?(%Orchard.Requests.Request{}, @request.retry_of_request) and
                   present_text?(@request.retry_of_request.public_id) -> %>
                <.link
                  id="request-retry-of-link"
                  navigate={~p"/console/requests/#{@request.retry_of_request.public_id}"}
                  class="text-navy underline hover:text-navy/80 dark:text-gold dark:hover:text-gold/80"
                >
                  <span class="font-mono">{@request.retry_of_request.public_id}</span>
                </.link>
              <% present_text?(@request.retry_of_request_id) -> %>
                <span class="font-mono">{@request.retry_of_request_id}</span>
              <% true -> %>
                <span>—</span>
            <% end %>
          </.detail_field>
          <.detail_field id="request-payload-capture-mode" label="Payload Capture">
            {format_atom(@request.payload_capture_mode)}
          </.detail_field>
          <.detail_field id="request-reserved-output-tokens" label="Reserved Output Tokens" mono>
            {format_integer(@request.reserved_output_tokens)}
          </.detail_field>
        </dl>
      </.card>
    </div>
    """
  end

  attr(:events, :list, required: true)

  defp request_timeline(assigns) do
    ~H"""
    <div id="request-timeline-card">
      <.card>
        <:title>Timeline</:title>

        <.table id="request-timeline" rows={@events} row_id={&"request-event-#{&1.seq}"}>
          <:col :let={event} label="Seq" mono>{event.seq}</:col>
          <:col :let={event} label="Occurred At" mono>{format_datetime(event.occurred_at)}</:col>
          <:col :let={event} label="Event">{event.event_type}</:col>
          <:col :let={event} label="State">
            <%= if event.state do %>
              <.badge tone={state_tone(event.state)}>{format_state(event.state)}</.badge>
            <% else %>
              <span class="text-slate-400 dark:text-slate-500">—</span>
            <% end %>
          </:col>
          <:col :let={event} label="Payload" class="max-w-xs truncate">
            {format_payload(event.payload)}
          </:col>
          <:empty>No lifecycle events recorded yet.</:empty>
        </.table>
      </.card>
    </div>
    """
  end

  # ===========================================================================
  # Local function components
  # ===========================================================================

  attr(:wrapper_id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:default_open, :boolean, default: false)
  slot(:inner_block, required: true)

  defp disclosure_section(assigns) do
    ~H"""
    <div id={@wrapper_id}>
      <details
        class="rounded-lg border border-slate-200 bg-white dark:border-slate-700 dark:bg-slate-800"
        {if @default_open, do: [{:open, true}], else: []}
      >
        <summary class="cursor-pointer select-none px-4 py-3 text-base font-semibold text-slate-900 dark:text-slate-100 hover:bg-slate-50 dark:hover:bg-slate-700/50 rounded-lg">
          {@title}
        </summary>
        <div class="border-t border-slate-200 px-4 py-4 dark:border-slate-700">
          {render_slot(@inner_block)}
        </div>
      </details>
    </div>
    """
  end

  attr(:data, :map, default: nil)
  attr(:content_id, :string, required: true)
  attr(:fallback_id, :string, required: true)
  attr(:fallback_text, :string, default: "Not captured for this request.")

  defp json_block(assigns) do
    ~H"""
    <div :if={present_map?(@data)} id={@content_id}>
      <pre class="overflow-x-auto rounded-md bg-slate-50 p-4 text-xs font-mono text-slate-800 dark:bg-slate-900/60 dark:text-slate-200"><code>{format_json(@data)}</code></pre>
    </div>
    <p
      :if={!present_map?(@data)}
      id={@fallback_id}
      class="text-sm text-slate-400 dark:text-slate-500"
    >
      {@fallback_text}
    </p>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:mono, :boolean, default: false)
  slot(:inner_block, required: true)

  defp detail_field(assigns) do
    ~H"""
    <div id={@id}>
      <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {@label}
      </dt>
      <dd class={[
        "mt-1 text-sm text-slate-900 dark:text-slate-100",
        @mono && "font-mono"
      ]}>
        {render_slot(@inner_block)}
      </dd>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp metric_tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg bg-slate-50 px-4 py-3 dark:bg-slate-900/60">
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {@label}
      </p>
      <p class="mt-1 text-2xl font-mono text-slate-900 dark:text-slate-100">
        {@value}
      </p>
    </div>
    """
  end

  # ===========================================================================
  # Data loading
  # ===========================================================================

  defp assign_loading_state(socket) do
    assign(socket,
      request_status: :loading,
      request: nil,
      events: [],
      load_error: nil,
      last_checked_at: nil,
      refresh_mode: :static
    )
  end

  defp load_request(socket) do
    public_id = socket.assigns.public_id
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Requests.get_request_by_public_id(public_id) do
      nil ->
        assign(socket,
          request_status: :not_found,
          request: nil,
          events: [],
          load_error: nil,
          last_checked_at: now,
          refresh_mode: :static
        )

      %Request{} = request ->
        events = Requests.list_request_events(request)
        mode = if should_poll?(%{request_status: :ok, request: request}), do: :polling, else: :static

        assign(socket,
          request_status: :ok,
          request: request,
          events: events,
          load_error: nil,
          last_checked_at: now,
          refresh_mode: mode
        )
    end
  rescue
    e ->
      assign(socket,
        request_status: :error,
        request: nil,
        events: [],
        load_error: "Request details unavailable: #{Exception.message(e)}",
        last_checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        refresh_mode: :static
      )
  end

  # ===========================================================================
  # Polling
  # ===========================================================================

  defp should_poll?(%{request_status: :ok, request: %Request{state: state}}) do
    state not in Request.terminal_states()
  end

  defp should_poll?(_assigns), do: false

  defp schedule_refresh(interval_ms) do
    Process.send_after(self(), :refresh_request, interval_ms)
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

  # ===========================================================================
  # State helpers
  # ===========================================================================

  defp error_terminal_state?(state) do
    state in Request.terminal_states() and state != :completed
  end

  # ===========================================================================
  # Freshness helpers
  # ===========================================================================

  defp request_freshness_text(nil, :polling),
    do: "Waiting for first live check \u00b7 Auto-refreshing every #{request_refresh_interval_label()}"

  defp request_freshness_text(nil, :static),
    do: "Waiting for first live check"

  defp request_freshness_text(%DateTime{} = dt, :polling),
    do: "Last checked #{Calendar.strftime(dt, "%H:%M:%S")} UTC \u00b7 Auto-refreshing every #{request_refresh_interval_label()}"

  defp request_freshness_text(%DateTime{} = dt, :static),
    do: "Last checked #{Calendar.strftime(dt, "%H:%M:%S")} UTC \u00b7 Auto-refresh stopped"

  defp request_refresh_interval_label do
    ms = refresh_interval_ms()
    if rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s", else: "#{ms}ms"
  end

  # ===========================================================================
  # Formatting
  # ===========================================================================

  defp state_tone(:completed), do: :success
  defp state_tone(:failed), do: :error
  defp state_tone(:interrupted), do: :error
  defp state_tone(:cancelled), do: :warning
  defp state_tone(:timed_out), do: :warning
  defp state_tone(:running), do: :processing
  defp state_tone(:streaming), do: :processing
  defp state_tone(:dispatching), do: :processing
  defp state_tone(_), do: :info

  defp format_state(nil), do: "—"
  defp format_state(state) when is_atom(state), do: Atom.to_string(state)
  defp format_state(state), do: to_string(state)

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp format_integer(nil), do: "—"
  defp format_integer(n) when is_integer(n), do: to_string(n)

  defp format_token_total(input, output) when is_integer(input) and is_integer(output),
    do: to_string(input + output)

  defp format_token_total(_, _), do: "—"

  defp format_bool(true), do: "Yes"
  defp format_bool(false), do: "No"
  defp format_bool(nil), do: "—"

  defp format_text(nil), do: "—"
  defp format_text(""), do: "—"

  defp format_text(s) when is_binary(s) do
    if String.trim(s) == "", do: "—", else: s
  end

  defp format_atom(nil), do: "—"
  defp format_atom(a) when is_atom(a), do: Atom.to_string(a)

  defp present_text?(nil), do: false
  defp present_text?(""), do: false
  defp present_text?(s) when is_binary(s), do: String.trim(s) != ""
  defp present_text?(_), do: false

  defp present_map?(nil), do: false
  defp present_map?(m) when is_map(m) and map_size(m) == 0, do: false
  defp present_map?(m) when is_map(m), do: true
  defp present_map?(_), do: false

  defp format_json(nil), do: "—"

  defp format_json(map) when is_map(map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(map, pretty: true)
    end
  end

  defp format_payload(nil), do: "—"
  defp format_payload(map) when is_map(map) and map_size(map) == 0, do: "—"

  defp format_payload(map) when is_map(map) do
    case Jason.encode(map) do
      {:ok, json} -> json
      {:error, _} -> inspect(map)
    end
  end
end
