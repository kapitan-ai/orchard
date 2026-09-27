defmodule OrchardConsole.LocalNodeCard do
  @moduledoc "Local-machine Node evidence within the Nodes Inventory workspace."

  use OrchardConsole, :html

  attr(:summary, :map, required: true)
  attr(:loading, :boolean, default: false)

  @doc "Renders identity, current evidence and model serving as distinct facts."
  @spec local_node_card(map()) :: Phoenix.LiveView.Rendered.t()
  def local_node_card(assigns) do
    ~H"""
    <section id="nodes-local-machine" aria-label="This machine's Node">
      <.card variant={:primary}>
        <:title>This machine</:title>
        <%= if @summary.node do %>
          <h2 class="text-xl font-semibold text-slate-900 dark:text-slate-100 break-words">
            {@summary.node.hostname || @summary.node.display_name}
          </h2>
          <p class="mt-1 text-xs font-mono text-slate-500 dark:text-slate-400 break-all">
            Node · {@summary.node.id}
          </p>
        <% end %>
        <p id="nodes-local-status" role="status" class={[
          "mt-3 mb-6 text-base font-medium",
          if(@summary.state == :healthy,
            do: "text-forest dark:text-emerald-400",
            else: "text-slate-900 dark:text-slate-100")
        ]}>
          {if @loading, do: "Checking this machine’s Node…", else: headline(@summary.state)}
        </p>
        <%= if @summary.node do %>
          <div class="grid gap-6 lg:grid-cols-2">
            <dl class="space-y-3 text-sm">
              <div><dt class="text-slate-500 dark:text-slate-400">Last observed Node health</dt><dd>{String.capitalize(to_string(@summary.node.health))}</dd></div>
              <div><dt class="text-slate-500 dark:text-slate-400">Lifecycle</dt><dd>{String.capitalize(to_string(@summary.node.state))}</dd></div>
              <div><dt class="text-slate-500 dark:text-slate-400">Last successful observation</dt>
                <dd class="font-mono">
                  <.local_time :if={@summary.node.last_heartbeat_at} value={@summary.node.last_heartbeat_at} format={:datetime_second} />
                  <span :if={!@summary.node.last_heartbeat_at}>Not available</span>
                </dd>
              </div>
              <div><dt class="text-slate-500 dark:text-slate-400">Source</dt><dd>Controller’s persisted Node observation</dd></div>
            </dl>
            <div class="border-t border-slate-200 pt-4 lg:border-t-0 lg:border-l lg:pl-6 lg:pt-0 dark:border-slate-700">
              <h3 class="font-semibold text-slate-900 dark:text-slate-100">Model serving</h3>
              <%= cond do %>
                <% @summary.runtime == nil -> %>
                  <p class="mt-2 text-sm">Current model status is unknown.</p>
                <% @summary.runtime.loaded_models == [] -> %>
                  <p class="mt-2 text-sm">No models loaded.</p>
                <% true -> %>
                  <p class="mt-2 text-sm">{@summary.runtime.loaded_models |> length()} model(s) reported loaded.</p>
              <% end %>
              <p class="mt-2 text-sm text-slate-500 dark:text-slate-400">
                Node health alone does not mean a model can serve your request.
              </p>
              <.link patch={~p"/console/nodes?section=runtime"} class="mt-4 inline-block text-sm font-medium text-navy dark:text-sky-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy focus-visible:ring-offset-2 dark:focus-visible:ring-sky-400 dark:focus-visible:ring-offset-slate-800">
                View Runtime
              </.link>
              <.link navigate={~p"/console/nodes/#{@summary.node.id}"} class="mt-4 ml-4 inline-block text-sm font-medium text-navy dark:text-sky-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy focus-visible:ring-offset-2 dark:focus-visible:ring-sky-400 dark:focus-visible:ring-offset-slate-800">
                Inspect Node
              </.link>
            </div>
          </div>
        <% end %>
        <p :if={!@loading && @summary.state != :healthy} class="mt-6 text-sm text-slate-600 dark:text-slate-300">
          {attention(@summary.state)}
        </p>
      </.card>
    </section>
    """
  end

  defp headline(:healthy), do: "This machine’s Node is connected and healthy."
  defp headline(:stale), do: "The last successful Node observation is out of date."
  defp headline(:unavailable), do: "We can’t reach this machine’s Node."
  defp headline(:attention), do: "This machine’s Node needs attention."
  defp headline(:unknown), do: "This machine’s Node is not identified yet."

  defp attention(:stale),
    do:
      "A current Runtime response does not make the older persisted Node observation fresh. Inspect Node for evidence."

  defp attention(:unavailable),
    do:
      "Check that the Node service is running on this machine. The failed check does not tell us why it stopped responding."

  defp attention(:attention), do: "Inspect Node and Runtime for the reported health details."

  defp attention(:unknown),
    do:
      "The installation’s local identity has not been matched to trusted Node evidence. This does not prove the Node service is stopped."
end
