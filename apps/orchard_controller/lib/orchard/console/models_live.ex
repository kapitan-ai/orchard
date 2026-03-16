defmodule OrchardConsole.ModelsLive do
  @moduledoc """
  Console models page — full catalog view with lifecycle actions.
  """

  use OrchardConsole, :live_view

  alias Ecto.Changeset
  alias Orchard.Models

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Models", active_nav: :models)
      |> assign_loading_state()

    if connected?(socket) do
      {:ok, load_models(socket)}
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
    <div id="models-loading-card">
      <.card>
        <:title>Model Catalog</:title>
        <p class="text-sm text-slate-500 dark:text-slate-400">
          Loading model catalog\u2026
        </p>
      </.card>
    </div>
    """
  end

  def render(%{models_status: :error} = assigns) do
    ~H"""
    <div id="models-error-card">
      <.card>
        <:title>Models unavailable</:title>
        <p class="text-sm text-slate-500 dark:text-slate-400">
          {@load_error}
        </p>
      </.card>
    </div>
    """
  end

  def render(%{models_status: :ok} = assigns) do
    ~H"""
    <div id="models-catalog-card">
      <.card>
        <:title>Model Catalog</:title>
        <:subtitle>Manage model visibility and lifecycle state.</:subtitle>

        <.table id="models-catalog" rows={@models} row_id={&"model-#{&1.id}"}>
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

          <:empty>No models imported yet.</:empty>
        </.table>
      </.card>
    </div>
    """
  end

  # -- Private helpers --

  defp assign_loading_state(socket) do
    assign(socket,
      models_status: :loading,
      models: [],
      load_error: nil
    )
  end

  defp load_models(socket) do
    assign(socket,
      models_status: :ok,
      models: Models.list_models(),
      load_error: nil
    )
  rescue
    _ ->
      assign(socket,
        models_status: :error,
        models: [],
        load_error: "Model catalog data unavailable."
      )
  end

  defp apply_transition(socket, id, transition_fun, action) do
    case transition_fun.(id) do
      {:ok, model} ->
        socket
        |> put_flash(:info, success_message(action, model))
        |> load_models()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Model not found.")
        |> load_models()

      {:error, %Changeset{} = changeset} ->
        socket
        |> put_flash(:error, transition_error_message(changeset))
        |> load_models()
    end
  rescue
    _ ->
      socket
      |> put_flash(:error, "Model update unavailable.")
      |> load_models()
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
