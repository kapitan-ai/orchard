defmodule OrchardConsole.OverviewLive do
  @moduledoc """
  Console overview page — readiness, runtime snapshot, request counts,
  and model catalog with periodic refresh.
  """

  use OrchardConsole, :live_view

  alias Orchard.API.{Endpoint, Readiness, Transport}
  alias Orchard.Governance
  alias Orchard.Models
  alias Orchard.Models.Model
  alias Orchard.Requests
  alias Orchard.Requests.Request
  alias Phoenix.LiveView.JS

  @readiness_check_order [
    :controller_boot_completed,
    :postgres_reachable,
    :migrations_current,
    :public_api_https_enabled
  ]

  @default_refresh_interval_ms 5_000

  @quickstart_step_definitions [
    %{
      id: :system_healthy,
      dom_id: "system-healthy",
      ordinal: 1,
      title: "Controller checks pass",
      evidence: "This Controller's readiness checks"
    },
    %{
      id: :import_first_model,
      dom_id: "import-first-model",
      ordinal: 2,
      title: "Import your first model",
      evidence: "At least one active catalog Model"
    },
    %{
      id: :run_test_request,
      dom_id: "run-test-request",
      ordinal: 3,
      title: "Run a test request",
      evidence: "At least one completed durable Request"
    },
    %{
      id: :create_api_key,
      dom_id: "create-api-key",
      ordinal: 4,
      title: "Create an API Token",
      evidence: "An active API Token exists; not model-specific access"
    },
    %{
      id: :connect_your_tools,
      dom_id: "connect-your-tools",
      ordinal: 5,
      title: "Connect your tools",
      evidence: "Guide opened in this browser; connection not verified"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Overview", active_nav: :overview)
      |> assign(build_version: OrchardConsole.display_version())
      |> assign(quickstart_client_id: "overview-quickstart-client-#{Ecto.UUID.generate()}")

    if connected?(socket) do
      {:ok, socket |> load_overview() |> schedule_refresh()}
    else
      {:ok, assign_loading_state(socket)}
    end
  end

  @impl true
  def handle_info(:refresh_overview, socket) do
    {:noreply, socket |> load_overview() |> schedule_refresh()}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    # Cancel existing timer and re-arm after reload so there's always exactly one poll
    {:noreply, socket |> cancel_refresh() |> load_overview() |> schedule_refresh()}
  end

  @impl true
  def handle_event("quickstart_client_state_loaded", params, socket) do
    {:noreply,
     update_quickstart_client_state(socket, %{
       hydrated?: true,
       dismissed?: quickstart_pref_enabled?(Map.get(params, "dismissed")),
       guide_seen?: quickstart_pref_enabled?(Map.get(params, "guide_seen"))
     })}
  end

  @impl true
  def handle_event("quickstart_guide_seen", _params, socket) do
    {:noreply, update_quickstart_client_state(socket, %{guide_seen?: true})}
  end

  @impl true
  def handle_event("quickstart_dismiss", _params, socket) do
    socket =
      socket
      |> update_quickstart_client_state(%{dismissed?: true})
      |> push_event("overview_quickstart:set_dismissed", %{dismissed: true})

    {:noreply, socket}
  end

  @impl true
  def handle_event("quickstart_recover", _params, socket) do
    socket =
      socket
      |> update_quickstart_client_state(%{dismissed?: false})
      |> push_event("overview_quickstart:set_dismissed", %{dismissed: false})

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="overview-command" class="space-y-4">
      <section id="overview-status" aria-label="Operational status">
        <.card variant={:primary} padding={:sm}>
          <div class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-slate-500 dark:text-slate-400">
            <span class="inline-flex items-center gap-2">
              Controller readiness <.badge tone={readiness_badge_tone(@readiness.status)}>{readiness_badge_label(@readiness.status)}</.badge>
            </span>
            <span class="inline-flex flex-wrap items-center gap-2">
              Default Runtime Endpoint <.badge tone={runtime_badge_tone(@runtime)}>{runtime_badge_label(@runtime)}</.badge>
            </span>
            <span class="font-mono">{@build_version}</span>
          </div>
          <p
            id="overview-hero-status-copy"
            role="status"
            aria-live="polite"
            class={["mt-3 text-sm font-medium", hero_status_copy_class(@readiness, @runtime)]}
          >
            {hero_status_copy(@readiness, @runtime)}
          </p>
          <div id="overview-freshness" class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-2 text-xs text-slate-500 dark:text-slate-400">
            <span :if={@last_updated_at == nil}>Waiting for first live update</span>
            <span :if={@last_updated_at != nil}>
              Last refresh <.local_time value={@last_updated_at} format={:time_second} />
            </span>
            <span>Auto-refreshing every {refresh_interval_label()}</span>
            <.button id="overview-refresh-now" variant={:ghost} size={:sm} phx-click="refresh_now">
              Refresh now
            </.button>
          </div>
          <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
            Point-in-time checks and reads; each source can fail independently. Not fleet or inference readiness.
          </p>
        </.card>
      </section>

      <section id="overview-metrics" aria-label="Current summary metrics" class="space-y-3">
        <.metric_grid class="grid-cols-2 md:grid-cols-3 xl:grid-cols-6">
          <.overview_metric id="overview-metric-checks-passing" label="Checks passing" value={readiness_metric(@readiness)} source="Controller readiness" evidence={if @readiness.status == :error, do: "Recorded", else: source_evidence(@readiness.status)} />
          <.overview_metric id="overview-metric-loaded-models" label="Loaded models" value={format_count(runtime_loaded_count(@runtime))} source="Default Runtime Endpoint" evidence={source_evidence(@runtime.status)} />
          <.overview_metric id="overview-metric-catalog-models" label="Catalog models" value={format_count(@model_catalog.total)} source="Durable catalog" evidence={source_evidence(@model_catalog.status)} />
          <.overview_metric id="overview-metric-total-requests" label="Total requests" value={format_count(@request_summary.total)} source="Durable Requests" evidence={source_evidence(@request_summary.status)} />
          <.overview_metric id="overview-metric-avg-ttft" label="Avg TTFT" value={format_duration(@request_performance.avg_ttft_ms)} source="Unwindowed Request mean" evidence={performance_evidence(@request_performance, :avg_ttft_ms)} />
          <.overview_metric id="overview-metric-avg-tokens-per-second" label="Avg tok/s" value={format_rate(@request_performance.avg_tokens_per_second)} source="Unwindowed Request mean" evidence={performance_evidence(@request_performance, :avg_tokens_per_second)} />
        </.metric_grid>
        <.disclosure_section id="overview-metric-definitions" title="Metric definitions and provenance">
          <dl class="space-y-3 text-sm text-slate-600 dark:text-slate-300">
            <div>
              <dt class="font-medium text-slate-900 dark:text-slate-100">Source, scope and freshness</dt>
              <dd>Controller checks, one default Runtime Endpoint observation, and durable database aggregates are separate reads at the last refresh. Database totals span this installation, without a time-window filter. The refresh time does not certify that every source succeeded.</dd>
            </div>
            <div>
              <dt class="font-medium text-slate-900 dark:text-slate-100">Avg TTFT</dt>
              <dd>Arithmetic mean from Request creation to first recorded public output, including waiting and earlier attempts. Not client receipt time.</dd>
            </div>
            <div>
              <dt class="font-medium text-slate-900 dark:text-slate-100">Avg tok/s</dt>
              <dd>Existing unwindowed arithmetic mean of each qualifying Request's output tokens divided by seconds from first recorded public output to completion. Not a provider-native generation rate or throughput trend.</dd>
            </div>
            <div>
              <dt class="font-medium text-slate-900 dark:text-slate-100">Qualifying performance evidence</dt>
              <dd>Completed Requests with recorded first output and completion, completion after first output, and positive output tokens. No qualifying evidence is Not recorded; a failed read is Unavailable. Neither is zero.</dd>
            </div>
          </dl>
        </.disclosure_section>
      </section>

      <.quickstart_panel quickstart={@quickstart} client_id={@quickstart_client_id} />

      <section id="overview-requests" aria-label="Current Request states">
        <.card padding={:sm}>
          <:title>Current Request states</:title>
          <:subtitle>Source: durable Request rows · installation-wide · read at last refresh. Current distribution, not history.</:subtitle>
          <%= cond do %>
            <% @request_summary.status == :loading -> %>
              <.state_message id="overview-request-summary-loading" kind={:loading} layout={:compact} title="Loading request summary." />
            <% @request_summary.status == :ok -> %>
              <div class="mb-3 flex flex-wrap items-center gap-3">
                <.badge tone={:info}>{@request_summary.active} active</.badge>
                <.badge tone={:neutral}>{@request_summary.terminal} terminal</.badge>
              </div>
              <dl id="overview-request-counts" class="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6">
                <div :for={row <- @request_summary.rows} class="min-w-0 rounded-lg border border-slate-200 px-3 py-2 dark:border-slate-700">
                  <dt class="text-xs font-mono text-slate-500 dark:text-slate-400">{row.state}</dt>
                  <dd class="mt-1 text-lg font-mono text-slate-900 dark:text-slate-100">{row.count}</dd>
                </div>
              </dl>
            <% true -> %>
              <.state_message id="overview-request-summary-error" kind={:error} layout={:compact} title={@request_summary.message || "Request summary unavailable."} />
          <% end %>
        </.card>
      </section>

      <div class="grid items-start gap-4 lg:grid-cols-2">
        <section id="overview-runtime" aria-label="Default Runtime Endpoint snapshot" class="min-w-0">
          <.card padding={:sm}>
            <:title>Default Runtime Endpoint</:title>
            <:subtitle>Source: one live snapshot · default target only · observed at last refresh. Not fleet-wide schedulability.</:subtitle>
            <.detail_grid class="grid-cols-1 sm:grid-cols-2">
              <.detail_field id="overview-runtime-health" label="Runtime health">{runtime_health_label(@runtime)}</.detail_field>
              <.detail_field id="overview-worker-state" label="Worker state">{worker_state_badge_label(@runtime)}</.detail_field>
              <.detail_field id="overview-runtime-node" label="Observed Node" mono break_all>{runtime_node_label(@runtime)}</.detail_field>
              <.detail_field id="overview-runtime-active-requests" label="Active requests" mono>{if @runtime.status == :ok, do: format_count(@runtime.active_request_count), else: "—"}</.detail_field>
              <.detail_field id="overview-primary-model" label="Loaded model" mono class="sm:col-span-2">
                <.model_identity value={primary_loaded_model(@runtime)} />
              </.detail_field>
            </.detail_grid>
            <p class="mt-3 text-xs text-slate-500 dark:text-slate-400">Loaded models do not establish Workspace access or inference readiness.</p>
            <div class="mt-4">
              <%= cond do %>
                <% @runtime.status == :loading -> %>
                  <.state_message id="overview-runtime-loading" kind={:loading} layout={:compact} title="Loading runtime snapshot." />
                <% @runtime.status == :ok -> %>
                  <.disclosure_section id="overview-loaded-models" title="Loaded model set">
                    <.table id="overview-runtime-models" rows={@runtime.loaded_models}>
                      <:col :let={m} label="Model" mono><.model_identity value={m.model_id} /></:col>
                      <:col :let={m} label="Version" mono>{m.version}</:col>
                      <:empty>
                        <.state_message id="overview-runtime-empty" kind={:empty} layout={:compact} title="No loaded models." />
                      </:empty>
                    </.table>
                  </.disclosure_section>
                <% true -> %>
                  <.state_message id="overview-runtime-unavailable" kind={:error} layout={:compact} title="Runtime unavailable." body={@runtime.message} />
              <% end %>
            </div>
          </.card>
        </section>

        <div class="min-w-0 space-y-4">
          <section id="overview-controller" aria-label="Controller readiness">
            <.card padding={:sm}>
              <:title>Controller readiness</:title>
              <:subtitle>Source: this Controller · checked at last refresh. Internal orchard.readiness.legacy_m0.v1 predicate; public health responses are status-only.</:subtitle>
              <dl id="overview-readiness" class="space-y-3">
                <div :for={row <- @readiness.rows} class="flex flex-wrap items-start justify-between gap-2">
                  <dt class="min-w-0 flex-1">
                    <span class="wrap-anywhere font-mono text-xs text-slate-700 dark:text-slate-200">{row.key}</span>
                    <p :if={row.label} class="text-sm font-medium text-slate-900 dark:text-slate-100">{row.label}</p>
                    <p :if={row.description} class="text-xs text-slate-500 dark:text-slate-400">{row.description}</p>
                  </dt>
                  <dd><.badge tone={check_badge_tone(row.status)}>{check_badge_label(row.status)}</.badge></dd>
                </div>
              </dl>
            </.card>
          </section>
          <section id="overview-catalog" aria-label="Catalog lifecycle">
            <.card padding={:sm}>
              <:title>Catalog lifecycle</:title>
              <:subtitle>Source: durable Model catalog · installation-wide · read at last refresh. Lifecycle is not loadedness or access.</:subtitle>
              <%= cond do %>
                <% @model_catalog.status == :loading -> %>
                  <.state_message id="overview-model-catalog-loading" kind={:loading} layout={:compact} title="Loading model catalog." />
                <% @model_catalog.status == :ok -> %>
                  <dl id="overview-model-counts" class="space-y-2">
                    <div :for={row <- @model_catalog.rows} class="flex justify-between gap-3 text-sm font-mono">
                      <dt class="text-slate-500 dark:text-slate-400">{row.state}</dt>
                      <dd class="text-slate-900 dark:text-slate-100">{row.count}</dd>
                    </div>
                  </dl>
                <% true -> %>
                  <.state_message id="overview-model-catalog-error" kind={:error} layout={:compact} title={@model_catalog.message || "Model catalog data unavailable."} />
              <% end %>
            </.card>
          </section>
        </div>
      </div>

      <nav aria-label="Overview destinations" class="flex flex-wrap gap-2">
        <.link :for={{id, label, path} <- [
          {"playground", "Open Playground", ~p"/console/playground"},
          {"nodes", "Open Nodes", ~p"/console/nodes"},
          {"models", "Open Models", ~p"/console/models"},
          {"requests", "Open Requests", ~p"/console/requests"}
        ]} id={"overview-open-#{id}"} navigate={path} class={quickstart_cta_class(:pending)}>
          {label}
        </.link>
      </nav>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:source, :string, required: true)
  attr(:evidence, :string, required: true)

  defp overview_metric(assigns) do
    ~H"""
    <div id={@id} class="min-w-0 space-y-1">
      <.metric_tile density={:compact} label={@label} value={@value} />
      <p class="text-center text-xs text-slate-500 dark:text-slate-400">{@source}</p>
      <p class="text-center text-xs text-slate-500 dark:text-slate-400">{@evidence}</p>
    </div>
    """
  end

  attr(:quickstart, :map, required: true)
  attr(:client_id, :string, required: true)

  defp quickstart_panel(assigns) do
    ~H"""
    <div id="overview-quickstart">
      <%!-- A new LiveView mount must remount the hook to rehydrate browser preferences. --%>
      <div id={@client_id} phx-hook="OverviewQuickstart">
        <%= case @quickstart.mode do %>
          <% :hydrating -> %>
            <.card>
              <:title>Quickstart</:title>
              <:subtitle>Restoring quickstart preferences for this browser.</:subtitle>

              <div id="overview-quickstart-hydrating" class="space-y-2">
                <p class="text-sm text-slate-600 dark:text-slate-300">
                  Loading your quickstart state before choosing the checklist or compact summary.
                </p>
              </div>
            </.card>

          <% :compact_dismissed -> %>
            <% dismissed_content = dismissed_quickstart_content(@quickstart) %>
            <.card padding={:sm}>
              <:title>Quickstart hidden</:title>
              <:subtitle>{dismissed_content.subtitle}</:subtitle>

              <div id="overview-quickstart-dismissed" class="space-y-4">
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <p class="text-sm text-slate-600 dark:text-slate-300">
                    {dismissed_content.body}
                  </p>

                  <button
                    id="overview-quickstart-recover"
                    type="button"
                    data-quickstart-action="recover"
                    class={quickstart_cta_class(:pending)}
                  >
                    {dismissed_content.recover_label}
                  </button>
                </div>

                <p class="text-sm text-slate-600 dark:text-slate-300">
                  {dismissed_content.guide_hint}
                </p>

                <.quickstart_guide guide_seen?={@quickstart.guide_seen?} />
              </div>
            </.card>

          <% :compact_completed -> %>
            <.card padding={:sm}>
              <div id="overview-quickstart-completed" class="space-y-3">
                <div class="flex flex-wrap items-center gap-2">
                  <.icon name="hero-check-circle" class="h-5 w-5 text-forest dark:text-emerald-400" />
                  <h2 class="text-sm font-semibold text-slate-900 dark:text-slate-100">Quickstart complete</h2>
                  <span class="text-xs text-slate-500 dark:text-slate-400">Browser preferences + current onboarding evidence</span>
                </div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Not a check of current inference readiness. The integration guide remains available.</p>
                <.quickstart_guide guide_seen?={@quickstart.guide_seen?} />
              </div>
            </.card>

          <% :full -> %>
            <.card padding={:sm}>
              <:title>Quickstart</:title>
              <:subtitle>Current onboarding evidence + browser-local guide and visibility preferences. Not inference readiness.</:subtitle>

              <div id="overview-quickstart-full" class="space-y-4">
                <div class="flex justify-end">
                  <button
                    id="overview-quickstart-dismiss"
                    type="button"
                    data-quickstart-action="dismiss"
                    class={quickstart_cta_class(:pending)}
                  >
                    Dismiss
                  </button>
                </div>

                <ol class="space-y-3" id="overview-quickstart-steps">
                  <li
                    :for={step <- @quickstart.steps}
                    id={"overview-quickstart-step-#{step.dom_id}"}
                    data-status={Atom.to_string(step.status)}
                    class={quickstart_step_row_class(step.status)}
                  >
                    <div class="flex items-center gap-3">
                      <span
                        id={"overview-quickstart-indicator-#{step.dom_id}"}
                        class={quickstart_indicator_class(step.status)}
                      >
                        <%= if step.status == :completed do %>
                          <.icon name="hero-check" class="h-4 w-4" />
                        <% else %>
                          {step.ordinal}
                        <% end %>
                      </span>
                      <div class="min-w-0">
                        <p class="text-sm font-medium text-slate-900 dark:text-slate-100">{step.title}</p>
                        <p class="text-xs text-slate-500 dark:text-slate-400">{step.evidence}</p>
                      </div>
                    </div>

                    <div class="flex items-center gap-2">
                      <%= cond do %>
                        <% step.status == :completed -> %>
                          <span class="text-xs text-emerald-600 dark:text-emerald-400 font-medium">Complete</span>
                        <% step.action == nil -> %>
                          <span
                            id={"overview-quickstart-note-#{step.dom_id}"}
                            class="text-xs text-slate-500 dark:text-slate-400 italic"
                          >
                            Checks update automatically
                          </span>
                        <% step.action.kind == :navigate -> %>
                          <.link
                            id={"overview-quickstart-action-#{step.dom_id}"}
                            navigate={step.action.path}
                            data-quickstart-action-emphasis={Atom.to_string(step.status)}
                            class={quickstart_cta_class(step.status)}
                          >
                            {step.action.label}
                          </.link>
                        <% step.action.kind == :open_guide -> %>
                          <button
                            id={"overview-quickstart-action-#{step.dom_id}"}
                            type="button"
                            phx-click={
                              JS.dispatch("orchard:quickstart-guide:open",
                                to: "#overview-quickstart-guide"
                              )
                            }
                            data-quickstart-action-emphasis={Atom.to_string(step.status)}
                            class={quickstart_cta_class(step.status)}
                          >
                            {step.action.label}
                          </button>
                      <% end %>
                    </div>
                  </li>
                </ol>

                <.quickstart_guide guide_seen?={@quickstart.guide_seen?} />
              </div>
            </.card>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:guide_seen?, :boolean, required: true)

  defp quickstart_guide(assigns) do
    ~H"""
    <div
      id="overview-quickstart-guide"
      phx-hook="QuickstartGuide"
      phx-update="ignore"
      data-guide-seen={to_string(@guide_seen?)}
    >
      <.disclosure_section
        id="overview-quickstart-guide-disclosure"
        title="Integration guide"
        summary_id="overview-quickstart-guide-summary"
      >
        <div class="space-y-4 text-sm text-slate-700 dark:text-slate-200">
          <p>
            Use the OpenAI-compatible API at
            <code id="overview-quickstart-guide-base-url" class="rounded bg-slate-100 px-1 py-0.5 text-xs dark:bg-slate-900">
              {quickstart_api_base_url()}
            </code>
            with your generated API Token and selected model.
          </p>

          <div class="space-y-2">
            <p class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
              curl example
            </p>
            <pre id="overview-quickstart-guide-curl" class="overflow-x-auto rounded-lg bg-slate-950 p-3 text-xs text-slate-100"><code>{quickstart_curl_example()}</code></pre>
          </div>

          <div class="space-y-2">
            <p class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
              Python OpenAI client
            </p>
            <pre id="overview-quickstart-guide-python" class="overflow-x-auto rounded-lg bg-slate-950 p-3 text-xs text-slate-100"><code>{quickstart_python_example()}</code></pre>
          </div>

          <div class="space-y-2">
            <p class="text-xs font-semibold uppercase tracking-wide text-slate-500 dark:text-slate-400">
              Generic tool configuration
            </p>
            <pre id="overview-quickstart-guide-tool-config" class="overflow-x-auto rounded-lg bg-slate-950 p-3 text-xs text-slate-100"><code>{quickstart_tool_configuration_example()}</code></pre>
          </div>
        </div>
      </.disclosure_section>
    </div>
    """
  end

  # ===========================================================================
  # Data loading
  # ===========================================================================

  defp load_overview(socket) do
    readiness = fetch_readiness()
    runtime = fetch_runtime()
    model_catalog = fetch_model_catalog()
    request_summary = fetch_request_summary()
    request_performance = fetch_request_performance()
    has_active_api_keys = fetch_active_api_keys()
    client_state = quickstart_client_state(socket)

    assign(socket,
      readiness: readiness,
      runtime: runtime,
      model_catalog: model_catalog,
      request_summary: request_summary,
      request_performance: request_performance,
      has_active_api_keys: has_active_api_keys,
      quickstart:
        build_quickstart(
          readiness,
          model_catalog,
          request_summary,
          has_active_api_keys,
          client_state
        ),
      last_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  defp assign_loading_state(socket) do
    loading_rows =
      %{}
      |> build_readiness_rows(Transport.metadata())
      |> Enum.map(&%{&1 | status: :unknown})

    readiness = %{
      status: :loading,
      passing: nil,
      total: length(@readiness_check_order),
      rows: loading_rows,
      message: nil
    }

    runtime = %{
      status: :loading,
      worker_state: :unknown,
      loaded_models: [],
      active_request_count: 0,
      node_metadata: nil,
      runtime_health: nil,
      message: nil
    }

    model_catalog = %{
      status: :loading,
      total: nil,
      by_state: zero_model_state_counts(),
      rows: [],
      message: nil
    }

    request_summary = %{
      status: :loading,
      total: nil,
      active: nil,
      terminal: nil,
      by_state: zero_request_state_counts(),
      rows: [],
      message: nil
    }

    request_performance = %{
      status: :loading,
      avg_ttft_ms: nil,
      avg_tokens_per_second: nil
    }

    assign(socket,
      readiness: readiness,
      runtime: runtime,
      model_catalog: model_catalog,
      request_summary: request_summary,
      request_performance: request_performance,
      has_active_api_keys: false,
      quickstart:
        build_quickstart(
          readiness,
          model_catalog,
          request_summary,
          false,
          default_quickstart_client_state()
        ),
      last_updated_at: nil
    )
  end

  defp fetch_readiness do
    transport = Transport.metadata()

    case Readiness.status() do
      {:ok, checks} ->
        rows = build_readiness_rows(checks, transport)

        %{
          status: :ok,
          passing: Enum.count(rows, &(&1.status == :ok)),
          total: length(rows),
          rows: rows,
          message: nil
        }

      {:error, _reason, checks} ->
        rows = build_readiness_rows(checks, transport)

        %{
          status: :error,
          passing: Enum.count(rows, &(&1.status == :ok)),
          total: length(rows),
          rows: rows,
          message: nil
        }
    end
  rescue
    _ ->
      rows =
        %{}
        |> build_readiness_rows(Transport.metadata())
        |> Enum.map(&%{&1 | status: :unknown})

      %{
        status: :unavailable,
        passing: 0,
        total: length(rows),
        rows: rows,
        message: "Readiness checks unavailable."
      }
  end

  defp fetch_runtime do
    case runtime_impl().snapshot() do
      {:ok, snapshot} ->
        snapshot
        |> Map.put_new(:node_metadata, nil)
        |> Map.put_new(:runtime_health, nil)
        |> Map.merge(%{status: :ok, message: nil})

      {:error, error} ->
        %{
          status: error.status,
          worker_state: :unknown,
          loaded_models: [],
          active_request_count: 0,
          node_metadata: nil,
          runtime_health: nil,
          message: error.message
        }
    end
  rescue
    _ ->
      %{
        status: :error,
        worker_state: :unknown,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil,
        message: "Runtime snapshot unavailable."
      }
  end

  defp fetch_model_catalog do
    summary = Models.catalog_summary()

    rows =
      Enum.map(Model.states(), fn state -> %{state: state, count: summary.by_state[state]} end)

    %{status: :ok, total: summary.total, by_state: summary.by_state, rows: rows, message: nil}
  rescue
    _ ->
      %{
        status: :error,
        total: nil,
        by_state: zero_model_state_counts(),
        rows: [],
        message: "Model catalog data unavailable."
      }
  end

  defp fetch_request_summary do
    summary = Requests.summary()

    rows =
      Enum.map(Request.states(), fn state -> %{state: state, count: summary.by_state[state]} end)

    %{
      status: :ok,
      total: summary.total,
      active: summary.active,
      terminal: summary.terminal,
      by_state: summary.by_state,
      rows: rows,
      message: nil
    }
  rescue
    _ ->
      %{
        status: :error,
        total: nil,
        active: nil,
        terminal: nil,
        by_state: zero_request_state_counts(),
        rows: [],
        message: "Request summary unavailable."
      }
  end

  defp fetch_request_performance do
    perf = Requests.performance_summary()

    %{
      status: :ok,
      avg_ttft_ms: perf.avg_ttft_ms,
      avg_tokens_per_second: perf.avg_tokens_per_second
    }
  rescue
    _ ->
      %{
        status: :error,
        avg_ttft_ms: nil,
        avg_tokens_per_second: nil
      }
  end

  defp fetch_active_api_keys do
    Governance.has_active_api_keys?()
  rescue
    _ -> false
  end

  defp build_quickstart(
         readiness,
         model_catalog,
         request_summary,
         has_active_api_keys,
         client_state
       ) do
    steps =
      @quickstart_step_definitions
      |> Enum.map(fn step ->
        Map.put(
          step,
          :complete?,
          quickstart_step_complete?(
            step.id,
            readiness,
            model_catalog,
            request_summary,
            has_active_api_keys,
            client_state
          )
        )
      end)
      |> assign_quickstart_step_statuses()

    completed? = quickstart_completed?(steps)

    Map.merge(client_state, %{
      steps: steps,
      completed?: completed?,
      mode: quickstart_mode(client_state, completed?)
    })
  end

  defp default_quickstart_client_state do
    %{dismissed?: false, guide_seen?: false, hydrated?: false}
  end

  defp quickstart_client_state(socket) do
    socket.assigns
    |> Map.get(:quickstart, default_quickstart_client_state())
    |> Map.take([:dismissed?, :guide_seen?, :hydrated?])
    |> then(&Map.merge(default_quickstart_client_state(), &1))
  end

  defp update_quickstart_client_state(socket, attrs) do
    client_state = merge_quickstart_client_state(quickstart_client_state(socket), attrs)

    assign(
      socket,
      :quickstart,
      build_quickstart(
        socket.assigns.readiness,
        socket.assigns.model_catalog,
        socket.assigns.request_summary,
        socket.assigns.has_active_api_keys,
        client_state
      )
    )
  end

  defp merge_quickstart_client_state(current, attrs) do
    %{
      dismissed?: Map.get(attrs, :dismissed?, current.dismissed?),
      guide_seen?: current.guide_seen? or Map.get(attrs, :guide_seen?, false),
      hydrated?: current.hydrated? or Map.get(attrs, :hydrated?, false)
    }
  end

  defp quickstart_completed?(steps), do: Enum.all?(steps, & &1.complete?)

  defp quickstart_mode(%{hydrated?: false}, _completed?), do: :hydrating
  defp quickstart_mode(%{dismissed?: true}, _completed?), do: :compact_dismissed
  defp quickstart_mode(_client_state, true), do: :compact_completed
  defp quickstart_mode(_client_state, false), do: :full

  defp dismissed_quickstart_content(%{completed?: true}) do
    %{
      subtitle: "You can restore the compact quickstart summary at any time.",
      body: "Quickstart is dismissed for this browser until you restore the compact summary.",
      recover_label: "Show quickstart summary",
      guide_hint:
        "Need the setup details without restoring the quickstart summary? Open the integration guide below."
    }
  end

  defp dismissed_quickstart_content(_quickstart) do
    %{
      subtitle: "You can restore the onboarding checklist at any time.",
      body: "Quickstart is dismissed for this browser until you restore the checklist.",
      recover_label: "Show checklist",
      guide_hint:
        "Need the setup details without restoring the checklist? Open the integration guide below."
    }
  end

  defp quickstart_pref_enabled?(true), do: true
  defp quickstart_pref_enabled?("1"), do: true
  defp quickstart_pref_enabled?(value) when is_binary(value), do: String.downcase(value) == "true"
  defp quickstart_pref_enabled?(_), do: false

  defp quickstart_step_complete?(
         :system_healthy,
         readiness,
         _model_catalog,
         _request_summary,
         _,
         _client_state
       ),
       do: readiness.status == :ok

  defp quickstart_step_complete?(
         :import_first_model,
         _readiness,
         model_catalog,
         _request_summary,
         _,
         _client_state
       ) do
    model_catalog.status == :ok and Map.get(model_catalog.by_state, :active, 0) > 0
  end

  defp quickstart_step_complete?(
         :run_test_request,
         _readiness,
         _model_catalog,
         request_summary,
         _,
         _client_state
       ) do
    request_summary.status == :ok and Map.get(request_summary.by_state, :completed, 0) > 0
  end

  defp quickstart_step_complete?(
         :create_api_key,
         _readiness,
         _model_catalog,
         _request_summary,
         has_active_api_keys,
         _client_state
       ),
       do: has_active_api_keys

  defp quickstart_step_complete?(
         :connect_your_tools,
         _readiness,
         _model_catalog,
         _request_summary,
         _has_active_api_keys,
         client_state
       ),
       do: client_state.guide_seen?

  defp assign_quickstart_step_statuses(steps) do
    {steps, _current_assigned?} =
      Enum.map_reduce(steps, false, fn step, current_assigned? ->
        cond do
          step.complete? ->
            {Map.put(step, :status, :completed), current_assigned?}

          current_assigned? ->
            {Map.put(step, :status, :pending), current_assigned?}

          true ->
            {Map.put(step, :status, :current), true}
        end
      end)

    Enum.map(steps, fn step -> Map.put(step, :action, quickstart_step_action(step.id)) end)
  end

  defp quickstart_step_action(:system_healthy), do: nil

  defp quickstart_step_action(:import_first_model),
    do: %{kind: :navigate, label: "Discover models →", path: ~p"/console/models/discover"}

  defp quickstart_step_action(:run_test_request),
    do: %{kind: :navigate, label: "Open Playground →", path: ~p"/console/playground"}

  defp quickstart_step_action(:create_api_key),
    do: %{kind: :navigate, label: "Manage API Tokens", path: ~p"/console/tenants"}

  defp quickstart_step_action(:connect_your_tools),
    do: %{kind: :open_guide, label: "View Integration Guide"}

  defp zero_model_state_counts do
    Map.new(Model.states(), &{&1, 0})
  end

  defp zero_request_state_counts do
    Map.new(Request.states(), &{&1, 0})
  end

  # ===========================================================================
  # Readiness helpers
  # ===========================================================================

  defp build_readiness_rows(checks, transport) do
    Enum.map(@readiness_check_order, fn key ->
      Map.merge(readiness_row_metadata(key, transport), %{
        key: key,
        status: if(Map.get(checks, key, false), do: :ok, else: :error)
      })
    end)
  end

  defp readiness_row_metadata(:public_api_https_enabled, transport) do
    %{
      label: "Public API transport",
      description: transport_mode_description(transport)
    }
  end

  defp readiness_row_metadata(_key, _transport), do: %{label: nil, description: nil}

  defp transport_mode_description(%{mode: "direct_https", cert_source: source}) do
    "Direct HTTPS · cert source: #{source}"
  end

  defp transport_mode_description(%{mode: "reverse_proxy", cert_source: source}) do
    "Reverse proxy HTTPS · cert source: #{source}"
  end

  defp transport_mode_description(%{mode: "plain_http_localhost", cert_source: source}) do
    "Plain HTTP localhost · local development or break-glass mode · cert source: #{source}"
  end

  defp transport_mode_description(%{mode: mode, cert_source: source}) do
    "#{mode} · cert source: #{source}"
  end

  # ===========================================================================
  # Badge helpers
  # ===========================================================================

  defp readiness_badge_tone(:ok), do: :success
  defp readiness_badge_tone(:error), do: :warning
  defp readiness_badge_tone(:loading), do: :neutral
  defp readiness_badge_tone(_), do: :neutral

  defp readiness_badge_label(:ok), do: "Ready"
  defp readiness_badge_label(:error), do: "Degraded"
  defp readiness_badge_label(:loading), do: "Loading"
  defp readiness_badge_label(_), do: "Unavailable"

  defp readiness_metric(%{status: :unavailable}), do: "—"
  defp readiness_metric(%{passing: nil}), do: "\u2014"
  defp readiness_metric(%{passing: p, total: t}), do: "#{p}/#{t}"

  defp source_evidence(:ok), do: "Recorded"
  defp source_evidence(:loading), do: "Loading"
  defp source_evidence(_), do: "Unavailable"

  defp performance_evidence(%{status: :ok} = performance, field) do
    if is_nil(Map.fetch!(performance, field)), do: "Not recorded", else: "Recorded"
  end

  defp performance_evidence(performance, _field), do: source_evidence(performance.status)

  defp runtime_health_label(%{status: :loading}), do: "Loading"
  defp runtime_health_label(%{status: status}) when status != :ok, do: "Unavailable"

  defp runtime_health_label(runtime) do
    case runtime_health_level(runtime) do
      :healthy -> "Healthy"
      :degraded -> "Degraded"
      :unhealthy -> "Unhealthy"
      :unsupported -> "Not recorded"
    end
  end

  # Classifies runtime health into a closed set for badge/hero decisions.
  # Returns :unsupported when old node-agent omits runtime_health.
  defp runtime_health_level(%{status: :ok, runtime_health: %{ready: false}}), do: :unhealthy

  defp runtime_health_level(%{status: :ok, runtime_health: %{health_code: c}})
       when is_binary(c) and c != "",
       do: :degraded

  defp runtime_health_level(%{status: :ok, runtime_health: %{health_message: m}})
       when is_binary(m) and m != "",
       do: :degraded

  defp runtime_health_level(%{status: :ok, runtime_health: %{}}), do: :healthy
  defp runtime_health_level(%{status: :ok}), do: :unsupported

  defp runtime_badge_tone(%{status: :loading}), do: :neutral
  defp runtime_badge_tone(%{status: status}) when status != :ok, do: :error

  defp runtime_badge_tone(%{status: :ok} = rt) do
    case runtime_health_level(rt) do
      :unhealthy -> :error
      :degraded -> :warning
      _ -> worker_state_badge_tone(rt)
    end
  end

  defp worker_state_badge_tone(%{worker_state: :idle}), do: :success
  defp worker_state_badge_tone(%{worker_state: :busy}), do: :processing

  defp worker_state_badge_tone(%{worker_state: state}) when state in [:starting, :stopping],
    do: :warning

  defp worker_state_badge_tone(%{worker_state: :failed}), do: :error
  defp worker_state_badge_tone(%{worker_state: :stopped}), do: :warning
  defp worker_state_badge_tone(_), do: :neutral

  defp runtime_badge_label(%{status: :loading}), do: "Loading"
  defp runtime_badge_label(%{status: status}) when status != :ok, do: "Unavailable"

  defp runtime_badge_label(%{status: :ok} = rt) do
    case runtime_health_level(rt) do
      :unhealthy -> "Unhealthy"
      :degraded -> "Degraded"
      _ -> worker_state_badge_label(rt)
    end
  end

  defp worker_state_badge_label(%{worker_state: :idle}), do: "Idle"
  defp worker_state_badge_label(%{worker_state: :busy}), do: "Busy"
  defp worker_state_badge_label(%{worker_state: :starting}), do: "Starting"
  defp worker_state_badge_label(%{worker_state: :stopping}), do: "Stopping"
  defp worker_state_badge_label(%{worker_state: :failed}), do: "Failed"
  defp worker_state_badge_label(%{worker_state: :stopped}), do: "Stopped"
  defp worker_state_badge_label(_), do: "Unknown"

  defp check_badge_tone(:ok), do: :success
  defp check_badge_tone(:error), do: :warning
  defp check_badge_tone(_), do: :neutral

  defp check_badge_label(:ok), do: "OK"
  defp check_badge_label(:error), do: "Blocked"
  defp check_badge_label(_), do: "Unknown"

  # Quickstart step row styling by status
  defp quickstart_step_row_class(:current) do
    "flex flex-wrap items-center justify-between gap-3 rounded-lg border-2 border-gold/40 bg-gold/5 px-4 py-3 shadow-sm dark:border-gold/30 dark:bg-gold/5"
  end

  defp quickstart_step_row_class(:completed) do
    "flex flex-wrap items-center justify-between gap-3 rounded-lg border border-emerald-200 bg-emerald-50/50 px-4 py-3 dark:border-emerald-800/40 dark:bg-emerald-950/20"
  end

  defp quickstart_step_row_class(:pending) do
    "flex flex-wrap items-center justify-between gap-3 rounded-lg border border-slate-200 px-4 py-3 dark:border-slate-700"
  end

  # Quickstart step indicator (ordinal circle) styling by status
  defp quickstart_indicator_class(:completed) do
    "inline-flex h-7 w-7 items-center justify-center rounded-full bg-emerald-100 text-emerald-600 dark:bg-emerald-900/40 dark:text-emerald-400"
  end

  defp quickstart_indicator_class(:current) do
    "inline-flex h-7 w-7 items-center justify-center rounded-full bg-gold/20 text-xs font-semibold text-gold-700 dark:bg-gold/20 dark:text-gold-300"
  end

  defp quickstart_indicator_class(:pending) do
    "inline-flex h-7 w-7 items-center justify-center rounded-full bg-slate-100 text-xs font-semibold text-slate-700 dark:bg-slate-800 dark:text-slate-200"
  end

  # Quickstart CTA styling: current = prominent, pending = secondary
  defp quickstart_cta_class(:current) do
    "inline-flex items-center gap-1 rounded-md bg-gold/10 px-3 py-1.5 text-sm font-medium text-gold-700 ring-1 ring-gold/30 hover:bg-gold/20 dark:text-gold-300 dark:ring-gold/40 dark:hover:bg-gold/30 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy/40 focus-visible:ring-offset-2 dark:focus-visible:ring-sky-400/40 dark:focus-visible:ring-offset-slate-800"
  end

  defp quickstart_cta_class(_status) do
    "inline-flex items-center gap-1 rounded-md border border-slate-300 px-2.5 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy/40 focus-visible:ring-offset-2 dark:focus-visible:ring-sky-400/40 dark:focus-visible:ring-offset-slate-800"
  end

  defp quickstart_api_base_url do
    Endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/v1")
  end

  defp quickstart_chat_completions_url do
    quickstart_api_base_url() <> "/chat/completions"
  end

  defp quickstart_curl_example do
    """
    curl #{quickstart_chat_completions_url()} \\
      -H \"Authorization: Bearer <your-api-key>\" \\
      -H \"Content-Type: application/json\" \\
      -d '{"model":"<your-model>","messages":[{"role":"user","content":"Hello from Orchard"}]}'
    """
    |> String.trim()
  end

  defp quickstart_python_example do
    """
    from openai import OpenAI

    client = OpenAI(
        base_url=\"#{quickstart_api_base_url()}\",
        api_key=\"<your-api-key>\",
    )

    response = client.chat.completions.create(
        model=\"<your-model>\",
        messages=[{"role": "user", "content": "Hello from Orchard"}],
    )

    print(response.choices[0].message.content)
    """
    |> String.trim()
  end

  defp quickstart_tool_configuration_example do
    """
    Provider: OpenAI-compatible / Custom OpenAI
    Base URL: #{quickstart_api_base_url()}
    API Token: <your-api-token>
    Model: <your-model>
    """
    |> String.trim()
  end

  defp runtime_loaded_count(%{status: :ok, loaded_models: models}), do: length(models)
  defp runtime_loaded_count(_), do: nil

  # ===========================================================================
  # Hero helpers
  # ===========================================================================

  # -- Node display helpers --

  defp runtime_node_label(%{status: :ok, node_metadata: %{display_name: name}})
       when is_binary(name) and name != "",
       do: name

  defp runtime_node_label(%{status: :ok, node_metadata: %{node_id: id}})
       when is_binary(id) and id != "",
       do: id

  defp runtime_node_label(%{status: :ok}), do: "Not recorded"
  defp runtime_node_label(%{status: :loading}), do: "Loading"
  defp runtime_node_label(_), do: "Runtime unavailable"

  defp primary_loaded_model(%{status: :ok, loaded_models: [first | _]}),
    do: format_loaded_model(first)

  defp primary_loaded_model(%{status: :ok, loaded_models: []}),
    do: "No model loaded"

  defp primary_loaded_model(%{status: :loading}), do: "Loading"
  defp primary_loaded_model(_), do: "Runtime unavailable"

  defp format_loaded_model(%{model_id: id, version: vsn})
       when is_binary(id) and id != "" and is_binary(vsn) and vsn != "",
       do: "#{id}@#{vsn}"

  defp format_loaded_model(%{model_id: id}) when is_binary(id) and id != "", do: id
  defp format_loaded_model(%{version: vsn}) when is_binary(vsn) and vsn != "", do: vsn
  defp format_loaded_model(_), do: "Unknown model"

  defp hero_status_copy(%{status: :loading}, _),
    do: "Connecting to live controller and runtime status."

  defp hero_status_copy(_, %{status: :loading}),
    do: "Connecting to live controller and runtime status."

  defp hero_status_copy(readiness, runtime) do
    controller_status_copy(readiness) <> " " <> runtime_status_copy(runtime)
  end

  defp controller_status_copy(%{status: :ok}), do: "Controller checks are passing."

  defp controller_status_copy(%{status: :error}),
    do: "Controller readiness checks are failing."

  defp controller_status_copy(_), do: "Controller readiness is unavailable."

  defp runtime_status_copy(%{status: :ok} = runtime) do
    case runtime_health_level(runtime) do
      :unhealthy ->
        "The default Runtime Endpoint reports unhealthy status."

      :degraded ->
        "The default Runtime Endpoint reports degraded health."

      _ ->
        "The default Runtime Endpoint is reachable. " <> runtime_worker_copy(runtime)
    end
  end

  defp runtime_status_copy(_), do: "The default Runtime Endpoint is unavailable."

  defp runtime_worker_copy(%{worker_state: state})
       when state in [:starting, :stopping],
       do: "Worker is transitioning."

  defp runtime_worker_copy(%{loaded_models: []}), do: "No model is currently loaded."

  defp runtime_worker_copy(runtime), do: "Worker state: #{worker_state_badge_label(runtime)}."

  # -- Hero copy CSS class --
  # Precedence mirrors hero_status_copy: loading → health → worker-state.

  defp hero_status_copy_class(%{status: :loading}, _),
    do: "text-slate-500 dark:text-slate-400"

  defp hero_status_copy_class(_, %{status: :loading}),
    do: "text-slate-500 dark:text-slate-400"

  defp hero_status_copy_class(%{status: :ok}, %{status: :ok} = rt) do
    case runtime_health_level(rt) do
      :unhealthy -> "text-red-600 dark:text-red-400"
      :degraded -> "text-amber-700 dark:text-amber-300"
      _ -> hero_worker_state_class(rt)
    end
  end

  defp hero_status_copy_class(_readiness, %{status: :ok} = rt) do
    case runtime_health_level(rt) do
      :unhealthy -> "text-red-600 dark:text-red-400"
      :degraded -> "text-amber-700 dark:text-amber-300"
      _ -> "text-amber-700 dark:text-amber-300"
    end
  end

  defp hero_status_copy_class(_, _),
    do: "text-red-600 dark:text-red-400"

  defp hero_worker_state_class(%{worker_state: state, loaded_models: models})
       when state in [:idle, :busy] and models != [],
       do: "text-slate-600 dark:text-slate-400"

  defp hero_worker_state_class(%{worker_state: state})
       when state in [:starting, :stopping],
       do: "text-amber-700 dark:text-amber-300"

  defp hero_worker_state_class(%{loaded_models: []}),
    do: "text-amber-700 dark:text-amber-300"

  defp hero_worker_state_class(_),
    do: "text-red-600 dark:text-red-400"

  # ===========================================================================
  # Format helpers
  # ===========================================================================

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when ms < 1000, do: "#{round(ms)} ms"

  defp format_duration(ms) do
    seconds = ms / 1000
    :erlang.float_to_binary(seconds, decimals: 1) <> " s"
  end

  defp format_rate(nil), do: "—"

  defp format_rate(rate) do
    :erlang.float_to_binary(rate / 1.0, decimals: 1)
  end

  defp format_count(nil), do: "—"
  defp format_count(count) when is_integer(count), do: Integer.to_string(count)
  defp format_count(other) when is_binary(other), do: other

  defp refresh_interval_label do
    ms = refresh_interval_ms()

    if rem(ms, 1000) == 0,
      do: "#{div(ms, 1000)}s",
      else: "#{ms}ms"
  end

  # ===========================================================================
  # Refresh / config
  # ===========================================================================

  defp schedule_refresh(socket) do
    ref = Process.send_after(self(), :refresh_overview, refresh_interval_ms())
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

  defp runtime_impl do
    console_config()[:runtime_impl] || OrchardConsole.Runtime
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end
end
