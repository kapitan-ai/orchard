defmodule OrchardConsole.ModelHubLive do
  @moduledoc """
  Console Model Hub scaffold page.
  """

  use OrchardConsole, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Model Hub", active_nav: :model_hub)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="model-hub-placeholder-card">
      <.card>
        <:title>Model Hub</:title>
        <:subtitle>Browse Hugging Face MLX text-generation models from the console.</:subtitle>

        <p id="model-hub-placeholder-copy" class="text-sm text-slate-600 dark:text-slate-300">
          Search, results, and detail browsing arrive in the next task. Download and import actions
          are intentionally out of scope for this scaffold.
        </p>
      </.card>
    </div>
    """
  end
end
