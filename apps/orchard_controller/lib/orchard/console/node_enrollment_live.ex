defmodule OrchardConsole.NodeEnrollmentLive do
  @moduledoc """
  Guides an operator through secure Node Enrollment and registration.
  """

  use OrchardConsole, :live_view

  alias Orchard.NodeEnrollmentBundle
  alias Orchard.NodeEnrollments

  @default_refresh_interval_ms 5_000
  @expiry_options [
    {"30 minutes", "1800"},
    {"1 hour", "3600"},
    {"4 hours", "14400"},
    {"24 hours", "86400"}
  ]
  @expiry_seconds Enum.map(@expiry_options, fn {_label, value} -> String.to_integer(value) end)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Add Node", active_nav: :nodes, page_mode: :workspace)
     |> assign_initial_state()}
  end

  @impl true
  def handle_params(
        %{"enrollment_id" => enrollment_id},
        _uri,
        %{assigns: %{stage: :delivering, delivery: %{enrollment_id: enrollment_id}}} = socket
      ) do
    {:noreply, socket}
  end

  def handle_params(%{"enrollment_id" => enrollment_id}, _uri, socket) do
    if connected?(socket) do
      case safe_fetch(enrollment_id) do
        {:ok, enrollment} ->
          {:noreply, restore_console_enrollment(socket, enrollment)}

        {:error, _reason} ->
          {:noreply,
           recovery_failed(
             socket,
             "That enrollment could not be found. Create a new enrollment to continue."
           )}
      end
    else
      {:noreply, assign(socket, stage: :loading)}
    end
  end

  def handle_params(_params, _uri, socket) do
    if connected?(socket) and
         socket.assigns.stage in [
           :loading,
           :delivering,
           :monitor,
           :delivery_failed,
           :recovery_failed
         ] do
      {:noreply,
       socket
       |> cancel_refresh()
       |> assign_initial_state()
       |> assign(stage: :enrollment)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("preparation_complete", _params, %{assigns: %{stage: :prepare}} = socket) do
    {:noreply, assign(socket, stage: :enrollment)}
  end

  def handle_event("preparation_complete", _params, socket), do: {:noreply, socket}

  def handle_event(
        "issue_enrollment",
        %{"enrollment" => params},
        %{assigns: %{stage: :enrollment}} = socket
      ) do
    with {:ok, attrs, form_params} <- validate_form(params),
         {:ok, bundle} <- safe_issue(attrs) do
      socket =
        socket
        |> push_event("node_enrollment_bundle", %{
          "contents" => bundle.contents,
          "enrollment_id" => bundle.enrollment.id,
          "filename" => bundle.filename
        })
        |> assign(
          stage: :delivering,
          form: to_form(form_params, as: :enrollment),
          delivery: %{
            enrollment_id: bundle.enrollment.id,
            expires_at: bundle.enrollment.expires_at,
            filename: bundle.filename,
            node_id: bundle.enrollment.node_id,
            display_name: bundle.enrollment.node.display_name
          },
          error_message: nil
        )
        |> push_patch(to: ~p"/console/nodes/new/#{bundle.enrollment.id}")

      {:noreply, socket}
    else
      {:error, {:validation, form}} ->
        {:noreply, assign(socket, form: form, error_message: nil)}

      {:error, {:bundle_publication_failed, enrollment_id, :output_failed, _failure_code}} ->
        case safe_fetch(enrollment_id) do
          {:ok, enrollment} ->
            {:noreply,
             socket
             |> restore_enrollment(enrollment)
             |> push_patch(to: ~p"/console/nodes/new/#{enrollment.id}")}

          {:error, _reason} ->
            {:noreply,
             recovery_failed(
               socket,
               "Enrollment #{enrollment_id} is output_failed and cannot be resumed. The provisioned Node remains in audit history, so create a new enrollment with a distinct Node name."
             )}
        end

      {:error,
       {:bundle_publication_reconciliation_failed, enrollment_id, _failure_code,
        _reconciliation_reason}} ->
        {:noreply,
         assign(
           socket,
           error_message:
             "No bundle was published. Enrollment #{enrollment_id} remains non-redeemable pending reconciliation, and its provisioned Node name remains reserved. Record the Enrollment ID and create a new enrollment with a distinct Node name after Controller recovery."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error_message: issue_error(reason))}
    end
  end

  def handle_event("issue_enrollment", _params, socket), do: {:noreply, socket}

  def handle_event(
        "node_enrollment_bundle_downloaded",
        %{"enrollment_id" => enrollment_id},
        %{assigns: %{stage: :delivering, delivery: %{enrollment_id: enrollment_id}}} = socket
      ) do
    case safe_mark_issued(enrollment_id) do
      {:ok, enrollment} ->
        {:noreply, enter_monitor(socket, enrollment)}

      {:error, _reason} ->
        {:noreply, reconcile_delivery(socket, enrollment_id, :downloaded)}
    end
  end

  def handle_event(
        "node_enrollment_bundle_download_failed",
        %{"enrollment_id" => enrollment_id},
        %{assigns: %{stage: :delivering, delivery: %{enrollment_id: enrollment_id}}} = socket
      ) do
    case safe_mark_output_failed(enrollment_id, "browser_download_failed") do
      {:ok, enrollment} -> {:noreply, reconcile_enrollment(socket, enrollment, :failed)}
      {:error, _reason} -> {:noreply, reconcile_delivery(socket, enrollment_id, :failed)}
    end
  end

  def handle_event("node_enrollment_bundle_downloaded", _params, socket), do: {:noreply, socket}

  def handle_event("node_enrollment_bundle_download_failed", _params, socket),
    do: {:noreply, socket}

  def handle_event("refresh_now", _params, socket) do
    {:noreply, socket |> cancel_refresh() |> refresh_enrollment() |> schedule_refresh()}
  end

  def handle_event("create_new_enrollment", _params, socket) do
    {:noreply,
     socket
     |> cancel_refresh()
     |> assign_initial_state()
     |> assign(stage: :enrollment)
     |> push_patch(to: ~p"/console/nodes/new")}
  end

  @impl true
  def handle_info(
        {:refresh_enrollment, generation},
        %{assigns: %{refresh_timer_ref: {_timer_ref, generation}}} = socket
      ) do
    {:noreply,
     socket
     |> assign(refresh_timer_ref: nil)
     |> refresh_enrollment()
     |> schedule_refresh()}
  end

  def handle_info({:refresh_enrollment, _generation}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="node-enrollment-download"
      phx-hook="NodeEnrollmentBundleDownload"
      class="mx-auto max-w-5xl space-y-6"
    >
      <div class="flex flex-wrap items-start justify-between gap-4">
        <div>
          <p class="text-sm font-medium text-sky-700 dark:text-sky-300">Nodes</p>
          <h1 class="mt-1 text-2xl font-semibold text-slate-950 dark:text-white">Add a Node</h1>
          <p class="mt-2 max-w-2xl text-sm text-slate-600 dark:text-slate-300">
            Prepare a new Mac, create its one-time enrollment, then review its trust evidence before admission.
          </p>
        </div>
        <.link
          navigate={~p"/console/nodes"}
          class="inline-flex items-center rounded-md px-3 py-2 text-sm font-medium text-slate-600 hover:bg-slate-100 hover:text-slate-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:text-slate-300 dark:hover:bg-slate-800 dark:hover:text-white"
        >
          Back to Nodes
        </.link>
      </div>

      <nav aria-label="Node setup progress" class="rounded-xl border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-700 dark:bg-slate-900">
        <ol class="grid gap-3 sm:grid-cols-5">
          <.progress_step number="1" label="Prepare Mac" state={progress_state(@stage, @enrollment, 1)} />
          <.progress_step number="2" label="Create Enrollment" state={progress_state(@stage, @enrollment, 2)} />
          <.progress_step number="3" label="Install and Register" state={progress_state(@stage, @enrollment, 3)} />
          <.progress_step number="4" label="Review and Admit" state={progress_state(@stage, @enrollment, 4)} />
          <.progress_step number="5" label="Node Active" state={progress_state(@stage, @enrollment, 5)} />
        </ol>
      </nav>

      <p
        id="node-enrollment-live-announcer"
        class="sr-only"
        aria-live="polite"
        aria-atomic="true"
      >
        {live_announcement(@stage, @enrollment, @error_message)}
      </p>

      <.card>
        <%= case @stage do %>
          <% :loading -> %>
            <.state_message
              id="node-enrollment-status-loading"
              kind={:loading}
              layout={:panel}
              title="Loading enrollment status."
              body="Orchard will retrieve the durable enrollment state after the Console connects."
            />
          <% :prepare -> %>
            <.prepare_step />
          <% :enrollment -> %>
            <.enrollment_step
              form={@form}
              error_message={@error_message}
              expiry_options={@expiry_options}
            />
          <% :delivering -> %>
            <.delivery_step delivery={@delivery} />
          <% :monitor -> %>
            <.monitor_step
              delivery={@delivery}
              enrollment={@enrollment}
              error_message={@error_message}
              last_checked_at={@last_checked_at}
            />
          <% :delivery_failed -> %>
            <.failure_step message={@error_message} />
          <% :recovery_failed -> %>
            <.recovery_failure_step message={@error_message} />
        <% end %>
      </.card>
    </div>
    """
  end

  attr(:number, :string, required: true)
  attr(:label, :string, required: true)
  attr(:state, :atom, required: true)

  defp progress_step(assigns) do
    ~H"""
    <li
      class="flex items-center gap-2 sm:block"
      aria-current={@state == :current && "step"}
    >
      <span
        aria-hidden="true"
        class={[
        "inline-flex size-7 shrink-0 items-center justify-center rounded-full text-xs font-semibold",
        progress_circle_class(@state)
      ]}
      >
        <%= if @state == :complete do %>
          <.icon name="hero-check" class="size-4" />
        <% else %>
          {@number}
        <% end %>
      </span>
      <span class={[
        "text-xs font-medium sm:mt-2 sm:block",
        @state == :current && "text-navy dark:text-sky-300",
        @state != :current && "text-slate-500 dark:text-slate-400"
      ]}>
        {@label}
        <span class="sr-only">, {progress_state_label(@state)}</span>
      </span>
    </li>
    """
  end

  defp prepare_step(assigns) do
    ~H"""
    <section id="node-prepare-step" class="space-y-6">
      <div>
        <p class="text-sm font-medium text-sky-700 dark:text-sky-300">Step 1 of 5</p>
        <h2 class="mt-1 text-xl font-semibold text-slate-950 dark:text-white">Prepare the target Mac</h2>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-300">
          Complete these items on the Mac you want to add. Keep this Console open on the Controller Mac.
        </p>
      </div>

      <ol class="space-y-4">
        <li class="flex gap-3 rounded-lg border border-slate-200 p-4 dark:border-slate-700">
          <span class="inline-flex size-7 shrink-0 items-center justify-center rounded-full bg-sky-100 text-sm font-semibold text-sky-800 dark:bg-sky-950 dark:text-sky-200">1</span>
          <div>
            <h3 class="font-medium text-slate-950 dark:text-white">Install Orchard on the target Mac</h3>
            <p class="mt-1 text-sm text-slate-600 dark:text-slate-300">
              For the validated <strong>source-development split-role path</strong>, prepare the
              Node Agent host using the source-development runbook. For a
              <strong>packaged multi-Mac rehearsal only</strong>, install the signed Orchard.app
              DMG with the <strong>Node Agent Install Role</strong> and configure the target's
              protected shared BEAM cookie and Node Agent identity from the packaging runbook.
              On the Controller Mac, separately configure external Postgres and the explicit
              Runtime Endpoint targets. The target Mac does not connect to Postgres. Packaged
              multi-Mac still has open production-acceptance gaps. On the target Mac, run
              <code class="font-mono text-xs">sudo orchardctl start</code>, then
              <code class="font-mono text-xs">orchardctl status</code> and confirm the Node Agent
              service is running before continuing.
            </p>
          </div>
        </li>
        <li class="flex gap-3 rounded-lg border border-slate-200 p-4 dark:border-slate-700">
          <span class="inline-flex size-7 shrink-0 items-center justify-center rounded-full bg-sky-100 text-sm font-semibold text-sky-800 dark:bg-sky-950 dark:text-sky-200">2</span>
          <div>
            <h3 class="font-medium text-slate-950 dark:text-white">Return here to create the enrollment</h3>
            <p class="mt-1 text-sm text-slate-600 dark:text-slate-300">
              Orchard will download a one-time JSON bundle. Transfer it securely to the target Mac and use it immediately.
            </p>
          </div>
        </li>
      </ol>

      <div class="flex justify-end">
        <.button id="node-preparation-complete" phx-click="preparation_complete">
          Continue to Enrollment
        </.button>
      </div>
    </section>
    """
  end

  attr(:form, :map, required: true)
  attr(:error_message, :string, default: nil)
  attr(:expiry_options, :list, required: true)

  defp enrollment_step(assigns) do
    ~H"""
    <section id="node-enrollment-step" class="space-y-6">
      <div>
        <p class="text-sm font-medium text-sky-700 dark:text-sky-300">Step 2 of 5</p>
        <h2 class="mt-1 text-xl font-semibold text-slate-950 dark:text-white">Create a one-time enrollment</h2>
        <p class="mt-2 text-sm text-slate-600 dark:text-slate-300">
          The downloaded bundle contains a short-lived secret. Orchard will not display or download it again.
        </p>
      </div>

      <.state_message
        :if={@error_message}
        id="node-enrollment-error"
        kind={:error}
        layout={:compact}
        title="Enrollment could not be created."
        body={@error_message}
      />

      <.form for={@form} id="node-enrollment-form" phx-submit="issue_enrollment" class="space-y-5">
        <.input
          field={@form[:display_name]}
          label="Node name"
          placeholder="render-node-03"
          autocomplete="off"
          required
        />
        <.input
          field={@form[:pool_id]}
          label="Initial pool intent"
          placeholder="general"
          autocomplete="off"
          required
        />
        <p class="-mt-3 text-xs text-slate-500 dark:text-slate-400">
          A Pool is an existing scheduling group. This intent pre-fills the admission review,
          and you can change it before admitting the node.
        </p>
        <.input
          field={@form[:expiry_seconds]}
          type="select"
          label="Enrollment expires after"
          options={@expiry_options}
        />

        <div class="flex justify-end">
          <.button id="issue-node-enrollment" type="submit" phx-disable-with="Creating enrollment...">
            Create Enrollment and Download
          </.button>
        </div>
      </.form>
    </section>
    """
  end

  attr(:delivery, :map, required: true)

  defp delivery_step(assigns) do
    ~H"""
    <section id="node-enrollment-delivery-step" class="space-y-5">
      <.state_message
        id="node-enrollment-delivering"
        kind={:loading}
        layout={:panel}
        title="Starting the one-time enrollment download."
        body="Keep this page open until the browser reports whether it accepted the download attempt. This does not verify where the file was saved."
      />
      <p class="text-center text-xs font-mono text-slate-500 dark:text-slate-400">
        {@delivery.filename}
      </p>
    </section>
    """
  end

  attr(:delivery, :map, required: true)
  attr(:enrollment, :any, default: nil)
  attr(:error_message, :string, default: nil)
  attr(:last_checked_at, :any, default: nil)

  defp monitor_step(assigns) do
    ~H"""
    <section id="node-enrollment-monitor-step" class="space-y-6">
      <div>
        <p class="text-sm font-medium text-sky-700 dark:text-sky-300">
          {monitor_progress_label(@enrollment)}
        </p>
        <h2 class="mt-1 text-xl font-semibold text-slate-950 dark:text-white">
          {monitor_title(@enrollment, @delivery.display_name)}
        </h2>
        <p :if={usable_bundle?(@enrollment)} class="mt-2 text-sm text-slate-600 dark:text-slate-300">
          Move <span class="font-mono text-xs">{@delivery.filename}</span> to the target Mac, then run:
        </p>
      </div>

      <div :if={usable_bundle?(@enrollment)} class="rounded-lg bg-slate-950 p-4 text-slate-100">
        <code id="node-enrollment-command" class="break-all font-mono text-sm">orchardctl node join --enrollment-bundle /secure/path/on-target/{@delivery.filename}</code>
      </div>
      <div
        :if={usable_bundle?(@enrollment)}
        class="space-y-1 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-950 dark:border-amber-800 dark:bg-amber-950/40 dark:text-amber-100"
      >
        <p>Replace the example path with the bundle's actual path on the target Mac.</p>
        <p>
          Transfer it through a protected administrator channel. Keep the bundle out of chat,
          tickets, logs, and shell history.
        </p>
      </div>

      <.state_message
        :if={
          @enrollment && @enrollment.state == :pending_publication &&
            !terminal_enrollment?(@enrollment)
        }
        id="node-enrollment-publication-pending"
        kind={:loading}
        layout={:compact}
        title="Waiting for download confirmation."
        body="Keep this page open. Orchard has not made this enrollment redeemable and will not display its secret again."
      />

      <.state_message
        :if={@error_message}
        id="node-enrollment-status-error"
        kind={:error}
        layout={:compact}
        title="Enrollment status unavailable."
        body={@error_message}
      />

      <div
        :if={@enrollment && reviewable_for_admission?(@enrollment)}
        id="node-enrollment-registered"
        role="status"
        class="rounded-lg border border-emerald-200 bg-emerald-50 p-4 text-emerald-950 dark:border-emerald-800 dark:bg-emerald-950/40 dark:text-emerald-100"
      >
        <p class="text-sm font-semibold">Registered - awaiting admission.</p>
        <p class="mt-1 text-sm">
          Review the Node's trust evidence before explicitly admitting it.
        </p>
      </div>

      <div :if={@enrollment && terminal_enrollment?(@enrollment)} class="space-y-4">
        <.state_message
          id="node-enrollment-terminal-state"
          kind={:error}
          layout={:compact}
          title="This enrollment can no longer register a node."
          body={terminal_enrollment_message(@enrollment)}
        />
        <.button id="replace-terminal-node-enrollment" phx-click="create_new_enrollment">
          Create New Enrollment
        </.button>
      </div>

      <div
        :if={
          @enrollment && @enrollment.state != :pending_publication &&
            !terminal_enrollment?(@enrollment)
        }
        id="node-enrollment-live-status"
        aria-live="polite"
        aria-atomic="false"
        class="space-y-3"
      >
        <.status_row
          label="Enrollment download attempt accepted"
          complete={true}
          detail="Browser accepted the one-time file download; target custody is not verified"
        />
        <.status_row
          label="Node registered"
          complete={registered?(@enrollment)}
          detail={registration_detail(@enrollment)}
        />
        <.status_row
          label="Admission review"
          complete={admitted?(@enrollment)}
          detail={admission_detail(@enrollment)}
        />
        <.status_row
          label="Node active"
          complete={activation_complete?(@enrollment)}
          detail={activation_detail(@enrollment)}
        />
      </div>

      <div class="flex flex-wrap items-center justify-between gap-3">
        <p id="node-enrollment-refresh-status" class="text-xs text-slate-500 dark:text-slate-400">
          <%= if refresh_stopped?(@enrollment) do %>
            Automatic checks have stopped because this enrollment or Node reached a terminal state.
            Use Refresh now to reload its durable status.
          <% else %>
            Orchard checks registration automatically every {refresh_interval_label()}.
          <% end %>
          <span :if={@last_checked_at}>
            Last checked <.local_time value={@last_checked_at} format={:time_second} />.
          </span>
        </p>
        <div class="flex flex-wrap gap-2">
          <.button id="node-enrollment-refresh" variant={:ghost} size={:sm} phx-click="refresh_now">
            Refresh now
          </.button>
          <.link
            :if={
              @enrollment && reviewable_for_admission?(@enrollment) &&
                !terminal_enrollment?(@enrollment)
            }
            id="review-node-admission"
            navigate={~p"/console/nodes/#{@delivery.node_id}"}
            class="inline-flex items-center justify-center rounded-md bg-navy px-4 py-2 text-sm font-medium text-white hover:bg-navy-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy focus-visible:ring-offset-2 dark:bg-sky-500 dark:hover:bg-sky-400 dark:focus-visible:ring-sky-400"
          >
            Review and Admit Node
          </.link>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:complete, :boolean, required: true)
  attr(:detail, :string, required: true)

  defp status_row(assigns) do
    ~H"""
    <div class="flex items-start gap-3 rounded-lg border border-slate-200 p-4 dark:border-slate-700">
      <span class={[
        "mt-0.5 inline-flex size-6 shrink-0 items-center justify-center rounded-full",
        @complete && "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300",
        !@complete && "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"
      ]}>
        <%= if @complete do %>
          <.icon name="hero-check" class="size-4" />
        <% else %>
          <span class="size-2 rounded-full bg-current"></span>
        <% end %>
      </span>
      <div>
        <p class="text-sm font-medium text-slate-950 dark:text-white">{@label}</p>
        <p class="mt-1 text-xs text-slate-500 dark:text-slate-400">{@detail}</p>
      </div>
    </div>
    """
  end

  attr(:message, :string, required: true)

  defp failure_step(assigns) do
    ~H"""
    <section id="node-enrollment-failure-step" class="space-y-5">
      <.state_message
        id="node-enrollment-delivery-failed"
        kind={:error}
        layout={:panel}
        title="Enrollment download was not completed."
        body={@message}
      />
      <div class="flex justify-end">
        <.button id="create-new-node-enrollment" phx-click="create_new_enrollment">
          Create New Enrollment
        </.button>
      </div>
    </section>
    """
  end

  attr(:message, :string, required: true)

  defp recovery_failure_step(assigns) do
    ~H"""
    <section id="node-enrollment-recovery-failed" class="space-y-5">
      <.state_message
        id="node-enrollment-recovery-error"
        kind={:error}
        layout={:panel}
        title="Enrollment cannot be resumed here."
        body={@message}
      />
      <div class="flex justify-end">
        <.button id="create-console-node-enrollment" phx-click="create_new_enrollment">
          Create New Enrollment
        </.button>
      </div>
    </section>
    """
  end

  defp assign_initial_state(socket) do
    assign(socket,
      stage: :prepare,
      form:
        to_form(
          %{"display_name" => "", "expiry_seconds" => "3600", "pool_id" => "general"},
          as: :enrollment
        ),
      delivery: nil,
      enrollment: nil,
      error_message: nil,
      refresh_timer_ref: nil,
      last_checked_at: nil,
      expiry_options: @expiry_options
    )
  end

  defp validate_form(params) do
    form_params = %{
      "display_name" => normalize_text(params["display_name"]),
      "expiry_seconds" => normalize_text(params["expiry_seconds"]),
      "pool_id" => normalize_text(params["pool_id"])
    }

    errors =
      []
      |> require_text(:display_name, form_params["display_name"], "must not be empty")
      |> require_text(:pool_id, form_params["pool_id"], "must not be empty")
      |> validate_expiry(form_params["expiry_seconds"])

    validate_normalized_form(form_params, errors)
  end

  defp validate_normalized_form(form_params, []),
    do: validate_shared_attrs(form_params, shared_attrs(form_params))

  defp validate_normalized_form(form_params, errors),
    do: {:error, {:validation, to_form(form_params, as: :enrollment, errors: errors)}}

  defp shared_attrs(form_params) do
    %{
      creator_id: nil,
      creator_type: "operator",
      display_name: form_params["display_name"],
      expiry_seconds: String.to_integer(form_params["expiry_seconds"]),
      pool_id: form_params["pool_id"],
      surface: "console"
    }
  end

  defp validate_shared_attrs(form_params, attrs) do
    case NodeEnrollmentBundle.validate_attrs(attrs) do
      {:ok, normalized} ->
        {:ok, normalized, form_params}

      {:error, {:invalid_enrollment_bundle_attrs, shared_errors}} ->
        errors = Enum.map(shared_errors, &shared_form_error/1)
        {:error, {:validation, to_form(form_params, as: :enrollment, errors: errors)}}
    end
  end

  defp shared_form_error({field, reason}),
    do: {field, {shared_validation_message(field, reason), []}}

  defp normalize_text(value) when is_binary(value), do: String.trim(value)
  defp normalize_text(_value), do: ""

  defp require_text(errors, field, "", message), do: [{field, {message, []}} | errors]
  defp require_text(errors, _field, _value, _message), do: errors

  defp validate_expiry(errors, value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds in @expiry_seconds -> errors
      _other -> [{:expiry_seconds, {"must be one of the available periods", []}} | errors]
    end
  end

  defp shared_validation_message(:display_name, :too_long),
    do: "must be 128 bytes or fewer"

  defp shared_validation_message(:display_name, :invalid_format),
    do: "must not contain control characters"

  defp shared_validation_message(:pool_id, :too_long), do: "must be 64 bytes or fewer"

  defp shared_validation_message(:pool_id, :invalid_format),
    do: "may contain only letters, numbers, dots, underscores, and hyphens"

  defp shared_validation_message(_field, _reason), do: "is invalid"

  defp safe_issue(attrs) do
    enrollment_issuer_impl().issue(attrs)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp safe_mark_issued(enrollment_id) do
    enrollments_impl().mark_issued(enrollment_id, actor_id: nil, actor_type: "operator")
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp safe_mark_output_failed(enrollment_id, reason) do
    enrollments_impl().mark_output_failed(enrollment_id,
      actor_id: nil,
      actor_type: "operator",
      reason: reason
    )
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp refresh_enrollment(%{assigns: %{delivery: %{enrollment_id: id}}} = socket) do
    case safe_fetch(id) do
      {:ok, enrollment} ->
        assign(socket,
          enrollment: enrollment,
          error_message: nil,
          last_checked_at: DateTime.utc_now()
        )

      {:error, _reason} ->
        assign(socket, error_message: "Orchard could not read the latest enrollment state.")
    end
  end

  defp refresh_enrollment(socket), do: socket

  defp reconcile_delivery(socket, enrollment_id, acknowledgement) do
    case safe_fetch(enrollment_id) do
      {:ok, enrollment} -> reconcile_enrollment(socket, enrollment, acknowledgement)
      {:error, _reason} -> delivery_uncertain(socket)
    end
  end

  defp reconcile_enrollment(socket, %{state: :output_failed}, acknowledgement)
       when acknowledgement in [:downloaded, :confirmation_failed] do
    delivery_failed(
      socket,
      "The browser accepted the download, but Orchard could not confirm publication. The downloaded bundle is not redeemable and did not establish Node identity or trust. The previous provisioned Node remains in audit history. Create a new enrollment with a distinct Node name."
    )
  end

  defp reconcile_enrollment(socket, %{state: :output_failed}, _acknowledgement),
    do: delivery_failed(socket)

  defp reconcile_enrollment(socket, %{state: :pending_publication}, :downloaded) do
    enrollment_id = socket.assigns.delivery.enrollment_id

    case safe_mark_output_failed(enrollment_id, "publication_confirmation_failed") do
      {:ok, enrollment} -> reconcile_enrollment(socket, enrollment, :confirmation_failed)
      {:error, _reason} -> reconcile_delivery(socket, enrollment_id, :confirmation_failed)
    end
  end

  defp reconcile_enrollment(socket, %{state: :pending_publication} = enrollment, :failed),
    do: delivery_uncertain(socket, enrollment)

  defp reconcile_enrollment(
         socket,
         %{state: :pending_publication} = enrollment,
         :confirmation_failed
       ),
       do: delivery_uncertain(socket, enrollment)

  defp reconcile_enrollment(socket, enrollment, _acknowledgement),
    do: enter_monitor(socket, enrollment)

  defp enter_monitor(socket, enrollment) do
    socket
    |> assign(
      stage: :monitor,
      enrollment: enrollment,
      error_message: nil,
      last_checked_at: DateTime.utc_now()
    )
    |> refresh_enrollment()
    |> schedule_refresh()
  end

  defp restore_enrollment(socket, enrollment) do
    socket
    |> cancel_refresh()
    |> assign(
      stage: :monitor,
      delivery: delivery_from_enrollment(enrollment),
      enrollment: enrollment,
      error_message: nil,
      last_checked_at: DateTime.utc_now()
    )
    |> schedule_refresh()
  end

  defp restore_console_enrollment(socket, enrollment) do
    if console_enrollment?(enrollment) do
      restore_enrollment(socket, enrollment)
    else
      recovery_failed(
        socket,
        "This enrollment was created outside this Console flow. Continue from the surface that issued it, or create a new Console enrollment."
      )
    end
  end

  defp delivery_from_enrollment(enrollment) do
    %{
      enrollment_id: enrollment.id,
      expires_at: enrollment.expires_at,
      filename: NodeEnrollmentBundle.filename(enrollment.node.display_name),
      node_id: enrollment.node_id,
      display_name: enrollment.node.display_name
    }
  end

  defp delivery_failed(socket, message \\ nil) do
    assign(socket,
      stage: :delivery_failed,
      error_message:
        message ||
          "The browser could not download the enrollment file. No redeemable enrollment was left behind, and the bundle did not establish Node identity or trust. The previous provisioned Node remains in audit history. Check browser download permissions, then create a new enrollment with a distinct Node name."
    )
  end

  defp delivery_uncertain(socket, enrollment \\ nil) do
    socket
    |> assign(
      stage: :monitor,
      enrollment: enrollment || socket.assigns.enrollment,
      error_message:
        "Orchard could not confirm the bundle delivery result. No Node identity or trust has been established while the enrollment remains non-redeemable. Keep this page open while Orchard checks the durable enrollment state.",
      last_checked_at:
        if(enrollment, do: DateTime.utc_now(), else: socket.assigns.last_checked_at)
    )
    |> schedule_refresh()
  end

  defp recovery_failed(socket, message) do
    socket
    |> cancel_refresh()
    |> assign(
      stage: :recovery_failed,
      delivery: nil,
      enrollment: nil,
      error_message: message,
      last_checked_at: nil
    )
  end

  defp console_enrollment?(%{audit_metadata: %{"surface" => "console"}}), do: true
  defp console_enrollment?(_enrollment), do: false

  defp safe_fetch(id) do
    enrollments_impl().fetch(id)
  rescue
    _error -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
    _kind, _reason -> {:error, :unavailable}
  end

  defp schedule_refresh(%{assigns: %{stage: :monitor, enrollment: enrollment}} = socket)
       when not is_nil(enrollment) do
    if refresh_stopped?(enrollment) do
      cancel_refresh(socket)
    else
      schedule_monitor_refresh(socket)
    end
  end

  defp schedule_refresh(%{assigns: %{stage: :monitor}} = socket),
    do: schedule_monitor_refresh(socket)

  defp schedule_refresh(socket), do: socket

  defp schedule_monitor_refresh(socket) do
    socket = cancel_refresh(socket)
    generation = make_ref()

    timer_ref =
      Process.send_after(self(), {:refresh_enrollment, generation}, refresh_interval_ms())

    assign(socket, refresh_timer_ref: {timer_ref, generation})
  end

  defp cancel_refresh(%{assigns: %{refresh_timer_ref: nil}} = socket), do: socket

  defp cancel_refresh(socket) do
    {timer_ref, _generation} = socket.assigns.refresh_timer_ref
    Process.cancel_timer(timer_ref)
    assign(socket, refresh_timer_ref: nil)
  end

  defp enrollment_issuer_impl do
    console_config()[:node_enrollment_bundle_issuer_impl] || NodeEnrollmentBundle
  end

  defp enrollments_impl do
    console_config()[:node_enrollments_impl] || NodeEnrollments
  end

  defp refresh_interval_ms do
    console_config()[:refresh_interval_ms] || @default_refresh_interval_ms
  end

  defp refresh_interval_label, do: "#{div(refresh_interval_ms(), 1_000)} seconds"

  defp console_config, do: Application.get_env(:orchard_controller, :console, [])

  defp progress_state(:monitor, %{node: %{state: state}}, step)
       when state in [:decommissioning, :removed] do
    if step <= 3, do: :complete, else: :unavailable
  end

  defp progress_state(:monitor, %{node: %{state: state}}, step)
       when state in [:cordoned, :draining, :maintenance] do
    if step <= 4, do: :complete, else: :unavailable
  end

  defp progress_state(stage, enrollment, step) do
    current = current_step(stage, enrollment)

    cond do
      step < current -> :complete
      step == current -> :current
      true -> :pending
    end
  end

  defp current_step(:prepare, _enrollment), do: 1
  defp current_step(:loading, _enrollment), do: 3
  defp current_step(:enrollment, _enrollment), do: 2
  defp current_step(:delivering, _enrollment), do: 2
  defp current_step(:delivery_failed, _enrollment), do: 2
  defp current_step(:recovery_failed, _enrollment), do: 2
  defp current_step(:monitor, %{state: :pending_publication}), do: 2
  defp current_step(:monitor, %{node: %{state: :active}}), do: 6

  defp current_step(:monitor, %{node: %{state: state}})
       when state in [:admitted, :cordoned, :draining, :maintenance, :decommissioning, :removed],
       do: 5

  defp current_step(:monitor, %{node: %{state: :registered}}), do: 4
  defp current_step(:monitor, _enrollment), do: 3

  defp monitor_step_number(enrollment), do: min(current_step(:monitor, enrollment), 5)

  defp live_announcement(:delivering, _enrollment, _error_message),
    do: "Starting the one-time enrollment download."

  defp live_announcement(:delivery_failed, _enrollment, _error_message),
    do: "Enrollment download failed. No Node identity or trust was established."

  defp live_announcement(:recovery_failed, _enrollment, _error_message),
    do: "Enrollment recovery failed."

  defp live_announcement(:monitor, enrollment, error_message) when not is_nil(enrollment) do
    cond do
      terminal_enrollment?(enrollment) ->
        "This enrollment can no longer register a node."

      enrollment.state == :pending_publication ->
        "Waiting for download confirmation. No Node identity or trust was established."

      true ->
        error_message || monitor_title(enrollment, enrollment.node.display_name)
    end
  end

  defp live_announcement(_stage, _enrollment, error_message), do: error_message || ""

  defp monitor_progress_label(%{node: %{state: state}})
       when state in [:decommissioning, :removed],
       do: "Terminal lifecycle state"

  defp monitor_progress_label(%{node: %{state: state}})
       when state in [:cordoned, :draining, :maintenance],
       do: "Post-activation lifecycle state"

  defp monitor_progress_label(enrollment),
    do: "Step #{monitor_step_number(enrollment)} of 5"

  defp progress_circle_class(:complete),
    do: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950 dark:text-emerald-300"

  defp progress_circle_class(:current),
    do: "bg-navy text-white ring-4 ring-sky-100 dark:bg-sky-500 dark:ring-sky-950"

  defp progress_circle_class(:pending),
    do: "bg-slate-100 text-slate-500 dark:bg-slate-800 dark:text-slate-400"

  defp progress_circle_class(:unavailable),
    do: "bg-slate-100 text-slate-400 dark:bg-slate-800 dark:text-slate-500"

  defp progress_state_label(:complete), do: "complete"
  defp progress_state_label(:current), do: "current step"
  defp progress_state_label(:pending), do: "pending"
  defp progress_state_label(:unavailable), do: "unavailable"

  defp registered?(%{node: %{state: state}})
       when state in [
              :registered,
              :admitted,
              :active,
              :cordoned,
              :draining,
              :maintenance,
              :decommissioning,
              :removed
            ],
       do: true

  defp registered?(_enrollment), do: false

  defp admitted?(%{node: %{state: state}})
       when state in [:admitted, :active, :cordoned, :draining, :maintenance],
       do: true

  defp admitted?(_enrollment), do: false

  defp reviewable_for_admission?(%{node: %{state: :registered}}), do: true
  defp reviewable_for_admission?(_enrollment), do: false

  defp activation_complete?(%{node: %{state: state}})
       when state in [:active, :cordoned, :draining, :maintenance],
       do: true

  defp activation_complete?(_enrollment), do: false

  defp terminal_enrollment?(%{state: state}) when state in [:expired, :revoked, :output_failed],
    do: true

  defp terminal_enrollment?(%{state: state, expires_at: %DateTime{} = expires_at})
       when state in [:pending_publication, :issued] do
    DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  end

  defp terminal_enrollment?(_enrollment), do: false

  defp refresh_stopped?(enrollment),
    do: terminal_enrollment?(enrollment) or removed_node?(enrollment)

  defp removed_node?(%{node: %{state: :removed}}), do: true
  defp removed_node?(_enrollment), do: false

  defp terminal_enrollment_message(%{state: :revoked}),
    do:
      "The enrollment was revoked. It cannot establish Node identity or trust. The provisioned Node remains in audit history, so a new enrollment needs a distinct Node name."

  defp terminal_enrollment_message(%{state: :output_failed}),
    do:
      "Bundle delivery failed. It did not establish Node identity or trust. The provisioned Node remains in audit history, so a new enrollment needs a distinct Node name."

  defp terminal_enrollment_message(_enrollment),
    do:
      "The enrollment expired. It cannot establish Node identity or trust. The provisioned Node remains in audit history, so a new enrollment needs a distinct Node name."

  defp registration_detail(enrollment) do
    if registered?(enrollment),
      do: "The node agent registered successfully",
      else: "Waiting for orchardctl node join on the target Mac"
  end

  defp admission_detail(%{node: %{state: :decommissioning}}),
    do: "Admission actions are unavailable while the Node is being decommissioned"

  defp admission_detail(%{node: %{state: :removed}}),
    do: "Admission actions are unavailable for a removed Node"

  defp admission_detail(enrollment) do
    if admitted?(enrollment),
      do: "Human admission decision recorded",
      else: "Available after registration and trust evidence review"
  end

  defp activation_detail(%{node: %{state: :active}}),
    do: "The node may receive scheduled work"

  defp activation_detail(%{node: %{state: :cordoned}}),
    do: "No new work will be scheduled; existing work may continue"

  defp activation_detail(%{node: %{state: :draining}}),
    do: "Waiting for active requests to finish; no new work will be scheduled"

  defp activation_detail(%{node: %{state: :maintenance}}),
    do: "Unschedulable while upgrades or diagnostics run"

  defp activation_detail(%{node: %{state: :decommissioning}}),
    do: "Trust revocation and cleanup are in progress"

  defp activation_detail(%{node: %{state: :removed}}),
    do: "This Node is a terminal tombstone and cannot receive work"

  defp activation_detail(_enrollment),
    do: "Activation follows admission and a fresh runtime observation"

  defp usable_bundle?(%{
         state: :issued,
         node: %{state: :provisioned},
         expires_at: %DateTime{} = expires_at
       }),
       do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp usable_bundle?(_enrollment), do: false

  defp monitor_title(%{state: :pending_publication} = enrollment, display_name) do
    if terminal_enrollment?(enrollment),
      do: "Enrollment for #{display_name} expired",
      else: "Confirm the enrollment download"
  end

  defp monitor_title(%{node: %{state: :registered}}, display_name),
    do: "Review and admit #{display_name}"

  defp monitor_title(%{node: %{state: :active}}, display_name),
    do: "#{display_name} is active"

  defp monitor_title(%{node: %{state: :admitted}}, display_name),
    do: "Await activation for #{display_name}"

  defp monitor_title(%{node: %{state: :cordoned}}, display_name),
    do: "#{display_name} is cordoned"

  defp monitor_title(%{node: %{state: :draining}}, display_name),
    do: "#{display_name} is draining"

  defp monitor_title(%{node: %{state: :maintenance}}, display_name),
    do: "#{display_name} is in maintenance"

  defp monitor_title(%{node: %{state: :decommissioning}}, display_name),
    do: "#{display_name} is being decommissioned"

  defp monitor_title(%{node: %{state: :removed}}, display_name),
    do: "#{display_name} has been removed"

  defp monitor_title(_enrollment, display_name), do: "Install and register #{display_name}"

  defp issue_error(:node_trust_not_initialized),
    do: "Node trust is not initialized on this Controller."

  defp issue_error(:controller_https_not_configured),
    do: "Configure the Controller HTTPS endpoint before creating an enrollment."

  defp issue_error(:controller_https_trust_invalid),
    do: "The Controller HTTPS trust certificate is unavailable or invalid."

  defp issue_error(:controller_standby),
    do: "This Controller is on standby. Create the enrollment on the active Controller."

  defp issue_error(:controller_leadership_unproven),
    do: "Controller leadership could not be proven, so no enrollment was issued."

  defp issue_error(%Ecto.Changeset{}),
    do: "The node name is already in use or is invalid. Choose another name."

  defp issue_error(_reason),
    do:
      "Orchard could not create the enrollment. Verify Controller trust and HTTPS settings, then try again."
end
