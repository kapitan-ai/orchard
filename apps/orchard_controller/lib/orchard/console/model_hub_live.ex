defmodule OrchardConsole.ModelHubLive do
  @moduledoc """
  Console Model Hub page for browsing Hugging Face MLX text-generation models.
  """

  use OrchardConsole, :live_view

  @empty_form %{"query" => ""}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Model Hub", active_nav: :model_hub)
      |> assign_defaults()

    if connected?(socket) do
      {:ok, start_search(socket, "")}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("search", %{"model_hub_search" => %{"query" => raw_query}}, socket) do
    {:noreply, start_search(socket, raw_query)}
  end

  def handle_event("select_model", %{"repo_id" => repo_id}, socket) do
    cond do
      not result_present?(socket.assigns.search_results, repo_id) ->
        {:noreply, socket}

      repo_id == socket.assigns.selected_repo_id and
          socket.assigns.detail_status in [:loading, :ok] ->
        {:noreply, socket}

      true ->
        {:noreply, start_detail(socket, repo_id)}
    end
  end

  @impl true
  def handle_info(
        {:model_hub, ref, :search_finished, result},
        %{assigns: %{active_search_ref: ref}} = socket
      ) do
    case result do
      {:ok, %{results: results}} ->
        results = normalize_search_results(results)

        case results do
          [] ->
            {:noreply,
             socket
             |> assign(
               search_status: :empty,
               search_results: [],
               search_error: nil,
               active_search_ref: nil,
               active_search_pid: nil,
               pending_selected_repo_id: nil
             )
             |> clear_detail()}

          _results ->
            selected_repo_id =
              pick_selected_repo_id(results, socket.assigns.pending_selected_repo_id)

            socket =
              assign(socket,
                search_status: :ok,
                search_results: results,
                search_error: nil,
                active_search_ref: nil,
                active_search_pid: nil,
                pending_selected_repo_id: nil
              )

            {:noreply, start_detail(socket, selected_repo_id)}
        end

      {:error, error} ->
        {:noreply,
         socket
         |> assign(
           search_status: :error,
           search_results: [],
           search_error: error,
           active_search_ref: nil,
           active_search_pid: nil,
           pending_selected_repo_id: nil
         )
         |> clear_detail()}
    end
  end

  def handle_info({:model_hub, _ref, :search_finished, _result}, socket), do: {:noreply, socket}

  def handle_info(
        {:model_hub, ref, :detail_finished, result},
        %{assigns: %{active_detail_ref: ref}} = socket
      ) do
    case result do
      {:ok, detail} ->
        detail = normalize_detail(detail)

        {:noreply,
         assign(socket,
           detail_status: :ok,
           model_detail: detail,
           detail_error: nil,
           active_detail_ref: nil,
           active_detail_pid: nil,
           selected_repo_id: detail.repo_id
         )}

      {:error, error} ->
        {:noreply,
         assign(socket,
           detail_status: :error,
           model_detail: nil,
           detail_error: error,
           active_detail_ref: nil,
           active_detail_pid: nil
         )}
    end
  end

  def handle_info({:model_hub, _ref, :detail_finished, _result}, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    maybe_cancel_task(socket.assigns.active_search_pid)
    maybe_cancel_task(socket.assigns.active_detail_pid)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="grid gap-6 xl:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]">
        <div id="model-hub-search-card">
          <.card>
            <:title>Model Hub</:title>
            <:subtitle>Browse Hugging Face MLX text-generation models from the console.</:subtitle>

            <div class="space-y-4">
              <p id="model-hub-read-only-note" class="text-sm text-slate-600 dark:text-slate-300">
                Read-only in B1. Download and import are deferred to B2/B3.
              </p>

              <.form for={@form} id="model-hub-search-form" phx-change="search" phx-submit="search" class="space-y-3">
                <.input
                  field={@form[:query]}
                  id="model-hub-search-input"
                  type="search"
                  label="Search"
                  placeholder="Filter by repo name or author"
                  phx-debounce="300"
                />
              </.form>

              <%= case @search_status do %>
                <% :loading -> %>
                  <.state_message
                    id="model-hub-results-loading"
                    kind={:loading}
                    layout={:compact}
                    title="Loading Model Hub results…"
                    body={search_loading_body(@search_query)}
                  />
                <% :empty -> %>
                  <.state_message
                    id="model-hub-results-empty"
                    kind={:empty}
                    layout={:compact}
                    title="No matching models found."
                    body={search_empty_body(@search_query)}
                  />
                <% :error -> %>
                  <.state_message
                    id="model-hub-results-error"
                    kind={:error}
                    layout={:compact}
                    title={error_title(@search_error, "Model Hub unavailable.")}
                    body={search_error_body(@search_query)}
                  />
                <% :ok -> %>
                  <.table
                    id="model-hub-results-table"
                    rows={@search_results}
                    row_id={fn result -> "model-hub-result-#{dom_id_fragment(result.repo_id)}" end}
                    row_class={fn result -> result_row_class(result, @selected_repo_id) end}
                  >
                    <:col :let={result} label="Model" class="min-w-[18rem]">
                      <div>
                        <p class="font-mono text-xs text-slate-900 dark:text-slate-100 break-all">
                          {result.repo_id}
                        </p>
                        <p :if={present_text?(result.author)} class="mt-1 text-xs text-slate-500 dark:text-slate-400">
                          {result.author}
                        </p>
                      </div>
                    </:col>
                    <:col :let={result} label="Downloads" mono>
                      {format_integer(result.downloads)}
                    </:col>
                    <:col :let={result} label="Likes" mono>
                      {format_integer(result.likes)}
                    </:col>
                    <:col :let={result} label="Updated">
                      {format_datetime(result.last_modified)}
                    </:col>
                    <:col :let={result} label="Access">
                      <.badge tone={access_badge_tone(result.gated)}>
                        {access_badge_label(result.gated)}
                      </.badge>
                    </:col>
                    <:action :let={result}>
                      <.button
                        id={"model-hub-select-#{dom_id_fragment(result.repo_id)}"}
                        variant={if result.repo_id == @selected_repo_id, do: :primary, else: :secondary}
                        size={:sm}
                        phx-click="select_model"
                        phx-value-repo_id={result.repo_id}
                      >
                        Inspect
                      </.button>
                    </:action>
                  </.table>
              <% end %>
            </div>
          </.card>
        </div>

        <div id="model-hub-detail-card">
          <.card>
            <:title>Model Details</:title>
            <:subtitle>Normalized repository metadata and file listing.</:subtitle>

            <%= case @detail_status do %>
              <% :idle -> %>
                <.state_message
                  id="model-hub-detail-idle"
                  kind={:empty}
                  layout={:compact}
                  title="Select a model to inspect"
                  body="Choose a search result to load repository metadata and file listings."
                />
              <% :loading -> %>
                <.state_message
                  id="model-hub-detail-loading"
                  kind={:loading}
                  layout={:compact}
                  title="Loading model details…"
                  body={detail_loading_body(@selected_repo_id)}
                />
              <% :error -> %>
                <.state_message
                  id="model-hub-detail-error"
                  kind={:error}
                  layout={:compact}
                  title={error_title(@detail_error, "Model details unavailable.")}
                  body={detail_error_body(@selected_repo_id)}
                />
              <% :ok -> %>
                <div id="model-hub-detail-content" class="space-y-5">
                  <div class="flex flex-wrap items-start justify-between gap-3">
                    <div>
                      <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                        Repository
                      </p>
                      <p
                        id="model-hub-detail-repo-id"
                        class="mt-1 font-mono text-sm text-slate-900 break-all dark:text-slate-100"
                      >
                        {@model_detail.repo_id}
                      </p>
                    </div>

                    <.badge tone={access_badge_tone(@model_detail.gated)}>
                      {access_badge_label(@model_detail.gated)}
                    </.badge>
                  </div>

                  <div id="model-hub-detail-metadata" class="grid gap-3 sm:grid-cols-2">
                    <div
                      :for={field <- detail_fields(@model_detail)}
                      id={"model-hub-detail-#{field.id}"}
                      class="rounded-lg border border-slate-200 bg-slate-50 px-4 py-3 dark:border-slate-700 dark:bg-slate-900/40"
                    >
                      <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                        {field.label}
                      </p>
                      <p class={[
                        "mt-1 text-sm text-slate-900 dark:text-slate-100",
                        field.mono && "font-mono text-xs break-all"
                      ]}>
                        {field.value}
                      </p>
                    </div>
                  </div>

                  <div class="space-y-3">
                    <div>
                      <h3 class="text-sm font-medium text-slate-900 dark:text-slate-100">
                        Repository files
                      </h3>
                      <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
                        File inventory reported by Hugging Face for this repository.
                      </p>
                    </div>

                    <.table
                      id="model-hub-detail-siblings"
                      rows={@model_detail.siblings}
                      row_id={fn sibling ->
                        "model-hub-detail-file-#{dom_id_fragment(sibling.path)}"
                      end}
                    >
                      <:col :let={sibling} label="Path" class="min-w-[18rem]">
                        <span class="font-mono text-xs text-slate-900 break-all dark:text-slate-100">
                          {sibling.path}
                        </span>
                      </:col>
                      <:col :let={sibling} label="Size bytes" mono>
                        {format_integer(sibling.size_bytes)}
                      </:col>
                      <:empty>
                        <.state_message
                          id="model-hub-detail-siblings-empty"
                          kind={:empty}
                          layout={:compact}
                          body="No files reported by Hugging Face."
                        />
                      </:empty>
                    </.table>
                  </div>
                </div>
            <% end %>
          </.card>
        </div>
      </div>
    </div>
    """
  end

  defp assign_defaults(socket) do
    assign(socket,
      form: to_form(@empty_form, as: :model_hub_search),
      search_query: "",
      search_status: :loading,
      search_results: [],
      search_error: nil,
      active_search_ref: nil,
      active_search_pid: nil,
      pending_selected_repo_id: nil,
      selected_repo_id: nil,
      detail_status: :idle,
      model_detail: nil,
      detail_error: nil,
      active_detail_ref: nil,
      active_detail_pid: nil
    )
  end

  defp start_search(socket, raw_query) do
    query = normalize_query(raw_query)
    ref = make_ref()
    pending_selected_repo_id = socket.assigns.selected_repo_id

    socket =
      socket
      |> cancel_search()
      |> cancel_detail()
      |> assign(
        form: to_form(%{"query" => query}, as: :model_hub_search),
        search_query: query,
        search_status: :loading,
        search_results: [],
        search_error: nil,
        active_search_ref: ref,
        pending_selected_repo_id: pending_selected_repo_id
      )
      |> clear_detail()

    case model_hub_impl().start_search(self(), ref, search_param(query)) do
      {:ok, pid} ->
        assign(socket, active_search_pid: pid)

      _other ->
        assign(socket,
          search_status: :error,
          search_error: default_error(),
          active_search_ref: nil,
          active_search_pid: nil,
          pending_selected_repo_id: nil
        )
    end
  end

  defp start_detail(socket, repo_id) when is_binary(repo_id) do
    ref = make_ref()

    socket =
      socket
      |> cancel_detail()
      |> assign(
        selected_repo_id: repo_id,
        pending_selected_repo_id: repo_id,
        detail_status: :loading,
        model_detail: nil,
        detail_error: nil,
        active_detail_ref: ref
      )

    case model_hub_impl().start_detail(self(), ref, repo_id) do
      {:ok, pid} ->
        assign(socket, active_detail_pid: pid)

      _other ->
        assign(socket,
          detail_status: :error,
          detail_error: default_error(),
          active_detail_ref: nil,
          active_detail_pid: nil
        )
    end
  end

  defp clear_detail(socket) do
    assign(socket,
      selected_repo_id: nil,
      detail_status: :idle,
      model_detail: nil,
      detail_error: nil,
      active_detail_ref: nil,
      active_detail_pid: nil
    )
  end

  defp cancel_search(socket) do
    maybe_cancel_task(socket.assigns.active_search_pid)

    assign(socket,
      active_search_ref: nil,
      active_search_pid: nil,
      pending_selected_repo_id: nil
    )
  end

  defp cancel_detail(socket) do
    maybe_cancel_task(socket.assigns.active_detail_pid)

    assign(socket,
      active_detail_ref: nil,
      active_detail_pid: nil
    )
  end

  defp maybe_cancel_task(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end
  end

  defp maybe_cancel_task(_pid), do: :ok

  defp search_param(""), do: nil
  defp search_param(query), do: query

  defp normalize_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_query(_query), do: ""

  defp pick_selected_repo_id([], _current_repo_id), do: nil

  defp pick_selected_repo_id(results, current_repo_id) do
    case Enum.find(results, &(&1.repo_id == current_repo_id)) do
      nil -> results |> List.first() |> Map.get(:repo_id)
      result -> result.repo_id
    end
  end

  defp result_present?(results, repo_id), do: Enum.any?(results, &(&1.repo_id == repo_id))

  defp model_hub_impl do
    console_config()[:model_hub_impl] || OrchardConsole.ModelHub
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  defp default_error do
    %{
      status: :error,
      code: "hf_error",
      message: "Hugging Face request failed."
    }
  end

  defp search_loading_body(""), do: "Loading the most-downloaded MLX text-generation models."
  defp search_loading_body(query), do: "Searching Hugging Face for \"#{query}\"."

  defp search_empty_body(""), do: "Try a more specific search once the initial browse completes."
  defp search_empty_body(query), do: "No MLX text-generation models matched \"#{query}\"."

  defp search_error_body(""), do: "Try again in a moment or adjust Hugging Face connectivity."
  defp search_error_body(query), do: "The search for \"#{query}\" could not be completed."

  defp detail_loading_body(nil), do: "Waiting for the selected repository metadata."
  defp detail_loading_body(repo_id), do: "Loading metadata and file inventory for #{repo_id}."

  defp detail_error_body(nil), do: "Select another repository to retry the lookup."
  defp detail_error_body(repo_id), do: "The detail lookup for #{repo_id} did not complete."

  defp error_title(%{message: message}, _fallback) when is_binary(message) and message != "",
    do: message

  defp error_title(_error, fallback), do: fallback

  defp result_row_class(%{repo_id: repo_id}, repo_id) do
    "bg-sky-50/70 hover:bg-sky-100/70 dark:bg-sky-900/20 dark:hover:bg-sky-900/30"
  end

  defp result_row_class(_result, _selected_repo_id), do: nil

  defp access_badge_tone(true), do: :warning
  defp access_badge_tone(false), do: :success

  defp access_badge_label(true), do: "Gated"
  defp access_badge_label(false), do: "Open"

  defp normalize_search_results(results) when is_list(results) do
    results
    |> Enum.map(&normalize_search_result/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_search_results(_results), do: []

  defp normalize_search_result(result) when is_map(result) do
    case detail_get(result, :repo_id) do
      repo_id when is_binary(repo_id) and repo_id != "" ->
        %{
          repo_id: repo_id,
          author: detail_get(result, :author),
          downloads: detail_get(result, :downloads),
          likes: detail_get(result, :likes),
          tags: normalize_list(detail_get(result, :tags)),
          pipeline_tag: detail_get(result, :pipeline_tag),
          library_name: detail_get(result, :library_name),
          used_storage_bytes: detail_get(result, :used_storage_bytes),
          last_modified: detail_get(result, :last_modified),
          gated: detail_get(result, :gated) == true
        }

      _other ->
        nil
    end
  end

  defp normalize_search_result(_result), do: nil

  defp normalize_detail(detail) when is_map(detail) do
    %{
      repo_id: detail_get(detail, :repo_id) || "",
      revision_sha: detail_get(detail, :revision_sha),
      author: detail_get(detail, :author),
      downloads: detail_get(detail, :downloads),
      likes: detail_get(detail, :likes),
      tags: normalize_list(detail_get(detail, :tags)),
      pipeline_tag: detail_get(detail, :pipeline_tag),
      library_name: detail_get(detail, :library_name),
      used_storage_bytes: detail_get(detail, :used_storage_bytes),
      last_modified: detail_get(detail, :last_modified),
      gated: detail_get(detail, :gated) == true,
      metadata_summary: %{
        license: detail_get(detail_get(detail, :metadata_summary), :license),
        languages: normalize_list(detail_get(detail_get(detail, :metadata_summary), :languages)),
        base_models:
          normalize_list(detail_get(detail_get(detail, :metadata_summary), :base_models))
      },
      config_summary: %{
        model_type: detail_get(detail_get(detail, :config_summary), :model_type),
        architectures:
          normalize_list(detail_get(detail_get(detail, :config_summary), :architectures)),
        context_window_tokens:
          detail_get(detail_get(detail, :config_summary), :context_window_tokens),
        quantization_bits: detail_get(detail_get(detail, :config_summary), :quantization_bits)
      },
      siblings: normalize_siblings(detail_get(detail, :siblings))
    }
  end

  defp normalize_detail(_detail), do: normalize_detail(%{})

  defp normalize_list(values) when is_list(values), do: values
  defp normalize_list(_values), do: []

  defp normalize_siblings(values) when is_list(values), do: Enum.map(values, &normalize_sibling/1)
  defp normalize_siblings(_values), do: []

  defp normalize_sibling(sibling) when is_map(sibling) do
    %{
      path: detail_get(sibling, :path) || "",
      size_bytes: detail_get(sibling, :size_bytes)
    }
  end

  defp normalize_sibling(_sibling), do: %{path: "", size_bytes: nil}

  defp detail_get(detail, key) when is_map(detail) do
    Map.get(detail, key, Map.get(detail, Atom.to_string(key)))
  end

  defp detail_get(_detail, _key), do: nil

  defp detail_fields(detail) do
    [
      %{id: "author", label: "Author", value: display_value(detail.author), mono: false},
      %{
        id: "revision",
        label: "Revision SHA",
        value: display_value(detail.revision_sha),
        mono: true
      },
      %{
        id: "downloads",
        label: "Downloads",
        value: format_integer(detail.downloads),
        mono: false
      },
      %{id: "likes", label: "Likes", value: format_integer(detail.likes), mono: false},
      %{
        id: "pipeline",
        label: "Pipeline",
        value: display_value(detail.pipeline_tag),
        mono: false
      },
      %{id: "library", label: "Library", value: display_value(detail.library_name), mono: false},
      %{
        id: "storage",
        label: "Used storage bytes",
        value: format_integer(detail.used_storage_bytes),
        mono: false
      },
      %{
        id: "updated",
        label: "Last updated",
        value: format_datetime(detail.last_modified),
        mono: false
      },
      %{
        id: "license",
        label: "License",
        value: display_value(detail.metadata_summary.license),
        mono: false
      },
      %{
        id: "languages",
        label: "Languages",
        value: format_list(detail.metadata_summary.languages),
        mono: false
      },
      %{
        id: "base-models",
        label: "Base models",
        value: format_list(detail.metadata_summary.base_models),
        mono: false
      },
      %{
        id: "model-type",
        label: "Model type",
        value: display_value(detail.config_summary.model_type),
        mono: false
      },
      %{
        id: "architectures",
        label: "Architectures",
        value: format_list(detail.config_summary.architectures),
        mono: false
      },
      %{
        id: "context-window",
        label: "Context window",
        value: format_integer(detail.config_summary.context_window_tokens),
        mono: false
      },
      %{
        id: "quantization",
        label: "Quantization bits",
        value: format_integer(detail.config_summary.quantization_bits),
        mono: false
      },
      %{id: "tags", label: "Tags", value: format_list(detail.tags), mono: false}
    ]
  end

  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(_value), do: "—"

  defp format_list(values) when is_list(values) do
    case Enum.reject(values, &(&1 in [nil, ""])) do
      [] -> "—"
      filtered -> Enum.join(filtered, ", ")
    end
  end

  defp format_list(_values), do: "—"

  defp format_datetime(nil), do: "—"

  defp format_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
      _other -> value
    end
  end

  defp format_datetime(_value), do: "—"

  defp display_value(value) when value in [nil, ""], do: "—"
  defp display_value(value), do: to_string(value)

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp dom_id_fragment(value) do
    fragment =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> case do
        "" -> "item"
        normalized -> normalized
      end

    suffix =
      :sha256
      |> :crypto.hash(value)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "#{fragment}-#{suffix}"
  end
end
