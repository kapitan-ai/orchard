defmodule OrchardConsole.OverviewLive do
  @moduledoc """
  Console overview page — readiness, runtime snapshot, and summary counts.
  """

  use OrchardConsole, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Overview")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-8">
      <div class="flex items-center gap-3 mb-8">
        <img src={~p"/images/favicon.png"} alt="Orchard" class="h-8 w-8" />
        <h1 class="text-2xl font-semibold text-slate-900 dark:text-slate-50">
          Orchard Console
        </h1>
      </div>

      <div class="rounded-lg border border-slate-200 bg-white p-6 dark:border-slate-700 dark:bg-slate-800">
        <h2 class="text-lg font-medium text-slate-900 dark:text-slate-100 mb-2">
          Overview
        </h2>
        <p class="text-sm text-slate-500 dark:text-slate-400">
          Sovereign LLM inference on Apple Silicon.
        </p>
        <div class="mt-4 flex items-center gap-2">
          <span class="inline-flex items-center rounded-full bg-forest-50 px-2.5 py-0.5 text-xs font-medium text-forest-700 ring-1 ring-inset ring-forest/20 dark:bg-forest-900/30 dark:text-forest-400 dark:ring-forest/30">
            Console Online
          </span>
          <span class="text-xs text-slate-400 dark:text-slate-500 font-mono">
            v0.1.0
          </span>
        </div>
      </div>
    </div>
    """
  end
end
