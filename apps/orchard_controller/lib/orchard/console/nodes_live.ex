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

      <%!-- Compatibility Warning --%>
      <div
        :if={compatibility_mode(@runtime) in [:legacy, :partial]}
        id="nodes-compat-warning"
        class="rounded-lg border border-amber-300 bg-amber-50 p-4 dark:border-amber-600/50 dark:bg-amber-900/20"
      >
        <p class="text-sm font-medium text-amber-800 dark:text-amber-200">
          <%= if compatibility_mode(@runtime) == :legacy do %>
            The connected node-agent does not report inventory metadata or runtime health.
            Auto-registration and detailed diagnostics may be incomplete until the agent is upgraded.
          <% else %>
            The connected node-agent reports only partial status metadata.
            Some diagnostics may be incomplete.
          <% end %>
        </p>
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

        <%!-- Live Runtime Card --%>
        <div class="xl:col-span-1">
          <div id="nodes-runtime-card">
          <.card>
            <:title>Live Runtime</:title>
            <:subtitle>Current configured runtime target.</:subtitle>

            <%= cond do %>
              <% @runtime.status == :loading -> %>
                <.state_message id="nodes-runtime-loading" kind={:loading} layout={:compact} title="Loading runtime status." />
              <% @runtime.status != :ok -> %>
                <.state_message id="nodes-runtime-unavailable" kind={:error} layout={:compact} title="Runtime unavailable." body={@runtime.message} />
              <% true -> %>
                <div class="space-y-4">
                  <%!-- Worker + Health Badges --%>
                  <div class="flex flex-wrap items-center gap-2">
                    <.badge tone={worker_badge_tone(@runtime.worker_state)}>
                      {worker_badge_label(@runtime.worker_state)}
                    </.badge>
                    <.badge tone={runtime_health_tone(@runtime.runtime_health)}>
                      {runtime_health_label(@runtime.runtime_health)}
                    </.badge>
                    <span class="text-xs font-mono text-slate-400 dark:text-slate-500">
                      {@runtime.active_request_count} active request(s)
                    </span>
                  </div>

                  <%!-- Metadata Detail --%>
                  <dl :if={@runtime.node_metadata} class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                    <dt class="text-slate-500 dark:text-slate-400">Node</dt>
                    <dd class="font-mono text-slate-900 dark:text-slate-100">{@runtime.node_metadata.display_name || @runtime.node_metadata.node_id || "—"}</dd>
                    <dt class="text-slate-500 dark:text-slate-400">Endpoint</dt>
                    <dd class="font-mono text-slate-900 dark:text-slate-100">{format_metadata_endpoint(@runtime.node_metadata)}</dd>
                    <dt class="text-slate-500 dark:text-slate-400">Backend</dt>
                    <dd class="font-mono text-slate-900 dark:text-slate-100">{@runtime.node_metadata.worker_backend || "—"}</dd>
                  </dl>

                  <%!-- Runtime Health Detail --%>
                  <div id="nodes-runtime-health-detail">
                    <%= if @runtime.runtime_health == nil do %>
                      <p class="text-xs text-slate-400 dark:text-slate-500">
                        Detailed runtime health is unavailable from this agent.
                      </p>
                    <% else %>
                      <dl :if={has_health_detail?(@runtime.runtime_health)} class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
                        <dt :if={@runtime.runtime_health.health_code} class="text-slate-500 dark:text-slate-400">Health Code</dt>
                        <dd :if={@runtime.runtime_health.health_code} class="font-mono text-slate-900 dark:text-slate-100">{@runtime.runtime_health.health_code}</dd>
                        <dt :if={@runtime.runtime_health.health_message} class="text-slate-500 dark:text-slate-400">Message</dt>
                        <dd :if={@runtime.runtime_health.health_message} class="text-slate-900 dark:text-slate-100">{@runtime.runtime_health.health_message}</dd>
                        <dt :if={@runtime.runtime_health.affected_model} class="text-slate-500 dark:text-slate-400">Affected Model</dt>
                        <dd :if={@runtime.runtime_health.affected_model} class="font-mono text-slate-900 dark:text-slate-100">{@runtime.runtime_health.affected_model}</dd>
                      </dl>
                    <% end %>
                  </div>

                  <%!-- Loaded Models --%>
                  <div>
                    <h4 class="mb-2 text-sm font-medium text-slate-700 dark:text-slate-300">Loaded Models</h4>
                    <.table id="nodes-runtime-models" rows={@runtime.loaded_models}>
                      <:col :let={m} label="Model" mono>{m.model_id}</:col>
                      <:col :let={m} label="Version" mono>{m.version}</:col>
                      <:empty>
                        <.state_message id="nodes-runtime-models-empty" kind={:empty} layout={:compact} title="No loaded models." />
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
    """
  end

  # ===========================================================================
  # Data loading
  # ===========================================================================

  defp load_nodes_page(socket) do
    # Runtime first: observe_status may persist a newly discovered node,
    # so inventory queried second can show it in the same cycle.
    runtime = fetch_runtime()
    inventory = fetch_inventory()

    assign(socket,
      runtime: runtime,
      inventory: inventory,
      last_refreshed_at: DateTime.utc_now() |> DateTime.truncate(:second)
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
      runtime: %{
        status: :loading,
        worker_state: :unknown,
        loaded_models: [],
        active_request_count: 0,
        node_metadata: nil,
        runtime_health: nil,
        message: nil
      },
      last_refreshed_at: nil,
      refresh_timer: nil
    )
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
  # Compatibility classification
  # ===========================================================================

  defp compatibility_mode(%{status: status}) when status != :ok, do: :unknown

  defp compatibility_mode(%{node_metadata: meta, runtime_health: health}) do
    case {meta, health} do
      {nil, nil} -> :legacy
      {nil, _} -> :partial
      {_, nil} -> :partial
      _ -> :full
    end
  end

  defp compatibility_mode(_), do: :unknown

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
