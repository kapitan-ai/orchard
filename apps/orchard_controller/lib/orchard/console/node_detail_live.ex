defmodule OrchardConsole.NodeDetailLive do
  @moduledoc """
  Console detail drill-in for node inventory rows and admission candidates.
  """

  use OrchardConsole, :live_view

  require Logger

  alias Orchard.ClusterManagement.{
    ActionPreview,
    ActionPreviewBuilder,
    MemoryBudgetPresenter,
    StatusBuilder
  }

  alias Orchard.ControlPlane
  alias Orchard.Nodes
  alias Orchard.Nodes.{AdmissionCandidate, Lifecycle, Node}

  @default_refresh_interval_ms 5_000
  @pending_admission_categories ~w(pending_observed pending_provisioned pending_registered)
  @lifecycle_actions Lifecycle.actions()

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Node Detail",
       active_nav: :nodes,
       page_mode: :workspace,
       target_kind: nil,
       target_id: nil,
       load_status: :loading,
       record: nil,
       status: nil,
       latest_decision: nil,
       memory_budget: nil,
       action: nil,
       refresh_timer: nil,
       message: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {target_kind, target_id} = target_from_params(socket.assigns.live_action, params)

    socket =
      assign(socket,
        target_kind: target_kind,
        target_id: target_id,
        load_status: :loading,
        action: nil,
        message: nil
      )

    if connected?(socket) do
      {:noreply, socket |> cancel_refresh() |> load_detail() |> schedule_refresh()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:refresh_node_detail, socket) do
    {:noreply, socket |> load_detail() |> schedule_refresh()}
  end

  @impl true
  def handle_event("open_admit", _params, socket) do
    if can_open_admit?(socket.assigns.target_kind, socket.assigns.record, socket.assigns.status) do
      {:noreply, put_action(socket, :admit, default_action_inputs(:admit), false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_reject", _params, socket) do
    if can_open_reject?(socket.assigns.target_kind, socket.assigns.record, socket.assigns.status) do
      {:noreply, put_action(socket, :reject, default_action_inputs(:reject), false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "open_lifecycle",
        %{"action" => action},
        %{assigns: %{record: %Node{}}} = socket
      ) do
    with {:ok, action} <- lifecycle_action(action),
         :node <- socket.assigns.target_kind do
      {:noreply, put_action(socket, action, default_action_inputs(action), false)}
    else
      _error -> {:noreply, socket}
    end
  end

  def handle_event("open_lifecycle", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_action", _params, socket) do
    {:noreply, assign(socket, action: nil)}
  end

  def handle_event("action_change", %{"action" => _params}, %{assigns: %{action: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("action_change", %{"action" => params}, socket) do
    action = socket.assigns.action
    inputs = normalize_action_inputs(action.kind, params)
    confirmed? = truthy?(Map.get(params, "confirmed"))

    {:noreply, put_action(socket, action.kind, inputs, confirmed?)}
  end

  def handle_event("execute_action", %{"action" => _params}, %{assigns: %{action: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("execute_action", %{"action" => params}, socket) do
    action = socket.assigns.action
    inputs = normalize_action_inputs(action.kind, params)
    confirmed? = truthy?(Map.get(params, "confirmed"))

    socket = put_action(socket, action.kind, inputs, confirmed?)

    if action_executable?(socket.assigns.action) do
      execute_action(socket, socket.assigns.action)
    else
      {:noreply,
       put_action_error(socket, "Resolve blockers and confirm the preview before executing.")}
    end
  end

  # ===========================================================================
  # Render
  # ===========================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div id="node-detail-page" class="space-y-6">
      <.link
        navigate={~p"/console/nodes"}
        class="inline-flex items-center rounded-md px-2 py-1 text-sm font-medium text-slate-600 hover:bg-slate-100 hover:text-navy focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:text-slate-300 dark:hover:bg-slate-800 dark:hover:text-sky-300 dark:focus-visible:ring-sky-400"
      >
        Back to Nodes
      </.link>

      <%= cond do %>
        <% @load_status == :loading -> %>
          <.state_message id="node-detail-loading" kind={:loading} layout={:panel} title="Loading node detail." />
        <% @load_status == :not_found -> %>
          <.state_message id="node-detail-not-found" kind={:empty} layout={:panel} title="Node detail not found." body={@message} />
        <% @load_status == :error -> %>
          <.state_message id="node-detail-error" kind={:error} layout={:panel} title="Node detail unavailable." body={@message} />
        <% true -> %>
          <div id="node-detail-content" class="space-y-6">
            <div id="node-detail-header-card">
              <.card>
                <:title>{detail_title(@target_kind, @record)}</:title>
                <:subtitle>{detail_subtitle(@target_kind, @record)}</:subtitle>

                <div
                  :if={detail_action_buttons?(@target_kind, @record, @status)}
                  id="node-detail-actions"
                  class="mb-4 flex flex-wrap gap-2"
                >
                  <.button
                    :if={can_open_admit?(@target_kind, @record, @status)}
                    id="node-detail-open-admit"
                    variant={:primary}
                    size={:sm}
                    phx-click="open_admit"
                  >
                    Preview admit
                  </.button>
                  <.button
                    :if={can_open_reject?(@target_kind, @record, @status)}
                    id="node-detail-open-reject"
                    variant={:danger}
                    size={:sm}
                    phx-click="open_reject"
                  >
                    Preview reject
                  </.button>
                  <.button
                    :for={lifecycle_action <- lifecycle_action_buttons(@target_kind, @record)}
                    id={"node-detail-open-lifecycle-#{lifecycle_action}"}
                    variant={lifecycle_action_variant(lifecycle_action)}
                    size={:sm}
                    phx-click="open_lifecycle"
                    phx-value-action={lifecycle_action}
                  >
                    {lifecycle_action_button_label(lifecycle_action)}
                  </.button>
                </div>

                <div class="flex flex-wrap items-center gap-2">
                  <.badge tone={admission_category_tone(status_value(@status, :admission, :category))}>
                    {format_status_value(status_value(@status, :admission, :category))}
                  </.badge>
                  <.badge tone={health_tone(status_value(@status, :health, :status))}>
                    {format_status_value(status_value(@status, :health, :status))}
                  </.badge>
                  <.badge tone={freshness_tone(status_value(@status, :freshness, :status))}>
                    {format_status_value(status_value(@status, :freshness, :status))}
                  </.badge>
                  <span class="text-xs font-mono text-slate-500 dark:text-slate-400">
                    {resource_id(@target_kind, @record)}
                  </span>
                </div>
              </.card>
            </div>

            <div id="node-detail-status-groups" class="grid gap-4 lg:grid-cols-2">
              <.status_group
                id="node-detail-lifecycle"
                title="Lifecycle"
                badge={format_status_value(status_value(@status, :lifecycle, :state))}
                tone={lifecycle_tone(status_value(@status, :lifecycle, :state))}
              >
                <.detail_grid id="node-detail-lifecycle-grid" class="sm:grid-cols-2">
                  <.detail_field id="node-detail-lifecycle-state" label="State" mono>
                    {format_status_value(status_value(@status, :lifecycle, :state))}
                  </.detail_field>
                  <.detail_field id="node-detail-resource-type" label="Resource" mono>
                    {status_value(@status, :resource, :type)}
                  </.detail_field>
                </.detail_grid>
              </.status_group>

              <.status_group
                id="node-detail-admission"
                title="Admission"
                badge={format_status_value(status_value(@status, :admission, :category))}
                tone={admission_category_tone(status_value(@status, :admission, :category))}
              >
                <.detail_grid id="node-detail-admission-grid" class="sm:grid-cols-2">
                  <.detail_field id="node-detail-admission-category" label="Category" mono>
                    {format_status_value(status_value(@status, :admission, :category))}
                  </.detail_field>
                  <.detail_field id="node-detail-admission-source" label="Source" mono>
                    {format_status_value(status_value(@status, :admission, :source))}
                  </.detail_field>
                  <.detail_field id="node-detail-admission-latest" label="Latest Decision" mono>
                    {format_status_value(status_value(@status, :admission, :latest_decision))}
                  </.detail_field>
                </.detail_grid>
              </.status_group>

              <.status_group
                id="node-detail-health"
                title="Health"
                badge={format_status_value(status_value(@status, :health, :status))}
                tone={health_tone(status_value(@status, :health, :status))}
              >
                <.detail_grid id="node-detail-health-grid" class="sm:grid-cols-2">
                  <.detail_field id="node-detail-health-status" label="Health" mono>
                    {format_status_value(status_value(@status, :health, :status))}
                  </.detail_field>
                </.detail_grid>
              </.status_group>

              <.status_group
                id="node-detail-freshness"
                title="Freshness"
                badge={format_status_value(status_value(@status, :freshness, :status))}
                tone={freshness_tone(status_value(@status, :freshness, :status))}
              >
                <.detail_grid id="node-detail-freshness-grid" class="sm:grid-cols-2">
                  <.detail_field id="node-detail-freshness-status" label="Freshness" mono>
                    {format_status_value(status_value(@status, :freshness, :status))}
                  </.detail_field>
                  <.detail_field id="node-detail-freshness-source" label="Source" mono>
                    {format_status_value(status_value(@status, :freshness, :source))}
                  </.detail_field>
                  <.detail_field id="node-detail-freshness-observed" label="Observed At" mono>
                    <.local_time
                      :if={status_value(@status, :freshness, :observed_at)}
                      value={status_value(@status, :freshness, :observed_at)}
                      format={:datetime_second}
                    />
                    <span :if={!status_value(@status, :freshness, :observed_at)}>Never observed</span>
                  </.detail_field>
                </.detail_grid>
              </.status_group>

              <.status_group
                id="node-detail-transport"
                title="Transport"
                badge={format_status_value(status_value(@status, :transport, :status))}
                tone={transport_tone(status_value(@status, :transport, :status))}
              >
                <.detail_grid id="node-detail-transport-grid" class="sm:grid-cols-2">
                  <.detail_field id="node-detail-transport-status" label="Transport" mono>
                    {format_status_value(status_value(@status, :transport, :status))}
                  </.detail_field>
                  <.detail_field id="node-detail-target-ref" label="Target" mono break_all>
                    {target_ref(@target_kind, @record)}
                  </.detail_field>
                </.detail_grid>
              </.status_group>

              <.status_group
                id="node-detail-runtime"
                title="Runtime"
                badge={format_status_value(status_value(@status, :runtime, :status))}
                tone={runtime_tone(status_value(@status, :runtime, :status))}
              >
                <.detail_grid id="node-detail-runtime-grid" class="sm:grid-cols-2">
                  <.detail_field id="node-detail-runtime-status" label="Runtime" mono>
                    {format_status_value(status_value(@status, :runtime, :status))}
                  </.detail_field>
                  <.detail_field id="node-detail-runtime-health-code" label="Health Code" mono>
                    {format_optional(status_value(@status, :runtime, :health_code))}
                  </.detail_field>
                  <.detail_field id="node-detail-runtime-message" label="Message">
                    {format_optional(status_value(@status, :runtime, :health_message))}
                  </.detail_field>
                </.detail_grid>
              </.status_group>

              <.status_group
                id="node-detail-compatibility"
                title="Compatibility"
                badge={format_status_value(status_value(@status, :compatibility, :status))}
                tone={compatibility_tone(status_value(@status, :compatibility, :status))}
              >
                <.detail_grid id="node-detail-compatibility-grid" class="sm:grid-cols-2">
                  <.detail_field id="node-detail-compatibility-status" label="Compatibility" mono>
                    {format_status_value(status_value(@status, :compatibility, :status))}
                  </.detail_field>
                </.detail_grid>
              </.status_group>

              <.status_group
                id="node-detail-scheduling"
                title="Scheduling"
                badge={scheduling_badge(status_value(@status, :scheduling, :eligible))}
                tone={scheduling_tone(status_value(@status, :scheduling, :eligible))}
              >
                <.detail_grid id="node-detail-scheduling-grid" class="sm:grid-cols-2">
                  <.detail_field id="node-detail-scheduling-eligible" label="Eligible" mono>
                    {scheduling_badge(status_value(@status, :scheduling, :eligible))}
                  </.detail_field>
                  <.detail_field id="node-detail-scheduling-codes" label="Reason Codes">
                    <.code_list
                      id="node-detail-scheduling-code-list"
                      codes={status_value(@status, :scheduling, :reason_codes) || []}
                      empty="No scheduler rejection codes."
                    />
                  </.detail_field>
                </.detail_grid>
              </.status_group>
            </div>

            <div :if={@memory_budget} id="node-detail-memory-budget">
              <.card>
                <:title>Memory Telemetry</:title>
                <:subtitle>Observe-only memory-budget diagnostics. This section is non-gating.</:subtitle>
                <div class="space-y-3">
                  <div
                    :for={budget <- @memory_budget.runtime_memory_budgets}
                    class="rounded-lg border border-slate-200 bg-slate-50/60 p-3 dark:border-slate-700 dark:bg-slate-900/50"
                  >
                    <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
                      <span class="font-mono text-sm text-slate-900 dark:text-slate-100">
                        {budget[:model_ref] || "unknown model"}
                      </span>
                      <.badge tone={memory_budget_status_tone(budget)}>
                        {memory_budget_status_label(budget)}
                      </.badge>
                    </div>
                    <dl class="grid gap-2 text-sm sm:grid-cols-2 lg:grid-cols-4">
                      <div>
                        <dt class="text-slate-500 dark:text-slate-400">Mode</dt>
                        <dd class="font-mono text-slate-900 dark:text-slate-100">{budget[:mode] || "unknown"}</dd>
                      </div>
                      <div>
                        <dt class="text-slate-500 dark:text-slate-400">Working Set</dt>
                        <dd class="font-mono text-slate-900 dark:text-slate-100">{memory_budget_working_set_label(budget)}</dd>
                      </div>
                      <div>
                        <dt class="text-slate-500 dark:text-slate-400">Headroom</dt>
                        <dd class="font-mono text-slate-900 dark:text-slate-100">{memory_budget_headroom_label(budget)}</dd>
                      </div>
                      <div>
                        <dt class="text-slate-500 dark:text-slate-400">KV Cache Bytes/Token</dt>
                        <dd class="font-mono text-slate-900 dark:text-slate-100">{format_positive_integer(budget[:kv_cache_bytes_per_token])}</dd>
                      </div>
                      <div>
                        <dt class="text-slate-500 dark:text-slate-400">Max Context</dt>
                        <dd class="font-mono text-slate-900 dark:text-slate-100">{format_positive_integer(budget[:max_context_tokens])}</dd>
                      </div>
                      <div>
                        <dt class="text-slate-500 dark:text-slate-400">Recommended Context</dt>
                        <dd class="font-mono text-slate-900 dark:text-slate-100">{format_positive_integer(budget[:recommended_context_tokens])}</dd>
                      </div>
                      <div>
                        <dt class="text-slate-500 dark:text-slate-400">Resident</dt>
                        <dd class="font-mono text-slate-900 dark:text-slate-100">{format_positive_integer(budget[:resident_memory_bytes])}</dd>
                      </div>
                      <div>
                        <dt class="text-slate-500 dark:text-slate-400">Prefill Bytes/Token</dt>
                        <dd class="font-mono text-slate-900 dark:text-slate-100">{format_positive_integer(budget[:prefill_workspace_bytes_per_token])}</dd>
                      </div>
                    </dl>
                  </div>
                  <p
                    :if={memory_budget_truncated_count(@memory_budget) > 0}
                    id="node-detail-memory-budget-truncation"
                    class="text-sm text-amber-700 dark:text-amber-400"
                  >
                    Note: {memory_budget_truncated_count(@memory_budget)} additional memory budget row(s) truncated upstream.
                  </p>
                </div>
              </.card>
            </div>

            <div id="node-detail-warnings-card">
              <.card>
                <:title>Warnings</:title>
                <.coded_entry_list
                  id="node-detail-warnings"
                  entries={status_value(@status, :warnings)}
                  empty="No warnings reported."
                  tone={:warning}
                />
              </.card>
            </div>

            <div :if={@latest_decision} id="node-detail-latest-decision-card">
              <.card variant={:secondary}>
                <:title>Latest Admission Decision</:title>
                <.detail_grid id="node-detail-latest-decision-grid" class="sm:grid-cols-3">
                  <.detail_field id="node-detail-decision-kind" label="Decision" mono>
                    {format_status_value(@latest_decision.decision)}
                  </.detail_field>
                  <.detail_field id="node-detail-decision-reason" label="Reason">
                    {format_optional(@latest_decision.reason)}
                  </.detail_field>
                  <.detail_field id="node-detail-decision-at" label="Decided At" mono>
                    <.local_time value={@latest_decision.decided_at} format={:datetime_second} />
                  </.detail_field>
                </.detail_grid>
              </.card>
            </div>

            <div :if={@target_kind == :candidate} id="node-detail-candidate-evidence-card">
              <.card>
                <:title>Candidate Evidence</:title>
                <:subtitle>Observed candidate evidence is preserved as review context.</:subtitle>
                <div class="grid gap-4 lg:grid-cols-3">
                  <.evidence_block
                    id="node-detail-observed-identity"
                    title="Observed Identity"
                    rows={evidence_rows(@record.observed_identity)}
                  />
                  <.evidence_block
                    id="node-detail-inventory-evidence"
                    title="Inventory Snapshot"
                    rows={evidence_rows(@record.inventory)}
                  />
                  <.evidence_block
                    id="node-detail-compatibility-evidence"
                    title="Compatibility Evidence"
                    rows={evidence_rows(@record.compatibility_evidence)}
                  />
                </div>
                <div :if={@record.node_id} class="mt-4">
                  <.link
                    navigate={~p"/console/nodes/#{@record.node_id}"}
                    class="inline-flex items-center rounded-md px-3 py-1.5 text-sm font-medium text-navy hover:bg-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:text-sky-300 dark:hover:bg-slate-800 dark:focus-visible:ring-sky-400"
                  >
                    Review linked node
                  </.link>
                </div>
              </.card>
            </div>

            <.action_preview_panel :if={@action} action={@action} />
          </div>
      <% end %>
    </div>
    """
  end

  # ===========================================================================
  # Data loading
  # ===========================================================================

  defp target_from_params(:candidate, %{"candidate_id" => candidate_id}),
    do: {:candidate, candidate_id}

  defp target_from_params(:node, %{"node_id" => node_id}), do: {:node, node_id}

  defp load_detail(%{assigns: %{target_kind: :node, target_id: node_id}} = socket) do
    case Nodes.fetch_node(node_id) do
      {:ok, %Node{} = node} ->
        latest_decision = Nodes.latest_admission_decision_for_node(node.id)
        status = StatusBuilder.node_status_map(node, latest_decision: latest_decision)

        socket
        |> assign(
          page_title: "#{node.display_name || node.hostname || "Node"} Detail",
          load_status: :ok,
          record: node,
          status: status,
          latest_decision: latest_decision,
          memory_budget: MemoryBudgetPresenter.for_node(node, runtime_impl()),
          message: nil
        )
        |> refresh_open_action()

      {:error, :node_not_found} ->
        assign(socket,
          load_status: :not_found,
          record: nil,
          status: nil,
          latest_decision: nil,
          memory_budget: nil,
          action: nil,
          message: "The requested node inventory row was not found."
        )
    end
  rescue
    error ->
      Logger.warning("Node detail load failed: #{inspect(error)}")
      detail_error(socket)
  catch
    kind, reason ->
      Logger.warning("Node detail load #{kind}: #{inspect(reason)}")
      detail_error(socket)
  end

  defp load_detail(%{assigns: %{target_kind: :candidate, target_id: candidate_id}} = socket) do
    case Nodes.fetch_admission_candidate(candidate_id) do
      {:ok, %AdmissionCandidate{} = candidate} ->
        latest_decision = Nodes.latest_admission_decision_for_candidate(candidate.id)
        status = StatusBuilder.candidate_status_map(candidate, latest_decision: latest_decision)

        socket
        |> assign(
          page_title: "#{candidate_display_label(candidate)} Detail",
          load_status: :ok,
          record: candidate,
          status: status,
          latest_decision: latest_decision,
          memory_budget: nil,
          message: nil
        )
        |> refresh_open_action()

      {:error, :candidate_not_found} ->
        assign(socket,
          load_status: :not_found,
          record: nil,
          status: nil,
          latest_decision: nil,
          memory_budget: nil,
          action: nil,
          message: "The requested admission candidate was not found."
        )
    end
  rescue
    error ->
      Logger.warning("Admission candidate detail load failed: #{inspect(error)}")
      detail_error(socket)
  catch
    kind, reason ->
      Logger.warning("Admission candidate detail load #{kind}: #{inspect(reason)}")
      detail_error(socket)
  end

  defp detail_error(socket) do
    assign(socket,
      load_status: :error,
      record: nil,
      status: nil,
      latest_decision: nil,
      memory_budget: nil,
      action: nil,
      message: "Node detail could not be loaded."
    )
  end

  defp refresh_open_action(%{assigns: %{action: nil}} = socket), do: socket

  defp refresh_open_action(%{assigns: %{action: action}} = socket) do
    refreshed = put_action(socket, action.kind, action.inputs, action.confirmed)

    case action.error do
      nil -> refreshed
      error -> put_action_error(refreshed, error)
    end
  end

  # ===========================================================================
  # Actions
  # ===========================================================================

  defp put_action(socket, kind, inputs, confirmed?) do
    preview =
      socket
      |> build_action_preview(kind, inputs)
      |> ActionPreview.to_map()

    assign(socket,
      action: %{
        kind: kind,
        inputs: inputs,
        confirmed: confirmed?,
        preview: preview,
        error: nil
      }
    )
  end

  defp build_action_preview(
         %{assigns: %{target_kind: :node, record: %Node{id: id}}},
         :admit,
         inputs
       ) do
    ActionPreviewBuilder.admit_node(id, inputs)
  end

  defp build_action_preview(
         %{assigns: %{target_kind: :candidate, record: %AdmissionCandidate{id: id}}},
         :reject,
         inputs
       ) do
    ActionPreviewBuilder.reject_admission(id, inputs)
  end

  defp build_action_preview(
         %{assigns: %{target_kind: :node, record: %Node{id: id}}},
         :reject,
         inputs
       ) do
    ActionPreviewBuilder.reject_admission(id, inputs)
  end

  defp build_action_preview(
         %{assigns: %{target_kind: :node, record: %Node{id: id}}},
         kind,
         inputs
       )
       when kind in @lifecycle_actions do
    ActionPreviewBuilder.node_lifecycle(kind, id, inputs)
  end

  defp execute_action(socket, %{kind: :admit, inputs: inputs}) do
    with :ok <- ControlPlane.authorize_write_path(:node_admission),
         {:ok, _result} <- Nodes.admit_node(socket.assigns.record.id, inputs, audit_opts()) do
      {:noreply,
       socket
       |> put_flash(:info, "Node admitted.")
       |> assign(action: nil)
       |> load_detail()}
    else
      {:error, reason} -> {:noreply, put_action_error(socket, error_message(reason))}
    end
  end

  defp execute_action(%{assigns: %{target_kind: :candidate}} = socket, %{
         kind: :reject,
         inputs: inputs
       }) do
    with :ok <- ControlPlane.authorize_write_path(:node_admission),
         {:ok, _result} <-
           Nodes.reject_admission_candidate(socket.assigns.record.id, inputs, audit_opts()) do
      {:noreply,
       socket
       |> put_flash(:info, "Admission rejected.")
       |> assign(action: nil)
       |> load_detail()}
    else
      {:error, reason} -> {:noreply, put_action_error(socket, error_message(reason))}
    end
  end

  defp execute_action(%{assigns: %{target_kind: :node}} = socket, %{kind: :reject, inputs: inputs}) do
    with :ok <- ControlPlane.authorize_write_path(:node_admission),
         {:ok, _result} <- Nodes.reject_admission(socket.assigns.record.id, inputs, audit_opts()) do
      {:noreply,
       socket
       |> put_flash(:info, "Admission rejected.")
       |> assign(action: nil)
       |> load_detail()}
    else
      {:error, reason} -> {:noreply, put_action_error(socket, error_message(reason))}
    end
  end

  defp execute_action(%{assigns: %{target_kind: :node}} = socket, %{kind: kind, inputs: inputs})
       when kind in @lifecycle_actions do
    with :ok <- ControlPlane.authorize_write_path(:node_lifecycle),
         {:ok, _result} <- Lifecycle.execute(kind, socket.assigns.record.id, inputs, audit_opts()) do
      {:noreply,
       socket
       |> put_flash(:info, lifecycle_success_message(kind))
       |> assign(action: nil)
       |> load_detail()}
    else
      {:error, reason} -> {:noreply, put_action_error(socket, error_message(reason))}
    end
  end

  defp put_action_error(%{assigns: %{action: action}} = socket, message) do
    assign(socket, action: Map.put(action, :error, message))
  end

  defp audit_opts, do: [actor_type: "operator", actor_id: nil]

  defp default_action_inputs(:admit) do
    %{
      "trust_evidence_ref" => "",
      "pool_id" => "",
      "routing_policy_id" => "",
      "capacity_policy_reason" => "",
      "controller_dispatch_ceiling" => 1
    }
  end

  defp default_action_inputs(:reject), do: %{"reason" => ""}

  defp default_action_inputs(:decommission) do
    %{"reason" => "", "node_id_confirmation" => "", "acknowledged" => "false"}
  end

  defp default_action_inputs(:drain), do: %{"reason" => "", "acknowledged" => "false"}

  defp default_action_inputs(action) when action in @lifecycle_actions do
    %{"reason" => ""}
  end

  defp normalize_action_inputs(:admit, params) do
    %{
      "trust_evidence_ref" => Map.get(params, "trust_evidence_ref", ""),
      "pool_id" => Map.get(params, "pool_id", ""),
      "routing_policy_id" => Map.get(params, "routing_policy_id", ""),
      "capacity_policy_reason" => Map.get(params, "capacity_policy_reason", ""),
      "controller_dispatch_ceiling" =>
        normalize_capacity_ceiling(Map.get(params, "controller_dispatch_ceiling", "1"))
    }
  end

  defp normalize_action_inputs(:reject, params) do
    %{"reason" => Map.get(params, "reason", "")}
  end

  defp normalize_action_inputs(:decommission, params) do
    %{
      "reason" => Map.get(params, "reason", ""),
      "node_id_confirmation" => Map.get(params, "node_id_confirmation", ""),
      "acknowledged" => Map.get(params, "acknowledged", "false")
    }
  end

  defp normalize_action_inputs(:drain, params) do
    %{
      "reason" => Map.get(params, "reason", ""),
      "acknowledged" => Map.get(params, "acknowledged", "false")
    }
  end

  defp normalize_action_inputs(action, params) when action in @lifecycle_actions do
    %{"reason" => Map.get(params, "reason", "")}
  end

  defp action_executable?(%{confirmed: true, preview: preview, kind: kind, inputs: inputs}) do
    preview_entries(preview, :blockers) == [] and
      not missing_required_input?(kind, preview, inputs)
  end

  defp action_executable?(_action), do: false

  defp missing_required_input?(:reject, preview, inputs) do
    "requires_reason" in preview_codes(preview, :confirmation_requirements) and
      blank?(Map.get(inputs, "reason"))
  end

  defp missing_required_input?(:admit, preview, inputs) do
    "requires_reason" in preview_codes(preview, :confirmation_requirements) and
      blank?(Map.get(inputs, "capacity_policy_reason"))
  end

  defp missing_required_input?(kind, preview, inputs) when kind in @lifecycle_actions do
    requirements = preview_codes(preview, :confirmation_requirements)

    missing_typed_node_id?(requirements, inputs, preview) or
      missing_consequence_acknowledgement?(requirements, inputs)
  end

  defp missing_required_input?(_kind, _preview, _inputs), do: false

  defp normalize_capacity_ceiling(value) when is_integer(value), do: value

  defp normalize_capacity_ceiling(value) when is_binary(value) do
    case Integer.parse(value) do
      {ceiling, ""} -> ceiling
      _invalid -> value
    end
  end

  defp normalize_capacity_ceiling(value), do: value

  defp can_open_admit?(:node, %Node{}, status) do
    status_value(status, :admission, :category) in ["pending_provisioned", "pending_registered"]
  end

  defp can_open_admit?(_target_kind, _record, _status), do: false

  defp can_open_reject?(_target_kind, record, status)
       when is_struct(record, Node) or is_struct(record, AdmissionCandidate) do
    status_value(status, :admission, :category) in @pending_admission_categories
  end

  defp can_open_reject?(_target_kind, _record, _status), do: false

  defp detail_action_buttons?(target_kind, record, status) do
    can_open_admit?(target_kind, record, status) or
      can_open_reject?(target_kind, record, status) or
      lifecycle_action_buttons(target_kind, record) != []
  end

  defp lifecycle_action_buttons(:node, %Node{}), do: @lifecycle_actions
  defp lifecycle_action_buttons(_target_kind, _record), do: []

  defp lifecycle_action_kind?(kind), do: kind in @lifecycle_actions

  defp lifecycle_action(action) when is_binary(action) do
    action = String.to_existing_atom(action)

    if action in @lifecycle_actions, do: {:ok, action}, else: :error
  rescue
    ArgumentError -> :error
  end

  # ===========================================================================
  # Display helpers
  # ===========================================================================

  defp detail_title(:node, %Node{} = node), do: node.display_name || node.hostname || node.id

  defp detail_title(:candidate, %AdmissionCandidate{} = candidate),
    do: candidate_display_label(candidate)

  defp detail_title(_kind, _record), do: "Node Detail"

  defp detail_subtitle(:node, %Node{} = node), do: "Node inventory row #{node.id}"

  defp detail_subtitle(:candidate, %AdmissionCandidate{} = candidate),
    do: "Admission candidate #{candidate.id}"

  defp detail_subtitle(_kind, _record), do: nil

  defp resource_id(:node, %Node{id: id}), do: "node #{id}"
  defp resource_id(:candidate, %AdmissionCandidate{id: id}), do: "candidate #{id}"
  defp resource_id(_kind, _record), do: "unknown"

  defp target_ref(:node, %Node{} = node), do: format_host_port(node.advertise_addr, node.rpc_port)

  defp target_ref(:candidate, %AdmissionCandidate{} = candidate) do
    candidate.target_ref || candidate.endpoint_target || "Unconfigured"
  end

  defp target_ref(_kind, _record), do: "Unconfigured"

  defp candidate_display_label(%AdmissionCandidate{observed_identity: identity} = candidate) do
    [
      map_get(identity, "display_name"),
      map_get(identity, "hostname"),
      map_get(identity, "claimed_node_id"),
      candidate.target_ref,
      candidate.endpoint_target,
      candidate.id
    ]
    |> Enum.find(&present?/1)
  end

  defp status_value(status, :warnings) when is_map(status) do
    case map_get(status, :warnings) do
      warnings when is_list(warnings) -> warnings
      _warnings -> []
    end
  end

  defp status_value(status, group, key) when is_map(status) do
    case map_get(status, group) do
      group_status when is_map(group_status) -> map_get(group_status, key)
      _group_status -> nil
    end
  end

  defp status_value(_status, _group, _key), do: nil

  defp preview_entries(preview, key) when is_map(preview) do
    case map_get(preview, key) do
      entries when is_list(entries) -> entries
      _entries -> []
    end
  end

  defp preview_codes(preview, key) when is_map(preview) do
    case map_get(preview, key) do
      codes when is_list(codes) -> codes
      _codes -> []
    end
  end

  defp preview_value(preview, key) when is_map(preview), do: map_get(preview, key)
  defp preview_value(_preview, _key), do: nil

  defp nested_preview_value(preview, group, key) when is_map(preview) do
    case map_get(preview, group) do
      group_value when is_map(group_value) -> map_get(group_value, key)
      _group_value -> nil
    end
  end

  defp evidence_rows(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> %{key: to_string(key), value: value} end)
    |> Enum.sort_by(& &1.key)
  end

  defp evidence_rows(_value), do: []

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    fetch_map_value(map, key, Atom.to_string(key))
  end

  defp map_get(map, key) when is_map(map) and is_binary(key) do
    fetch_map_value(map, key, key_atom(key))
  end

  defp map_get(_map, _key), do: nil

  defp fetch_map_value(map, key, fallback_key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_fallback_map_value(map, fallback_key)
    end
  end

  defp fetch_fallback_map_value(_map, nil), do: nil

  defp fetch_fallback_map_value(map, fallback_key) do
    Map.get(map, fallback_key)
  end

  defp key_atom("display_name"), do: :display_name
  defp key_atom("hostname"), do: :hostname
  defp key_atom("claimed_node_id"), do: :claimed_node_id
  defp key_atom(_key), do: nil

  defp format_optional(value) when is_binary(value) and value != "", do: value
  defp format_optional(nil), do: "Not reported"
  defp format_optional(""), do: "Not reported"
  defp format_optional(value), do: to_string(value)

  defp format_status_value(nil), do: "unknown"

  defp format_status_value(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> format_status_value()
  end

  defp format_status_value(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp format_status_value(value), do: to_string(value)

  defp format_data(nil), do: "Not reported"
  defp format_data(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_data(value) when is_binary(value), do: value
  defp format_data(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp format_data(value), do: inspect(value, pretty: true, limit: 50)

  defp format_host_port(host, port) when is_binary(host) and is_integer(port) do
    if String.contains?(host, ":"),
      do: "[#{host}]:#{port}",
      else: "#{host}:#{port}"
  end

  defp format_host_port(_host, _port), do: "Unconfigured"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_value), do: false

  defp truthy?(value), do: value in [true, "true", "on", "1", 1]

  defp memory_budget_status_tone(%{display_state: :invalid}), do: :error
  defp memory_budget_status_tone(%{status_code: "ok"}), do: :success
  defp memory_budget_status_tone(%{status_code: "disabled"}), do: :neutral
  defp memory_budget_status_tone(_budget), do: :warning

  defp memory_budget_status_label(%{display_state: :invalid}), do: "invalid telemetry"

  defp memory_budget_status_label(%{status_code: code, status_message: message}) do
    case message do
      nil -> code
      "" -> code
      _ -> "#{code} (#{message})"
    end
  end

  defp memory_budget_status_label(_budget), do: "unreported"

  defp memory_budget_working_set_label(%{
         budget_available: true,
         target_working_set_bytes: bytes
       })
       when is_integer(bytes) and bytes > 0,
       do: Integer.to_string(bytes)

  defp memory_budget_working_set_label(%{budget_available: true}), do: "reported"
  defp memory_budget_working_set_label(_budget), do: "unknown"

  defp memory_budget_headroom_label(%{headroom_available: true}), do: "estimate reported"
  defp memory_budget_headroom_label(_budget), do: "estimate unavailable"

  defp memory_budget_truncated_count(%{runtime_memory_budgets_truncated_count: count})
       when is_integer(count) and count > 0,
       do: count

  defp memory_budget_truncated_count(_memory_budget), do: 0

  defp format_positive_integer(value) when is_integer(value) and value > 0,
    do: Integer.to_string(value)

  defp format_positive_integer(_value), do: "unknown"

  defp runtime_impl do
    Application.get_env(:orchard_controller, :console, [])[:runtime_impl] ||
      OrchardConsole.Runtime
  end

  defp lifecycle_tone("active"), do: :success
  defp lifecycle_tone(state) when state in ["cordoned", "draining", "maintenance"], do: :warning
  defp lifecycle_tone("removed"), do: :neutral
  defp lifecycle_tone(_state), do: :neutral

  defp admission_category_tone("rejected"), do: :error
  defp admission_category_tone("pending_registered"), do: :info
  defp admission_category_tone("pending_provisioned"), do: :warning
  defp admission_category_tone(_category), do: :neutral

  defp health_tone("healthy"), do: :success
  defp health_tone("degraded"), do: :warning
  defp health_tone(status) when status in ["unhealthy", "unreachable"], do: :error
  defp health_tone(_status), do: :neutral

  defp freshness_tone("fresh"), do: :success
  defp freshness_tone("stale"), do: :warning
  defp freshness_tone("unreachable"), do: :error
  defp freshness_tone(_status), do: :neutral

  defp transport_tone("reachable"), do: :success
  defp transport_tone("target_unconfigured"), do: :warning

  defp transport_tone(status) when status in ["timeout", "connect_failed", "identity_mismatch"],
    do: :error

  defp transport_tone(_status), do: :neutral

  defp runtime_tone("ready"), do: :success
  defp runtime_tone("not_ready"), do: :error
  defp runtime_tone(_status), do: :neutral

  defp compatibility_tone("compatible"), do: :success

  defp compatibility_tone(status)
       when status in ["legacy_metadata", "partial_metadata", "version_skew"], do: :warning

  defp compatibility_tone("unsupported_version"), do: :error
  defp compatibility_tone(_status), do: :neutral

  defp scheduling_badge(true), do: "Eligible"
  defp scheduling_badge(false), do: "Blocked"
  defp scheduling_badge(_value), do: "Unknown"

  defp scheduling_tone(true), do: :success
  defp scheduling_tone(false), do: :warning
  defp scheduling_tone(_value), do: :neutral

  defp action_title(:admit), do: "Admit Node Preview"
  defp action_title(:reject), do: "Reject Admission Preview"
  defp action_title(:cordon), do: "Cordon Node Preview"
  defp action_title(:uncordon), do: "Uncordon Node Preview"
  defp action_title(:drain), do: "Drain Node Preview"
  defp action_title(:cancel_drain), do: "Cancel Drain Preview"
  defp action_title(:maintenance), do: "Maintenance Node Preview"
  defp action_title(:resume), do: "Resume Node Preview"
  defp action_title(:decommission), do: "Decommission Node Preview"

  defp action_submit_label(:admit), do: "Admit node"
  defp action_submit_label(:reject), do: "Reject admission"
  defp action_submit_label(:cordon), do: "Cordon node"
  defp action_submit_label(:uncordon), do: "Uncordon node"
  defp action_submit_label(:drain), do: "Start drain"
  defp action_submit_label(:cancel_drain), do: "Cancel drain"
  defp action_submit_label(:maintenance), do: "Enter maintenance"
  defp action_submit_label(:resume), do: "Resume node"
  defp action_submit_label(:decommission), do: "Start decommission"

  defp action_variant(kind) when kind in [:reject, :decommission], do: :danger
  defp action_variant(_kind), do: :primary

  defp action_panel_class(kind) when kind in [:reject, :decommission],
    do: "border-red-200 bg-red-50/40 dark:border-red-900/50 dark:bg-red-950/20"

  defp action_panel_class(_kind), do: ""

  defp action_explanation(:admit) do
    "Execution revalidates admission blockers before mutating node state."
  end

  defp action_explanation(:reject) do
    "Rejection records an admission decision and keeps the candidate visible for audit review."
  end

  defp action_explanation(kind) when kind in @lifecycle_actions do
    "Execution revalidates lifecycle blockers before mutating node state."
  end

  defp action_form_id(kind) when kind in [:admit, :reject], do: "admission-action-form"
  defp action_form_id(kind) when kind in @lifecycle_actions, do: "node-action-form"

  defp confirmation_label(kind) when kind in [:admit, :reject] do
    "I reviewed the preview and understand this admission action."
  end

  defp confirmation_label(kind) when kind in @lifecycle_actions do
    "I reviewed the preview and understand this lifecycle action."
  end

  defp lifecycle_action_button_label(:cordon), do: "Preview cordon"
  defp lifecycle_action_button_label(:uncordon), do: "Preview uncordon"
  defp lifecycle_action_button_label(:drain), do: "Preview drain"
  defp lifecycle_action_button_label(:cancel_drain), do: "Preview cancel drain"
  defp lifecycle_action_button_label(:maintenance), do: "Preview maintenance"
  defp lifecycle_action_button_label(:resume), do: "Preview resume"
  defp lifecycle_action_button_label(:decommission), do: "Preview decommission"

  defp lifecycle_action_variant(:decommission), do: :danger
  defp lifecycle_action_variant(_action), do: :secondary

  defp lifecycle_success_message(:cordon), do: "Node cordoned."
  defp lifecycle_success_message(:uncordon), do: "Node uncordoned."
  defp lifecycle_success_message(:drain), do: "Node drain started."
  defp lifecycle_success_message(:cancel_drain), do: "Node drain cancelled."
  defp lifecycle_success_message(:maintenance), do: "Node moved to maintenance."
  defp lifecycle_success_message(:resume), do: "Node resumed."
  defp lifecycle_success_message(:decommission), do: "Node decommission started."

  defp error_message(:controller_standby), do: "This controller is in standby mode."

  defp error_message(:controller_leadership_unproven),
    do: "This controller has not proven local leadership."

  defp error_message(:candidate_not_found), do: "Node admission candidate was not found."
  defp error_message(:node_not_found), do: "Node was not found."
  defp error_message(:reason_required), do: "A nonblank rejection reason is required."
  defp error_message(:admission_not_pending), do: "Admission is not pending."

  defp error_message(:admission_actor_identity_unavailable),
    do: "The local controller identity could not be proven for admission provenance."

  defp error_message(:admission_not_rejected), do: "Admission is not rejected."
  defp error_message(:admission_rejected), do: "Admission rejection must be cleared first."
  defp error_message(:node_not_registered), do: "Node is not registered."
  defp error_message(:node_not_pending_admission), do: "Node is not pending admission."
  defp error_message(:node_not_active), do: "Node is not active."
  defp error_message(:node_unhealthy), do: "Node health is unhealthy."
  defp error_message(:node_unreachable), do: "Node is unreachable."
  defp error_message(:drain_already_running), do: "Node drain is already running."
  defp error_message(:drain_not_running), do: "Node drain is not running."
  defp error_message(:decommission_already_running), do: "Node decommission is already running."
  defp error_message(:maintenance_requires_drain), do: "Node must be draining before maintenance."

  defp error_message(:drain_completion_unverified),
    do: "Manual maintenance is unavailable until node drain completion can be verified."

  defp error_message(:lifecycle_transition_invalid),
    do: "Node lifecycle state does not allow this action."

  defp error_message(:inventory_missing), do: "Registered node inventory is missing."
  defp error_message(:trust_not_established), do: "Node trust evidence is required."
  defp error_message(:pool_required), do: "Node pool assignment is required."
  defp error_message(:policy_required), do: "Required policy inputs are missing."
  defp error_message(_reason), do: "Node action failed."

  defp missing_typed_node_id?(requirements, inputs, preview) do
    "requires_typed_node_id" in requirements and
      Map.get(inputs, "node_id_confirmation") != nested_preview_value(preview, :target, :id)
  end

  defp missing_consequence_acknowledgement?(requirements, inputs) do
    consequence_acknowledgement_required?(requirements) and
      not truthy?(Map.get(inputs, "acknowledged"))
  end

  defp consequence_acknowledgement_required?(requirements) do
    Enum.any?(
      requirements,
      &(&1 in [
          "requires_drain_consequence_acknowledgement",
          "requires_decommission_consequence_acknowledgement"
        ])
    )
  end

  # ===========================================================================
  # Refresh / config
  # ===========================================================================

  defp schedule_refresh(socket) do
    ref = Process.send_after(self(), :refresh_node_detail, refresh_interval_ms())
    assign(socket, refresh_timer: ref)
  end

  defp cancel_refresh(socket) do
    case socket.assigns[:refresh_timer] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    assign(socket, refresh_timer: nil)
  end

  defp refresh_interval_ms do
    case console_config()[:refresh_interval_ms] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_refresh_interval_ms
    end
  end

  defp console_config do
    Application.get_env(:orchard_controller, :console, [])
  end

  # ===========================================================================
  # Local components
  # ===========================================================================

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:badge, :string, default: nil)
  attr(:tone, :atom, default: :neutral)
  slot(:inner_block, required: true)

  defp status_group(assigns) do
    ~H"""
    <div id={@id}>
      <.card padding={:sm}>
        <:title>
          <span class="flex flex-wrap items-center gap-2">
            <span>{@title}</span>
            <.badge :if={@badge} tone={@tone}>{@badge}</.badge>
          </span>
        </:title>
        {render_slot(@inner_block)}
      </.card>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:entries, :list, default: [])
  attr(:empty, :string, required: true)
  attr(:tone, :atom, default: :neutral)

  defp coded_entry_list(assigns) do
    ~H"""
    <div id={@id}>
      <p :if={@entries == []} class="text-sm text-slate-500 dark:text-slate-400">
        {@empty}
      </p>
      <ul :if={@entries != []} class="space-y-2">
        <li :for={entry <- @entries} class="flex flex-wrap items-start gap-2 text-sm">
          <.code_chip code={map_get(entry, :code)} tone={@tone} />
          <span class="text-slate-700 dark:text-slate-300">
            {format_optional(map_get(entry, :message))}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:codes, :list, default: [])
  attr(:empty, :string, required: true)

  defp code_list(assigns) do
    ~H"""
    <div id={@id}>
      <p :if={@codes == []} class="text-sm text-slate-500 dark:text-slate-400">
        {@empty}
      </p>
      <div :if={@codes != []} class="flex flex-wrap gap-2">
        <.code_chip :for={code <- @codes} code={code} tone={:neutral} />
      </div>
    </div>
    """
  end

  attr(:code, :any, required: true)
  attr(:tone, :atom, default: :neutral)

  defp code_chip(assigns) do
    ~H"""
    <span class={[
      "inline-flex max-w-full items-center rounded border px-2 py-0.5 font-mono text-xs",
      code_chip_class(@tone)
    ]}>
      {format_optional(@code)}
    </span>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:rows, :list, default: [])

  defp evidence_block(assigns) do
    ~H"""
    <div id={@id} class="rounded-lg border border-slate-200 bg-slate-50/60 p-3 dark:border-slate-700 dark:bg-slate-900/50">
      <h3 class="text-sm font-medium text-slate-800 dark:text-slate-100">{@title}</h3>
      <p :if={@rows == []} class="mt-2 text-sm text-slate-500 dark:text-slate-400">
        No evidence reported.
      </p>
      <dl :if={@rows != []} class="mt-3 space-y-3">
        <div :for={row <- @rows}>
          <dt class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
            {row.key}
          </dt>
          <dd class="mt-1 max-h-36 overflow-auto rounded border border-slate-200 bg-white p-2 font-mono text-xs text-slate-800 dark:border-slate-700 dark:bg-slate-950 dark:text-slate-200">
            <pre class="whitespace-pre-wrap break-words">{format_data(row.value)}</pre>
          </dd>
        </div>
      </dl>
    </div>
    """
  end

  attr(:action, :map, required: true)

  defp action_preview_panel(assigns) do
    ~H"""
    <div id="node-action-preview">
      <.card class={action_panel_class(@action.kind)}>
        <:title>{action_title(@action.kind)}</:title>
        <:subtitle>{action_explanation(@action.kind)}</:subtitle>

        <form id={action_form_id(@action.kind)} phx-change="action_change" phx-submit="execute_action" class="space-y-5">
          <div id="action-preview-summary" class="grid gap-4 lg:grid-cols-3">
            <.detail_grid id="action-preview-current" class="rounded-lg border border-slate-200 bg-white p-3 dark:border-slate-700 dark:bg-slate-950">
              <.detail_field id="action-preview-current-state" label="Current" mono>
                {format_status_value(nested_preview_value(@action.preview, :current, :state))}
              </.detail_field>
              <.detail_field id="action-preview-active-requests" label="Active Requests" mono>
                {format_optional(preview_value(@action.preview, :active_request_count))}
              </.detail_field>
            </.detail_grid>

            <.detail_grid id="action-preview-scheduling" class="rounded-lg border border-slate-200 bg-white p-3 dark:border-slate-700 dark:bg-slate-950">
              <.detail_field id="action-preview-scheduling-state" label="Scheduler" mono>
                {scheduling_badge(nested_preview_value(@action.preview, :scheduler_eligibility, :eligible))}
              </.detail_field>
              <.detail_field id="action-preview-scheduling-codes" label="Reason Codes">
                <.code_list
                  id="action-preview-scheduler-code-list"
                  codes={nested_preview_value(@action.preview, :scheduler_eligibility, :reason_codes) || []}
                  empty="No scheduler rejection codes."
                />
              </.detail_field>
            </.detail_grid>

            <.detail_grid id="action-preview-transition" class="rounded-lg border border-slate-200 bg-white p-3 dark:border-slate-700 dark:bg-slate-950">
              <.detail_field id="action-preview-transition-from" label="From" mono>
                {format_status_value(nested_preview_value(@action.preview, :expected_transition, :from))}
              </.detail_field>
              <.detail_field id="action-preview-transition-to" label="To" mono>
                {format_status_value(nested_preview_value(@action.preview, :expected_transition, :to))}
              </.detail_field>
              <.detail_field id="action-preview-audit-action" label="Audit Action" mono break_all>
                {format_optional(preview_value(@action.preview, :audit_action))}
              </.detail_field>
            </.detail_grid>
          </div>

          <div class="grid gap-4 lg:grid-cols-2">
            <div class="rounded-lg border border-red-200 bg-red-50/60 p-3 dark:border-red-900/50 dark:bg-red-950/20">
              <h3 class="text-sm font-medium text-red-800 dark:text-red-200">Blockers</h3>
              <div class="mt-2">
                <.coded_entry_list
                  id="action-preview-blockers"
                  entries={preview_entries(@action.preview, :blockers)}
                  empty="No blockers."
                  tone={:error}
                />
              </div>
            </div>
            <div class="rounded-lg border border-amber-200 bg-amber-50/60 p-3 dark:border-amber-900/50 dark:bg-amber-950/20">
              <h3 class="text-sm font-medium text-amber-800 dark:text-amber-200">Warnings</h3>
              <div class="mt-2">
                <.coded_entry_list
                  id="action-preview-warnings"
                  entries={preview_entries(@action.preview, :warnings)}
                  empty="No warnings."
                  tone={:warning}
                />
              </div>
            </div>
          </div>

          <div class="grid gap-4 lg:grid-cols-2">
            <div>
              <h3 class="mb-2 text-sm font-medium text-slate-800 dark:text-slate-100">
                Consequences
              </h3>
              <.code_list
                id="action-preview-consequence-codes"
                codes={preview_codes(@action.preview, :consequence_codes)}
                empty="No consequence codes."
              />
            </div>
            <div>
              <h3 class="mb-2 text-sm font-medium text-slate-800 dark:text-slate-100">
                Confirmation Requirements
              </h3>
              <.code_list
                id="action-preview-confirmation-requirements"
                codes={preview_codes(@action.preview, :confirmation_requirements)}
                empty="No confirmation requirements."
              />
            </div>
          </div>

          <div :if={@action.kind == :admit} id="action-admit-inputs" class="grid gap-4 md:grid-cols-2">
            <.input
              id="action-trust-evidence-ref"
              name="action[trust_evidence_ref]"
              value={@action.inputs["trust_evidence_ref"]}
              label="Trust Evidence Reference"
              placeholder="registration-audit:..."
            />
            <.input
              id="action-pool-id"
              name="action[pool_id]"
              value={@action.inputs["pool_id"]}
              label="Pool ID"
              placeholder="pool identifier"
            />
            <.input
              id="action-routing-policy-id"
              name="action[routing_policy_id]"
              value={@action.inputs["routing_policy_id"]}
              label="Routing Policy ID"
              placeholder="policy identifier"
            />
            <.input
              id="action-capacity-policy-reason"
              name="action[capacity_policy_reason]"
              type="textarea"
              rows="2"
              value={@action.inputs["capacity_policy_reason"]}
              label="Capacity Policy Reason"
              placeholder="Explain the approved dispatch-capacity bound."
              errors={admission_reason_errors(@action)}
            />
            <.input
              id="action-controller-dispatch-ceiling"
              name="action[controller_dispatch_ceiling]"
              type="number"
              min="0"
              value={@action.inputs["controller_dispatch_ceiling"]}
              label="Controller Dispatch Ceiling"
            />
          </div>

          <div :if={@action.kind == :reject} id="action-reject-inputs">
            <.input
              id="action-reason"
              name="action[reason]"
              type="textarea"
              rows="3"
              value={@action.inputs["reason"]}
              label="Rejection Reason"
              placeholder="Describe why this admission is being rejected."
              errors={reject_reason_errors(@action)}
            />
          </div>

          <div :if={lifecycle_action_kind?(@action.kind)} id="action-lifecycle-inputs" class="space-y-4">
            <.input
              id="action-lifecycle-reason"
              name="action[reason]"
              type="textarea"
              rows="2"
              value={@action.inputs["reason"]}
              label="Reason"
              placeholder="Optional operator note."
            />
            <.input
              :if={"requires_typed_node_id" in preview_codes(@action.preview, :confirmation_requirements)}
              id="action-node-id-confirmation"
              name="action[node_id_confirmation]"
              value={@action.inputs["node_id_confirmation"]}
              label="Type Node ID"
              placeholder={nested_preview_value(@action.preview, :target, :id)}
              errors={typed_node_id_errors(@action)}
            />
            <.input
              :if={consequence_acknowledgement_required?(preview_codes(@action.preview, :confirmation_requirements))}
              id="action-acknowledged"
              name="action[acknowledged]"
              type="checkbox"
              checked={truthy?(@action.inputs["acknowledged"])}
              label="I acknowledge the disclosed lifecycle consequences."
            />
          </div>

          <div class="rounded-lg border border-slate-200 bg-slate-50 p-3 dark:border-slate-700 dark:bg-slate-900/50">
            <.input
              id="action-confirmed"
              name="action[confirmed]"
              type="checkbox"
              checked={@action.confirmed}
              label={confirmation_label(@action.kind)}
            />
          </div>

          <p :if={@action.error} id="action-preview-error" class="text-sm font-medium text-red-700 dark:text-red-300">
            {@action.error}
          </p>

          <div class="flex flex-wrap justify-end gap-2">
            <.button id="action-cancel" variant={:secondary} phx-click="cancel_action">
              Cancel
            </.button>
            <.button
              id="action-submit"
              type="submit"
              variant={action_variant(@action.kind)}
              disabled={!action_executable?(@action)}
            >
              {action_submit_label(@action.kind)}
            </.button>
          </div>
        </form>
      </.card>
    </div>
    """
  end

  defp reject_reason_errors(%{kind: :reject, preview: preview, inputs: inputs}) do
    if missing_required_input?(:reject, preview, inputs),
      do: ["A nonblank rejection reason is required."],
      else: []
  end

  defp reject_reason_errors(_action), do: []

  defp admission_reason_errors(%{kind: :admit, preview: preview, inputs: inputs}) do
    if missing_required_input?(:admit, preview, inputs),
      do: ["A nonblank capacity policy reason is required."],
      else: []
  end

  defp admission_reason_errors(_action), do: []

  defp typed_node_id_errors(%{kind: :decommission, preview: preview, inputs: inputs}) do
    requirements = preview_codes(preview, :confirmation_requirements)

    if missing_typed_node_id?(requirements, inputs, preview),
      do: ["Type the node ID exactly to confirm decommission."],
      else: []
  end

  defp typed_node_id_errors(_action), do: []

  defp code_chip_class(:error),
    do:
      "border-red-200 bg-red-100 text-red-800 dark:border-red-800 dark:bg-red-950 dark:text-red-200"

  defp code_chip_class(:warning),
    do:
      "border-amber-200 bg-amber-100 text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200"

  defp code_chip_class(_tone),
    do:
      "border-slate-200 bg-slate-100 text-slate-700 dark:border-slate-700 dark:bg-slate-900 dark:text-slate-200"
end
