defmodule OrchardConsole.ModelsLive do
  @moduledoc """
  Console models page — full catalog view with lifecycle actions.
  """

  use OrchardConsole, :live_view

  alias Ecto.Changeset
  alias Orchard.Models
  alias Orchard.Models.Model

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Models", active_nav: :models)
      |> assign_loading_state()

    if connected?(socket) do
      {:ok, load_catalog(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("activate", %{"id" => id}, socket) do
    {:noreply, apply_transition(socket, id, &Models.activate_model/1, :activate)}
  end

  def handle_event("deprecate", %{"id" => id}, socket) do
    {:noreply, apply_transition(socket, id, &Models.deprecate_model/1, :deprecate)}
  end

  def handle_event("retire", %{"id" => id}, socket) do
    {:noreply, apply_transition(socket, id, &Models.retire_model/1, :retire)}
  end

  @impl true
  def render(%{models_status: :loading} = assigns) do
    ~H"""
    <.state_message
      id="models-loading-card"
      kind={:loading}
      layout={:panel}
      title="Model Catalog"
      body="Loading model catalog…"
    />
    """
  end

  def render(%{models_status: :error} = assigns) do
    ~H"""
    <.state_message
      id="models-error-card"
      kind={:error}
      layout={:panel}
      title="Models unavailable"
      body={@load_error}
    />
    """
  end

  def render(%{models_status: :ok} = assigns) do
    ~H"""
    <div id="models-catalog-card">
      <.card>
        <:title>Model Catalog</:title>
        <:subtitle>Manage model visibility and lifecycle state.</:subtitle>

        <div id="models-summary" class="grid grid-cols-5 gap-3 mb-4">
          <.summary_tile
            id="models-summary-total"
            label="Total"
            value={@models_summary.total}
            tone={:neutral}
          />
          <.summary_tile
            :for={{state, tone} <- summary_state_tiles()}
            id={"models-summary-#{state}"}
            label={Phoenix.Naming.humanize(state)}
            value={@models_summary.by_state[state] || 0}
            tone={tone}
          />
        </div>

        <.table
          id="models-catalog"
          rows={@models}
          row_id={&"model-#{&1.id}"}
          row_class={&table_row_class/1}
        >
          <:col :let={model} label="Model" mono>{model.model_id}</:col>
          <:col :let={model} label="Version" mono>{model.version}</:col>
          <:col :let={model} label="State">
            <.badge tone={state_tone(model.state)}>{model.state}</.badge>
          </:col>
          <:col :let={model} label="Format" mono>{model.format}</:col>
          <:col :let={model} label="Capabilities">{format_capabilities(model.capabilities)}</:col>
          <:col :let={model} label="Max Context" mono>{format_integer(model.max_context_tokens)}</:col>
          <:col :let={model} label="Imported" mono>{format_datetime(model.inserted_at)}</:col>

          <:action :let={model}>
            <span
              :if={Models.available_transitions(model) == []}
              class="text-slate-400 dark:text-slate-500"
            >
              —
            </span>
            <.button
              :for={action <- row_actions(model)}
              variant={action.variant}
              size={:sm}
              phx-click={action.event}
              phx-value-id={model.id}
              phx-disable-with={action.busy_label}
            >
              {action.label}
            </.button>
          </:action>

          <:empty>
            <.state_message id="models-empty-state" kind={:empty} layout={:compact} title="No models imported yet.">
              <:action>
                Use <code class="font-mono bg-slate-100 dark:bg-slate-700 px-1 py-0.5 rounded">orchardctl models import &lt;bundle-path&gt;</code> to add your first model bundle.
              </:action>
            </.state_message>
          </:empty>
        </.table>
      </.card>
    </div>
    """
  end

  # -- Private components --

  attr(:id, :string, required: true)
  attr(:label, :string, required: true)
  attr(:value, :integer, required: true)
  attr(:tone, :atom, values: [:neutral, :info, :success, :warning])

  defp summary_tile(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-lg border px-3 py-2 text-center",
        tile_tone_classes(@tone)
      ]}
    >
      <p class="text-lg font-semibold font-mono">{format_integer(@value)}</p>
      <p class="text-xs text-slate-500 dark:text-slate-400">{@label}</p>
    </div>
    """
  end

  defp tile_tone_classes(:neutral),
    do: "border-slate-200 dark:border-slate-700"

  defp tile_tone_classes(:info),
    do: "border-sky-200 dark:border-sky-800"

  defp tile_tone_classes(:success),
    do: "border-forest-200 dark:border-emerald-800"

  defp tile_tone_classes(:warning),
    do: "border-amber-200 dark:border-amber-800"

  # -- Private helpers --

  defp summary_state_tiles do
    Enum.map(Model.states(), fn state -> {state, state_tone(state)} end)
  end

  defp table_row_class(%{state: :active}),
    do:
      "bg-forest-50/50 hover:bg-forest-100/50 dark:bg-emerald-900/20 dark:hover:bg-emerald-900/30"

  defp table_row_class(_), do: nil

  defp assign_loading_state(socket) do
    assign(socket,
      models_status: :loading,
      models: [],
      models_summary: nil,
      load_error: nil
    )
  end

  defp load_catalog(socket) do
    assign(socket,
      models_status: :ok,
      models: Models.list_models(),
      models_summary: Models.catalog_summary(),
      load_error: nil
    )
  rescue
    _ ->
      assign(socket,
        models_status: :error,
        models: [],
        models_summary: nil,
        load_error: "Model catalog data unavailable."
      )
  end

  defp apply_transition(socket, id, transition_fun, action) do
    case transition_fun.(id) do
      {:ok, model} ->
        socket
        |> put_flash(:info, success_message(action, model))
        |> load_catalog()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Model not found.")
        |> load_catalog()

      {:error, %Changeset{} = changeset} ->
        socket
        |> put_flash(:error, transition_error_message(changeset))
        |> load_catalog()
    end
  rescue
    _ ->
      socket
      |> put_flash(:error, "Model update unavailable.")
      |> load_catalog()
  end

  defp row_actions(model) do
    model
    |> Models.available_transitions()
    |> Enum.map(&action_for_transition/1)
  end

  defp action_for_transition(:active) do
    %{label: "Activate", busy_label: "Activating\u2026", event: "activate", variant: :secondary}
  end

  defp action_for_transition(:deprecated) do
    %{
      label: "Deprecate",
      busy_label: "Deprecating\u2026",
      event: "deprecate",
      variant: :secondary
    }
  end

  defp action_for_transition(:retired) do
    %{label: "Retire", busy_label: "Retiring\u2026", event: "retire", variant: :danger}
  end

  defp state_tone(:active), do: :success
  defp state_tone(:deprecated), do: :warning
  defp state_tone(:registered), do: :info
  defp state_tone(:retired), do: :neutral

  defp format_capabilities([]), do: "\u2014"
  defp format_capabilities(caps) when is_list(caps), do: Enum.join(caps, ", ")
  defp format_capabilities(_), do: "\u2014"

  defp format_integer(nil), do: "\u2014"
  defp format_integer(n) when is_integer(n), do: Integer.to_string(n)

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_datetime(_), do: "\u2014"

  defp success_message(:activate, model), do: "Activated #{display_id(model)}."
  defp success_message(:deprecate, model), do: "Deprecated #{display_id(model)}."
  defp success_message(:retire, model), do: "Retired #{display_id(model)}."

  defp display_id(model), do: "#{model.model_id}@#{model.version}"

  defp transition_error_message(%Changeset{errors: [{:state, {msg, opts}} | _]}) do
    formatted =
      Enum.reduce(opts, msg, fn {key, val}, acc ->
        String.replace(acc, "%{#{key}}", to_string(val))
      end)

    "Unable to update model: #{formatted}"
  end

  defp transition_error_message(_), do: "Unable to update model."
end
