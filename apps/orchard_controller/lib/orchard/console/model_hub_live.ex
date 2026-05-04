defmodule OrchardConsole.ModelHubLive do
  @moduledoc """
  Console Model Hub page for browsing Hugging Face MLX text-generation models.
  """

  use OrchardConsole, :live_view

  alias OrchardConsole.Redaction
  alias Phoenix.LiveView.JS

  @empty_form %{"query" => ""}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Model Hub", active_nav: :model_hub)
      |> assign_defaults()

    if connected?(socket) do
      download_coordinator_impl().subscribe()
      socket = rehydrate_download(socket)
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

  def handle_event("download_model", _params, socket) do
    OrchardConsole.LicenseGate.guard(socket, fn ->
      handle_download_model(socket)
    end)
  end

  def handle_event("retry_download", _params, socket) do
    OrchardConsole.LicenseGate.guard(socket, fn ->
      handle_retry_download(socket)
    end)
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

          [_first | _rest] = nonempty_results ->
            selected_repo_id =
              pick_selected_repo_id(
                nonempty_results,
                socket.assigns.pending_selected_repo_id
              )

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
           search_error: sanitize_error(error),
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

        socket =
          assign(socket,
            detail_status: :ok,
            model_detail: detail,
            detail_error: nil,
            active_detail_ref: nil,
            active_detail_pid: nil,
            selected_repo_id: detail.repo_id
          )

        # Now that selected_repo_id is known, rehydrate download state
        # for this specific repo when the coordinator has a snapshot.
        socket = maybe_rehydrate_for_repo(socket, detail.repo_id)

        {:noreply, socket}

      {:error, error} ->
        {:noreply,
         assign(socket,
           detail_status: :error,
           model_detail: nil,
           detail_error: sanitize_error(error),
           active_detail_ref: nil,
           active_detail_pid: nil
         )}
    end
  end

  def handle_info({:model_hub, _ref, :detail_finished, _result}, socket), do: {:noreply, socket}

  # Download snapshot from coordinator (PubSub broadcast)

  def handle_info({:model_hub_download, snapshot}, socket) do
    {:noreply, apply_download_snapshot(socket, snapshot)}
  end

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
          <.card max_height="xl:max-h-[calc(100vh-12rem)]">
            <:title>Model Hub</:title>
            <:subtitle>Browse Hugging Face MLX text-generation models from the console.</:subtitle>

            <div class="space-y-4">
              <.form for={@form} id="model-hub-search-form" phx-change="search" phx-submit="search" class="space-y-3">
                <.input
                  field={@form[:query]}
                  id="model-hub-search-input"
                  type="search"
                  label="Search"
                  placeholder="Filter by repo name or author…"
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
                    row_click={fn result -> JS.push("select_model", value: %{repo_id: result.repo_id}) end}
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
                      <.local_time value={result.last_modified} format={:datetime_minute} />
                    </:col>
                    <:col :let={result} label="Access">
                      <.badge tone={access_badge_tone(result.gated)}>
                        {access_badge_label(result.gated)}
                      </.badge>
                    </:col>

                  </.table>
              <% end %>
            </div>
          </.card>
        </div>

        <div id="model-hub-detail-card">
          <.card max_height="xl:max-h-[calc(100vh-12rem)]">
            <:title>Model Details</:title>
            <:subtitle>Normalized repository metadata and file listing.</:subtitle>

            <%= case @detail_status do %>
              <% :idle -> %>
                <.state_message
                  id="model-hub-detail-idle"
                  kind={:empty}
                  layout={:compact}
                    title="Select a model"
                    body="Click a search result to load repository metadata and file listings."
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
                <div id="model-hub-detail-content">
                  <div
                    id="model-hub-detail-sticky-header"
                    class="xl:sticky xl:top-0 xl:z-[5] xl:bg-white xl:dark:bg-slate-800 xl:-mx-6 xl:px-6 xl:pb-4 xl:border-b xl:border-slate-100 xl:dark:border-slate-700/50 space-y-5"
                  >
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

                    <div id="model-hub-download-action" class="flex items-center gap-3">
                      <.button
                        id="model-hub-download-button"
                        variant={:primary}
                        phx-click="download_model"
                        disabled={
                          @model_detail.gated == true or
                            download_busy_for_selected?(
                              @download_status,
                              @visible_download_key,
                              @selected_repo_id
                            )
                        }
                      >
                        Download & Import
                      </.button>
                      <p
                        :if={@model_detail.gated == true}
                        id="model-hub-download-gated-note"
                        class="text-sm text-amber-600 dark:text-amber-400"
                      >
                        This repository is gated on Hugging Face. Console download is unavailable.
                      </p>
                    </div>
                  </div>

                  <div id="model-hub-detail-body" class="space-y-5 pt-5">
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
                        <%= if Map.get(field, :kind) == :local_time do %>
                          <.local_time value={field.value} format={field.format} />
                        <% else %>
                          {field.value}
                        <% end %>
                      </p>
                    </div>
                  </div>

                  <.repository_files_section siblings={@model_detail.siblings} />
                  </div>
                </div>
            <% end %>
          </.card>

          <%!-- Download progress panel (visible during active download) --%>
          <div
            :if={@download_status in [:starting, :downloading, :preparing, :importing]}
            id="model-hub-download-progress"
            class="mt-4 rounded-lg border border-sky-200 bg-sky-50 px-5 py-4 dark:border-sky-800 dark:bg-sky-900/20"
          >
            <div class="space-y-2">
              <div class="flex items-center gap-2">
                <.badge tone={:info}>
                  <span id="model-hub-download-status">{download_status_label(@download_status)}</span>
                </.badge>
                <span
                  :if={@download_progress && @download_progress[:repo_id]}
                  id="model-hub-download-repo-id"
                  class="font-mono text-xs text-slate-700 dark:text-slate-300 break-all"
                >
                  {@download_progress[:repo_id]}
                </span>
              </div>

              <% bar = download_progress_bar(@download_progress) %>
              <div class="flex items-center gap-3">
                <div
                  id="model-hub-download-progress-bar"
                  role="progressbar"
                  aria-label="Model download progress"
                  data-mode={bar.mode}
                  aria-valuemin="0"
                  aria-valuemax="100"
                  aria-valuenow={bar.aria_now}
                  class="flex-1 h-2 rounded-full bg-slate-200 dark:bg-slate-700 overflow-hidden"
                >
                  <div
                    id="model-hub-download-progress-fill"
                    class={[
                      "h-2 rounded-full transition-all duration-300",
                      if(bar.mode == :determinate,
                        do: "bg-sky-500",
                        else: "bg-sky-500/60 w-1/3 animate-pulse"
                      )
                    ]}
                    style={bar.bar_style}
                  />
                </div>
                <span
                  id="model-hub-download-progress-percent"
                  class="text-xs font-medium text-slate-600 dark:text-slate-300 tabular-nums w-16 text-right"
                >
                  {bar.percent_label}
                </span>
              </div>

              <div :if={@download_progress} class="space-y-1 text-sm text-slate-600 dark:text-slate-300">
                <p id="model-hub-download-file-progress">
                  <%= if @download_progress[:total_files] do %>
                    {@download_progress[:files_completed] || 0} of {@download_progress[:total_files]} files
                  <% else %>
                    {@download_progress[:files_completed] || 0} files
                  <% end %>
                </p>
                <p id="model-hub-download-byte-progress">
                  <%= if @download_progress[:total_bytes] && @download_progress[:total_bytes] > 0 do %>
                    {format_bytes(@download_progress[:bytes_downloaded])} of {format_bytes(@download_progress[:total_bytes])}
                  <% else %>
                    {format_bytes(@download_progress[:bytes_downloaded])} downloaded
                  <% end %>
                </p>
                <p
                  id="model-hub-download-current-file"
                  class="font-mono text-xs text-slate-500 dark:text-slate-400 truncate"
                >
                  {if @download_progress[:current_file], do: @download_progress[:current_file], else: "\u2014"}
                </p>
              </div>
            </div>
          </div>

          <%!-- Download success panel --%>
          <div
            :if={@download_status == :completed}
            id="model-hub-download-complete"
            class="mt-4 rounded-lg border border-emerald-200 bg-emerald-50 px-5 py-4 dark:border-emerald-800 dark:bg-emerald-900/20"
          >
            <div class="space-y-2">
              <p class="text-sm font-medium text-emerald-800 dark:text-emerald-200">
                <%= if @download_result[:state] == :active do %>
                  Model is now active.
                <% else %>
                  Model imported successfully.
                <% end %>
              </p>
              <p :if={@download_result} class="text-sm text-slate-600 dark:text-slate-300">
                <span id="model-hub-download-model-id" class="font-mono text-xs">
                  {@download_result[:model_id]}
                </span>
                <span :if={@download_result[:version]} class="text-slate-400 dark:text-slate-500">
                  @
                </span>
                <span
                  :if={@download_result[:version]}
                  id="model-hub-download-version"
                  class="font-mono text-xs"
                >
                  {String.slice(@download_result[:version] || "", 0..11)}
                </span>
              </p>
              <div class="flex flex-wrap items-center gap-3">
                <.link
                  :if={@download_result[:state] == :active}
                  id="model-hub-download-playground-link"
                  navigate={~p"/console/playground"}
                  class="inline-flex items-center rounded-md bg-forest-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-forest-700 dark:bg-emerald-600 dark:hover:bg-emerald-700"
                >
                  Open Playground &rarr;
                </.link>
                <.link
                  id="model-hub-download-models-link"
                  navigate={~p"/console/models"}
                  class="inline-block text-sm font-medium text-forest-600 hover:text-forest-700 dark:text-emerald-400 dark:hover:text-emerald-300"
                >
                  View in Models &rarr;
                </.link>
              </div>
            </div>
          </div>

          <%!-- Download error panel --%>
          <div
            :if={@download_status == :error}
            id="model-hub-download-error"
            class="mt-4 rounded-lg border border-red-200 bg-red-50 px-5 py-4 dark:border-red-800 dark:bg-red-900/20"
          >
            <div class="space-y-2">
              <p class="text-sm font-medium text-red-800 dark:text-red-200">
                {error_title(@download_error, "Model download and import failed.")}
              </p>
              <p
                :if={@download_progress && @download_progress[:repo_id]}
                id="model-hub-download-error-repo"
                class="font-mono text-xs text-red-600 dark:text-red-400 break-all"
              >
                {@download_progress[:repo_id]}
              </p>
              <.button
                id="model-hub-download-retry"
                variant={:secondary}
                size={:sm}
                phx-click="retry_download"
              >
                Try again
              </.button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp handle_download_model(socket) do
    %{assigns: assigns} = socket

    cond do
      assigns.detail_status != :ok ->
        {:noreply, socket}

      assigns.model_detail == nil ->
        {:noreply, socket}

      assigns.model_detail.gated == true ->
        {:noreply, socket}

      download_busy_for_selected?(assigns) ->
        {:noreply, socket}

      true ->
        {:noreply, start_download_via_coordinator(socket, assigns.model_detail.repo_id)}
    end
  end

  defp handle_retry_download(socket) do
    case socket.assigns do
      %{download_status: :error, download_progress: %{repo_id: repo_id}}
      when is_binary(repo_id) and repo_id != "" ->
        {:noreply, start_download_via_coordinator(socket, repo_id)}

      _ ->
        {:noreply, socket}
    end
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
      active_detail_pid: nil,
      # Download state (driven by coordinator snapshots)
      download_status: :idle,
      visible_download_key: nil,
      download_progress: nil,
      download_result: nil,
      download_error: nil
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

  defp start_download_via_coordinator(socket, repo_id) when is_binary(repo_id) do
    case download_coordinator_impl().start_download(repo_id, activate: true) do
      {:ok, snapshot} ->
        apply_download_snapshot(socket, snapshot)

      {:error, {:already_downloading, snapshot}} ->
        apply_download_snapshot(socket, snapshot)

      {:error, snapshot} when is_map(snapshot) ->
        apply_download_snapshot(socket, snapshot)
    end
  end

  defp download_busy_for_selected?(%{
         download_status: status,
         visible_download_key: visible_key,
         selected_repo_id: selected_repo_id
       }) do
    download_busy_for_selected?(status, visible_key, selected_repo_id)
  end

  defp download_busy_for_selected?(status, {repo_id, _revision}, selected_repo_id)
       when is_binary(repo_id) do
    active_download_status?(status) and repo_id == selected_repo_id
  end

  defp download_busy_for_selected?(_status, _visible_key, _selected_repo_id), do: false

  defp active_download_status?(status),
    do: status in [:starting, :downloading, :preparing, :importing]

  defp apply_download_snapshot(socket, %{status: status} = snapshot) do
    key = snapshot[:key]
    visible_key = socket.assigns[:visible_download_key]
    selected_repo_id = socket.assigns[:selected_repo_id]

    # Show this snapshot if:
    # - no download is currently visible
    # - it matches the visible download key
    # - it matches the currently selected repo
    should_apply? =
      visible_key == nil ||
        (key != nil && key == visible_key) ||
        snapshot[:repo_id] == selected_repo_id

    if should_apply? do
      assign(socket,
        download_status: status,
        visible_download_key: key,
        download_progress: snapshot[:progress],
        download_result: snapshot[:result],
        download_error: sanitize_error(snapshot[:error])
      )
    else
      socket
    end
  end

  defp rehydrate_download(socket) do
    case download_coordinator_impl().latest_snapshot() do
      nil -> socket
      snapshot -> apply_download_snapshot(socket, snapshot)
    end
  end

  defp maybe_rehydrate_for_repo(socket, repo_id) do
    case download_coordinator_impl().latest_snapshot_for_repo(repo_id) do
      nil -> socket
      snapshot -> apply_download_snapshot(socket, snapshot)
    end
  end

  defp download_coordinator_impl do
    console_config()[:download_coordinator_impl] || OrchardConsole.ModelHubDownloadCoordinator
  end

  defp download_status_label(:starting), do: "Starting"
  defp download_status_label(:downloading), do: "Downloading"
  defp download_status_label(:preparing), do: "Preparing bundle"
  defp download_status_label(:importing), do: "Importing"
  defp download_status_label(_status), do: "Processing"

  # ---------------------------------------------------------------------------
  # Repository files disclosure
  # ---------------------------------------------------------------------------

  attr(:siblings, :list, required: true)

  defp repository_files_section(%{siblings: []} = assigns) do
    ~H"""
    <div class="space-y-3">
      <div>
        <h3 class="text-sm font-medium text-slate-900 dark:text-slate-100">
          Repository files
        </h3>
        <p class="mt-1 text-sm text-slate-500 dark:text-slate-400">
          File inventory reported by Hugging Face for this repository.
        </p>
      </div>
      <.state_message
        id="model-hub-detail-siblings-empty"
        kind={:empty}
        layout={:compact}
        body="No files reported by Hugging Face."
      />
    </div>
    """
  end

  defp repository_files_section(assigns) do
    summary = build_file_inventory_summary(assigns.siblings)
    assigns = assign(assigns, :summary, summary)

    ~H"""
    <.disclosure_section
      id="model-hub-files-disclosure"
      title="Repository files"
      summary_id="model-hub-files-summary"
    >
      <:summary>
        <span id="model-hub-files-summary-total">{@summary.total_label}</span>
        <span
          :for={group <- @summary.shard_groups}
          class="block text-xs text-slate-400 dark:text-slate-500"
        >
          {group}
        </span>
      </:summary>

      <p class="mb-3 text-sm text-slate-500 dark:text-slate-400">
        File inventory reported by Hugging Face for this repository.
      </p>

      <.table
        id="model-hub-detail-siblings"
        rows={@siblings}
        row_id={fn sibling ->
          "model-hub-detail-file-#{dom_id_fragment(sibling.path)}"
        end}
      >
        <:col :let={sibling} label="Path" class="min-w-[18rem]">
          <span class="font-mono text-xs text-slate-900 break-all dark:text-slate-100">
            {sibling.path}
          </span>
        </:col>
        <:col :let={sibling} label="Size" mono>
          {format_bytes(sibling.size_bytes)}
        </:col>
      </.table>
    </.disclosure_section>
    """
  end

  defp build_file_inventory_summary(siblings) do
    file_count = length(siblings)
    {known_bytes, unknown_count} = sum_sibling_bytes(siblings)

    total_label = format_file_summary(file_count, known_bytes, unknown_count)
    shard_groups = build_safetensors_shard_groups(siblings)

    %{total_label: total_label, shard_groups: shard_groups}
  end

  defp sum_sibling_bytes(siblings) do
    Enum.reduce(siblings, {0, 0}, fn sibling, {bytes, unknown} ->
      case sibling.size_bytes do
        n when is_integer(n) and n > 0 -> {bytes + n, unknown}
        _ -> {bytes, unknown + 1}
      end
    end)
  end

  defp format_file_summary(count, known_bytes, unknown_count) do
    file_word = if count == 1, do: "file", else: "files"

    cond do
      unknown_count == 0 ->
        "#{count} #{file_word} \u2014 #{format_bytes(known_bytes)} total"

      unknown_count == count ->
        "#{count} #{file_word} \u2014 size unavailable"

      true ->
        "#{count} #{file_word} \u2014 at least #{format_bytes(known_bytes)}"
    end
  end

  defp build_safetensors_shard_groups(siblings) do
    siblings
    |> Enum.with_index()
    |> Enum.filter(fn {sibling, _idx} -> safetensors_shard?(sibling.path) end)
    |> Enum.group_by(fn {sibling, _idx} -> safetensors_shard_pattern(sibling.path) end)
    |> Enum.reject(fn {_pattern, members} -> length(members) < 2 end)
    |> Enum.map(fn {pattern, members} ->
      first_index = members |> Enum.map(fn {_s, idx} -> idx end) |> Enum.min()
      shard_count = length(members)

      {known_bytes, unknown_count} =
        Enum.reduce(members, {0, 0}, fn {sibling, _idx}, {bytes, unknown} ->
          case sibling.size_bytes do
            n when is_integer(n) and n > 0 -> {bytes + n, unknown}
            _ -> {bytes, unknown + 1}
          end
        end)

      {first_index, format_shard_group_line(pattern, shard_count, known_bytes, unknown_count)}
    end)
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, label} -> label end)
  end

  @safetensors_shard_regex ~r/-\d+-of-\d+\.safetensors$/

  defp safetensors_shard?(path) when is_binary(path) do
    Regex.match?(@safetensors_shard_regex, path)
  end

  defp safetensors_shard?(_), do: false

  defp safetensors_shard_pattern(path) do
    Regex.replace(@safetensors_shard_regex, path, "-*.safetensors")
  end

  defp format_shard_group_line(pattern, shard_count, known_bytes, unknown_count) do
    shard_word = if shard_count == 1, do: "shard", else: "shards"

    size_part =
      cond do
        unknown_count == 0 -> format_bytes(known_bytes)
        unknown_count == shard_count -> "size unavailable"
        true -> "at least #{format_bytes(known_bytes)}"
      end

    "#{pattern} (#{shard_count} #{shard_word}, #{size_part})"
  end

  defp format_bytes(nil), do: "0\u00a0B"
  defp format_bytes(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes}\u00a0B"

  defp format_bytes(bytes) when is_integer(bytes) do
    {value, unit} =
      cond do
        bytes < 1024 * 1024 -> {bytes / 1024, "KB"}
        bytes < 1024 * 1024 * 1024 -> {bytes / (1024 * 1024), "MB"}
        bytes < 1024 * 1024 * 1024 * 1024 -> {bytes / (1024 * 1024 * 1024), "GB"}
        true -> {bytes / (1024 * 1024 * 1024 * 1024), "TB"}
      end

    "#{:erlang.float_to_binary(value, decimals: 1)}\u00a0#{unit}"
  end

  defp format_bytes(_bytes), do: "0\u00a0B"

  defp format_download_percentage(_downloaded, nil), do: nil
  defp format_download_percentage(_downloaded, 0), do: nil

  defp format_download_percentage(downloaded, total)
       when is_integer(downloaded) and is_integer(total) and total > 0 do
    pct = div(downloaded * 100, total)
    min(pct, 100)
  end

  defp format_download_percentage(_downloaded, _total), do: nil

  defp download_progress_bar(nil) do
    %{mode: :indeterminate, percent_label: "Estimating\u2026", bar_style: nil, aria_now: nil}
  end

  defp download_progress_bar(progress) do
    case format_download_percentage(progress[:bytes_downloaded], progress[:total_bytes]) do
      nil ->
        %{mode: :indeterminate, percent_label: "Estimating\u2026", bar_style: nil, aria_now: nil}

      pct ->
        %{
          mode: :determinate,
          percent_label: "#{pct}%",
          bar_style: "width: #{pct}%",
          aria_now: pct
        }
    end
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

  defp pick_selected_repo_id([_first | _rest] = results, current_repo_id) do
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

  defp sanitize_error(%{} = error), do: Redaction.sanitize_error_map(error)
  defp sanitize_error(_error), do: nil

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

  defp error_title(%{"message" => message}, _fallback) when is_binary(message) and message != "",
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
        label: "Used storage",
        value: format_bytes(detail.used_storage_bytes),
        mono: false
      },
      %{
        id: "updated",
        label: "Last updated",
        kind: :local_time,
        value: detail.last_modified,
        format: :datetime_minute,
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

  defp format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_integer(_value), do: "—"

  defp format_list(values) when is_list(values) do
    case Enum.reject(values, &(&1 in [nil, ""])) do
      [] -> "—"
      filtered -> Enum.join(filtered, ", ")
    end
  end

  defp format_list(_values), do: "—"

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
