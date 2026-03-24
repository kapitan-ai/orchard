defmodule OrchardConsole.NodesLive do
  @moduledoc """
  Console nodes page — persistent node inventory with live runtime diagnostics.

  Combines persisted inventory from `Orchard.Nodes` with live runtime
  status from `OrchardConsole.Runtime`, polling on a configurable interval.
  Runtime failure does not suppress persisted inventory rendering.
  """

  use OrchardConsole, :live_view

  alias Orchard.Nodes

  @default_refresh_interval_ms 5_000

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Nodes", active_nav: :nodes)

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
          <span class="font-mono">
            {freshness_text(@last_refreshed_at)}
          </span>
          <span>· Auto-refreshing every {refresh_interval_label()}</span>
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

      <%!-- Main Grid --%>
      <div class="grid gap-6 xl:grid-cols-3">
        <%!-- Persisted Inventory Table --%>
        <div class="xl:col-span-2">
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
                    <span class="font-medium text-slate-900 dark:text-slate-100">{node.display_name}</span>
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
                  <:col :let={node} label="Last Seen" mono>{format_datetime(node.last_heartbeat_at)}</:col>
                </.table>
              <% true -> %>
                <.state_message id="nodes-inventory-error" kind={:error} layout={:compact} title="Node inventory unavailable." body={@inventory.message} />
              <% end %>
          </.card>
          </div>
        </div>

        <%!-- Live Cluster Column --%>
        <div class="xl:col-span-1 space-y-4">
          <%!-- Cluster Summary Card --%>
          <div id="nodes-live-cluster-card">
          <.card>
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
                <div id="nodes-cluster-summary" class="grid gap-2 grid-cols-2 sm:grid-cols-3">
                  <.summary_tile id="cluster-configured" label="Configured" value={format_count(@cluster.summary.configured)} tone={:neutral} />
                  <.summary_tile id="cluster-reachable" label="Reachable" value={format_count(@cluster.summary.reachable)} tone={:success} />
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
              <.card>
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
    </div>
    """
  end

  # ===========================================================================
  # Data loading
  # ===========================================================================

  defp load_nodes_page(socket) do
    observed_at = DateTime.utc_now() |> DateTime.truncate(:second)

    # Runtime first: observe_status may persist a newly discovered node,
    # so inventory queried second can show it in the same cycle.
    cluster = fetch_runtime_cluster(observed_at)
    inventory = fetch_inventory()

    assign(socket,
      cluster: cluster,
      inventory: inventory,
      last_refreshed_at: observed_at
    )
  end

  defp assign_loading_state(socket) do
    assign(socket,
      inventory: %{
        status: :loading,
        rows: [],
        summary: %{
          total: nil,
          by_health: %{healthy: nil, degraded: nil, unhealthy: nil, unreachable: nil}
        },
        message: nil
      },
      cluster: %{
        status: :loading,
        targets: [],
        summary: empty_cluster_summary(),
        message: nil
      },
      last_refreshed_at: nil,
      refresh_timer: nil
    )
  end

  # NOTE: Requires runtime_impl() to implement cluster_snapshot/1.
  # OverviewLive and HealthController use snapshot/0|1 (single-target).
  # NodesLive is the only consumer of cluster_snapshot/1.
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
    _ ->
      %{
        status: :error,
        targets: [],
        summary: empty_cluster_summary(),
        message: "Runtime cluster snapshots unavailable."
      }
  end

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
      compatibility: target_compatibility(entry)
    }
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
    %{configured: 0, reachable: 0, unavailable: 0, unhealthy: 0, degraded: 0}
  end

  defp target_label(target) do
    host = to_string(Keyword.get(target, :host, "?"))
    port = Keyword.get(target, :port)
    format_host_port(host, port)
  end

  defp target_dom_id(target) do
    host = to_string(Keyword.get(target, :host, "unknown"))
    port = Keyword.get(target, :port, 0)
    raw = "#{host}-#{port}"

    raw
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim_leading("-")
    |> String.trim_trailing("-")
  end

  defp fetch_inventory do
    rows = Nodes.list_nodes()
    summary = Nodes.summary()
    %{status: :ok, rows: rows, summary: summary, message: nil}
  rescue
    _ ->
      %{
        status: :error,
        rows: [],
        summary: %{total: 0, by_health: %{healthy: 0, degraded: 0, unhealthy: 0, unreachable: 0}},
        message: "Node inventory unavailable."
      }
  end

  # ===========================================================================
  # Cluster display helpers
  # ===========================================================================

  defp cluster_subtitle(%{status: :loading}), do: "Loading..."
  defp cluster_subtitle(%{status: :error}), do: "Error"

  defp cluster_subtitle(%{summary: s}) do
    "#{s.configured} target(s) configured, #{s.reachable} reachable"
  end

  defp cluster_subtitle(_), do: ""

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

  defp has_health_detail?(%{health_code: c, health_message: m, affected_model: a}) do
    c != nil or m != nil or a != nil
  end

  defp has_health_detail?(_), do: false

  # ===========================================================================
  # Format helpers
  # ===========================================================================

  defp format_count(nil), do: "\u2014"
  defp format_count(count) when is_integer(count), do: Integer.to_string(count)

  defp format_address(%{advertise_addr: addr, rpc_port: port})
       when is_binary(addr) and is_integer(port),
       do: format_host_port(addr, port)

  defp format_address(_), do: "—"

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

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

  defp freshness_text(nil), do: "Waiting for first live update"

  defp freshness_text(%DateTime{} = dt),
    do: "Last refreshed #{Calendar.strftime(dt, "%H:%M:%S")} UTC"

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
    do: "bg-forest-50/50 ring-forest-200/60 dark:bg-emerald-900/20 dark:ring-emerald-700/30"

  defp summary_tile_classes(:warning),
    do: "bg-amber-50/50 ring-amber-200/60 dark:bg-amber-900/20 dark:ring-amber-700/30"

  defp summary_tile_classes(:error),
    do: "bg-red-50/50 ring-red-200/60 dark:bg-red-900/20 dark:ring-red-700/30"

  defp summary_tile_classes(_),
    do: "bg-slate-50 ring-slate-200/60 dark:bg-slate-900/60 dark:ring-slate-700/30"
end
