defmodule OrchardConsole.PlaygroundLive do
  @moduledoc """
  Console playground page — placeholder for the streaming chat UI.
  """

  use OrchardConsole, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Playground", active_nav: :playground)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card>
        <:title>Coming soon</:title>
        <p class="text-sm text-slate-500 dark:text-slate-400">
          The console playground is not implemented yet.
        </p>
      </.card>
    </div>
    """
  end
end
