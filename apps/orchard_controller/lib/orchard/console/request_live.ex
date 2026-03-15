defmodule OrchardConsole.RequestLive do
  @moduledoc """
  Console request detail page — placeholder for the request timeline view.
  """

  use OrchardConsole, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, active_nav: :requests, public_id: nil, page_title: "Request")}
  end

  @impl true
  def handle_params(%{"public_id" => public_id}, _uri, socket) do
    {:noreply, assign(socket, public_id: public_id, page_title: "Request #{public_id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card>
        <:title>Coming soon</:title>
        <p class="text-sm text-slate-500 dark:text-slate-400">
          Request detail view is not implemented yet.
        </p>
        <div :if={@public_id} class="mt-3">
          <span class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
            Public ID
          </span>
          <p class="mt-1 font-mono text-sm text-slate-900 dark:text-slate-100">
            {@public_id}
          </p>
        </div>
      </.card>
    </div>
    """
  end
end
