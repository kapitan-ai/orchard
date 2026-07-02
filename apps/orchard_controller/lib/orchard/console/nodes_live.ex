defmodule OrchardConsole.NodesLive do
  @moduledoc """
  Console nodes page — persistent node inventory with live runtime diagnostics.

  Combines persisted inventory from `Orchard.Nodes` with live runtime
  status from `OrchardConsole.Runtime`, polling on a configurable interval.
  Runtime failure does not suppress persisted inventory rendering.
  """

  use OrchardConsole, :live_view

  require Logger

  alias Orchard.Nodes
  alias Orchard.Nodes.AdmissionCandidate
  alias Orchard.RuntimeEndpoint.Target
  alias OrchardConsole.NodesPageData

  @default_refresh_interval_ms 5_000
  @safe_tokenization_counter_keys [
    :control_token_in_user_content,
    :detector_error,
    :prompt_token_ids_dispatched,
    :unsafe_mode_active,
    :parity_drift,
    :catalog_drift,
    :degraded_no_manifest_catalog
  ]

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Nodes", active_nav: :nodes, page_mode: :workspace)

    if connected?(socket) do
      {:ok, socket |> load_nodes_page() |> schedule_refresh()}
    else
      {:ok, assign_loading_state(socket)}
    end
  end

  @impl true
  def handle_info(:refresh_nodes, socket) do
    {:noreply, socket |> load_nodes_page() |> schedule_refresh()}
  end

  @impl true
  def handle_event("refresh_now", _params, socket) do
    {:noreply, socket |> cancel_refresh() |> load_nodes_page() |> schedule_refresh()}
  end

  # ===========================================================================
  # Render
  # ===========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Inventory Summary --%>
      <div id="nodes-summary-card">
      <.card>
        <:title>Inventory Summary</:title>
        <:subtitle>Persisted node inventory with periodic runtime refresh.</:subtitle>

        <div id="nodes-summary" class="grid gap-3 sm:grid-cols-3 xl:grid-cols-5">
          <.summary_tile id="nodes-summary-total" label="Total" value={format_count(@inventory.summary.total)} tone={:neutral} />
          <.summary_tile id="nodes-summary-healthy" label="Healthy" value={format_count(@inventory.summary.by_health[:healthy])} tone={:success} />
          <.summary_tile id="nodes-summary-degraded" label="Degraded" value={format_count(@inventory.summary.by_health[:degraded])} tone={:warning} />
          <.summary_tile id="nodes-summary-unhealthy" label="Unhealthy" value={format_count(@inventory.summary.by_health[:unhealthy])} tone={:error} />
          <.summary_tile id="nodes-summary-unreachable" label="Unreachable" value={format_count(@inventory.summary.by_health[:unreachable])} tone={:error} />
        </div>

        <div id="nodes-freshness" class="mt-4 flex flex-wrap items-center gap-3 text-xs text-slate-500 dark:text-slate-400">
          <span :if={@last_refreshed_at == nil} class="font-mono">Waiting for first live update</span>
          <span :if={@last_refreshed_at != nil} class="font-mono">
            Last refreshed <.local_time value={@last_refreshed_at} format={:time_second} />
          </span>
          <span :if={@last_refreshed_at != nil}>· Auto-refreshing every {refresh_interval_label()}</span>
          <.button
            id="nodes-refresh-now"
            variant={:ghost}
            size={:sm}
            phx-click="refresh_now"
          >
            Refresh now
          </.button>
        </div>
      </.card>
      </div>

      <%!-- Admission Review Queue --%>
      <div id="nodes-pending-admissions-card">
      <.card>
        <:title>Admission Review</:title>
        <:subtitle>{pending_admissions_subtitle(@pending_admissions)}</:subtitle>

        <%= cond do %>
          <% @pending_admissions.status == :loading -> %>
            <.state_message id="nodes-pending-loading" kind={:loading} layout={:compact} title="Loading pending admissions." />
          <% @pending_admissions.status == :ok and @pending_admissions.rows == [] -> %>
            <.state_message
              id="nodes-pending-empty-state"
              kind={:empty}
              layout={:compact}
              title="No admission review items."
              body="New pending candidates and registered nodes will appear here; rejected records remain visible for audit after decisions."
            />
          <% @pending_admissions.status == :ok -> %>
            <.table
              id="nodes-pending-table"
              rows={@pending_admissions.rows}
              row_id={fn row -> "pending-admission-#{row.kind}-#{row.id}" end}
            >
              <:col :let={row} label="Identity" class="min-w-44">
                <span class="font-medium text-slate-900 dark:text-slate-100">{row.display_label}</span>
                <span
                  :if={row.node_id && row.kind == :candidate}
                  class="mt-1 block text-xs font-mono text-slate-500 dark:text-slate-400"
                >
                  linked node {row.node_id}
                </span>
              </:col>
              <:col :let={row} label="Source" class="min-w-28" header_class="whitespace-nowrap">
                <.badge tone={pending_source_tone(row.source)}>
                  {pending_source_label(row.source)}
                </.badge>
              </:col>
              <:col :let={row} label="Admission" class="min-w-32" header_class="whitespace-nowrap">
                <.badge tone={admission_category_tone(row.admission_category)}>
                  {format_status_value(row.admission_category)}
                </.badge>
              </:col>
              <:col :let={row} label="Compatibility" class="min-w-32" header_class="whitespace-nowrap">
                <.badge tone={compatibility_tone(status_value(row.status, :compatibility, :status))}>
                  {format_status_value(status_value(row.status, :compatibility, :status))}
                </.badge>
              </:col>
              <:col :let={row} label="Target" mono class="min-w-40 max-w-[16rem] break-all" header_class="whitespace-nowrap">
                {format_pending_target(row)}
              </:col>
              <:col :let={row} label="Last Observed" mono class="min-w-40" header_class="whitespace-nowrap">
                <.local_time
                  :if={row.observed_at}
                  value={row.observed_at}
                  format={:datetime_second}
                />
                <span :if={!row.observed_at}>Never observed</span>
              </:col>
              <:action :let={row}>
                <.link
                  navigate={pending_detail_path(row)}
                  class="inline-flex items-center rounded-md px-3 py-1.5 text-sm font-medium text-navy hover:bg-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:text-sky-300 dark:hover:bg-slate-800 dark:focus-visible:ring-sky-400"
                >
                  Review
                </.link>
              </:action>
            </.table>
          <% true -> %>
            <.state_message id="nodes-pending-error" kind={:error} layout={:compact} title="Pending admissions unavailable." body={@pending_admissions.message} />
          <% end %>
      </.card>
      </div>

      <%!-- Main Grid --%>
      <div class="grid gap-6 xl:grid-cols-12">
        <div class="xl:col-span-8">
          <div class="space-y-6">
          <%!-- Persisted Inventory Table --%>
          <div id="nodes-inventory-card">
          <.card>
            <:title>Registered Nodes</:title>

            <%= cond do %>
              <% @inventory.status == :loading -> %>
                <.state_message id="nodes-inventory-loading" kind={:loading} layout={:compact} title="Loading node inventory." />
              <% @inventory.status == :ok and @inventory.rows == [] -> %>
                <.state_message
                  id="nodes-empty-state"
                  kind={:empty}
                  layout={:panel}
                  title="No nodes registered yet."
                  body="A compatible node-agent will appear here after a successful status read."
                />
              <% @inventory.status == :ok -> %>
                <.table id="nodes-table" rows={@inventory.rows} row_id={fn node -> "node-#{node.id}" end}>
                  <:col :let={node} label="Display Name">
                    <.link
                      navigate={~p"/console/nodes/#{node.id}"}
                      class="font-medium text-slate-900 hover:text-navy focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:text-slate-100 dark:hover:text-sky-300 dark:focus-visible:ring-sky-400"
                    >
                      {node.display_name}
                    </.link>
                  </:col>
                  <:col :let={node} label="Hostname" mono>{node.hostname}</:col>
                  <:col :let={node} label="Address" mono>{format_address(node)}</:col>
                  <:col :let={node} label="State">
                    <.badge tone={state_badge_tone(node.state)}>{node.state}</.badge>
                  </:col>
                  <:col :let={node} label="Health">
                    <.badge tone={health_badge_tone(node.health)}>{node.health}</.badge>
                  </:col>
                  <:col :let={node} label="Agent Version" mono>{node.agent_version || "—"}</:col>
                  <:col :let={node} label="Last Seen" mono><.local_time value={node.last_heartbeat_at} format={:datetime_second} /></:col>
                </.table>
              <% true -> %>
                <.state_message id="nodes-inventory-error" kind={:error} layout={:compact} title="Node inventory unavailable." body={@inventory.message} />
              <% end %>
          </.card>
          </div>
          </div>
        </div>

        <%!-- Live Cluster Column --%>
        <div class="xl:col-span-4 space-y-6">
          <%!-- Cluster Summary Card --%>
          <div id="nodes-live-cluster-card">
          <.card variant={:rail} padding={:sm}>
            <:title>Live Cluster</:title>
            <:subtitle><%= cluster_subtitle(@cluster) %></:subtitle>

            <%= cond do %>
              <% @cluster.status == :loading -> %>
                <.state_message id="nodes-cluster-loading" kind={:loading} layout={:compact} title="Loading cluster status." />
              <% @cluster.status == :error -> %>
                <.state_message id="nodes-cluster-error" kind={:error} layout={:compact} title="Cluster status unavailable." body={@cluster.message} />
              <% @cluster.targets == [] -> %>
                <.state_message id="nodes-cluster-empty" kind={:empty} layout={:compact} title="No runtime targets configured." />
              <% true -> %>
                <div id="nodes-cluster-summary" class="grid gap-2 grid-cols-2 sm:grid-cols-3 xl:grid-cols-2">
                  <.summary_tile id="cluster-configured" label="Configured" value={format_count(@cluster.summary.configured)} tone={:neutral} />
                  <.summary_tile id="cluster-reachable" label="Reachable" value={format_count(@cluster.summary.reachable)} tone={:success} />
                  <.summary_tile id="cluster-prompt-token-capable" label="Prompt-ID Capable" value={prompt_token_capable_summary(@cluster.summary)} tone={prompt_token_capable_summary_tone(@cluster.summary)} />
                  <.summary_tile id="cluster-degraded" label="Degraded" value={format_count(@cluster.summary.degraded)} tone={:warning} />
                  <.summary_tile id="cluster-unhealthy" label="Unhealthy" value={format_count(@cluster.summary.unhealthy)} tone={:error} />
                  <.summary_tile id="cluster-unavailable" label="Unavailable" value={format_count(@cluster.summary.unavailable)} tone={:error} />
                </div>
            <% end %>
          </.card>
          </div>

          <%!-- Per-Target Runtime Cards --%>
          <div id="nodes-runtime-targets" class="space-y-4">
            <div :for={t <- @cluster.targets} id={"nodes-runtime-card-#{t.target_dom_id}"}>
              <.card variant={:rail} padding={:sm}>
                <:title><%= target_card_title(t) %></:title>
                <:subtitle><%= t.target_label %></:subtitle>

                <%!-- Per-target compatibility warning --%>
                <div
                  :if={t.compatibility in [:legacy, :partial]}
                  id={"nodes-runtime-compat-#{t.target_dom_id}"}
                  class="mb-3 rounded border border-amber-300 bg-amber-50 p-2 dark:border-amber-600/50 dark:bg-amber-900/20"
                >
                  <p class="text-xs font-medium text-amber-800 dark:text-amber-200">
                    <%= if t.compatibility == :legacy do %>
                      This node-agent does not report metadata or health.
                    <% else %>
                      This node-agent reports only partial status metadata.
                    <% end %>
                  </p>
                </div>

                <%= if t.status != :ok do %>
                  <.state_message id={"nodes-runtime-unavailable-#{t.target_dom_id}"} kind={:error} layout={:compact} title="Unavailable" body={t.message} />
                <% else %>
                  <div class="space-y-4">
                    <%!-- Worker + Health Badges --%>
                    <div class="flex flex-wrap items-center gap-2">
                      <.badge tone={worker_badge_tone(t.worker_state)}>
                        {worker_badge_label(t.worker_state)}
                      </.badge>
                      <.badge tone={runtime_health_tone(t.runtime_health)}>
                        {runtime_health_label(t.runtime_health)}
                      </.badge>
                      <span id={"nodes-tokenizer-capability-#{t.target_dom_id}"}>
                        <.badge tone={tokenizer_capability_tone(t)}>
                          {tokenizer_capability_label(t)}
                        </.badge>
                      </span>
                      <span class="text-xs font-mono text-slate-400 dark:text-slate-500">
                        {t.active_request_count} active
                      </span>
                    </div>

                    <%!-- Metadata Detail --%>
                    <dl :if={t.node_metadata} class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                      <dt class="text-slate-500 dark:text-slate-400">Node</dt>
                      <dd class="font-mono text-slate-900 dark:text-slate-100">{t.node_metadata.display_name || t.node_metadata.node_id || "—"}</dd>
                      <dt class="text-slate-500 dark:text-slate-400">Endpoint</dt>
                      <dd class="font-mono text-slate-900 dark:text-slate-100">{format_metadata_endpoint(t.node_metadata)}</dd>
                      <dt class="text-slate-500 dark:text-slate-400">Backend</dt>
                      <dd class="font-mono text-slate-900 dark:text-slate-100">{t.node_metadata.worker_backend || "—"}</dd>
                    </dl>

                    <%!-- Runtime Health Detail --%>
                    <div id={"nodes-runtime-health-#{t.target_dom_id}"}>
                      <%= if t.runtime_health == nil do %>
                        <p class="text-xs text-slate-400 dark:text-slate-500">
                          Health detail unavailable from this agent.
                        </p>
                      <% else %>
                        <dl :if={has_health_detail?(t.runtime_health)} class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                          <dt :if={t.runtime_health.health_code} class="text-slate-500 dark:text-slate-400">Health Code</dt>
                          <dd :if={t.runtime_health.health_code} class="font-mono text-slate-900 dark:text-slate-100">{t.runtime_health.health_code}</dd>
                          <dt :if={t.runtime_health.health_message} class="text-slate-500 dark:text-slate-400">Message</dt>
                          <dd :if={t.runtime_health.health_message} class="text-slate-900 dark:text-slate-100">{t.runtime_health.health_message}</dd>
                          <dt :if={t.runtime_health.affected_model} class="text-slate-500 dark:text-slate-400">Affected</dt>
                          <dd :if={t.runtime_health.affected_model} class="font-mono text-slate-900 dark:text-slate-100">{t.runtime_health.affected_model}</dd>
                        </dl>
                      <% end %>
                    </div>

                    <%!-- Observe-only Memory Telemetry --%>
                    <div
                      id={"nodes-memory-telemetry-#{t.target_dom_id}"}
                      class="rounded-lg border border-slate-200 bg-slate-50/60 p-3 dark:border-slate-700 dark:bg-slate-900/50"
                    >
                      <div class="mb-2">
                        <h4 class="text-sm font-medium text-slate-700 dark:text-slate-300">
                          Memory Telemetry
                        </h4>
                        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                          Observe-only memory-budget diagnostics. This section is non-gating.
                        </p>
                      </div>

                      <%= if t.runtime_memory_budgets == [] do %>
                        <p
                          id={"nodes-memory-telemetry-empty-#{t.target_dom_id}"}
                          class="text-xs text-slate-400 dark:text-slate-500"
                        >
                          No memory-budget observation reported by this target.
                        </p>
                      <% else %>
                        <.table id={"nodes-memory-telemetry-table-#{t.target_dom_id}"} rows={t.runtime_memory_budgets}>
                          <:col :let={budget} label="Model" mono>{budget.model_ref}</:col>
                          <:col :let={budget} label="Status">{memory_budget_status_label(budget)}</:col>
                          <:col :let={budget} label="Working Set">{memory_budget_working_set_label(budget)}</:col>
                          <:col :let={budget} label="Headroom Observation">{memory_budget_headroom_label(budget)}</:col>
                          <:col :let={budget} label="Resident / KV / Prefill">
                            {memory_budget_metadata_label(budget)}
                          </:col>
                        </.table>

                        <p
                          :if={t.runtime_memory_budgets_truncated_count > 0}
                          id={"nodes-memory-telemetry-truncated-#{t.target_dom_id}"}
                          class="mt-2 text-xs text-slate-500 dark:text-slate-400"
                        >
                          Showing {length(t.runtime_memory_budgets)} telemetry rows;
                          {t.runtime_memory_budgets_truncated_count} additional row(s) omitted.
                        </p>
                      <% end %>
                    </div>

                    <%!-- Loaded Models --%>
                    <div>
                      <h4 class="mb-2 text-sm font-medium text-slate-700 dark:text-slate-300">Loaded Models</h4>
                      <.table id={"nodes-runtime-models-#{t.target_dom_id}"} rows={t.loaded_models}>
                        <:col :let={m} label="Model" mono>{m.model_id}</:col>
                        <:col :let={m} label="Version" mono>{m.version}</:col>
                        <:empty>
                          <.state_message id={"nodes-models-empty-#{t.target_dom_id}"} kind={:empty} layout={:compact} title="No loaded models." />
                        </:empty>
                      </.table>
                    </div>
                  </div>
                <% end %>
              </.card>
            </div>
          </div>
        </div>
      </div>

      <div id="nodes-safe-tokenization-telemetry-card">
      <.card variant={:secondary}>
        <:title>Safe Tokenization Counters</:title>
        <:subtitle>Process-local observe-only counters since counter process start.</:subtitle>

        <div id="nodes-safe-tokenization-counters" class="grid gap-2 grid-cols-2 sm:grid-cols-3 xl:grid-cols-4">
          <.summary_tile
            id="nodes-safe-tokenization-counter-prompt-token-ids-dispatched"
            label="Prompt IDs Dispatched"
            value={format_prompt_token_ids_dispatched(@safe_tokenization_counters.prompt_token_ids_dispatched)}
            tone={prompt_token_ids_dispatched_tone(@safe_tokenization_counters.prompt_token_ids_dispatched)}
          />
          <.summary_tile
            id="nodes-safe-tokenization-counter-unsafe-mode-active"
            label="Unsafe Fallback"
            value={format_count(@safe_tokenization_counters.unsafe_mode_active.count)}
            tone={counter_warning_tone(@safe_tokenization_counters.unsafe_mode_active)}
          />
          <.summary_tile
            id="nodes-safe-tokenization-counter-parity-drift"
            label="Parity Drift"
            value={format_count(@safe_tokenization_counters.parity_drift.count)}
            tone={counter_error_tone(@safe_tokenization_counters.parity_drift)}
          />
          <.summary_tile
            id="nodes-safe-tokenization-counter-catalog-drift"
            label="Catalog Drift"
            value={format_count(@safe_tokenization_counters.catalog_drift.count)}
            tone={counter_warning_tone(@safe_tokenization_counters.catalog_drift)}
          />
          <.summary_tile
            id="nodes-safe-tokenization-counter-control-token-in-user-content"
            label="Control Token Hits"
            value={format_count(@safe_tokenization_counters.control_token_in_user_content.count)}
            tone={counter_warning_tone(@safe_tokenization_counters.control_token_in_user_content)}
          />
          <.summary_tile
            id="nodes-safe-tokenization-counter-detector-error"
            label="Detector Errors"
            value={format_count(@safe_tokenization_counters.detector_error.count)}
            tone={counter_warning_tone(@safe_tokenization_counters.detector_error)}
          />
          <.summary_tile
            id="nodes-safe-tokenization-counter-degraded-no-manifest-catalog"
            label="No Manifest Catalog"
            value={format_count(@safe_tokenization_counters.degraded_no_manifest_catalog.count)}
            tone={counter_warning_tone(@safe_tokenization_counters.degraded_no_manifest_catalog)}
          />
        </div>
      </.card>
      </div>
    </div>
    """
  end

  # ===========================================================================
  # Data loading
  # ===========================================================================

  defp load_nodes_page(socket) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    # Runtime first: observe_status may refresh an existing node's inventory
    # and lifecycle state (e.g. admitted -> active), so inventory queried
    # second reflects it in the same cycle.
    cluster = fetch_runtime_cluster(observed_at)
    inventory = fetch_inventory()
    pending_admissions = fetch_pending_admissions(inventory.rows)
    safe_tokenization_counters = fetch_safe_tokenization_counters()

    assign(socket,
      cluster: cluster,
      inventory: inventory,
      pending_admissions: pending_admissions,
      safe_tokenization_counters: safe_tokenization_counters,
      last_refreshed_at: observed_at
    )
  end

  defp assign_loading_state(socket) do
    assign(socket,
      inventory: %{
        status: :loading,
        rows: [],
        statuses: [],
        summary: %{
          total: nil,
          by_health: %{healthy: nil, degraded: nil, unhealthy: nil, unreachable: nil}
        },
        message: nil
      },
      pending_admissions: %{
        status: :loading,
        rows: [],
        count: nil,
        pending_count: nil,
        rejected_count: nil,
        message: nil
      },
      cluster: %{
        status: :loading,
        targets: [],
        summary: empty_cluster_summary(),
        message: nil
      },
      safe_tokenization_counters: fetch_safe_tokenization_counters(),
      last_refreshed_at: nil,
      refresh_timer: nil
    )
  end

  defp fetch_runtime_cluster(observed_at) do
    raw_entries = runtime_impl().cluster_snapshot(observed_at: observed_at)
    targets = Enum.map(raw_entries, &normalize_runtime_target/1)

    %{
      status: :ok,
      targets: targets,
      summary: build_cluster_summary(targets),
      message: nil
    }
  rescue
    error ->
      Logger.warning("Nodes cluster fetch failed: #{inspect(error)}")
      cluster_error_state()
  catch
    kind, reason ->
      Logger.warning("Nodes cluster fetch #{kind}: #{inspect(reason)}")
      cluster_error_state()
  end

  defp cluster_error_state do
    %{
      status: :error,
      targets: [],
      summary: empty_cluster_summary(),
      message: "Runtime cluster snapshots unavailable."
    }
  end

  @memory_budget_limit 20
  @max_model_ref_length 160
  @max_mode_length 40
  @max_status_code_length 80
  @max_status_message_length 240

  defp normalize_runtime_target(entry) do
    target = entry.target

    %{
      target: target,
      target_label: target_label(target),
      target_dom_id: target_dom_id(target),
      status: entry.status,
      message: entry[:message],
      worker_state: entry[:worker_state] || :unknown,
      loaded_models: entry[:loaded_models] || [],
      active_request_count: entry[:active_request_count] || 0,
      node_metadata: entry[:node_metadata],
      runtime_health: entry[:runtime_health],
      supports_prompt_token_ids: entry[:supports_prompt_token_ids] == true,
      runtime_memory_budgets: target_memory_budgets(entry),
      runtime_memory_budgets_truncated_count: target_memory_budgets_truncated_count(entry),
      compatibility: target_compatibility(entry)
    }
  end

  defp target_memory_budgets(entry) do
    case entry[:runtime_memory_budgets] do
      budgets when is_list(budgets) ->
        budgets
        |> Enum.take(@memory_budget_limit)
        |> Enum.map(&target_memory_budget_row/1)

      _ ->
        []
    end
  end

  defp target_memory_budget_row(budget) when is_map(budget) do
    %{
      display_state: target_memory_budget_display_state(budget_get(budget, :display_state)),
      model_ref: target_model_ref_string(budget_get(budget, :model_ref)),
      mode: target_mode_string(budget_get(budget, :mode)),
      budget_available: target_memory_budget_boolean(budget_get(budget, :budget_available)),
      headroom_available: target_memory_budget_boolean(budget_get(budget, :headroom_available)),
      status_code: target_status_code_string(budget_get(budget, :status_code)),
      status_message: target_status_message_optional_string(budget_get(budget, :status_message)),
      target_working_set_bytes:
        target_memory_budget_integer(budget_get(budget, :target_working_set_bytes)),
      resident_memory_bytes:
        target_memory_budget_integer(budget_get(budget, :resident_memory_bytes)),
      kv_cache_bytes_per_token:
        target_memory_budget_integer(budget_get(budget, :kv_cache_bytes_per_token)),
      prefill_workspace_bytes_per_token:
        target_memory_budget_integer(budget_get(budget, :prefill_workspace_bytes_per_token))
    }
  end

  defp target_memory_budget_row(_budget) do
    %{
      display_state: :invalid,
      model_ref: "unknown model",
      mode: "unknown",
      budget_available: nil,
      headroom_available: nil,
      status_code: "invalid_status",
      status_message: "memory budget telemetry payload was malformed",
      target_working_set_bytes: nil,
      resident_memory_bytes: nil,
      kv_cache_bytes_per_token: nil,
      prefill_workspace_bytes_per_token: nil
    }
  end

  defp budget_get(budget, key), do: Map.get(budget, key, Map.get(budget, Atom.to_string(key)))

  defp target_memory_budget_display_state(state) when state in [:observed, :invalid], do: state
  defp target_memory_budget_display_state(_), do: :invalid

  defp target_model_ref_string(value),
    do: target_memory_budget_bounded_string(value, "unknown model", @max_model_ref_length)

  defp target_mode_string(value),
    do: target_memory_budget_bounded_string(value, "unknown", @max_mode_length)

  defp target_status_code_string(value),
    do: target_memory_budget_bounded_string(value, "unreported", @max_status_code_length)

  defp target_status_message_optional_string(value),
    do: target_memory_budget_bounded_optional_string(value, @max_status_message_length)

  defp target_memory_budget_bounded_string(value, _fallback, limit)
       when is_binary(value) and value != "",
       do: String.slice(value, 0, limit)

  defp target_memory_budget_bounded_string(_value, fallback, _limit), do: fallback

  defp target_memory_budget_bounded_optional_string(value, limit)
       when is_binary(value) and value != "",
       do: String.slice(value, 0, limit)

  defp target_memory_budget_bounded_optional_string(_value, _limit), do: nil

  defp target_memory_budget_boolean(value) when is_boolean(value), do: value
  defp target_memory_budget_boolean(_), do: nil

  defp target_memory_budget_integer(value) when is_integer(value) and value >= 0, do: value
  defp target_memory_budget_integer(_), do: nil

  defp target_memory_budgets_truncated_count(entry) do
    list_count =
      case entry[:runtime_memory_budgets] do
        budgets when is_list(budgets) -> max(length(budgets) - @memory_budget_limit, 0)
        _ -> 0
      end

    case entry[:runtime_memory_budgets_truncated_count] do
      count when is_integer(count) and count > 0 -> max(count, list_count)
      _ -> list_count
    end
  end

  defp target_compatibility(%{status: status}) when status != :ok, do: :unknown

  defp target_compatibility(%{node_metadata: meta, runtime_health: health}) do
    case {meta, health} do
      {nil, nil} -> :legacy
      {nil, _} -> :partial
      {_, nil} -> :partial
      _ -> :full
    end
  end

  defp target_compatibility(_), do: :unknown

  defp build_cluster_summary(targets) do
    ok_targets = Enum.filter(targets, &(&1.status == :ok))

    %{
      configured: length(targets),
      reachable: length(ok_targets),
      prompt_token_capable: Enum.count(ok_targets, &(&1.supports_prompt_token_ids == true)),
      unavailable: length(targets) - length(ok_targets),
      unhealthy:
        Enum.count(ok_targets, fn t ->
          t.runtime_health != nil and t.runtime_health.ready == false
        end),
      degraded:
        Enum.count(ok_targets, fn t ->
          t.runtime_health != nil and t.runtime_health.ready == true and
            ((t.runtime_health[:health_code] != nil and t.runtime_health[:health_code] != "") or
               (t.runtime_health[:health_message] != nil and
                  t.runtime_health[:health_message] != ""))
        end)
    }
  end

  defp empty_cluster_summary do
    %{
      configured: 0,
      reachable: 0,
      prompt_token_capable: 0,
      unavailable: 0,
      unhealthy: 0,
      degraded: 0
    }
  end

  defp target_label(%Target{transport: :grpc_compat, address: address}), do: target_label(address)

  defp target_label(%Target{transport: :beam, address: address}) do
    beam_address_label(address)
  end

  defp target_label(target) when is_list(target) do
    host = to_string(Keyword.get(target, :host, "?"))
    port = Keyword.get(target, :port)
    format_host_port(host, port)
  end

  defp target_label(%{host: host, port: port}) do
    format_host_port(to_string(host), port)
  end

  defp target_label(_target), do: "unknown"

  defp target_dom_id(%Target{transport: :grpc_compat, address: address}),
    do: target_dom_id(address)

  defp target_dom_id(%Target{transport: :beam, address: address}) do
    "beam-#{beam_address_label(address)}"
    |> sanitize_dom_id()
  end

  defp target_dom_id(target) when is_list(target) do
    host = to_string(Keyword.get(target, :host, "unknown"))
    port = Keyword.get(target, :port, 0)
    sanitize_dom_id("#{host}-#{port}")
  end

  defp target_dom_id(%{host: host, port: port}) do
    sanitize_dom_id("#{host}-#{port}")
  end

  defp target_dom_id(_target), do: "unknown"

  defp beam_address_label(address) when is_atom(address), do: Atom.to_string(address)
  defp beam_address_label(address) when is_binary(address), do: address
  defp beam_address_label(_address), do: "unknown"

  defp sanitize_dom_id(raw) do
    raw
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim_leading("-")
    |> String.trim_trailing("-")
  end

  defp fetch_inventory do
    rows = Nodes.list_nodes()
    summary = Nodes.summary()
    NodesPageData.inventory(rows, summary)
  rescue
    _ ->
      %{
        status: :error,
        rows: [],
        statuses: [],
        summary: %{total: 0, by_health: %{healthy: 0, degraded: 0, unhealthy: 0, unreachable: 0}},
        message: "Node inventory unavailable."
      }
  end

  defp fetch_pending_admissions(nodes) do
    candidates =
      Nodes.list_admission_candidates(admission_category: AdmissionCandidate.review_categories())

    NodesPageData.pending_admissions(candidates, nodes)
  rescue
    error ->
      Logger.warning("Pending admission fetch failed: #{inspect(error)}")
      pending_admissions_error_state()
  catch
    kind, reason ->
      Logger.warning("Pending admission fetch #{kind}: #{inspect(reason)}")
      pending_admissions_error_state()
  end

  defp pending_admissions_error_state do
    %{
      status: :error,
      rows: [],
      count: 0,
      pending_count: 0,
      rejected_count: 0,
      message: "Pending admission candidates unavailable."
    }
  end

  defp fetch_safe_tokenization_counters do
    telemetry_counters_impl().snapshot()
    |> normalize_safe_tokenization_counters()
  rescue
    error ->
      Logger.warning("Safe tokenization counter fetch failed: #{inspect(error)}")
      zero_safe_tokenization_counters()
  catch
    kind, reason ->
      Logger.warning("Safe tokenization counter fetch #{kind}: #{inspect(reason)}")
      zero_safe_tokenization_counters()
  end

  defp normalize_safe_tokenization_counters(snapshot) when is_map(snapshot) do
    counters =
      @safe_tokenization_counter_keys
      |> Map.new(fn key ->
        {key, normalize_safe_tokenization_counter(key, Map.get(snapshot, key))}
      end)

    Map.put(counters, :started_at, normalize_started_at(snapshot[:started_at]))
  end

  defp normalize_safe_tokenization_counters(_snapshot), do: zero_safe_tokenization_counters()

  defp normalize_safe_tokenization_counter(:prompt_token_ids_dispatched, counter)
       when is_map(counter) do
    case counter[:count] do
      count when is_integer(count) and count >= 0 ->
        %{
          count: count,
          token_count: normalize_token_count(counter[:token_count]),
          last_seen_at: normalize_last_seen_at(counter[:last_seen_at])
        }

      _other ->
        zero_prompt_token_ids_dispatched_counter()
    end
  end

  defp normalize_safe_tokenization_counter(:prompt_token_ids_dispatched, _counter) do
    zero_prompt_token_ids_dispatched_counter()
  end

  defp normalize_safe_tokenization_counter(_key, counter) when is_map(counter) do
    case counter[:count] do
      count when is_integer(count) and count >= 0 ->
        %{count: count, last_seen_at: normalize_last_seen_at(counter[:last_seen_at])}

      _other ->
        zero_safe_tokenization_counter()
    end
  end

  defp normalize_safe_tokenization_counter(_key, _counter), do: zero_safe_tokenization_counter()

  defp zero_safe_tokenization_counters do
    %{
      started_at: nil,
      control_token_in_user_content: zero_safe_tokenization_counter(),
      detector_error: zero_safe_tokenization_counter(),
      prompt_token_ids_dispatched: zero_prompt_token_ids_dispatched_counter(),
      unsafe_mode_active: zero_safe_tokenization_counter(),
      parity_drift: zero_safe_tokenization_counter(),
      catalog_drift: zero_safe_tokenization_counter(),
      degraded_no_manifest_catalog: zero_safe_tokenization_counter()
    }
  end

  defp zero_safe_tokenization_counter do
    %{count: 0, last_seen_at: nil}
  end

  defp zero_prompt_token_ids_dispatched_counter do
    Map.put(zero_safe_tokenization_counter(), :token_count, 0)
  end

  defp normalize_token_count(count) when is_integer(count) and count >= 0, do: count
  defp normalize_token_count(_count), do: 0

  defp normalize_started_at(%DateTime{} = started_at), do: started_at
  defp normalize_started_at(_started_at), do: nil

  defp normalize_last_seen_at(%DateTime{} = last_seen_at), do: last_seen_at
  defp normalize_last_seen_at(_last_seen_at), do: nil

  # ===========================================================================
  # Cluster display helpers
  # ===========================================================================

  defp cluster_subtitle(%{status: :loading}), do: "Loading..."
  defp cluster_subtitle(%{status: :error}), do: "Error"

  defp cluster_subtitle(%{summary: s}) do
    "#{s.configured} target(s) configured, #{s.reachable} reachable"
  end

  defp cluster_subtitle(_), do: ""

  defp prompt_token_capable_summary(%{prompt_token_capable: capable, reachable: reachable})
       when is_integer(capable) and is_integer(reachable) and reachable >= 0,
       do: "#{capable}/#{reachable}"

  defp prompt_token_capable_summary(_), do: "—"

  defp prompt_token_capable_summary_tone(%{prompt_token_capable: capable, reachable: reachable})
       when is_integer(capable) and is_integer(reachable) and reachable > 0 and
              capable == reachable,
       do: :success

  defp prompt_token_capable_summary_tone(_), do: :neutral

  defp target_card_title(%{node_metadata: %{display_name: name}})
       when is_binary(name) and name != "",
       do: name

  defp target_card_title(%{target_label: label}), do: label

  # ===========================================================================
  # Badge helpers
  # ===========================================================================

  # State badges — closed set per SPEC
  defp state_badge_tone(:provisioned), do: :neutral
  defp state_badge_tone(:registered), do: :info
  defp state_badge_tone(:admitted), do: :info
  defp state_badge_tone(:active), do: :success
  defp state_badge_tone(:cordoned), do: :warning
  defp state_badge_tone(:draining), do: :warning
  defp state_badge_tone(:maintenance), do: :warning
  defp state_badge_tone(:decommissioning), do: :warning
  defp state_badge_tone(:removed), do: :neutral
  defp state_badge_tone(_), do: :neutral

  # Health badges
  defp health_badge_tone(:healthy), do: :success
  defp health_badge_tone(:degraded), do: :warning
  defp health_badge_tone(:unhealthy), do: :error
  defp health_badge_tone(:unreachable), do: :error
  defp health_badge_tone(_), do: :neutral

  # Worker state badges — mirrors OverviewLive
  defp worker_badge_tone(:idle), do: :success
  defp worker_badge_tone(:busy), do: :processing
  defp worker_badge_tone(state) when state in [:starting, :stopping], do: :warning
  defp worker_badge_tone(:failed), do: :error
  defp worker_badge_tone(:stopped), do: :warning
  defp worker_badge_tone(_), do: :neutral

  defp worker_badge_label(:idle), do: "Idle"
  defp worker_badge_label(:busy), do: "Busy"
  defp worker_badge_label(:starting), do: "Starting"
  defp worker_badge_label(:stopping), do: "Stopping"
  defp worker_badge_label(:failed), do: "Failed"
  defp worker_badge_label(:stopped), do: "Stopped"
  defp worker_badge_label(_), do: "Unknown"

  # Runtime health
  defp runtime_health_tone(nil), do: :neutral
  defp runtime_health_tone(%{ready: false}), do: :error

  defp runtime_health_tone(%{ready: true, health_code: code, health_message: msg})
       when (code != nil and code != "") or (msg != nil and msg != ""),
       do: :warning

  defp runtime_health_tone(%{ready: true}), do: :success
  defp runtime_health_tone(_), do: :neutral

  defp runtime_health_label(nil), do: "Unsupported"
  defp runtime_health_label(%{ready: false}), do: "Unhealthy"

  defp runtime_health_label(%{ready: true, health_code: code, health_message: msg})
       when (code != nil and code != "") or (msg != nil and msg != ""),
       do: "Degraded"

  defp runtime_health_label(%{ready: true}), do: "Healthy"
  defp runtime_health_label(_), do: "Unknown"

  defp tokenizer_capability_tone(%{supports_prompt_token_ids: true}), do: :success
  defp tokenizer_capability_tone(_), do: :neutral

  defp tokenizer_capability_label(%{supports_prompt_token_ids: true}), do: "Prompt IDs: capable"
  defp tokenizer_capability_label(_), do: "Prompt IDs: legacy"

  defp has_health_detail?(%{health_code: c, health_message: m, affected_model: a}) do
    c != nil or m != nil or a != nil
  end

  defp has_health_detail?(_), do: false

  defp pending_source_tone(:runtime_endpoint_observation), do: :info
  defp pending_source_tone("runtime_endpoint_observation"), do: :info
  defp pending_source_tone(:provisioned_node), do: :neutral
  defp pending_source_tone("provisioned_node"), do: :neutral
  defp pending_source_tone(:registered_node), do: :info
  defp pending_source_tone("registered_node"), do: :info
  defp pending_source_tone(_source), do: :neutral

  defp pending_source_label(:runtime_endpoint_observation), do: "observed"
  defp pending_source_label("runtime_endpoint_observation"), do: "observed"
  defp pending_source_label(:provisioned_node), do: "provisioned"
  defp pending_source_label("provisioned_node"), do: "provisioned"
  defp pending_source_label(:registered_node), do: "registered"
  defp pending_source_label("registered_node"), do: "registered"
  defp pending_source_label(source), do: format_status_value(source)

  defp admission_category_tone(:rejected), do: :error
  defp admission_category_tone("rejected"), do: :error
  defp admission_category_tone(:pending_registered), do: :info
  defp admission_category_tone("pending_registered"), do: :info
  defp admission_category_tone(:pending_provisioned), do: :warning
  defp admission_category_tone("pending_provisioned"), do: :warning
  defp admission_category_tone(:pending_observed), do: :neutral
  defp admission_category_tone("pending_observed"), do: :neutral
  defp admission_category_tone(_category), do: :neutral

  defp compatibility_tone("compatible"), do: :success
  defp compatibility_tone("legacy_metadata"), do: :warning
  defp compatibility_tone("partial_metadata"), do: :warning
  defp compatibility_tone("version_skew"), do: :warning
  defp compatibility_tone("unsupported_version"), do: :error
  defp compatibility_tone(_status), do: :neutral

  # Observe-only memory telemetry display helpers.
  defp memory_budget_status_label(%{display_state: :invalid}), do: "invalid telemetry"

  defp memory_budget_status_label(%{status_code: code, status_message: message}) do
    case message do
      nil -> code
      "" -> code
      _ -> "#{code} — #{message}"
    end
  end

  defp memory_budget_status_label(_), do: "unreported"

  defp memory_budget_working_set_label(%{
         budget_available: true,
         target_working_set_bytes: bytes
       })
       when is_integer(bytes) and bytes >= 0,
       do: "reported · #{format_bytes(bytes)}"

  defp memory_budget_working_set_label(%{budget_available: true}), do: "reported"
  defp memory_budget_working_set_label(_), do: "unreported"

  defp memory_budget_headroom_label(%{headroom_available: true}), do: "estimate reported"
  defp memory_budget_headroom_label(_), do: "estimate unavailable"

  defp memory_budget_metadata_label(budget) do
    [
      "resident #{telemetry_presence_label(budget[:resident_memory_bytes])}",
      "KV #{telemetry_presence_label(budget[:kv_cache_bytes_per_token])}",
      "prefill #{telemetry_presence_label(budget[:prefill_workspace_bytes_per_token])}"
    ]
    |> Enum.join(" · ")
  end

  defp format_prompt_token_ids_dispatched(%{count: count, token_count: token_count}) do
    "#{count} events · #{token_count} tokens"
  end

  defp prompt_token_ids_dispatched_tone(%{count: count}) when count > 0, do: :success
  defp prompt_token_ids_dispatched_tone(_counter), do: :neutral

  defp counter_warning_tone(%{count: count}) when count > 0, do: :warning
  defp counter_warning_tone(_counter), do: :neutral

  defp counter_error_tone(%{count: count}) when count > 0, do: :error
  defp counter_error_tone(_counter), do: :neutral

  # Phase 2 observe-only contract: zero-valued resident/KV/prefill fields still
  # mean the underlying estimate is missing or incomplete for operator purposes,
  # so the UI keeps them in the neutral "unreported" bucket rather than
  # implying a measured zero-byte observation.
  defp telemetry_presence_label(value) when is_integer(value) and value > 0, do: "reported"
  defp telemetry_presence_label(_), do: "unreported"

  # ===========================================================================
  # Format helpers
  # ===========================================================================

  defp format_count(nil), do: "\u2014"
  defp format_count(count) when is_integer(count), do: Integer.to_string(count)

  defp pending_admissions_subtitle(%{
         status: :ok,
         pending_count: pending_count,
         rejected_count: rejected_count
       })
       when is_integer(pending_count) and is_integer(rejected_count) do
    [
      pending_review_count_label(pending_count),
      rejected_review_count_label(rejected_count)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp pending_admissions_subtitle(%{status: :ok, count: count}) when is_integer(count) do
    "#{count} admission review items."
  end

  defp pending_admissions_subtitle(%{status: :loading}), do: "Loading review queue."
  defp pending_admissions_subtitle(_pending), do: "Review queue unavailable."

  defp pending_review_count_label(0), do: "No pending decisions."
  defp pending_review_count_label(1), do: "1 awaiting operator decision."
  defp pending_review_count_label(count), do: "#{count} awaiting operator decision."

  defp rejected_review_count_label(0), do: nil
  defp rejected_review_count_label(1), do: "1 rejected record visible for audit."
  defp rejected_review_count_label(count), do: "#{count} rejected records visible for audit."

  defp pending_detail_path(%{kind: :candidate, id: id}), do: ~p"/console/nodes/pending/#{id}"
  defp pending_detail_path(%{kind: :node, id: id}), do: ~p"/console/nodes/#{id}"

  defp status_value(status, group, key) when is_map(status) do
    case map_get(status, group) do
      group_status when is_map(group_status) -> map_get(group_status, key)
      _group_status -> nil
    end
  end

  defp status_value(_status, _group, _key), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(_map, _key), do: nil

  defp format_status_value(nil), do: "unknown"

  defp format_status_value(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> format_status_value()
  end

  defp format_status_value(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_status_value(value), do: to_string(value)

  defp format_pending_target(%{target_ref: target}) when is_binary(target) and target != "",
    do: target

  defp format_pending_target(_row), do: "Unconfigured"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: "#{bytes} bytes"

  defp format_address(%{advertise_addr: addr, rpc_port: port})
       when is_binary(addr) and is_integer(port),
       do: format_host_port(addr, port)

  defp format_address(_), do: "—"

  defp format_metadata_endpoint(%{listen_host: host, listen_port: port})
       when host != nil and port != nil,
       do: format_host_port(host, port)

  defp format_metadata_endpoint(_), do: "—"

  # Bracket IPv6 addresses for unambiguous host:port display
  defp format_host_port(host, port) do
    if String.contains?(host, ":"),
      do: "[#{host}]:#{port}",
      else: "#{host}:#{port}"
  end

  defp refresh_interval_label do
    ms = refresh_interval_ms()
    if rem(ms, 1000) == 0, do: "#{div(ms, 1000)}s", else: "#{ms}ms"
  end

  # ===========================================================================
  # Refresh / config
  # ===========================================================================

  defp schedule_refresh(socket) do
    ref = Process.send_after(self(), :refresh_nodes, refresh_interval_ms())
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

  defp telemetry_counters_impl do
    console_config()[:telemetry_counters_impl] || Orchard.Tokenizer.TelemetryCounters
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  # ===========================================================================
  # Local function component
  # ===========================================================================

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:tone, :atom, default: :neutral)

  defp summary_tile(assigns) do
    ~H"""
    <div id={@id} class={[
      "rounded-lg px-4 py-3 ring-1",
      summary_tile_classes(@tone)
    ]}>
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
        {@label}
      </p>
      <p class="mt-1 text-2xl font-mono text-slate-900 dark:text-slate-100">
        {@value}
      </p>
    </div>
    """
  end

  defp summary_tile_classes(:success),
    do: "bg-forest-50/50 ring-forest-300/60 dark:bg-emerald-900/20 dark:ring-emerald-700/30"

  defp summary_tile_classes(:warning),
    do: "bg-amber-50/50 ring-amber-200/60 dark:bg-amber-900/20 dark:ring-amber-700/30"

  defp summary_tile_classes(:error),
    do: "bg-red-50/50 ring-red-200/60 dark:bg-red-900/20 dark:ring-red-700/30"

  defp summary_tile_classes(_),
    do: "bg-slate-50 ring-slate-200/60 dark:bg-slate-900/60 dark:ring-slate-700/30"
end
