defmodule OrchardConsole.RequestLive do
  @moduledoc """
  Console request detail page — shows request summary, usage, errors,
  canonical request JSON, and event timeline for a single inference request.
  """

  use OrchardConsole, :live_view

  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, Tenant}
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
          <.state_message
            id="request-loading-card"
            kind={:loading}
            layout={:panel}
            title="Loading request"
            body="Request details will appear when the LiveView connects."
          />

        <% :not_found -> %>
          <.state_message
            id="request-not-found-card"
            kind={:empty}
            layout={:panel}
            title="Request not found"
            body={"No persisted request exists for public ID #{@public_id}."}
          />

        <% :error -> %>
          <.state_message
            id="request-error-card"
            kind={:error}
            layout={:panel}
            title="Request unavailable"
            body={@load_error}
          />

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
        id="request-back-to-requests"
        navigate={~p"/console/requests"}
        class="inline-flex items-center gap-1.5 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50 dark:border-slate-600 dark:bg-slate-800 dark:text-slate-200 dark:hover:bg-slate-700"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" />
        Back to Requests
      </.link>

      <span id="request-freshness" class="text-xs text-slate-500 dark:text-slate-400 font-mono">
        <%= cond do %>
          <% @last_checked_at == nil and @refresh_mode == :polling -> %>
            Waiting for first live check · Auto-refreshing every {request_refresh_interval_label()}
          <% @last_checked_at == nil -> %>
            Waiting for first live check
          <% @refresh_mode == :polling -> %>
            Last checked <.local_time value={@last_checked_at} format={:time_second} /> · Auto-refreshing every {request_refresh_interval_label()}
          <% true -> %>
            Last checked <.local_time value={@last_checked_at} format={:time_second} /> · Auto-refresh stopped
        <% end %>
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

        <.detail_grid class="grid-cols-2 sm:grid-cols-3 lg:grid-cols-4">
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
            <.local_time value={@request.inserted_at} format={:datetime_second} />
          </.detail_field>
          <.detail_field id="request-completed-at" label="Completed" mono>
            <.local_time value={@request.completed_at} format={:datetime_second} />
          </.detail_field>
          <.detail_field id="request-state" label="State">
            {format_state(@request.state)}
          </.detail_field>
        </.detail_grid>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp request_execution_metadata(assigns) do
    schedule = parse_scheduler_decision(assigns.request.scheduler_decision)
    assigns = assign(assigns, :schedule, schedule)

    ~H"""
    <div id="request-execution-metadata-card">
      <.card>
        <:title>Execution Metadata</:title>

        <.detail_grid class="grid-cols-2 sm:grid-cols-3 lg:grid-cols-5">
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
            <.local_time value={@request.first_token_at} format={:datetime_second} />
          </.detail_field>
          <.detail_field id="request-execution-http-status" label="HTTP Status" mono>
            {format_integer(@request.http_status)}
          </.detail_field>
          <.detail_field id="request-schedule-strategy" label="Strategy" mono>
            {format_text(@schedule.strategy)}
          </.detail_field>
          <.detail_field id="request-schedule-node" label="Scheduled Node" mono>
            {format_text(@schedule.selected_node_id)}
          </.detail_field>
          <.detail_field id="request-schedule-candidates" label="Candidates" mono>
            {format_nullable_integer(@schedule.candidate_count)}
          </.detail_field>
          <.detail_field id="request-schedule-tier" label="Tier" mono>
            {format_text(@schedule.selected_tier)}
          </.detail_field>
        </.detail_grid>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp request_usage(assigns) do
    assigns =
      assigns
      |> assign(:ttft_ms, elapsed_ms(assigns.request.inserted_at, assigns.request.first_token_at))
      |> assign(
        :generation_ms,
        elapsed_ms(assigns.request.first_token_at, assigns.request.completed_at)
      )
      |> assign(
        :total_latency_ms,
        elapsed_ms(assigns.request.inserted_at, assigns.request.completed_at)
      )
      |> assign(:tokens_per_second, request_tokens_per_second(assigns.request))

    ~H"""
    <div id="request-usage-card">
      <.card>
        <:title>Token Usage & Performance</:title>

        <.metric_grid
          gap_class="gap-4"
          class="grid-cols-2 sm:grid-cols-3 xl:grid-cols-4"
        >
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
          <.metric_tile
            id="request-ttft"
            label="TTFT"
            value={format_duration(@ttft_ms)}
          />
          <.metric_tile
            id="request-generation-time"
            label="Generation"
            value={format_duration(@generation_ms)}
          />
          <.metric_tile
            id="request-total-latency"
            label="Total Latency"
            value={format_duration(@total_latency_ms)}
          />
          <.metric_tile
            id="request-tokens-per-second"
            label="Tok/s"
            value={format_rate(@tokens_per_second)}
          />
        </.metric_grid>
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

        <.detail_grid
          gap_class="gap-4"
          class="grid-cols-1 sm:grid-cols-2"
        >
          <.detail_field id="request-error-code" label="Error Code" mono>
            {format_text(@request.error_code)}
          </.detail_field>
          <.detail_field id="request-error-message" label="Error Message">
            {format_text(@request.error_message)}
          </.detail_field>
        </.detail_grid>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp request_response_debug(assigns) do
    assigns = assign(assigns, :default_open, error_terminal_state?(assigns.request.state))

    ~H"""
    <.disclosure_section
      id="request-response-debug-card"
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
      id="request-canonical-card"
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

        <.detail_grid class="grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5">
          <.detail_field id="request-tenant" label="Organization">
            <.tenant_display request={@request} />
          </.detail_field>
          <.detail_field id="request-api-key" label="API Token">
            <.api_key_display request={@request} />
          </.detail_field>
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
        </.detail_grid>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp tenant_display(assigns) do
    assigns = assign(assigns, :tenant_info, tenant_provenance(assigns.request))

    ~H"""
    <%= case @tenant_info.mode do %>
      <% :resolved -> %>
        <span>{@tenant_info.name}</span>
        <span class="block text-xs font-mono text-slate-500 dark:text-slate-400">
          {@tenant_info.slug}
        </span>
      <% :legacy -> %>
        <span>{@tenant_info.name}</span>
        <span class="block text-xs font-mono text-slate-500 dark:text-slate-400">
          {@tenant_info.slug}
        </span>
      <% :orphan -> %>
        <span class="text-slate-500 dark:text-slate-400">Unknown Organization</span>
        <span class="block text-xs font-mono text-slate-500 dark:text-slate-400">
          {@tenant_info.raw_id}
        </span>
      <% :absent -> %>
        <span>—</span>
    <% end %>
    """
  end

  attr(:request, :map, required: true)

  defp api_key_display(assigns) do
    assigns = assign(assigns, :key_info, api_key_provenance(assigns.request))

    ~H"""
    <%= case @key_info.mode do %>
      <% :resolved -> %>
        <span>{@key_info.name}</span>
        <span class="block text-xs font-mono text-slate-500 dark:text-slate-400">
          {@key_info.token_prefix}
        </span>
        <.badge tone={@key_info.status_tone}>{@key_info.status_label}</.badge>
      <% :orphan -> %>
        <span class="text-slate-500 dark:text-slate-400">Unknown API Token</span>
        <span class="block text-xs font-mono text-slate-500 dark:text-slate-400">
          {@key_info.raw_id}
        </span>
        <.badge tone={:neutral}>Missing</.badge>
      <% :absent -> %>
        <span>—</span>
    <% end %>
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
            <:col :let={event} label="Occurred At" mono><.local_time value={event.occurred_at} format={:datetime_second} /></:col>
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

  attr(:data, :map, default: nil)
  attr(:content_id, :string, required: true)
  attr(:fallback_id, :string, required: true)
  attr(:fallback_text, :string, default: "Not captured for this request.")

  defp json_block(assigns) do
    assigns = assign(assigns, :json_render, json_render(assigns.data))

    ~H"""
    <div :if={present_map?(@data)} id={@content_id}>
      <pre class="overflow-x-auto rounded-md bg-slate-50 p-4 text-xs font-mono text-slate-800 dark:bg-slate-900/60 dark:text-slate-200"><code><%= case @json_render do %><% {:highlighted, tokens} -> %><span
          :for={{class, token} <- tokens}
          class={class}
        >{token}</span><% {:plain, json} -> %>{json}<% end %></code></pre>
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

        mode =
          if should_poll?(%{request_status: :ok, request: request}), do: :polling, else: :static

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

  defp request_refresh_interval_label do
    ms = refresh_interval_ms()
    if rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s", else: "#{ms}ms"
  end

  # ===========================================================================
  # Provenance helpers
  # ===========================================================================

  defp tenant_provenance(%{tenant: %Tenant{} = tenant}) do
    %{mode: :resolved, name: tenant.name, slug: tenant.slug}
  end

  defp tenant_provenance(%{tenant_id: tenant_id}) when is_binary(tenant_id) do
    if tenant_id == Governance.legacy_tenant_id() do
      %{
        mode: :legacy,
        name: Governance.legacy_tenant_name(),
        slug: Governance.legacy_tenant_slug()
      }
    else
      %{mode: :orphan, raw_id: tenant_id}
    end
  end

  defp tenant_provenance(_), do: %{mode: :absent}

  defp api_key_provenance(%{api_key: %ApiKey{} = key}) do
    {label, tone} = api_key_status_display(ApiKey.status(key, utc_now()))

    %{
      mode: :resolved,
      name: key.name,
      token_prefix: key.token_prefix,
      status_label: label,
      status_tone: tone
    }
  end

  defp api_key_provenance(%{api_key_id: api_key_id}) when is_binary(api_key_id) do
    %{mode: :orphan, raw_id: api_key_id}
  end

  defp api_key_provenance(_), do: %{mode: :absent}

  defp api_key_status_display(:active), do: {"Active", :success}
  defp api_key_status_display(:expired), do: {"Expired", :warning}
  defp api_key_status_display(:revoked), do: {"Revoked", :neutral}

  defp utc_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
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

  defp format_integer(nil), do: "—"
  defp format_integer(n) when is_integer(n), do: to_string(n)

  defp format_nullable_integer(nil), do: "—"
  defp format_nullable_integer(n) when is_integer(n), do: to_string(n)
  defp format_nullable_integer(_), do: "—"

  defp format_token_total(input, output) when is_integer(input) and is_integer(output),
    do: to_string(input + output)

  defp format_token_total(_, _), do: "—"

  # ---------------------------------------------------------------------------
  # Performance metric helpers
  # ---------------------------------------------------------------------------

  defp elapsed_ms(nil, _), do: nil
  defp elapsed_ms(_, nil), do: nil

  defp elapsed_ms(%DateTime{} = start_at, %DateTime{} = end_at) do
    ms = DateTime.diff(end_at, start_at, :millisecond)
    if ms >= 0, do: ms, else: nil
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{ms} ms"

  defp format_duration(ms) do
    seconds = ms / 1000
    :erlang.float_to_binary(seconds, decimals: 1) <> " s"
  end

  defp format_rate(nil), do: "—"

  defp format_rate(rate) do
    :erlang.float_to_binary(rate / 1.0, decimals: 1)
  end

  defp request_tokens_per_second(request) do
    generation_ms = elapsed_ms(request.first_token_at, request.completed_at)

    cond do
      is_nil(generation_ms) -> nil
      generation_ms <= 0 -> nil
      not is_integer(request.output_tokens) -> nil
      request.output_tokens <= 0 -> nil
      true -> request.output_tokens / (generation_ms / 1000.0)
    end
  end

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

  # ---------------------------------------------------------------------------
  # Scheduler decision parsing
  # ---------------------------------------------------------------------------

  defp parse_scheduler_decision(nil), do: empty_schedule()
  defp parse_scheduler_decision(decision) when not is_map(decision), do: empty_schedule()

  defp parse_scheduler_decision(decision) do
    %{
      strategy: schedule_string(decision, ["strategy", :strategy]),
      candidate_count: schedule_integer(decision, ["candidate_count", :candidate_count]),
      selected_tier: schedule_string(decision, ["selected_tier", :selected_tier]),
      selected_node_id: schedule_string(decision, ["node_id", :node_id])
    }
  end

  defp empty_schedule do
    %{strategy: nil, candidate_count: nil, selected_tier: nil, selected_node_id: nil}
  end

  defp schedule_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        s when is_binary(s) and s != "" -> s
        _ -> nil
      end
    end)
  end

  defp schedule_integer(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end
    end)
  end

  defp present_map?(nil), do: false
  defp present_map?(m) when is_map(m) and map_size(m) == 0, do: false
  defp present_map?(m) when is_map(m), do: true
  defp present_map?(_), do: false

  @json_highlight_max_bytes 20_000
  @json_token_pattern ~r/("(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null|[{}\[\],:])/u

  defp json_render(data) when is_map(data) do
    json = format_json(data)

    if byte_size(json) <= @json_highlight_max_bytes do
      {:highlighted, tokenize_json(json)}
    else
      {:plain, json}
    end
  end

  defp json_render(_), do: {:plain, "—"}

  defp tokenize_json(json) do
    @json_token_pattern
    |> Regex.split(json, include_captures: true, trim: false)
    |> Enum.map(&{json_token_class(&1), &1})
  end

  defp json_token_class(""), do: nil

  defp json_token_class(token) when token in ["{", "}", "[", "]", ",", ":"],
    do: "text-slate-400 dark:text-slate-500"

  defp json_token_class(token) when token in ["true", "false"],
    do: "text-amber-700 dark:text-amber-300"

  defp json_token_class("null"), do: "text-slate-500 italic dark:text-slate-400"

  defp json_token_class(<<"\"", _::binary>>),
    do: "text-forest-700 dark:text-emerald-300"

  defp json_token_class(token) do
    if Regex.match?(~r/^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/, token) do
      "text-sky-700 dark:text-sky-300"
    else
      nil
    end
  end

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
