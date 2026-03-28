defmodule OrchardConsole.OverviewLive do
  @moduledoc """
  Console overview page — readiness, runtime snapshot, request counts,
  and model catalog with periodic refresh.
  """

  use OrchardConsole, :live_view

  alias Orchard.API.Readiness
  alias Orchard.Governance
  alias Orchard.Models
  alias Orchard.Models.Model
  alias Orchard.Requests
  alias Orchard.Requests.Request

  @readiness_check_order [
    :controller_boot_completed,
    :postgres_reachable,
    :migrations_current,
    :public_api_https_enabled
  ]

  @default_refresh_interval_ms 5_000

  @quickstart_step_definitions [
    %{id: :system_healthy, dom_id: "system-healthy", ordinal: 1, title: "System is healthy"},
    %{
      id: :import_first_model,
      dom_id: "import-first-model",
      ordinal: 2,
      title: "Import your first model"
    },
    %{id: :run_test_request, dom_id: "run-test-request", ordinal: 3, title: "Run a test request"},
    %{id: :create_api_key, dom_id: "create-api-key", ordinal: 4, title: "Create an API key"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Overview", active_nav: :overview)
      |> assign(build_version: build_version())

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
       dismissed?: dismissed_param?(Map.get(params, "dismissed"))
     })}
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
    <div class="space-y-6">
      <div id="overview-quickstart" phx-hook="OverviewQuickstart">
        <%= if @quickstart.dismissed? do %>
          <.card>
            <:title>Quickstart hidden</:title>
            <:subtitle>You can restore the onboarding checklist at any time.</:subtitle>

            <div id="overview-quickstart-dismissed" class="flex items-center justify-between gap-3">
              <p class="text-sm text-slate-600 dark:text-slate-300">
                Quickstart is dismissed for this browser until you restore it.
              </p>

              <button
                id="overview-quickstart-recover"
                type="button"
                data-quickstart-action="recover"
                class="inline-flex items-center gap-1 rounded-md border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-800"
              >
                Show quickstart
              </button>
            </div>
          </.card>
        <% else %>
          <.card>
            <:title>Quickstart</:title>
            <:subtitle>Track the first server-derived onboarding steps directly from live system state.</:subtitle>

            <div id="overview-quickstart-full" class="space-y-4">
              <div class="flex justify-end">
                <button
                  id="overview-quickstart-dismiss"
                  type="button"
                  data-quickstart-action="dismiss"
                  class="inline-flex items-center gap-1 rounded-md border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-800"
                >
                  Dismiss
                </button>
              </div>

              <ol class="space-y-3" id="overview-quickstart-steps">
                <li
                  :for={step <- @quickstart.steps}
                  id={"overview-quickstart-step-#{step.dom_id}"}
                  data-status={Atom.to_string(step.status)}
                  class="flex items-center justify-between gap-3 rounded-lg border border-slate-200 px-4 py-3 dark:border-slate-700"
                >
                  <div class="flex items-center gap-3">
                    <span class="inline-flex h-7 w-7 items-center justify-center rounded-full bg-slate-100 text-xs font-semibold text-slate-700 dark:bg-slate-800 dark:text-slate-200">
                      {step.ordinal}
                    </span>
                    <span class="text-sm font-medium text-slate-900 dark:text-slate-100">{step.title}</span>
                  </div>

                  <.badge tone={quickstart_status_badge_tone(step.status)}>
                    {quickstart_status_badge_label(step.status)}
                  </.badge>
                </li>
              </ol>
            </div>
          </.card>
        <% end %>
      </div>

      <%!-- System Status (hero card) --%>
      <.card>
        <:title>System Status</:title>
        <:subtitle>Sovereign LLM inference on Apple Silicon.</:subtitle>

        <div class="space-y-4">
          <div class="flex flex-wrap items-center gap-2">
            <.badge tone={readiness_badge_tone(@readiness.status)}>
              {readiness_badge_label(@readiness.status)}
            </.badge>
            <.badge tone={runtime_badge_tone(@runtime)}>
              {runtime_badge_label(@runtime)}
            </.badge>
            <span class="text-xs font-mono text-slate-400 dark:text-slate-500">
              {@build_version}
            </span>
          </div>

          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
            <.metric_tile label="Checks passing" value={readiness_metric(@readiness)} />
            <.metric_tile label="Loaded models" value={format_count(runtime_loaded_count(@runtime))} />
            <.metric_tile label="Catalog models" value={format_count(@model_catalog.total)} />
            <.metric_tile label="Total requests" value={format_count(@request_summary.total)} />
          </div>

          <p id="overview-hero-status-copy" class={["text-sm", hero_status_copy_class(@readiness, @runtime)]}>
            {hero_status_copy(@readiness, @runtime)}
          </p>

          <div class="flex flex-wrap items-center gap-3 border-t border-slate-100 pt-3 dark:border-slate-700/50">
            <div class="flex flex-wrap items-center gap-4">
              <div id="overview-primary-model" class="flex items-center gap-2">
                <span class="text-xs text-slate-500 dark:text-slate-400">Loaded model:</span>
                <span class="text-sm font-mono text-slate-900 dark:text-slate-100">
                  {primary_loaded_model(@runtime)}
                </span>
              </div>
              <div id="overview-runtime-node" class="flex items-center gap-2">
                <span class="text-xs text-slate-500 dark:text-slate-400">Connected node:</span>
                <span class="text-sm font-mono text-slate-900 dark:text-slate-100">
                  {runtime_node_label(@runtime)}
                </span>
              </div>
            </div>
            <div class="ml-auto flex items-center gap-2">
              <.link
                id="overview-open-playground"
                navigate={~p"/console/playground"}
                class="inline-flex items-center gap-1 rounded-md bg-gold/10 px-3 py-1.5 text-xs font-medium text-gold-700 ring-1 ring-gold/30 hover:bg-gold/20 dark:text-gold-300 dark:ring-gold/40 dark:hover:bg-gold/30"
              >
                Open Playground
              </.link>
              <.link
                id="overview-open-nodes"
                navigate={~p"/console/nodes"}
                class="inline-flex items-center gap-1 rounded-md border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-800"
              >
                Open Nodes
              </.link>
              <.link
                id="overview-open-models"
                navigate={~p"/console/models"}
                class="inline-flex items-center gap-1 rounded-md border border-slate-300 px-3 py-1.5 text-xs font-medium text-slate-700 hover:bg-slate-50 dark:border-slate-600 dark:text-slate-300 dark:hover:bg-slate-800"
              >
                Open Models
              </.link>
            </div>
          </div>

          <div id="overview-freshness" class="flex flex-wrap items-center gap-3 text-xs text-slate-500 dark:text-slate-400">
            <span class="font-mono">
              {freshness_text(@last_updated_at)}
            </span>
            <span>· Auto-refreshing every {refresh_interval_label()}</span>
            <.button
              id="overview-refresh-now"
              variant={:ghost}
              size={:sm}
              phx-click="refresh_now"
            >
              Refresh now
            </.button>
          </div>
        </div>
      </.card>

      <div class="grid gap-6 lg:grid-cols-2">
        <%!-- Readiness --%>
        <.card>
          <:title>Readiness</:title>
          <:subtitle>Matches the <code class="text-xs font-mono">/health/ready</code> checks.</:subtitle>

          <.table id="overview-readiness" rows={@readiness.rows}>
            <:col :let={row} label="Check">
              <span class="font-mono text-xs">{row.key}</span>
            </:col>
            <:col :let={row} label="Status" class="text-right" header_class="text-right">
              <div class="flex justify-end">
                <.badge tone={check_badge_tone(row.status)}>
                  {check_badge_label(row.status)}
                </.badge>
              </div>
            </:col>
          </.table>
        </.card>

        <%!-- Runtime Snapshot --%>
        <.card>
          <:title>Runtime Snapshot</:title>
          <:subtitle>Node worker status and loaded model set.</:subtitle>

          <div class="mb-4 flex flex-wrap items-center gap-2">
            <.badge tone={runtime_badge_tone(@runtime)}>
              {runtime_badge_label(@runtime)}
            </.badge>
            <span :if={@runtime.status == :ok} class="text-xs font-mono text-slate-400 dark:text-slate-500">
              {@runtime.active_request_count} active request(s)
            </span>
          </div>

          <%= cond do %>
            <% @runtime.status == :loading -> %>
              <.state_message id="overview-runtime-loading" kind={:loading} layout={:compact} title="Loading runtime snapshot." />
            <% @runtime.status == :ok -> %>
              <.table id="overview-runtime-models" rows={@runtime.loaded_models}>
                <:col :let={m} label="Model" mono>{m.model_id}</:col>
                <:col :let={m} label="Version" mono>{m.version}</:col>
                <:empty>
                  <.state_message id="overview-runtime-empty" kind={:empty} layout={:compact} title="No loaded models." />
                </:empty>
              </.table>
            <% true -> %>
              <.state_message id="overview-runtime-unavailable" kind={:error} layout={:compact} title="Runtime unavailable." body={@runtime.message} />
          <% end %>
        </.card>

        <%!-- Model Catalog --%>
        <.card>
          <:title>Model Catalog</:title>
          <:subtitle>Catalog totals by lifecycle state.</:subtitle>

          <%= cond do %>
            <% @model_catalog.status == :loading -> %>
              <.state_message id="overview-model-catalog-loading" kind={:loading} layout={:compact} title="Loading model catalog." />
            <% @model_catalog.status == :ok -> %>
              <.table id="overview-model-counts" rows={@model_catalog.rows}>
                <:col :let={row} label="State" mono>{row.state}</:col>
                <:col :let={row} label="Count" mono class="text-right" header_class="text-right">
                  {row.count}
                </:col>
              </.table>
            <% true -> %>
              <.state_message id="overview-model-catalog-error" kind={:error} layout={:compact} title={@model_catalog.message || "Model catalog data unavailable."} />
          <% end %>
        </.card>

        <%!-- Request Counts --%>
        <.card>
          <:title>Request Counts</:title>
          <:subtitle>Durable request rows by lifecycle state.</:subtitle>

          <%= cond do %>
            <% @request_summary.status == :loading -> %>
              <.state_message id="overview-request-summary-loading" kind={:loading} layout={:compact} title="Loading request summary." />
            <% @request_summary.status == :ok -> %>
              <div class="mb-4 flex flex-wrap items-center gap-3">
                <.badge tone={:info}>{@request_summary.active} active</.badge>
                <.badge tone={:neutral}>{@request_summary.terminal} terminal</.badge>
              </div>
              <.table id="overview-request-counts" rows={@request_summary.rows}>
                <:col :let={row} label="State" mono>{row.state}</:col>
                <:col :let={row} label="Count" mono class="text-right" header_class="text-right">
                  {row.count}
                </:col>
              </.table>
            <% true -> %>
              <.state_message id="overview-request-summary-error" kind={:error} layout={:compact} title={@request_summary.message || "Request summary unavailable."} />
          <% end %>
        </.card>
      </div>
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
    has_active_api_keys = fetch_active_api_keys()
    client_state = quickstart_client_state(socket)

    assign(socket,
      readiness: readiness,
      runtime: runtime,
      model_catalog: model_catalog,
      request_summary: request_summary,
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
    loading_rows = Enum.map(@readiness_check_order, &%{key: &1, status: :unknown})

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

    assign(socket,
      readiness: readiness,
      runtime: runtime,
      model_catalog: model_catalog,
      request_summary: request_summary,
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
    case Readiness.status() do
      {:ok, checks} ->
        rows = build_readiness_rows(checks)

        %{
          status: :ok,
          passing: Enum.count(rows, &(&1.status == :ok)),
          total: length(rows),
          rows: rows,
          message: nil
        }

      {:error, _reason, checks} ->
        rows = build_readiness_rows(checks)

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
      rows = Enum.map(@readiness_check_order, &%{key: &1, status: :unknown})

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
            has_active_api_keys
          )
        )
      end)
      |> assign_quickstart_step_statuses()

    Map.merge(client_state, %{steps: steps})
  end

  defp default_quickstart_client_state do
    %{dismissed?: false}
  end

  defp quickstart_client_state(socket) do
    socket.assigns
    |> Map.get(:quickstart, default_quickstart_client_state())
    |> Map.take([:dismissed?])
    |> then(&Map.merge(default_quickstart_client_state(), &1))
  end

  defp update_quickstart_client_state(socket, attrs) do
    client_state =
      socket
      |> quickstart_client_state()
      |> Map.merge(attrs)

    assign(socket, :quickstart, Map.merge(socket.assigns.quickstart, client_state))
  end

  defp dismissed_param?(true), do: true
  defp dismissed_param?("1"), do: true
  defp dismissed_param?(value) when is_binary(value), do: String.downcase(value) == "true"
  defp dismissed_param?(_), do: false

  defp quickstart_step_complete?(:system_healthy, readiness, _model_catalog, _request_summary, _),
    do: readiness.status == :ok

  defp quickstart_step_complete?(
         :import_first_model,
         _readiness,
         model_catalog,
         _request_summary,
         _
       ) do
    model_catalog.status == :ok and Map.get(model_catalog.by_state, :active, 0) > 0
  end

  defp quickstart_step_complete?(
         :run_test_request,
         _readiness,
         _model_catalog,
         request_summary,
         _
       ) do
    request_summary.status == :ok and Map.get(request_summary.by_state, :completed, 0) > 0
  end

  defp quickstart_step_complete?(
         :create_api_key,
         _readiness,
         _model_catalog,
         _request_summary,
         has_active_api_keys
       ),
       do: has_active_api_keys

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

    steps
  end

  defp zero_model_state_counts do
    Map.new(Model.states(), &{&1, 0})
  end

  defp zero_request_state_counts do
    Map.new(Request.states(), &{&1, 0})
  end

  # ===========================================================================
  # Readiness helpers
  # ===========================================================================

  defp build_readiness_rows(checks) do
    Enum.map(@readiness_check_order, fn key ->
      %{key: key, status: if(Map.get(checks, key, false), do: :ok, else: :error)}
    end)
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

  defp readiness_metric(%{passing: nil}), do: "\u2014"
  defp readiness_metric(%{passing: p, total: t}), do: "#{p}/#{t}"

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
  defp runtime_health_level(_), do: :unsupported

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

  defp quickstart_status_badge_tone(:completed), do: :success
  defp quickstart_status_badge_tone(:current), do: :info
  defp quickstart_status_badge_tone(:pending), do: :neutral

  defp quickstart_status_badge_label(:completed), do: "Complete"
  defp quickstart_status_badge_label(:current), do: "Current"
  defp quickstart_status_badge_label(:pending), do: "Pending"

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

  defp runtime_node_label(%{status: :ok}), do: "Metadata unavailable"
  defp runtime_node_label(_), do: "Runtime unavailable"

  defp primary_loaded_model(%{status: :ok, loaded_models: [first | _]}),
    do: format_loaded_model(first)

  defp primary_loaded_model(%{status: :ok, loaded_models: []}),
    do: "No model loaded"

  defp primary_loaded_model(_), do: "Runtime unavailable"

  defp format_loaded_model(%{model_id: id, version: vsn})
       when is_binary(id) and id != "" and is_binary(vsn) and vsn != "",
       do: "#{id}@#{vsn}"

  defp format_loaded_model(%{model_id: id}) when is_binary(id) and id != "", do: id
  defp format_loaded_model(%{version: vsn}) when is_binary(vsn) and vsn != "", do: vsn
  defp format_loaded_model(_), do: "Unknown model"

  # Deterministic status copy derived from combined readiness + runtime state.
  # Evaluated on every render — not stored in assigns.
  #
  # Precedence: loading → health-aware (when runtime_health present) → worker-state.
  defp hero_status_copy(%{status: :loading}, _),
    do: "Connecting to live controller and runtime status."

  defp hero_status_copy(_, %{status: :loading}),
    do: "Connecting to live controller and runtime status."

  # Both readiness and runtime ok — check health first, then worker-state
  defp hero_status_copy(%{status: :ok} = readiness, %{status: :ok} = runtime) do
    hero_health_copy(readiness, runtime) || hero_worker_state_copy(readiness, runtime)
  end

  # Readiness failing, runtime ok — check health first, then readiness-degraded copy
  defp hero_status_copy(readiness, %{status: :ok} = runtime) do
    hero_readiness_health_copy(readiness, runtime) ||
      hero_readiness_degraded_copy(readiness, runtime)
  end

  defp hero_status_copy(_, _),
    do: "System is degraded: controller readiness is failing and the node runtime is unavailable."

  # -- Health-aware hero copy (returns nil when health is healthy/unsupported) --

  defp hero_health_copy(_readiness, runtime) do
    case runtime_health_level(runtime) do
      :unhealthy ->
        "Controller checks are passing, but the node runtime reports unhealthy status and may reject requests."

      :degraded ->
        "Controller checks are passing. The node runtime reports degraded health."

      _ ->
        nil
    end
  end

  defp hero_readiness_health_copy(_readiness, runtime) do
    case runtime_health_level(runtime) do
      :unhealthy ->
        "System is degraded: controller readiness is failing and the node runtime reports unhealthy status."

      :degraded ->
        "Controller readiness checks are failing. The node runtime reports degraded health."

      _ ->
        nil
    end
  end

  # -- Worker-state hero copy (existing logic, extracted) --

  defp hero_worker_state_copy(_readiness, %{worker_state: :idle, loaded_models: [_ | _]}),
    do: "System ready. Runtime is idle and a model is loaded for operator testing."

  defp hero_worker_state_copy(_readiness, %{worker_state: :busy, loaded_models: [_ | _]}),
    do: "System ready. Runtime is serving active requests."

  defp hero_worker_state_copy(_readiness, %{loaded_models: []}),
    do: "System ready, but no model is currently loaded in the runtime."

  defp hero_worker_state_copy(_readiness, %{worker_state: state})
       when state in [:starting, :stopping],
       do:
         "Controller checks are passing. Runtime is transitioning and may not accept requests yet."

  defp hero_worker_state_copy(_, _),
    do: "Controller checks are passing, but the node runtime is unavailable for inference."

  # -- Readiness-degraded hero copy (existing logic, extracted) --

  defp hero_readiness_degraded_copy(_readiness, %{worker_state: state})
       when state in [:idle, :busy],
       do: "Runtime is reachable, but one or more controller readiness checks are failing."

  defp hero_readiness_degraded_copy(_readiness, %{worker_state: state})
       when state in [:starting, :stopping],
       do: "Controller readiness checks are failing. Runtime is transitioning."

  defp hero_readiness_degraded_copy(_, _),
    do: "System is degraded: controller readiness is failing and the node runtime is unavailable."

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

  defp format_count(nil), do: "\u2014"
  defp format_count(count) when is_integer(count), do: Integer.to_string(count)
  defp format_count(other) when is_binary(other), do: other

  defp freshness_text(nil), do: "Waiting for first live update"

  defp freshness_text(%DateTime{} = dt) do
    "Last updated #{Calendar.strftime(dt, "%H:%M:%S")} UTC"
  end

  defp refresh_interval_label do
    ms = refresh_interval_ms()

    if rem(ms, 1000) == 0,
      do: "#{div(ms, 1000)}s",
      else: "#{ms}ms"
  end

  defp build_version do
    case Application.spec(:orchard_controller, :vsn) do
      nil -> "dev"
      vsn -> "v#{vsn}"
    end
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

  # ===========================================================================
  # Local function component
  # ===========================================================================

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp metric_tile(assigns) do
    ~H"""
    <div class="rounded-lg bg-slate-50 px-4 py-3 dark:bg-slate-900/60">
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {@label}
      </p>
      <p class="mt-1 text-2xl font-mono text-slate-900 dark:text-slate-100">
        {@value}
      </p>
    </div>
    """
  end
end
