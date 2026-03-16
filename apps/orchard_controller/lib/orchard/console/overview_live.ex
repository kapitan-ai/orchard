defmodule OrchardConsole.OverviewLive do
  @moduledoc """
  Console overview page — readiness, runtime snapshot, request counts,
  and model catalog with periodic refresh.
  """

  use OrchardConsole, :live_view

  alias Orchard.API.Readiness
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
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
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

          <p :if={@runtime.message} class="mb-3 text-sm text-amber-700 dark:text-amber-300">
            {@runtime.message}
          </p>

          <.table id="overview-runtime-models" rows={@runtime.loaded_models}>
            <:col :let={m} label="Model" mono>{m.model_id}</:col>
            <:col :let={m} label="Version" mono>{m.version}</:col>
            <:empty>
              {runtime_empty_text(@runtime.status)}
            </:empty>
          </.table>
        </.card>

        <%!-- Model Catalog --%>
        <.card>
          <:title>Model Catalog</:title>
          <:subtitle>Catalog totals by lifecycle state.</:subtitle>

          <p :if={@model_catalog.message} class="mb-3 text-sm text-amber-700 dark:text-amber-300">
            {@model_catalog.message}
          </p>

          <.table :if={@model_catalog.status == :ok} id="overview-model-counts" rows={@model_catalog.rows}>
            <:col :let={row} label="State" mono>{row.state}</:col>
            <:col :let={row} label="Count" mono class="text-right" header_class="text-right">
              {row.count}
            </:col>
          </.table>
        </.card>

        <%!-- Request Counts --%>
        <.card>
          <:title>Request Counts</:title>
          <:subtitle>Durable request rows by lifecycle state.</:subtitle>

          <div :if={@request_summary.status == :ok} class="mb-4 flex flex-wrap items-center gap-3">
            <.badge tone={:info}>{@request_summary.active} active</.badge>
            <.badge tone={:neutral}>{@request_summary.terminal} terminal</.badge>
          </div>

          <p :if={@request_summary.message} class="mb-3 text-sm text-amber-700 dark:text-amber-300">
            {@request_summary.message}
          </p>

          <.table :if={@request_summary.status == :ok} id="overview-request-counts" rows={@request_summary.rows}>
            <:col :let={row} label="State" mono>{row.state}</:col>
            <:col :let={row} label="Count" mono class="text-right" header_class="text-right">
              {row.count}
            </:col>
          </.table>
        </.card>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # Data loading
  # ===========================================================================

  defp load_overview(socket) do
    assign(socket,
      readiness: fetch_readiness(),
      runtime: fetch_runtime(),
      model_catalog: fetch_model_catalog(),
      request_summary: fetch_request_summary(),
      last_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  defp assign_loading_state(socket) do
    loading_rows = Enum.map(@readiness_check_order, &%{key: &1, status: :unknown})

    assign(socket,
      readiness: %{
        status: :loading,
        passing: nil,
        total: length(@readiness_check_order),
        rows: loading_rows,
        message: nil
      },
      runtime: %{
        status: :loading,
        worker_state: :unknown,
        loaded_models: [],
        active_request_count: 0,
        message: nil
      },
      model_catalog: %{
        status: :loading,
        total: nil,
        rows: [],
        message: nil
      },
      request_summary: %{
        status: :loading,
        total: nil,
        active: nil,
        terminal: nil,
        rows: [],
        message: nil
      },
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
        Map.merge(snapshot, %{status: :ok, message: nil})

      {:error, error} ->
        %{
          status: error.status,
          worker_state: :unknown,
          loaded_models: [],
          active_request_count: 0,
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
        message: "Runtime snapshot unavailable."
      }
  end

  defp fetch_model_catalog do
    summary = Models.catalog_summary()

    rows =
      Enum.map(Model.states(), fn state -> %{state: state, count: summary.by_state[state]} end)

    %{status: :ok, total: summary.total, rows: rows, message: nil}
  rescue
    _ ->
      %{status: :error, total: nil, rows: [], message: "Model catalog data unavailable."}
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
        rows: [],
        message: "Request summary unavailable."
      }
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

  defp runtime_badge_tone(%{status: :loading}), do: :neutral
  defp runtime_badge_tone(%{status: status}) when status != :ok, do: :error
  defp runtime_badge_tone(%{worker_state: :idle}), do: :success
  defp runtime_badge_tone(%{worker_state: :busy}), do: :processing

  defp runtime_badge_tone(%{worker_state: state}) when state in [:starting, :stopping],
    do: :warning

  defp runtime_badge_tone(%{worker_state: :failed}), do: :error
  defp runtime_badge_tone(%{worker_state: :stopped}), do: :warning
  defp runtime_badge_tone(_), do: :neutral

  defp runtime_badge_label(%{status: :loading}), do: "Loading"
  defp runtime_badge_label(%{status: status}) when status != :ok, do: "Unavailable"
  defp runtime_badge_label(%{worker_state: :idle}), do: "Idle"
  defp runtime_badge_label(%{worker_state: :busy}), do: "Busy"
  defp runtime_badge_label(%{worker_state: :starting}), do: "Starting"
  defp runtime_badge_label(%{worker_state: :stopping}), do: "Stopping"
  defp runtime_badge_label(%{worker_state: :failed}), do: "Failed"
  defp runtime_badge_label(%{worker_state: :stopped}), do: "Stopped"
  defp runtime_badge_label(_), do: "Unknown"

  defp check_badge_tone(:ok), do: :success
  defp check_badge_tone(:error), do: :warning
  defp check_badge_tone(_), do: :neutral

  defp check_badge_label(:ok), do: "OK"
  defp check_badge_label(:error), do: "Blocked"
  defp check_badge_label(_), do: "Unknown"

  defp runtime_loaded_count(%{status: :ok, loaded_models: models}), do: length(models)
  defp runtime_loaded_count(_), do: nil

  defp runtime_empty_text(:ok), do: "No loaded models."
  defp runtime_empty_text(:loading), do: "Loading runtime snapshot."
  defp runtime_empty_text(_), do: "Runtime unavailable."

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
