defmodule OrchardConsole.ModelsLive do
  @moduledoc """
  Console models page — full catalog view with lifecycle actions.
  """

  use OrchardConsole, :live_view

  alias Ecto.Changeset
  alias Orchard.Models
  alias Orchard.Models.Model
  alias OrchardConsole.ModelHubDownloadCoordinator

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Catalog", active_nav: :models, page_mode: :wide)
      |> assign_loading_state()

    if connected?(socket) do
      ModelHubDownloadCoordinator.subscribe()
      jobs = Map.new(ModelHubDownloadCoordinator.list_snapshots(), &{&1.key, &1})
      {:ok, socket |> assign(download_jobs: jobs) |> load_catalog()}
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

  def handle_event("delete", %{"id" => id}, socket) do
    {:noreply, apply_delete(socket, id)}
  end

  @impl true
  def handle_info({:model_hub_download, snapshot}, socket) do
    socket =
      assign(socket, download_jobs: Map.put(socket.assigns.download_jobs, snapshot.key, snapshot))

    {:noreply, if(snapshot.status == :completed, do: load_catalog(socket), else: socket)}
  end

  def handle_info({:model_hub_download_removed, key}, socket) do
    {:noreply, assign(socket, download_jobs: Map.delete(socket.assigns.download_jobs, key))}
  end

  @impl true
  def render(%{models_status: :loading} = assigns) do
    ~H"""
    <.models_navigation active={:catalog} />
    <.catalog_activity jobs={@download_jobs} />
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
    <.models_navigation active={:catalog} />
    <.catalog_activity jobs={@download_jobs} />
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
    <.models_navigation active={:catalog} />
    <.catalog_activity jobs={@download_jobs} />
    <div id="models-catalog-card">
      <.card>
        <:title>Imported models</:title>
        <:subtitle>Manage catalog visibility and lifecycle state. Active models still need access authorization and a ready Node before inference.</:subtitle>

        <.metric_grid id="models-summary" class="grid-cols-2 sm:grid-cols-3 xl:grid-cols-5 mb-4">
          <.metric_tile
            id="models-summary-total"
            label="Total"
            value={format_integer(@models_summary.total)}
            tone={:neutral}
            density={:compact}
          />
          <.metric_tile
            :for={{state, tone} <- summary_state_tiles()}
            id={"models-summary-#{state}"}
            label={Phoenix.Naming.humanize(state)}
            value={format_integer(@models_summary.by_state[state] || 0)}
            tone={tone}
            density={:compact}
          />
        </.metric_grid>

        <.table
          id="models-catalog"
          rows={@models}
          row_id={&"model-#{&1.id}"}
          row_class={&table_row_class/1}
        >
          <:col :let={model} label="Model" mono class="break-all">{model.model_id}</:col>
          <:col :let={model} label="Version" mono class="break-all">
            {model.version}
            <details class="mt-2 text-xs">
              <summary class="cursor-pointer text-navy dark:text-sky-400">Bundle SHA-256</summary>
              <span class="block mt-1 break-all">{model.artifact_sha256}</span>
            </details>
          </:col>
          <:col :let={model} label="Catalog state">
            <.badge tone={state_tone(model.state)}>{model.state}</.badge>
          </:col>
          <:col :let={model} label="Format" mono>{model.format}</:col>
          <:col :let={model} label="Capabilities">{format_capabilities(model.capabilities)}</:col>
          <:col :let={model} label="Max Context" mono>{format_integer(model.max_context_tokens)}</:col>
            <:col :let={model} label="Imported" mono><.local_time value={model.inserted_at} format={:datetime_minute} /></:col>

          <:action :let={model}>
            <span
              :if={row_actions(model) == []}
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
                <.link navigate={~p"/console/models/discover"} class="font-medium text-navy dark:text-sky-400 underline">Discover models</.link>
                <p class="mt-2">For an offline bundle, use <code class="font-mono bg-slate-100 dark:bg-slate-700 px-1 py-0.5 rounded">orchardctl models import &lt;bundle-path&gt;</code> to add your first model bundle.</p>
              </:action>
            </.state_message>
          </:empty>
        </.table>
      </.card>
    </div>
    """
  end

  attr(:jobs, :map, required: true)

  defp catalog_activity(assigns) do
    ~H"""
    <section id="catalog-import-activity" class="my-6">
      <.card>
        <:title>Imports</:title>
        <:subtitle>Models you are bringing into the Catalog. Transfer history lasts until this Controller restarts; successfully imported models remain below.</:subtitle>
        <.state_message :if={map_size(@jobs) == 0} id="catalog-imports-empty" kind={:empty} layout={:compact} title="No import activity in this Controller session" body="Discover a model to begin an import. Imported models are listed separately below." />
        <ul :if={map_size(@jobs) > 0} id="catalog-imports-list" class="space-y-3">
          <li :for={{key, job} <- catalog_jobs(@jobs)} class="rounded-lg border border-slate-200 p-4 dark:border-slate-700">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="break-all font-medium">{elem(key, 0)}</p>
                <p class="mt-1 break-all font-mono text-xs text-slate-500 dark:text-slate-400">Revision {elem(key, 1) || "unrecorded"}</p>
              </div>
              <.badge tone={import_status_tone(job.status)}>{import_status_label(job.status)}</.badge>
            </div>
            <p :if={job[:progress]} class="mt-2 text-sm text-slate-600 dark:text-slate-300">{import_bytes(job.progress[:bytes_downloaded])}<span :if={job.status == :cancelled}> transferred before cancellation</span><span :if={job.status != :cancelled}> downloaded</span></p>
            <p :if={job.status == :completed} class="mt-2 text-xs text-slate-500 dark:text-slate-400">Import completed. Catalog state and Node readiness remain separate.</p>
            <.link navigate={catalog_job_path(key)} aria-label={"Open #{elem(key, 0)}, revision #{elem(key, 1) || "unrecorded"}, in Catalog"} class="mt-3 inline-flex items-center gap-2 rounded-md border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:border-slate-600 dark:text-slate-200 dark:focus-visible:ring-sky-400">Open import <.icon name="hero-arrow-left" class="h-4 w-4 rotate-180" /></.link>
          </li>
        </ul>
      </.card>
    </section>
    """
  end

  defp catalog_jobs(jobs) do
    Enum.sort_by(jobs, fn {key, job} ->
      {if(job.status in [:completed, :cancelled, :error], do: 1, else: 0), key}
    end)
  end

  defp catalog_job_path({repo, revision}) do
    "/console/models/catalog/import?" <>
      URI.encode_query(%{"repo" => repo, "revision" => revision || ""})
  end

  defp import_status_label(:error), do: "Failed"
  defp import_status_label(:completed), do: "Imported"
  defp import_status_label(status), do: status |> Atom.to_string() |> Phoenix.Naming.humanize()
  defp import_status_tone(:error), do: :error
  defp import_status_tone(:completed), do: :success
  defp import_status_tone(:paused), do: :warning
  defp import_status_tone(:cancelled), do: :neutral
  defp import_status_tone(_), do: :info

  defp import_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    units = [{"GB", 1_073_741_824}, {"MB", 1_048_576}, {"KB", 1024}]
    {unit, divisor} = Enum.find(units, fn {_, divisor} -> bytes >= divisor end)
    "#{Float.round(bytes / divisor, 1)} #{unit}"
  end

  defp import_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: "#{bytes} bytes"

  defp import_bytes(_), do: "Byte progress unavailable"

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
      download_jobs: %{},
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

  defp apply_delete(socket, id) do
    case Models.delete_model(id) do
      {:ok, model} ->
        socket
        |> put_flash(:info, "Deleted #{display_id(model)}.")
        |> load_catalog()

      {:artifacts_cleanup_failed, model} ->
        socket
        |> put_flash(:error, "Deleted #{display_id(model)}, but artifact cleanup failed.")
        |> load_catalog()

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Model not found.")
        |> load_catalog()

      {:error, :not_retired} ->
        socket
        |> put_flash(:error, "Only retired models can be deleted.")
        |> load_catalog()

      {:error, {:model_in_use, count}} ->
        socket
        |> put_flash(
          :error,
          "Cannot delete: #{count} non-terminal request(s) still reference it."
        )
        |> load_catalog()

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Unable to delete model.")
        |> load_catalog()
    end
  rescue
    _ ->
      socket
      |> put_flash(:error, "Unable to delete model.")
      |> load_catalog()
  end

  defp row_actions(model) do
    transition_actions =
      model
      |> Models.available_transitions()
      |> Enum.map(&action_for_transition/1)

    transition_actions ++ delete_actions(model)
  end

  defp delete_actions(model) do
    if Models.deletable?(model) do
      [%{label: "Delete", busy_label: "Deleting\u2026", event: "delete", variant: :danger}]
    else
      []
    end
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
