defmodule OrchardConsole.RequestLive do
  @moduledoc """
  Console request detail page — shows request summary, usage, errors,
  canonical request JSON, the persisted scheduler explanation, and event
  timeline for a single inference request.
  """

  use OrchardConsole, :live_view

  alias Orchard.API.Ops.SchedulerExplanationPresenter
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, Tenant}
  alias Orchard.Requests
  alias Orchard.Requests.{Request, RequestStepEvent}
  alias OrchardConsole.RequestEvidence
  alias OrchardConsole.TimeHelpers

  @default_refresh_interval_ms 5_000
  @unsafe_scheduler_diagnostic_key_pattern ~r/(prompt|token|secret|credential|password|dsn|body|payload|request|response)/i

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
        refresh_request(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_request, socket) do
    {:noreply, refresh_request(socket)}
  end

  @impl true
  def handle_event("refresh_request", _params, socket) do
    {:noreply, refresh_request(socket)}
  end

  # ===========================================================================
  # Render
  # ===========================================================================

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :attempts, RequestEvidence.attempts(assigns.events))

    ~H"""
    <div id="request-detail" class="min-w-0 space-y-6">
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
          <.request_summary request={@request} attempts={@attempts} />
          <.request_errors request={@request} />
          <.request_timeline request={@request} events={@events} attempts={@attempts} />
          <.request_usage request={@request} />
          <.disclosure_section id="request-more-evidence" title="More evidence">
            <div class="space-y-6">
              <.request_execution_metadata request={@request} />
              <.request_scheduler_explanation
                status={@scheduler_explanation_status}
                explanation={@scheduler_explanation}
                error_reason={@scheduler_explanation_error}
              />
              <.request_provenance request={@request} />
            </div>
          </.disclosure_section>
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

      <div class="flex flex-wrap items-center gap-3">
      <button type="button" phx-click="refresh_request" phx-disable-with="Checking…"
        class="inline-flex items-center gap-2 rounded-md border border-slate-200 bg-white px-3 py-1.5 text-sm text-slate-700 dark:border-slate-700 dark:bg-slate-800 dark:text-slate-200">
        <.icon name="hero-arrow-path" class="h-4 w-4" />Refresh
      </button>
      <span id="request-freshness" class="text-xs text-slate-500 dark:text-slate-400">
        <%= cond do %>
          <% @last_checked_at == nil and @refresh_mode == :polling -> %>
            Waiting for first live check · Auto-refreshing every {request_refresh_interval_label()}
          <% @last_checked_at == nil -> %>
            Waiting for first live check
          <% @refresh_mode == :polling -> %>
            Last checked <.local_time value={@last_checked_at} format={:time_second} /> · Auto-refreshing every {request_refresh_interval_label()}
          <% true -> %>
            Checked <.local_time value={@last_checked_at} format={:time_second} /> · Auto-refresh stopped
        <% end %>
      </span>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # Section components
  # ===========================================================================

  attr(:request, :map, required: true)
  attr(:attempts, :list, required: true)

  defp request_summary(assigns) do
    ~H"""
    <div id="request-summary-card">
      <.card>
        <:title>
          <span class="flex flex-wrap items-center gap-3">
            {if @request.state in Request.terminal_states(), do: "Final outcome", else: "Current state"}
            <.badge tone={state_tone(@request.state)}>
              {format_state(@request.state)}
            </.badge>
          </span>
        </:title>

        <p class="mb-5 text-sm text-slate-500 dark:text-slate-400">
          {outcome_description(@request, @attempts)}
        </p>
        <dl class="mb-5">
          <.detail_field id="request-requested-model" label="Model" mono>
            <.model_identity id="request-requested-model-value" value={format_text(@request.requested_model)} />
          </.detail_field>
        </dl>
        <dl class="mb-3 grid max-w-xl grid-cols-2 gap-5">
          <.request_metric id="request-ttft" icon="hero-clock" label="Time to first token (TTFT)"
            value={RequestEvidence.duration(RequestEvidence.ttft_ms(@request))}
            note="Until first public output" />
          <.request_metric id="request-total-latency" icon="hero-clock" label="Total request time"
            value={RequestEvidence.duration(TimeHelpers.elapsed_ms(@request.inserted_at, @request.completed_at))}
            note={if @request.state in Request.terminal_states(), do: "Until final outcome", else: "Available when request ends"} />
        </dl>
        <details id="request-timing-help" class="mb-5">
          <summary class="request-evidence-summary">About these timings</summary>
          <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
            Timings start at Request creation and include waiting and retries.
            TTFT ends at the first recorded public output, not client receipt.
            Total time ends at the final outcome; active requests have no final duration.
          </p>
        </details>
        <details id="request-metadata">
          <summary class="request-evidence-summary">Request details</summary>
        <.detail_grid class="mt-4 request-metadata-grid grid-cols-1 sm:grid-cols-2">
          <.detail_field id="request-public-id" label="Public ID" mono>
            {@request.public_id}
          </.detail_field>
          <.detail_field id="request-endpoint" label="Endpoint">
            {format_atom(@request.endpoint)}
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
        </.detail_grid>
        </details>
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

  attr(:status, :atom, required: true)
  attr(:explanation, :map, default: nil)
  attr(:error_reason, :any, default: nil)

  defp request_scheduler_explanation(assigns) do
    ~H"""
    <div id="request-scheduler-explanation-card">
      <.card variant={scheduler_explanation_card_variant(@status)}>
        <:title>Scheduler Explanation</:title>
        <:subtitle>
          Shared selected, scored, skipped, and rejected candidate contract from SPEC.md §7.3.5.
        </:subtitle>

        <%= case @status do %>
          <% :ok -> %>
            <div class="space-y-5">
              <.detail_grid class="grid-cols-1 sm:grid-cols-3">
                <.detail_field id="scheduler-explanation-request-id" label="Request ID" mono break_all>
                  {format_text(@explanation.request_id)}
                </.detail_field>
                <.detail_field id="scheduler-explanation-selected-node" label="Selected Node" mono break_all>
                  {format_text(@explanation.selected_node_id)}
                </.detail_field>
                <.detail_field id="scheduler-explanation-selection-tier" label="Selection Tier" mono>
                  {format_text(@explanation.selection_tier)}
                </.detail_field>
              </.detail_grid>

              <.candidate_group
                id="scheduler-selected-candidate"
                title="Selected Candidate"
                candidates={selected_candidates(@explanation)}
                empty_text="No selected candidate was recorded."
                tone={:success}
              />
              <.candidate_group
                id="scheduler-scored-candidates"
                title="Scored Candidates"
                candidates={@explanation.scored_candidates}
                empty_text="No scored candidates were recorded."
                tone={:info}
              />
              <.candidate_group
                id="scheduler-skipped-candidates"
                title="Skipped Candidates"
                candidates={@explanation.skipped_candidates}
                empty_text="No skipped candidates were recorded."
                tone={:warning}
              />
              <.candidate_group
                id="scheduler-rejected-candidates"
                title="Rejected Candidates"
                candidates={@explanation.rejected_candidates}
                empty_text="No rejected candidates were recorded."
                tone={:error}
              />
            </div>

          <% :not_found -> %>
            <.state_message
              id="scheduler-explanation-not-found"
              kind={:empty}
              layout={:compact}
              title="No scheduler explanation recorded."
              body="This request has no persisted scheduler explanation."
            />

          <% :invalid -> %>
            <.state_message
              id="scheduler-explanation-invalid"
              kind={:error}
              layout={:compact}
              title="Scheduler explanation is invalid."
              body={scheduler_explanation_error_body(@error_reason)}
            />

          <% _ -> %>
            <.state_message
              id="scheduler-explanation-unavailable"
              kind={:error}
              layout={:compact}
              title="Scheduler explanation unavailable."
              body="The scheduler explanation state is unavailable."
            />
        <% end %>
      </.card>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:candidates, :list, default: [])
  attr(:empty_text, :string, required: true)
  attr(:tone, :atom, default: :neutral)

  defp candidate_group(assigns) do
    ~H"""
    <section id={@id} class="space-y-3">
      <div class="flex items-center gap-2">
        <h4 class="text-sm font-semibold text-slate-900 dark:text-slate-100">{@title}</h4>
        <.badge tone={@tone} class="font-mono">{length(@candidates)}</.badge>
      </div>

      <div :if={@candidates == []} class="rounded-lg border border-dashed border-slate-200 p-4 text-sm text-slate-500 dark:border-slate-700 dark:text-slate-400">
        {@empty_text}
      </div>

      <div :if={@candidates != []} class="grid gap-3 lg:grid-cols-2">
        <.candidate_card :for={{candidate, index} <- Enum.with_index(@candidates, 1)} id_prefix={@id} candidate={candidate} index={index} />
      </div>
    </section>
    """
  end

  attr(:id_prefix, :string, required: true)
  attr(:candidate, :map, required: true)
  attr(:index, :integer, required: true)

  defp candidate_card(assigns) do
    assigns =
      assigns
      |> assign(
        :components,
        scheduler_entries(sanitized_scheduler_metadata(assigns.candidate.components))
      )
      |> assign(
        :diagnostics,
        scheduler_entries(sanitized_scheduler_metadata(assigns.candidate.diagnostics))
      )

    ~H"""
    <article class="rounded-lg border border-slate-200 bg-slate-50 p-4 dark:border-slate-700 dark:bg-slate-900/40">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
            Candidate {@index}
          </p>
          <p class="mt-1 break-all font-mono text-sm text-slate-900 dark:text-slate-100">
            {format_text(@candidate.node_id)}
          </p>
        </div>
        <.badge tone={candidate_eligibility_tone(@candidate.eligible)}>
          {candidate_eligibility_label(@candidate.eligible)}
        </.badge>
      </div>

      <.detail_grid class="mt-4 grid-cols-2" gap_class="gap-x-4 gap-y-3">
        <.detail_field id={"#{@id_prefix}-candidate-#{@index}-target"} label="Target" mono break_all>
          {format_text(@candidate.target_ref)}
        </.detail_field>
        <.detail_field id={"#{@id_prefix}-candidate-#{@index}-tier"} label="Tier" mono>
          {format_text(@candidate.tier)}
        </.detail_field>
        <.detail_field id={"#{@id_prefix}-candidate-#{@index}-score"} label="Score" mono>
          {format_scheduler_score(@candidate.score)}
        </.detail_field>
      </.detail_grid>

      <div class="mt-4 space-y-3">
        <.code_badges title="Reason Codes" values={@candidate.reason_codes} empty_text="No reason codes." />
        <.key_value_list title="Score Components" entries={@components} empty_text="No score components." />
        <.key_value_list title="Diagnostics" entries={@diagnostics} empty_text="No diagnostics." />
      </div>
    </article>
    """
  end

  attr(:title, :string, required: true)
  attr(:values, :list, default: [])
  attr(:empty_text, :string, required: true)

  defp code_badges(assigns) do
    ~H"""
    <div>
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">{@title}</p>
      <div :if={@values != []} class="mt-2 flex flex-wrap gap-2">
        <.badge :for={value <- @values} tone={:neutral} class="font-mono">{value}</.badge>
      </div>
      <p :if={@values == []} class="mt-1 text-sm text-slate-400 dark:text-slate-500">{@empty_text}</p>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:entries, :list, default: [])
  attr(:empty_text, :string, required: true)

  defp key_value_list(assigns) do
    ~H"""
    <div>
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">{@title}</p>
      <dl :if={@entries != []} class="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
        <div :for={{key, value} <- @entries} class="rounded-md bg-white px-3 py-2 ring-1 ring-slate-200 dark:bg-slate-800 dark:ring-slate-700">
          <dt class="font-mono text-xs text-slate-500 dark:text-slate-400">{key}</dt>
          <dd class="mt-1 break-all font-mono text-sm text-slate-900 dark:text-slate-100">{format_scheduler_value(value)}</dd>
        </div>
      </dl>
      <p :if={@entries == []} class="mt-1 text-sm text-slate-400 dark:text-slate-500">{@empty_text}</p>
    </div>
    """
  end

  attr(:request, :map, required: true)

  defp request_usage(assigns) do
    ~H"""
    <div id="request-usage-card">
      <.card>
        <:title>Logical Request usage</:title>
        <dl class="grid gap-5 sm:grid-cols-2">
          <.request_metric id="request-input-tokens" icon="hero-document-text" label="Input tokens"
            value={stored_count(@request.input_tokens)} note="Prompt and context" />
          <.request_metric id="request-output-tokens" icon="hero-chat-bubble-left-right" label="Output tokens"
            value={stored_count(@request.output_tokens)} note="Model-generated output" />
        </dl>
        <p id="request-total-tokens" class="mt-5 text-sm text-slate-500 dark:text-slate-400">
          Total: <span class="font-mono">{format_token_total(@request.input_tokens, @request.output_tokens)}</span> tokens
        </p>
        <p class="mt-3 text-sm text-slate-500 dark:text-slate-400">
          Stored counts · measurement accuracy not recorded.
          <span :if={@request.input_tokens == 0 or @request.output_tokens == 0}>
            A stored zero may be a legacy placeholder, not measured zero.
          </span>
        </p>
        <details class="mt-4">
          <summary class="request-evidence-summary">What these counts mean</summary>
          <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
            These are the logical Request's stored counts, not a sum of all attempts.
            Discarded retry output is not added to public usage. This record does not
            establish an exact total or a lower bound. Missing values are not zero.
          </p>
        </details>
      </.card>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:note, :string, required: true)

  defp request_metric(assigns) do
    ~H"""
    <div id={@id} class="min-w-0">
      <dt class="flex items-center gap-2 text-xs text-slate-500 dark:text-slate-400">
        <.icon name={@icon} class="h-4 w-4 shrink-0" />{@label}
      </dt>
      <dd class={["mt-1 font-mono text-slate-900 dark:text-slate-100", if(@value == "Not recorded", do: "text-sm", else: "text-2xl")]}>{@value}</dd>
      <dd class="mt-1 max-w-sm text-xs text-slate-500 dark:text-slate-400">{@note}</dd>
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
      <:summary>{capture_description(@request.payload_capture_mode)}</:summary>
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
            No retained content available for this request.
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
            fallback_text="No retained content available for this request."
          />
        </div>

        <div>
          <h4 class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400 mb-2">
            Scheduler Decision
          </h4>
          <.json_block
            data={sanitized_scheduler_decision(@request.scheduler_decision)}
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
      <:summary>{capture_description(@request.payload_capture_mode)}</:summary>
      <.json_block
        data={@request.canonical_request}
        content_id="request-canonical-request"
        fallback_id="request-canonical-fallback"
        fallback_text="No retained content available for this request."
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
  attr(:request, :map, required: true)
  attr(:attempts, :list, required: true)

  defp request_timeline(assigns) do
    assigns =
      assign(
        assigns,
        :total_ms,
        TimeHelpers.elapsed_ms(assigns.request.inserted_at, assigns.request.completed_at)
      )

    ~H"""
    <div id="request-timeline-card">
      <.card>
        <:title>Execution Timeline · {length(@attempts)} recorded attempts</:title>
        <p class="mb-4 text-sm text-slate-500 dark:text-slate-400">
          Elapsed from Request creation. Expand an attempt to inspect its evidence.
        </p>
        <div :if={@total_ms && @total_ms > 0} class="mb-3 grid gap-2 lg:grid-cols-[14rem_minmax(0,1fr)_7rem]">
          <span class="text-xs text-slate-500 dark:text-slate-400">Elapsed from creation</span>
          <div class="flex justify-between font-mono text-xs text-slate-500 dark:text-slate-400">
            <span>0 s</span><span>{RequestEvidence.duration(div(@total_ms, 2))}</span><span>{RequestEvidence.duration(@total_ms)}</span>
          </div>
        </div>
        <div class="space-y-4">
          <.duration_bar request={@request} started_at={@request.inserted_at}
            ended_at={@request.completed_at} label="Logical Request" outcome={format_state(@request.state)} />
          <.request_attempts request={@request} attempts={@attempts} />
        </div>
        <p class="mt-3 text-xs text-slate-500 dark:text-slate-400">
          Gaps do not identify queue, loading, or cleanup phases.
        </p>
        <details id="request-recorded-events" class="mt-6">
          <summary class="request-evidence-summary">View {length(@events)} recorded events</summary>
          <p class="my-3 text-xs text-slate-500 dark:text-slate-400">
            Sequence order · elapsed from Request creation. Expand an event for its timestamp and retained payload.
          </p>
          <ol id="request-timeline" class="divide-y divide-slate-200 dark:divide-slate-700">
            <li :for={event <- @events} id={"request-event-#{event.seq}"} class="py-3">
              <details>
                <summary class="request-evidence-summary">
                  <span class="font-mono">#{event.seq}</span>
                  <span>{event_scope(event)} · {event.event_type}</span>
                  <span :if={event.state} class="font-mono">{format_state(event.state)}</span>
                  <span class="block pl-4 font-mono text-xs text-slate-500 dark:text-slate-400">
                    {RequestEvidence.duration(TimeHelpers.elapsed_ms(@request.inserted_at, event.occurred_at))}
                  </span>
                </summary>
                <div class="mt-3 space-y-3">
                  <p class="text-xs text-slate-500 dark:text-slate-400">
                    Recorded at: <.local_time value={event.occurred_at} format={:datetime_second} />
                  </p>
                  <.json_block data={event.payload} content_id={"request-event-payload-#{event.seq}"}
                    fallback_id={"request-event-empty-#{event.seq}"} fallback_text="No retained payload." />
                </div>
              </details>
            </li>
          </ol>
          <p :if={@events == []} class="text-sm text-slate-500 dark:text-slate-400">No lifecycle events recorded yet.</p>
        </details>
      </.card>
    </div>
    """
  end

  attr(:request, :map, required: true)
  attr(:started_at, :any, required: true)
  attr(:ended_at, :any, required: true)
  attr(:label, :string, required: true)
  attr(:outcome, :string, required: true)

  defp duration_bar(assigns) do
    assigns =
      assign(
        assigns,
        :bar,
        RequestEvidence.bar(
          assigns.request.inserted_at,
          assigns.request.completed_at,
          assigns.started_at,
          assigns.ended_at
        )
      )

    ~H"""
    <span class="grid min-w-0 gap-2 lg:grid-cols-[14rem_minmax(0,1fr)_7rem] lg:items-center">
      <span class="text-sm">
        <.icon name={attempt_icon(@outcome)} class="mr-1 inline-block h-4 w-4" />
        <span>{@label}</span>
        <span class="block text-xs text-slate-500 dark:text-slate-400">{@outcome}</span>
      </span>
      <span :if={@bar} class="relative block h-3 rounded bg-slate-100 dark:bg-slate-900" aria-hidden="true">
        <span class={["absolute block h-3 rounded", attempt_bar_class(@outcome)]}
          style={"left: #{@bar.left}%; width: #{@bar.width}%;"} />
      </span>
      <span :if={!@bar} class="text-xs text-slate-500 dark:text-slate-400">No bounded timing interval</span>
      <span class="font-mono text-xs lg:text-right">
        {RequestEvidence.duration(TimeHelpers.elapsed_ms(@started_at, @ended_at))}
      </span>
    </span>
    """
  end

  attr(:attempts, :list, required: true)
  attr(:request, :map, required: true)

  defp request_attempts(assigns) do
    ~H"""
    <div id="request-attempts-card" class="min-w-0">
        <p :if={@attempts == []} class="text-sm text-slate-500 dark:text-slate-400">
          No readable Inference Attempt evidence recorded. Request state does not prove an attempt count.
        </p>
        <ol class="divide-y divide-slate-200 dark:divide-slate-700">
          <li :for={attempt <- @attempts} id={"request-attempt-#{attempt.turn}-#{attempt.number}"}
            class="py-3">
            <details>
              <summary class="request-evidence-summary request-attempt-summary">
                <.duration_bar request={@request} started_at={attempt.started_at} ended_at={attempt.ended_at}
                  label={"Turn #{attempt.turn} · Attempt #{attempt.number}"} outcome={attempt.outcome} />
                <span class="mt-1 block text-xs text-navy dark:text-sky-400">Inspect attempt</span>
              </summary>
            <p class="mt-2 text-xs text-slate-500 dark:text-slate-400">
              Node: <span class="break-all font-mono">{attempt.result["node_id"] || "Not recorded"}</span>
            </p>
            <dl class="mt-3 space-y-2 text-sm">
              <div :for={{key, label} <- [{"failure_code", "Failure"}, {"retry_decision", "Retry decision"}]}
                :if={attempt.result[key]}>
                <dt class="text-xs text-slate-500 dark:text-slate-400">{label}</dt>
                <dd class="break-words font-mono">{attempt.result[key]}</dd>
              </div>
            </dl>
            <details class="mt-3">
              <summary class="request-evidence-summary">Attempt evidence</summary>
              <p class="my-2 break-all font-mono text-xs">{attempt.step_id}</p>
              <.json_block data={attempt.result} content_id={"attempt-result-#{attempt.turn}-#{attempt.number}"}
                fallback_id={"attempt-empty-#{attempt.turn}-#{attempt.number}"} fallback_text="No terminal result recorded." />
            </details>
            </details>
          </li>
        </ol>
    </div>
    """
  end

  # ===========================================================================
  # Local function components
  # ===========================================================================

  attr(:data, :map, default: nil)
  attr(:content_id, :string, required: true)
  attr(:fallback_id, :string, required: true)
  attr(:fallback_text, :string, default: "No retained content available for this request.")

  defp json_block(assigns) do
    assigns = assign(assigns, :json_render, json_render(assigns.data))

    ~H"""
    <div :if={present_map?(@data)} id={@content_id} class="min-w-0" phx-hook="RequestPayload">
      <div class="mb-2 flex flex-wrap items-center gap-3">
        <button type="button" data-copy-json class="rounded-md border border-slate-200 px-3 py-1.5 text-xs text-slate-700 dark:border-slate-700 dark:text-slate-200">
          Copy JSON
        </button>
        <span data-copy-status role="status" class="text-xs text-slate-500 dark:text-slate-400"></span>
      </div>
      <pre tabindex="0" aria-label="Retained JSON" class="overflow-x-auto rounded-md bg-slate-50 p-4 text-xs font-mono text-slate-800 dark:bg-slate-900/60 dark:text-slate-200"><code><%= case @json_render do %><% {:highlighted, tokens} -> %><span
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
      scheduler_explanation_status: :loading,
      scheduler_explanation: nil,
      scheduler_explanation_error: nil,
      load_error: nil,
      last_checked_at: nil,
      refresh_timer: nil,
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
          scheduler_explanation_status: :not_found,
          scheduler_explanation: nil,
          scheduler_explanation_error: nil,
          load_error: nil,
          last_checked_at: now,
          refresh_mode: :static
        )

      %Request{} = request ->
        events = Requests.list_request_events(request)

        mode =
          if should_poll?(%{request_status: :ok, request: request}), do: :polling, else: :static

        socket
        |> assign(
          request_status: :ok,
          request: request,
          events: events,
          load_error: nil,
          last_checked_at: now,
          refresh_mode: mode
        )
        |> assign_scheduler_explanation(request)
    end
  rescue
    _error ->
      assign(socket,
        request_status: :error,
        request: nil,
        events: [],
        scheduler_explanation_status: :error,
        scheduler_explanation: nil,
        scheduler_explanation_error: nil,
        load_error: "Request details could not be loaded. Try Refresh now.",
        last_checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        refresh_mode: :static
      )
  end

  defp assign_scheduler_explanation(socket, request) do
    case SchedulerExplanationPresenter.show(request) do
      {:ok, explanation} ->
        assign(socket,
          scheduler_explanation_status: :ok,
          scheduler_explanation: explanation,
          scheduler_explanation_error: nil
        )

      {:error, :scheduler_explanation_not_found} ->
        assign(socket,
          scheduler_explanation_status: :not_found,
          scheduler_explanation: nil,
          scheduler_explanation_error: nil
        )

      {:error, reason} ->
        assign(socket,
          scheduler_explanation_status: :invalid,
          scheduler_explanation: nil,
          scheduler_explanation_error: reason
        )
    end
  end

  # ===========================================================================
  # Polling
  # ===========================================================================

  defp should_poll?(%{request_status: :ok, request: %Request{state: state}}) do
    state not in Request.terminal_states()
  end

  defp should_poll?(_assigns), do: false

  defp refresh_request(socket) do
    if socket.assigns.refresh_timer, do: Process.cancel_timer(socket.assigns.refresh_timer)
    socket = load_request(socket)

    timer =
      if should_poll?(socket.assigns),
        do: Process.send_after(self(), :refresh_request, refresh_interval_ms())

    assign(socket, :refresh_timer, timer)
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

  defp scheduler_explanation_card_variant(:ok), do: :primary
  defp scheduler_explanation_card_variant(_status), do: :default

  defp scheduler_explanation_error_body(nil),
    do: "Persisted scheduler explanation is invalid."

  defp scheduler_explanation_error_body(reason),
    do:
      "Persisted scheduler explanation is invalid: #{scheduler_explanation_error_category(reason)}"

  defp scheduler_explanation_error_category({category, _field, _value}) when is_atom(category),
    do: to_string(category)

  defp scheduler_explanation_error_category({category, _value}) when is_atom(category),
    do: to_string(category)

  defp scheduler_explanation_error_category(category) when is_atom(category),
    do: to_string(category)

  defp scheduler_explanation_error_category(_reason), do: "unknown"

  defp selected_candidates(%{selected_node_id: selected_node_id} = explanation)
       when is_binary(selected_node_id) do
    explanation
    |> scheduler_candidate_lists()
    |> Enum.filter(&(&1.node_id == selected_node_id))
  end

  defp selected_candidates(_explanation), do: []

  defp scheduler_candidate_lists(explanation) do
    [
      Map.get(explanation, :scored_candidates),
      Map.get(explanation, :skipped_candidates),
      Map.get(explanation, :rejected_candidates)
    ]
    |> Enum.filter(&is_list/1)
    |> List.flatten()
  end

  defp candidate_eligibility_tone(true), do: :success
  defp candidate_eligibility_tone(false), do: :neutral

  defp candidate_eligibility_label(true), do: "Eligible"
  defp candidate_eligibility_label(false), do: "Not eligible"

  defp format_scheduler_score(score) when is_integer(score), do: to_string(score)
  defp format_scheduler_score(_score), do: "Not recorded"

  defp format_scheduler_value(value) when is_integer(value), do: to_string(value)

  defp format_scheduler_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp format_scheduler_value(value) when is_boolean(value), do: to_string(value)
  defp format_scheduler_value(value) when is_binary(value), do: value
  defp format_scheduler_value(nil), do: "Not recorded"
  defp format_scheduler_value(value), do: inspect(value)

  defp scheduler_entries(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp sanitized_scheduler_metadata(map) when is_map(map) do
    Map.reject(map, fn {key, _value} -> unsafe_scheduler_key?(key) end)
  end

  defp sanitized_scheduler_metadata(_value), do: %{}

  defp sanitized_scheduler_decision(map) when is_map(map) do
    map
    |> Map.reject(fn {key, _value} -> unsafe_scheduler_key?(key) end)
    |> Map.new(fn {key, value} -> {key, sanitized_scheduler_decision_value(value)} end)
  end

  defp sanitized_scheduler_decision(_value), do: nil

  defp sanitized_scheduler_decision_value(value) when is_map(value),
    do: sanitized_scheduler_decision(value)

  defp sanitized_scheduler_decision_value(values) when is_list(values),
    do: Enum.map(values, &sanitized_scheduler_decision_value/1)

  defp sanitized_scheduler_decision_value(value), do: value

  defp unsafe_scheduler_key?(key) do
    key
    |> to_string()
    |> String.match?(@unsafe_scheduler_diagnostic_key_pattern)
  end

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

  defp format_token_total(_, _), do: "Not recorded"

  defp stored_count(nil), do: "Not recorded"
  defp stored_count(count), do: to_string(count)

  defp capture_description(:full),
    do:
      "Full capture was selected. Only retained payloads are shown; absence does not prove expiry or redaction."

  defp capture_description(mode) when mode in [:none, :metadata],
    do:
      "#{mode} capture was selected. Request and response content is not retained under this policy."

  defp capture_description(_),
    do: "Capture policy was not recorded. Only retained evidence is shown."

  defp outcome_description(%{state: :completed}, attempts) do
    if Enum.any?(attempts, &(&1.result["retry_decision"] == "retried")) do
      "Completed after retry."
    else
      "Request completed."
    end
  end

  defp outcome_description(%{state: state}, _attempts) do
    if state in Request.terminal_states(),
      do: "Request ended. Inspect the failure and attempt evidence below.",
      else: "Request in progress. Final outcome and total time are not yet recorded."
  end

  defp attempt_bar_class("completed"), do: "bg-forest dark:bg-emerald-400"
  defp attempt_bar_class("failed"), do: "bg-red-600 dark:bg-red-400"
  defp attempt_bar_class(_), do: "bg-slate-500 dark:bg-slate-400"

  defp attempt_icon("completed"), do: "hero-check-circle"
  defp attempt_icon("failed"), do: "hero-exclamation-triangle"
  defp attempt_icon(_), do: "hero-clock"

  defp event_scope(event) do
    case RequestStepEvent.from_request_event(event) do
      {:ok, step} -> "#{step.step_type} · Turn #{step.turn_index} · Attempt #{step.attempt}"
      _ -> if(event.state, do: "Request", else: "Unclassified event")
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
end
