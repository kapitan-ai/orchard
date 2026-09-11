defmodule OrchardConsole.ModelHubLive do
  @moduledoc """
  Console Model Hub page for browsing Hugging Face MLX text-generation models.
  """

  use OrchardConsole, :live_view

  alias OrchardConsole.ModelHub
  alias OrchardConsole.Redaction
  alias Phoenix.LiveView.AsyncResult
  alias Phoenix.LiveView.JS

  @empty_form %{"query" => ""}

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Discover models", active_nav: :models, page_mode: :wide)
      |> assign_defaults()
      |> assign(catalog_route: socket.assigns[:live_action] == :catalog_job)

    socket =
      if socket.assigns.catalog_route,
        do: assign(socket, journey_step: :catalog, page_title: "Catalog"),
        else: socket

    if connected?(socket) do
      download_coordinator_impl().subscribe()
      socket = rehydrate_download(socket)

      {:ok, load_model_destination(socket, params)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("search", %{"model_hub_search" => %{"query" => raw_query}}, socket) do
    {:noreply, start_search(socket, raw_query)}
  end

  def handle_event("retry_search", _params, socket) do
    pending_selected_repo_id =
      socket.assigns.pending_selected_repo_id || socket.assigns.selected_repo_id

    socket =
      socket
      |> start_search(socket.assigns.search_query)
      |> assign(pending_selected_repo_id: pending_selected_repo_id)

    {:noreply, socket}
  end

  def handle_event("refresh_failed_revision", _params, socket) do
    case socket.assigns do
      %{
        download_status: :error,
        download_error: error,
        visible_download_key: {repo_id, _revision}
      }
      when is_binary(repo_id) and repo_id != "" ->
        if revision_changed?(error) do
          {:noreply, refresh_revision_destination(socket, repo_id)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, start_search(socket, "")}
  end

  def handle_event("clear_filter", _params, socket) do
    {:noreply, assign(socket, capability_filter: "all")}
  end

  def handle_event("filter_capability", %{"capability" => capability}, socket) do
    if capability in capability_options(socket.assigns.search_results) do
      socket = assign(socket, capability_filter: capability)
      visible = filter_results(socket.assigns.search_results, capability)

      socket =
        if result_present?(visible, socket.assigns.selected_repo_id),
          do: socket,
          else: socket |> cancel_detail() |> clear_detail()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_model", %{"repo_id" => repo_id}, socket) do
    cond do
      not result_present?(
        filter_results(socket.assigns.search_results, socket.assigns.capability_filter),
        repo_id
      ) ->
        {:noreply, socket}

      repo_id == socket.assigns.selected_repo_id and
          socket.assigns.detail_status in [:loading, :ok] ->
        {:noreply, socket}

      true ->
        {:noreply, start_detail(socket, repo_id)}
    end
  end

  def handle_event("open_catalog", %{"repo_id" => repo_id}, socket) do
    if result_present?(
         filter_results(socket.assigns.search_results, socket.assigns.capability_filter),
         repo_id
       ) do
      socket =
        if repo_id == socket.assigns.selected_repo_id and
             socket.assigns.detail_status in [:loading, :ok],
           do: socket,
           else: start_detail(socket, repo_id)

      {:noreply, assign(socket, journey_step: :catalog, page_title: "Catalog")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("back_to_discover", _params, %{assigns: %{catalog_route: true}} = socket) do
    {:noreply, push_navigate(socket, to: ~p"/console/models")}
  end

  def handle_event("back_to_discover", _params, socket) do
    {:noreply, restore_discovery(socket)}
  end

  def handle_event("toggle_downloads", _params, socket) do
    {:noreply, assign(socket, downloads_expanded: not socket.assigns.downloads_expanded)}
  end

  def handle_event("view_download", %{"repo_id" => repo} = params, socket) do
    key = held_download_key(socket.assigns.download_jobs, repo, Map.get(params, "revision", ""))

    case Map.get(socket.assigns.download_jobs, key) do
      nil ->
        {:noreply, socket}

      snapshot ->
        {:noreply, open_download_catalog(socket, snapshot)}
    end
  end

  def handle_event("restart_download", %{"repo_id" => repo} = params, socket) do
    key = held_download_key(socket.assigns.download_jobs, repo, Map.get(params, "revision", ""))

    case Map.get(socket.assigns.download_jobs, key) do
      %{status: :cancelled, key: {repo_id, revision}} = snapshot
      when is_binary(revision) and revision != "" ->
        {:noreply,
         start_download_via_coordinator(
           socket,
           repo_id,
           revision,
           Map.get(snapshot, :catalog_version)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_download", %{"repo_id" => repo} = params, socket) do
    key = held_download_key(socket.assigns.download_jobs, repo, Map.get(params, "revision", ""))

    case Map.get(socket.assigns.download_jobs, key) do
      %{status: status} when status in [:completed, :error, :cancelled] ->
        {:noreply,
         remove_download_result(socket, key, download_coordinator_impl().remove_download(key))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "control_download",
        %{"repo_id" => repo, "action" => action} = params,
        socket
      ) do
    command = %{"pause" => :pause, "resume" => :resume, "cancel" => :cancel}[action]
    key = held_download_key(socket.assigns.download_jobs, repo, Map.get(params, "revision", ""))

    case Map.get(socket.assigns.download_jobs, key) do
      %{status: status} when not is_nil(command) ->
        {:noreply, control_known_download(socket, key, command, status)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("download_model", _params, socket) do
    handle_download_model(socket)
  end

  def handle_event("repair_model", %{"model_hub_repair" => params}, socket) do
    handle_repair_model(socket, Map.get(params, "catalog_version"))
  end

  def handle_event("repair_model", _params, socket), do: {:noreply, socket}

  def handle_event("retry_download", _params, socket) do
    handle_retry_download(socket)
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
           active_search_pid: nil
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
        {socket, detail} = detail_for_open_download(socket, normalize_detail(detail))

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
        socket =
          if socket.assigns.opened_download_key,
            do: socket,
            else: maybe_rehydrate_for_repo(socket, detail.repo_id, detail.revision_sha)

        {:noreply, socket}

      {:error, error} ->
        {:noreply, detail_lookup_failed(socket, error)}
    end
  end

  def handle_info({:model_hub, _ref, :detail_finished, _result}, socket), do: {:noreply, socket}

  # Download snapshot from coordinator (PubSub broadcast)

  def handle_info({:model_hub_download_removed, key}, socket) do
    {:noreply, remove_download_snapshot(socket, key)}
  end

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
    assigns =
      assign(
        assigns,
        :visible_results,
        filter_results(assigns.search_results, assigns.capability_filter)
      )

    assigns = assign(assigns, :inline_download?, inline_download?(assigns))

    assigns =
      assign(
        assigns,
        :job_detail?,
        assigns.journey_step == :catalog and
          (assigns.inline_download? or not is_nil(assigns.opened_download_key))
      )

    ~H"""
    <div class="space-y-6 pb-6">
    <.models_navigation active={if @journey_step == :catalog, do: :catalog, else: :discover} />
    <span :if={@removal_focus_target} id={"model-hub-removal-focus-#{@removal_focus_sequence}"} aria-hidden="true" class="hidden" phx-mounted={JS.focus(to: @removal_focus_target)} />
    <h2 :if={@focus_discovery_after_removal} id="model-hub-removed-return-heading" tabindex="-1" phx-mounted={JS.focus()} class="text-xl font-semibold">Discover models</h2>
    <section :if={map_size(@download_jobs) > 0} id="model-hub-downloads" aria-label="Downloads" class="sticky top-0 z-20 rounded-lg border border-slate-200 bg-white p-3 shadow-sm dark:border-slate-700 dark:bg-slate-800">
    <button id="model-hub-toggle-downloads" type="button" phx-click="toggle_downloads" aria-expanded={to_string(@downloads_expanded)} aria-controls="model-hub-download-list" class="flex w-full flex-wrap items-center gap-2 rounded-md text-sm font-medium focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:focus-visible:ring-sky-400">
    <.icon name="hero-inbox" class="h-4 w-4" /> Downloads
    <span class="text-xs text-slate-500 dark:text-slate-400">{download_count(@download_jobs, :running)} running · {download_count(@download_jobs, :paused)} paused · {map_size(@download_jobs)} total</span>
    <span class="ml-auto">{if @downloads_expanded, do: "Minimize", else: "Show"}</span>
    </button>
    <p :if={@download_control_error} role="alert" class="mb-2 text-sm text-red-600 dark:text-red-400">{@download_control_error}</p>
    <div id="model-hub-download-list" hidden={not @downloads_expanded} class="max-h-[50vh] overflow-y-auto pt-3">
    <p class="mb-3 text-xs text-slate-500 dark:text-slate-400">Pause keeps partial files on disk. Download controls and history are available until the Controller restarts.</p>
    <p id="model-hub-download-bytes" class="mb-3 text-xs text-slate-500 dark:text-slate-400">Known downloaded bytes in unfinished jobs: {format_bytes(unfinished_download_bytes(@download_jobs))}. This is a progress estimate, not available disk space.</p>
    <ul class="space-y-3">
      <li :for={{key, job} <- ordered_downloads(@download_jobs)} class="rounded-md border border-slate-200 p-3 dark:border-slate-700">
        <p class="break-all text-sm font-medium">{elem(key, 0)}</p>
        <p class="break-all font-mono text-xs text-slate-500 dark:text-slate-400">Revision {elem(key, 1)}</p>
        <p class="my-2 text-sm">{download_status_label(job.status)} · {format_bytes((job[:progress] || %{})[:bytes_downloaded])}<span :if={job.status == :cancelled}> transferred before cancellation</span><span :if={job.status != :cancelled and (job[:progress] || %{})[:total_bytes]}> of {format_bytes(job.progress.total_bytes)}</span></p>
        <.download_controls :if={@visible_download_key != key or @inline_download?} key={key} status={job.status} />
        <.button size={:sm} variant={:secondary} phx-click={JS.push_focus() |> JS.push("view_download") |> JS.focus(to: "#model-hub-catalog-heading")} phx-value-repo_id={elem(key, 0)} phx-value-revision={to_string(elem(key, 1))} aria-label={"Open Catalog for #{elem(key, 0)}, revision #{elem(key, 1) || "unrecorded"}"}>Open Catalog <.icon name="hero-arrow-left" class="h-4 w-4 rotate-180" /></.button>
        <div :if={@visible_download_key == key and @downloads_expanded} class="mt-2">
          <p :if={job[:error]} class="text-sm text-red-600 dark:text-red-400">{error_title(sanitize_error(job.error), "Download failed.")}</p>
          <p class="break-all text-xs">{(job[:progress] || %{})[:current_file]}</p>
    <p class="text-xs">{(job[:progress] || %{})[:files_completed] || 0} files complete</p>
    <.link :if={job.status == :completed and job[:result]} navigate={catalog_result_path(job.result)} class="text-sm text-navy underline dark:text-sky-400">View in Catalog</.link>
          <p :if={job[:status] == :cancelled} class="text-xs">Download stopped. Partial files removed.</p>
        </div>
      </li>
    </ul>
    <.download_panel :if={not @inline_download?} {assigns} />
    </div>
    </section>

    <nav id="model-hub-journey-stepper" aria-label="Model setup: 6 steps" class="rounded-lg border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
      <p class="mb-3 text-xs text-slate-500 dark:text-slate-400">Step {if @journey_step == :discover, do: 1, else: 2} of 6</p>
      <ol class="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6">
        <li :for={{step, label, index} <- [{:discover, "Discover models", 1}, {:catalog, "Catalog", 2}, {:access, "Access", 3}, {:placement, "Placement", 4}, {:acquire, "Acquire", 5}, {:inference, "Test inference", 6}]} aria-current={if @journey_step == step, do: "step"} class="min-w-0">
          <span aria-disabled={if index > 2, do: "true"} title={if index > 2, do: "Future step - not available in this build"} class={["flex items-center gap-2 text-xs", index > 2 && "opacity-45", @journey_step == step && "font-semibold text-navy dark:text-sky-400"]}>
            <span class={["flex h-7 w-7 shrink-0 items-center justify-center rounded-full border", if(@journey_step == step, do: "border-navy bg-navy text-white dark:border-sky-400 dark:bg-sky-400 dark:text-slate-900", else: "border-slate-300 text-slate-500 dark:border-slate-600 dark:text-slate-400")]}>{index}</span>
            <span>{label}</span>
          </span>
        </li>
      </ol>
      <p class="mt-3 text-xs text-slate-500 dark:text-slate-400">Access through Test inference are future steps in this build.</p>
    </nav>

    <div :if={@journey_step == :catalog} id="model-hub-catalog-header" class="space-y-3">
    <.button id="model-hub-back-to-discover" variant={:ghost} size={:sm} phx-click={JS.push("back_to_discover") |> JS.pop_focus()}>
    <.icon name="hero-arrow-left" class="h-4 w-4" /> {if @catalog_route, do: "Back to Catalog", else: "Back to Discover"}
    </.button>
    <h2 id="model-hub-catalog-heading" tabindex="-1" phx-mounted={JS.focus()} class="text-xl font-semibold text-slate-900 dark:text-slate-100">{catalog_heading(@job_detail?, @download_status)}</h2>
    <p class="text-sm text-slate-600 dark:text-slate-300">{if @job_detail?, do: "Review this import’s recorded identity, status, and available actions.", else: "Import the exact revision you selected. Access, Node placement, and inference readiness remain separate."}</p>
    <p :if={not @job_detail? or (active_download_status?(@download_status) and @download_status not in [:paused, :pausing])} class="text-xs text-slate-500 dark:text-slate-400">An active import continues when you leave this page.</p>
    <p :if={@job_detail? and @download_status == :paused} class="text-xs text-slate-500 dark:text-slate-400">This download stays paused when you leave this page.</p>
    </div>
    <div class={["grid gap-6", @journey_step == :discover && "xl:grid-cols-[minmax(0,2fr)_minmax(0,3fr)]"]}>
        <div id="model-hub-search-card" hidden={@journey_step == :catalog}>
          <.card max_height="xl:max-h-[calc(100vh-12rem)]">
            <:title>Discover models</:title>
            <:subtitle>Browse Hugging Face MLX text-generation models from the console.</:subtitle>

            <div id="model-hub-node-context" class="mb-4 rounded-md border border-slate-200 p-3 text-sm dark:border-slate-700">
              <p class="font-medium">Your Nodes</p>
              <%= cond do %>
                <% @node_inventory.ok? -> %>
                  <%= if @node_inventory.result == [] do %>
                    <p>No Nodes registered. Model fit cannot be assessed yet.</p>
                  <% else %>
                    <p>{length(@node_inventory.result)} Nodes in this installation</p>
                    <ul class="mt-2 space-y-1 text-xs">
                      <li :for={node <- @node_inventory.result}>{node.display_name} · {node.state} · {Map.get(node.capabilities, "worker_backend", "Backend unknown")}</li>
                    </ul>
                    <p class="mt-2 text-xs">Hardware memory and exact model requirements are not available for a fit assessment.</p>
                  <% end %>
                <% @node_inventory.failed -> %>
                  <p>Node inventory unavailable. Compatibility has not been checked.</p>
                <% true -> %>
                  <p>Checking Node inventory…</p>
              <% end %>
              <.link navigate="/console/nodes" class="mt-2 inline-block text-xs text-navy underline dark:text-sky-400">View Nodes</.link>
            </div>

            <div class="space-y-4">
              <.form for={@form} id="model-hub-search-form" phx-change="search" phx-submit="search" class="space-y-3">
                <.input
                  field={@form[:query]}
                  id="model-hub-search-input"
                  type="search"
                  label="Search"
                  size={:lg}
                  placeholder="Search by repository name or author…"
                  phx-debounce="300"
                />
              </.form>

              <div class="flex flex-wrap gap-2">
                <.button :if={@search_query != ""} id="model-hub-clear-search" variant={:ghost} size={:sm} phx-click="clear_search">Clear search</.button>
                <.button id="model-hub-retry-search" variant={:secondary} size={:sm} phx-click="retry_search" disabled={@search_status == :loading}>
                  {if @search_status == :error, do: "Retry search", else: "Refresh results"}
                </.button>
              </div>
              <fieldset :if={@search_status == :ok} id="model-hub-capability-filters" class="space-y-2">
                <legend class="text-sm font-medium text-slate-700 dark:text-slate-300">Filter these results by capability</legend>
                <div class="flex flex-wrap gap-2">
                  <.button
                    :for={capability <- capability_options(@search_results)}
                    variant={if @capability_filter == capability, do: :primary, else: :secondary}
                    size={:sm}
                    phx-click="filter_capability"
                    phx-value-capability={capability}
                    aria-pressed={to_string(@capability_filter == capability)}
                  >
                    {capability_label(capability)}
                  </.button>
                </div>
                <p class="text-xs text-slate-500 dark:text-slate-400">Provider-reported capabilities for these results, not verified runtime support.</p>
              </fieldset>

              <%= case @search_status do %>
                <% :loading -> %>
                  <.state_message
                    id="model-hub-results-loading"
                    kind={:loading}
                    layout={:compact}
                    title="Loading models…"
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
                    title={error_title(@search_error, "Model discovery unavailable.")}
                    body={search_error_body(@search_query)}
                  />
                <% :ok -> %>
                  <div id="model-hub-results-table" role="list" aria-label="Provider results" class="space-y-3">
                    <div
                      :for={result <- @visible_results}
                      id={"model-hub-result-#{dom_id_fragment(result.repo_id)}"}
                      role="listitem"
                      class={["rounded-md border border-slate-200 dark:border-slate-700 p-3 space-y-3", result_row_class(result, @selected_repo_id)]}
                    >
                      <button
                        type="button"
                        class="block w-full rounded-md text-left space-y-3 cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy/40 dark:focus-visible:ring-sky-400/40"
                        phx-click="select_model"
                        phx-value-repo_id={result.repo_id}
                        aria-label={"Select " <> result.repo_id}
                        aria-pressed={to_string(result.repo_id == @selected_repo_id)}
                      >
                      <span class="flex items-start gap-3">
                        <span class="flex h-10 w-10 shrink-0 items-center justify-center rounded-md bg-slate-100 text-navy dark:bg-slate-900/60 dark:text-sky-400"><.icon name="hero-cube-transparent" class="h-6 w-6" /></span>
                        <span class="min-w-0">
                          <span class="block text-xs text-slate-500 dark:text-slate-400 break-all">{result_publisher(result.repo_id)}</span>
                          <span class="block text-sm font-semibold text-slate-900 dark:text-slate-100 break-all">{result_name(result.repo_id)}</span>
                        </span>
                      </span>
                      <span class="flex flex-wrap items-center gap-2 text-xs text-slate-600 dark:text-slate-300">
                        <span class="inline-flex items-center gap-1"><.icon name="hero-document-text" class="h-4 w-4" />{capability_label(result_capability(result))}</span>
                        <.badge tone={access_badge_tone(result.gated)}>{access_badge_label(result.gated)}</.badge>
                        <.badge :if={Map.get(result, :library_name)} tone={:neutral}>{result.library_name}</.badge>
                        <span :if={Map.get(result, :safetensors_total)} title="Provider-reported stored tensor count; quantized storage may differ from the model's architectural parameter count"><span class="font-mono">{compact_count(result.safetensors_total)}</span> stored parameters</span>
                      </span>
                      <span class="flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-slate-500 dark:text-slate-400">
                        <span class="inline-flex items-center gap-1"><.icon name="hero-inbox" class="h-4 w-4" /><span class="font-mono">{format_integer(result.downloads)}</span> downloads</span>
                        <span class="inline-flex items-center gap-1"><.icon name="hero-heart" class="h-4 w-4" /><span class="font-mono">{format_integer(result.likes)}</span> likes</span>
                      </span>
                      <span class="flex items-center gap-1 text-xs text-slate-500 dark:text-slate-400"><.icon name="hero-arrow-path" class="h-4 w-4" /><%= if result.last_modified do %>Updated <.local_time value={result.last_modified} format={:datetime_minute} /><% else %>Update date unavailable<% end %></span>
                      <span :if={result.repo_id == @selected_repo_id} class="flex items-center gap-1 text-xs font-medium text-navy dark:text-sky-400"><.icon name="hero-check" class="h-4 w-4" />Selected</span>
                      <span class="block text-xs text-slate-600 dark:text-slate-300" title="Provider metadata alone does not prove runtime support or memory fit on a Node.">
                        <%= if @node_inventory.ok? and @node_inventory.result == [] do %>Node fit: no Nodes registered<% else %>Node fit: not verified<% end %>
                      </span>
                      </button>
                      <.button variant={:secondary} size={:sm} phx-click={JS.push_focus() |> JS.push("open_catalog", value: %{repo_id: result.repo_id})} aria-label={"Import " <> result.repo_id}>
                        Import
                      </.button>
                    </div>
                    <.state_message :if={@visible_results == []} id="model-hub-filter-empty" kind={:empty} layout={:compact} title="No results match this filter.">
                      <:action><.button variant={:secondary} size={:sm} phx-click="clear_filter">Clear capability filter</.button></:action>
                    </.state_message>
                  </div>
              <% end %>
            </div>
          </.card>
        </div>

        <div id="model-hub-detail-card" role="region" aria-label={if @journey_step == :catalog, do: "Catalog import", else: "Model details"} tabindex="-1" class="scroll-mt-6">
          <.card max_height={if @journey_step == :discover, do: "xl:max-h-[calc(100vh-12rem)]", else: nil}>
            <:title><span id="model-hub-import-heading" tabindex="-1" class="scroll-mt-6">{cond do @job_detail? -> import_detail_title(@download_status); @journey_step == :catalog -> "Import model"; true -> "Model details" end}</span></:title>
            <:subtitle>{cond do @job_detail? -> "Recorded repository and revision for this import."; @journey_step == :catalog -> "Check the exact revision, then import it into your catalog."; true -> "Inspect provider information before choosing Import." end}</:subtitle>


            <%= case @detail_status do %>
              <% :idle -> %>
                <.state_message
                  id="model-hub-detail-idle"
                  kind={:empty}
                  layout={:compact}
                    title="Select a model"
                    body="Select a search result to inspect its repository and revision."
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

                      <.badge :if={is_nil(@opened_download_note)} tone={access_badge_tone(@model_detail.gated)}>
                        {access_badge_label(@model_detail.gated)}
                      </.badge>
                    </div>

                    <p class="text-xs text-slate-600 dark:text-slate-300 break-all">
                      Selected revision: <span class="font-mono">{@model_detail.revision_sha || "Unavailable"}</span>
                    </p>
    <.button :if={@journey_step == :discover} id="model-hub-open-catalog" variant={:primary} phx-click={JS.push_focus() |> JS.push("open_catalog", value: %{repo_id: @model_detail.repo_id})}>
    Import
    </.button>
    <p :if={@journey_step == :catalog and is_nil(@opened_download_note)} id="model-hub-import-storage" class="text-xs text-slate-600 dark:text-slate-300">
      Provider repository storage: <span class="font-mono">{format_bytes(@model_detail.used_storage_bytes)}</span>.
      Actual download size may differ.
    </p>
    <div :if={@journey_step == :catalog and is_nil(@opened_download_key)} id="model-hub-download-action" class="flex flex-wrap items-center gap-3">
                      <.button
                        id="model-hub-download-button"
                        variant={:primary}
                        phx-click="download_model"
                        disabled={
                          @model_detail.gated == true or not present_text?(@model_detail.revision_sha) or
                            download_busy_for_selected?(@download_jobs, @selected_repo_id) or
                            revision_refresh_required_for_selected?(
                              @download_status,
                              @download_error,
                              @visible_download_key,
                              @model_detail
                            )
                        }
                      >
                        Import this revision
                      </.button>
                      <p
                        :if={@model_detail.gated == true}
                        id="model-hub-download-gated-note"
                        class="text-sm text-amber-600 dark:text-amber-400"
                      >
                        This repository is gated on Hugging Face. Console download is unavailable.
                      </p>
                    </div>

                    <.form
                      :if={@journey_step == :catalog and is_nil(@opened_download_key)}
                      for={@repair_form}
                      id="model-hub-repair-form"
                      phx-submit="repair_model"
                      class="mt-5 space-y-3 border-t border-slate-200 pt-5 dark:border-slate-700"
                    >
                      <.input
                        field={@repair_form[:catalog_version]}
                        id="model-hub-repair-catalog-version"
                        type="text"
                        label="Repair as new Catalog version"
                        placeholder="source-revision-tool-admission"
                        autocomplete="off"
                        required
                      />
                      <div class="flex flex-wrap items-center gap-3">
                        <.button
                          id="model-hub-repair-button"
                          variant={:secondary}
                          type="submit"
                          disabled={
                            @model_detail.gated == true or
                              not present_text?(@model_detail.revision_sha) or
                              download_busy_for_selected?(@download_jobs, @selected_repo_id) or
                              revision_refresh_required_for_selected?(
                                @download_status,
                                @download_error,
                                @visible_download_key,
                                @model_detail
                              )
                          }
                        >
                          Import repair version
                        </.button>
                        <p id="model-hub-repair-note" class="text-xs text-slate-600 dark:text-slate-300">
                          Reimports this exact source revision under a distinct Catalog version. It does not alter an existing Catalog record or establish runtime qualification.
                        </p>
                      </div>
                    </.form>
                  </div>

                  <p :if={@opened_download_note} id="model-hub-opened-download-note" role="status" class="mt-4 text-sm text-slate-600 dark:text-slate-300">{@opened_download_note}</p>
                  <p class="mt-4 text-sm text-slate-600 dark:text-slate-300">
                    {if @job_detail?, do: "Catalog presence does not establish access authorization, Node placement, or inference readiness.", else: "Import downloads this revision and registers it in Catalog. Activate it from Catalog before granting access. Node placement and inference readiness are separate."}
                  </p>
                  <p :if={not present_text?(@model_detail.revision_sha)} id="model-hub-revision-unavailable" class="mt-2 text-sm text-amber-600 dark:text-amber-400">
                    The provider has not supplied a revision. Refresh the search before importing.
                  </p>

    <.download_panel :if={@inline_download?} {assigns} />
    <details :if={is_nil(@opened_download_note)} id="model-hub-detail-body" open={@journey_step == :discover} class="space-y-5 pt-5">
    <summary class={if @journey_step == :discover, do: "hidden", else: "cursor-pointer rounded-md text-sm font-medium text-navy dark:text-sky-400 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:focus-visible:ring-sky-400 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-slate-800"}>Provider details and files</summary>
                    <.detail_grid id="model-hub-detail-metadata" class="sm:grid-cols-2">
                      <.detail_field
                        :for={field <- metadata_fields(@model_detail)}
                        id={"model-hub-detail-#{field.id}"}
                        label={field.label}
                        mono={field.mono}
                        break_all={field.mono}
                      >
                        <%= if Map.get(field, :kind) == :local_time do %>
                          <.local_time value={field.value} format={field.format} />
                        <% else %>
                          {field.value}
                        <% end %>
                      </.detail_field>
                    </.detail_grid>

                    <.repository_files_section siblings={@model_detail.siblings} />
                  </details>
                </div>
            <% end %>
          </.card>

        </div>
      </div>
    </div>
    """
  end

  defp remove_download_result(socket, key, :ok) do
    socket = remove_download_snapshot(socket, key)

    focus_target =
      cond do
        map_size(socket.assigns.download_jobs) > 0 -> "#model-hub-toggle-downloads"
        socket.assigns.journey_step == :catalog -> "#model-hub-catalog-heading"
        true -> "#model-hub-removed-return-heading"
      end

    assign(socket,
      removal_focus_target: focus_target,
      removal_focus_sequence: socket.assigns.removal_focus_sequence + 1,
      focus_discovery_after_removal: focus_target == "#model-hub-removed-return-heading"
    )
  end

  defp remove_download_result(socket, key, {:error, _reason}) do
    apply_control_result(socket, key, {:error, :not_available})
  end

  defp remove_download_snapshot(socket, key) do
    opened? = socket.assigns.opened_download_key == key
    socket = if opened?, do: restore_discovery(socket), else: socket
    socket = assign(socket, download_jobs: Map.delete(socket.assigns.download_jobs, key))
    clear_visible_download_snapshot(socket, key)
  end

  defp refresh_revision_destination(%{assigns: %{catalog_route: true}} = socket, repo_id) do
    push_navigate(socket,
      to: "/console/models/discover?" <> URI.encode_query(%{"query" => repo_id})
    )
  end

  defp refresh_revision_destination(socket, repo_id) do
    socket
    |> start_search(repo_id)
    |> assign(
      opened_download_key: nil,
      opened_download_note: nil,
      discovery_return: nil,
      pending_selected_repo_id: repo_id,
      journey_step: :discover,
      page_title: "Discover models"
    )
  end

  defp load_model_destination(%{assigns: %{catalog_route: true}} = socket, params) do
    open_catalog_route(socket, params)
  end

  defp load_model_destination(socket, params) do
    socket
    |> assign_async(:node_inventory, fn ->
      {:ok, %{node_inventory: Orchard.Nodes.list_nodes_for_upgrade!()}}
    end)
    |> start_search(Map.get(params, "query", ""))
  end

  defp open_catalog_route(socket, params) do
    key =
      held_download_key(
        socket.assigns.download_jobs,
        Map.get(params, "repo"),
        Map.get(params, "revision", "")
      )

    case Map.get(socket.assigns.download_jobs, key) do
      nil ->
        assign(socket,
          detail_status: :error,
          detail_error: %{
            message:
              "This import is no longer in this Controller session. Return to Catalog for current imports and stored models."
          }
        )

      snapshot ->
        open_download_catalog(socket, snapshot)
    end
  end

  defp open_download_catalog(socket, snapshot) do
    return_state =
      socket.assigns.discovery_return ||
        Map.take(socket.assigns, [
          :search_status,
          :search_query,
          :search_results,
          :search_error,
          :form,
          :capability_filter,
          :selected_repo_id,
          :pending_selected_repo_id,
          :detail_status,
          :model_detail,
          :detail_error
        ])

    {repo, revision} = snapshot.key

    socket
    |> cancel_search()
    |> start_detail(repo)
    |> assign(
      removal_focus_target: nil,
      focus_discovery_after_removal: false,
      discovery_return: return_state,
      opened_download_key: snapshot.key,
      opened_download_note: "Loading provider details for the recorded download revision.",
      visible_download_key: snapshot.key,
      journey_step: :catalog,
      page_title: "Catalog",
      downloads_expanded: false,
      detail_status: :ok,
      model_detail: normalize_detail(%{repo_id: repo, revision_sha: revision})
    )
    |> apply_download_snapshot(snapshot)
    |> ensure_open_detail_state()
  end

  defp ensure_open_detail_state(%{assigns: %{active_detail_ref: nil}} = socket) do
    detail_lookup_failed(socket, nil)
  end

  defp ensure_open_detail_state(socket), do: socket

  defp restore_discovery(%{assigns: %{catalog_route: true}} = socket) do
    push_navigate(socket, to: ~p"/console/models")
  end

  defp restore_discovery(%{assigns: %{discovery_return: nil}} = socket) do
    assign(socket, journey_step: :discover, page_title: "Discover models")
  end

  defp restore_discovery(socket) do
    socket = socket |> cancel_detail() |> assign(socket.assigns.discovery_return)

    socket =
      assign(socket,
        opened_download_key: nil,
        opened_download_note: nil,
        discovery_return: nil,
        downloads_expanded: true,
        journey_step: :discover,
        page_title: "Discover models"
      )

    cond do
      socket.assigns.search_status == :loading ->
        pending = socket.assigns.pending_selected_repo_id || socket.assigns.selected_repo_id

        socket
        |> start_search(socket.assigns.search_query)
        |> assign(pending_selected_repo_id: pending)

      socket.assigns.detail_status == :loading and is_binary(socket.assigns.selected_repo_id) ->
        start_detail(socket, socket.assigns.selected_repo_id)

      true ->
        socket
    end
  end

  defp detail_for_open_download(%{assigns: %{opened_download_key: nil}} = socket, detail),
    do: {socket, detail}

  defp detail_for_open_download(socket, detail) do
    {repo, revision} = socket.assigns.opened_download_key

    if detail.repo_id == repo and is_binary(revision) and detail.revision_sha == revision do
      {assign(socket, opened_download_note: nil), detail}
    else
      note =
        "The provider now reports a different revision. Details for this download's recorded revision are unavailable. Your download remains pinned to its original revision."

      {assign(socket, opened_download_note: note),
       normalize_detail(%{repo_id: repo, revision_sha: revision})}
    end
  end

  defp detail_lookup_failed(socket, error) do
    socket = assign(socket, active_detail_ref: nil, active_detail_pid: nil)

    if socket.assigns.opened_download_key do
      assign(socket,
        opened_download_note:
          "Provider details are unavailable. The recorded download identity and controls remain available."
      )
    else
      assign(socket,
        detail_status: :error,
        model_detail: nil,
        detail_error: sanitize_error(error)
      )
    end
  end

  defp control_known_download(socket, key, command, status) do
    if command in available_download_controls(status) do
      apply_control_result(
        socket,
        key,
        download_coordinator_impl().control_download(key, command)
      )
    else
      socket
    end
  end

  defp apply_control_result(socket, _key, {:ok, snapshot}) do
    socket |> assign(download_control_error: nil) |> apply_download_snapshot(snapshot)
  end

  defp apply_control_result(socket, {repo, revision}, {:error, _reason}) do
    assign(socket,
      download_control_error:
        "This download changed: #{repo} (#{revision || "unrecorded revision"}). Check its current status and try again."
    )
  end

  defp held_download_key(jobs, repo, revision) do
    Enum.find(Map.keys(jobs), fn {job_repo, job_revision} ->
      job_repo == repo and to_string(job_revision) == revision
    end)
  end

  defp download_count(jobs, :running),
    do:
      Enum.count(jobs, fn {_, job} ->
        job.status in [:starting, :downloading, :pausing, :cancelling, :preparing, :importing]
      end)

  defp download_count(jobs, :paused),
    do: Enum.count(jobs, fn {_, job} -> job.status == :paused end)

  defp ordered_downloads(jobs) do
    Enum.sort_by(jobs, fn {key, job} ->
      {if(active_download_status?(job.status), do: 0, else: 1), key}
    end)
  end

  defp unfinished_download_bytes(jobs) do
    jobs
    |> Enum.filter(fn {_key, job} -> active_download_status?(job.status) end)
    |> Enum.map(fn {_key, job} -> (job[:progress] || %{})[:bytes_downloaded] end)
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.sum()
  end

  defp download_control_label(action, {repo, revision}) do
    label = %{pause: "Pause", resume: "Resume", cancel: "Cancel"}[action]
    "#{label} download for #{repo}, revision #{revision || "unrecorded"}"
  end

  defp available_download_controls(status) when status in [:starting, :downloading],
    do: [:pause, :cancel]

  defp available_download_controls(:pausing), do: [:cancel]

  defp available_download_controls(:paused), do: [:resume, :cancel]
  defp available_download_controls(_status), do: []

  defp download_controls(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <.button :for={action <- available_download_controls(@status)} variant={:secondary} size={:sm} phx-click="control_download" phx-value-repo_id={elem(@key, 0)} phx-value-revision={to_string(elem(@key, 1))} phx-value-action={action} aria-label={download_control_label(action, @key)}>{%{pause: "Pause", resume: "Resume", cancel: "Cancel"}[action]}</.button>
    <.button :if={@status == :cancelled and present_text?(elem(@key, 1))} variant={:primary} size={:sm} phx-click="restart_download" phx-value-repo_id={elem(@key, 0)} phx-value-revision={to_string(elem(@key, 1))} aria-label={"Restart download for #{elem(@key, 0)}, revision #{elem(@key, 1)}"}>Restart download</.button>
    <.button :if={@status in [:completed, :error, :cancelled]} variant={:secondary} size={:sm} phx-click="remove_download" phx-value-repo_id={elem(@key, 0)} phx-value-revision={to_string(elem(@key, 1))} aria-label={"Remove #{elem(@key, 0)}, revision #{elem(@key, 1) || "unrecorded"}, from Downloads"}>Remove from Downloads</.button>
    <p :if={@status == :completed} class="text-xs text-slate-500 dark:text-slate-400">Removing this history entry keeps the model in Catalog.</p>
    <p :if={@status == :paused}
    class="text-xs text-slate-500 dark:text-slate-400">Partial files kept. Resume continues this revision.</p>
      <p :if={@status == :cancelled} class="text-xs text-slate-500 dark:text-slate-400">Download stopped. Partial files removed.</p>
      <p :if={@status in [:preparing, :importing]} class="text-xs text-slate-500 dark:text-slate-400">Finalizing import. Pause and cancel are no longer available.</p>
    </div>
    """
  end

  defp catalog_heading(false, _status), do: "Add to your catalog"
  defp catalog_heading(true, :completed), do: "Model imported"
  defp catalog_heading(true, :cancelled), do: "Download cancelled"
  defp catalog_heading(true, :paused), do: "Download paused"
  defp catalog_heading(true, :error), do: "Import failed"
  defp catalog_heading(true, _status), do: "Import in progress"

  defp import_detail_title(status) when status in [:completed, :importing, :preparing, :error],
    do: "Import details"

  defp import_detail_title(_status), do: "Download details"

  defp inline_download?(%{
         detail_status: :ok,
         model_detail: %{repo_id: repo, revision_sha: revision},
         visible_download_key: {repo, revision}
       })
       when is_binary(revision), do: true

  defp inline_download?(_assigns), do: false

  defp download_panel(assigns) do
    ~H"""
          <%!-- Download progress panel (visible during active download) --%>
          <div
            :if={@download_status in [:starting, :downloading, :pausing, :paused, :cancelling, :cancelled, :preparing, :importing]}
            id="model-hub-download-progress"
            class="mt-4 rounded-lg border border-sky-200 bg-sky-50 px-5 py-4 dark:border-sky-800 dark:bg-sky-900/20"
          >
    <div class="space-y-2">
    <.download_controls key={@visible_download_key} status={@download_status} />


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
              <div :if={@download_status != :cancelled} class="flex items-center gap-3">
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

              <details open id="model-hub-progress-details">
    <summary class="cursor-pointer text-sm font-medium">Download details</summary>
    <div :if={@download_progress} class="space-y-1 text-sm text-slate-600 dark:text-slate-300">
                <p id="model-hub-download-file-progress">
                  <%= if @download_progress[:total_files] do %>
                    {@download_progress[:files_completed] || 0} of {@download_progress[:total_files]} files
                  <% else %>
                    {@download_progress[:files_completed] || 0} files
                  <% end %>
                </p>
                <p :if={@download_status == :cancelled} class="text-sm">{format_bytes(@download_progress[:bytes_downloaded])} transferred before cancellation. Restart downloads the original revision from the beginning.</p>
                <p :if={@download_status != :cancelled} id="model-hub-download-byte-progress">
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
              </details>
            </div>
          </div>

          <.download_controls :if={@download_status in [:completed, :error]} key={@visible_download_key} status={@download_status} />
          <%!-- Download success panel --%>
          <div
            :if={@download_status == :completed}
            id="model-hub-download-complete"
            class="mt-4 rounded-lg border border-emerald-200 bg-emerald-50 px-5 py-4 dark:border-emerald-800 dark:bg-emerald-900/20"
          >
            <div class="space-y-2">
              <p class="text-sm font-medium text-emerald-800 dark:text-emerald-200">
                <%= if @download_result[:state] == :active do %>
                  Model is now catalog-active.
                <% else %>
                  Model registered in Catalog. Activate it from Catalog before granting access.
                <% end %>
              </p>
              <p
                :if={@download_result[:state] == :active}
                id="model-hub-download-readiness-note"
                class="text-sm text-slate-600 dark:text-slate-300"
              >
                Catalog activation is not runtime readiness. Playground enables Send only when a node reports a loaded placement for this model.
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
                  class="font-mono text-xs break-all"
                >
                  {@download_result[:version]}
                </span>
              </p>
              <p :if={@download_result[:artifact_sha256]} id="model-hub-download-digest" class="text-xs text-slate-600 dark:text-slate-300 break-all">
                Bundle SHA-256: <span class="font-mono">{@download_result[:artifact_sha256]}</span>
              </p>
              <div class="flex flex-wrap items-center gap-3">
                <.link
                  :if={@download_result[:state] == :active}
                  id="model-hub-download-playground-link"
                  navigate={~p"/console/playground"}
                  class="inline-flex items-center rounded-md px-3 py-1.5 text-sm font-medium text-navy dark:text-sky-400 underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:focus-visible:ring-sky-400 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-slate-800"
                >
                  Open Playground &rarr;
                </.link>
                <.link
                  id="model-hub-download-models-link"
                  navigate={catalog_result_path(@download_result)}
                  class="inline-block rounded-md text-sm font-medium text-navy dark:text-sky-400 underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:focus-visible:ring-sky-400 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-slate-800"
                >
                  View in Catalog &rarr;
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
              <p
                :if={present_text?(download_key_revision(@visible_download_key))}
                id="model-hub-download-error-revision"
                class="font-mono text-xs text-red-600 dark:text-red-400 break-all"
              >
                Revision {download_key_revision(@visible_download_key)}
              </p>
              <.button
                :if={revision_changed?(@download_error)}
                id="model-hub-refresh-revision"
                variant={:secondary}
                size={:sm}
                phx-click="refresh_failed_revision"
              >
                Refresh and select again
              </.button>
              <.button
                :if={not revision_changed?(@download_error)}
                id="model-hub-download-retry"
                variant={:secondary}
                size={:sm}
                phx-click="retry_download"
              >
                Try again
              </.button>
            </div>
          </div>
    """
  end

  defp handle_download_model(%{assigns: %{opened_download_key: key}} = socket)
       when not is_nil(key), do: {:noreply, socket}

  defp handle_download_model(socket) do
    %{assigns: assigns} = socket

    cond do
      assigns.journey_step != :catalog ->
        {:noreply, socket}

      assigns.detail_status != :ok ->
        {:noreply, socket}

      assigns.model_detail == nil ->
        {:noreply, socket}

      assigns.model_detail.gated == true ->
        {:noreply, socket}

      not present_text?(assigns.model_detail.revision_sha) ->
        {:noreply, socket}

      revision_refresh_required_for_selected?(
        assigns.download_status,
        assigns.download_error,
        assigns.visible_download_key,
        assigns.model_detail
      ) ->
        {:noreply, socket}

      download_busy_for_selected?(assigns) ->
        {:noreply, socket}

      true ->
        {:noreply,
         start_download_via_coordinator(
           socket,
           assigns.model_detail.repo_id,
           assigns.model_detail.revision_sha
         )}
    end
  end

  defp handle_repair_model(socket, raw_catalog_version) do
    assigns = socket.assigns

    if download_ready_for_selected?(assigns) do
      case ModelHub.validate_catalog_version(
             raw_catalog_version,
             assigns.model_detail.revision_sha
           ) do
        {:ok, catalog_version} ->
          {:noreply,
           socket
           |> assign(repair_form: repair_form())
           |> start_download_via_coordinator(
             assigns.model_detail.repo_id,
             assigns.model_detail.revision_sha,
             catalog_version
           )}

        {:error, message} ->
          {:noreply,
           assign_repair_form_error(socket, normalize_query(raw_catalog_version), message)}
      end
    else
      {:noreply, socket}
    end
  end

  defp assign_repair_form_error(socket, catalog_version, message) do
    assign(socket,
      repair_form:
        to_form(%{"catalog_version" => catalog_version},
          as: :model_hub_repair,
          errors: [catalog_version: {message, []}]
        )
    )
  end

  defp download_ready_for_selected?(assigns) do
    assigns.journey_step == :catalog and assigns.detail_status == :ok and
      not is_nil(assigns.model_detail) and assigns.model_detail.gated != true and
      present_text?(assigns.model_detail.revision_sha) and
      not revision_refresh_required_for_selected?(
        assigns.download_status,
        assigns.download_error,
        assigns.visible_download_key,
        assigns.model_detail
      ) and not download_busy_for_selected?(assigns)
  end

  defp repair_form, do: to_form(%{"catalog_version" => ""}, as: :model_hub_repair)

  defp handle_retry_download(
         %{assigns: %{download_error: %{code: "hf_revision_changed"}}} = socket
       ),
       do: {:noreply, socket}

  defp handle_retry_download(socket) do
    case socket.assigns do
      %{
        download_status: :error,
        download_progress: %{repo_id: repo_id},
        visible_download_key: {repo_id, revision}
      }
      when is_binary(repo_id) and repo_id != "" ->
        catalog_version =
          get_in(socket.assigns.download_jobs, [{repo_id, revision}, :catalog_version])

        {:noreply, start_download_via_coordinator(socket, repo_id, revision, catalog_version)}

      _ ->
        {:noreply, socket}
    end
  end

  defp assign_defaults(socket) do
    assign(socket,
      journey_step: :discover,
      node_inventory: AsyncResult.loading(),
      form: to_form(@empty_form, as: :model_hub_search),
      repair_form: repair_form(),
      search_query: "",
      capability_filter: "all",
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
      opened_download_key: nil,
      opened_download_note: nil,
      discovery_return: nil,
      removal_focus_target: nil,
      removal_focus_sequence: 0,
      focus_discovery_after_removal: false,
      download_jobs: %{},
      downloads_expanded: false,
      download_control_error: nil,
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
        capability_filter: "all",
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
        repair_form: repair_form(),
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
      repair_form: repair_form(),
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

  defp start_download_via_coordinator(socket, repo_id, revision, catalog_version \\ nil)
       when is_binary(repo_id) do
    opts = [activate: false, revision: revision]

    opts =
      if is_nil(catalog_version),
        do: opts,
        else: Keyword.put(opts, :catalog_version, catalog_version)

    case download_coordinator_impl().start_download(repo_id, opts) do
      {:ok, snapshot} ->
        apply_download_snapshot(socket, snapshot)

      {:error, {:already_downloading, snapshot}} ->
        apply_download_snapshot(socket, snapshot)

      {:error, snapshot} when is_map(snapshot) ->
        apply_download_snapshot(socket, snapshot)
    end
  end

  defp download_busy_for_selected?(%{download_jobs: jobs, selected_repo_id: repo_id}) do
    download_busy_for_selected?(jobs, repo_id)
  end

  defp download_busy_for_selected?(jobs, selected_repo_id) do
    Enum.any?(jobs, fn {{repo_id, _revision}, job} ->
      repo_id == selected_repo_id and active_download_status?(job.status)
    end)
  end

  defp active_download_status?(status),
    do:
      status in [:starting, :downloading, :pausing, :paused, :cancelling, :preparing, :importing]

  defp revision_refresh_required_for_selected?(
         :error,
         error,
         {repo_id, revision},
         %{repo_id: repo_id, revision_sha: revision}
       ),
       do: revision_changed?(error)

  defp revision_refresh_required_for_selected?(
         _status,
         _error,
         _visible_key,
         _model_detail
       ),
       do: false

  defp apply_download_snapshot(socket, %{status: status} = snapshot) do
    socket =
      assign(socket,
        download_jobs: Map.put(socket.assigns.download_jobs, snapshot[:key], snapshot)
      )

    key = snapshot[:key]
    visible_key = socket.assigns[:visible_download_key]
    selected_repo_id = socket.assigns[:selected_repo_id]

    # Show this snapshot if:
    # - no download is currently visible
    # - it matches the visible download key
    # - it matches the currently selected repo
    should_apply? =
      (is_nil(socket.assigns.opened_download_key) or socket.assigns.opened_download_key == key) and
        not stale_revision_changed_for_selected_detail?(socket, snapshot) and
        (visible_key == nil ||
           (key != nil && key == visible_key) ||
           snapshot[:repo_id] == selected_repo_id)

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

  defp stale_revision_changed_for_selected_detail?(
         %{assigns: %{model_detail: %{repo_id: repo_id, revision_sha: revision}}},
         snapshot
       ) do
    stale_revision_changed_snapshot?(snapshot, repo_id, revision)
  end

  defp stale_revision_changed_for_selected_detail?(_socket, _snapshot), do: false

  defp rehydrate_download(socket) do
    socket =
      Enum.reduce(
        download_coordinator_impl().list_snapshots(),
        socket,
        &apply_download_snapshot(&2, &1)
      )

    case download_coordinator_impl().latest_snapshot() do
      nil -> socket
      snapshot -> apply_download_snapshot(socket, snapshot)
    end
  end

  defp maybe_rehydrate_for_repo(socket, repo_id, selected_revision) do
    case download_coordinator_impl().latest_snapshot_for_repo(repo_id) do
      nil ->
        socket

      snapshot ->
        if stale_revision_changed_snapshot?(snapshot, repo_id, selected_revision) do
          clear_visible_download_snapshot(socket, snapshot[:key])
        else
          apply_download_snapshot(socket, snapshot)
        end
    end
  end

  defp stale_revision_changed_snapshot?(
         %{status: :error, key: {repo_id, snapshot_revision}, error: error},
         repo_id,
         selected_revision
       ) do
    snapshot_revision != selected_revision and revision_changed?(sanitize_error(error))
  end

  defp stale_revision_changed_snapshot?(_snapshot, _repo_id, _selected_revision), do: false

  defp clear_visible_download_snapshot(
         %{assigns: %{visible_download_key: key}} = socket,
         key
       ) do
    assign(socket,
      download_status: :idle,
      visible_download_key: nil,
      download_progress: nil,
      download_result: nil,
      download_error: nil
    )
  end

  defp clear_visible_download_snapshot(socket, _key), do: socket

  defp download_coordinator_impl do
    console_config()[:download_coordinator_impl] || OrchardConsole.ModelHubDownloadCoordinator
  end

  defp download_status_label(:paused), do: "Paused"
  defp download_status_label(:pausing), do: "Pausing…"
  defp download_status_label(:cancelling), do: "Cancelling…"
  defp download_status_label(:cancelled), do: "Cancelled"
  defp download_status_label(:completed), do: "Completed"
  defp download_status_label(:error), do: "Failed"
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
    |> Enum.map(fn {pattern, members} -> shard_group_label(pattern, members) end)
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, label} -> label end)
  end

  defp shard_group_label(pattern, members) do
    first_index = members |> Enum.map(fn {_sibling, idx} -> idx end) |> Enum.min()
    shard_count = length(members)
    {known_bytes, unknown_count} = shard_group_size(members)

    {first_index, format_shard_group_line(pattern, shard_count, known_bytes, unknown_count)}
  end

  defp shard_group_size(members) do
    Enum.reduce(members, {0, 0}, fn {sibling, _idx}, acc ->
      add_shard_size(acc, sibling.size_bytes)
    end)
  end

  defp add_shard_size({bytes, unknown}, n) when is_integer(n) and n > 0, do: {bytes + n, unknown}
  defp add_shard_size({bytes, unknown}, _size), do: {bytes, unknown + 1}

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

  defp compact_count(value) when is_integer(value) and value >= 1_000_000_000,
    do: "#{Float.round(value / 1_000_000_000, 1)}B"

  defp compact_count(value) when is_integer(value) and value >= 1_000_000,
    do: "#{Float.round(value / 1_000_000, 1)}M"

  defp compact_count(value), do: format_integer(value)

  defp result_publisher(repo_id), do: repo_id |> String.split("/", parts: 2) |> hd()
  defp result_name(repo_id), do: repo_id |> String.split("/", parts: 2) |> List.last()

  defp result_row_class(%{repo_id: repo_id}, repo_id) do
    "bg-sky-50/70 hover:bg-sky-100/70 dark:bg-sky-900/20 dark:hover:bg-sky-900/30"
  end

  defp result_row_class(_result, _selected_repo_id), do: nil

  defp access_badge_tone(true), do: :warning
  defp access_badge_tone(false), do: :success

  defp access_badge_label(true), do: "Gated"
  defp access_badge_label(false), do: "Open"

  defp revision_changed?(%{code: "hf_revision_changed"}), do: true
  defp revision_changed?(_error), do: false

  defp download_key_revision({_repo_id, revision}), do: revision
  defp download_key_revision(_key), do: nil

  defp catalog_result_path(%{id: id}) when is_binary(id), do: "/console/models#model-" <> id
  defp catalog_result_path(_result), do: "/console/models"

  defp filter_results(results, "all"), do: results

  defp filter_results(results, capability),
    do: Enum.filter(results, &(result_capability(&1) == capability))

  defp capability_options(results),
    do: [
      "all" | ["unknown" | Enum.map(results, &result_capability/1)] |> Enum.uniq() |> Enum.sort()
    ]

  defp result_capability(%{pipeline_tag: tag}) when is_binary(tag) and tag != "", do: tag
  defp result_capability(_result), do: "unknown"

  defp capability_label("all"), do: "All capabilities"
  defp capability_label("unknown"), do: "Unknown"
  defp capability_label("text-generation"), do: "Text generation"
  defp capability_label(tag), do: Phoenix.Naming.humanize(tag)

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
          safetensors_total: detail_get(result, :safetensors_total),
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

  defp metadata_fields(detail) do
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
