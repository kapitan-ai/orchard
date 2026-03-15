defmodule OrchardConsole.OverviewLive do
  @moduledoc """
  Console overview page — readiness, runtime snapshot, and summary counts.

  W1T3: placeholder content using card/badge components.
  W1T4 will add real data from Orchard.Models and Orchard.Requests.
  """

  use OrchardConsole, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Overview", active_nav: :overview)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.card>
        <:title>System Status</:title>
        <:subtitle>Sovereign LLM inference on Apple Silicon.</:subtitle>
        <div class="flex items-center gap-3">
          <.badge tone={:success}>Console Online</.badge>
          <span class="text-xs text-slate-400 dark:text-slate-500 font-mono">
            v0.1.0
          </span>
        </div>
      </.card>
    </div>
    """
  end
end
