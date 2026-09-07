defmodule OrchardConsole.WorkspaceHandoffLive do
  @moduledoc "Guides an operator through a scoped colleague handoff without impersonating the colleague."
  use OrchardConsole, :live_view

  alias Orchard.Governance
  alias Orchard.Governance.PortalActivationCurl
  alias OrchardConsole.{WorkspaceAccess, WorkspacePresentation}

  @steps [
    "Workspace",
    "Model access",
    "Portal invitation",
    "Review scope",
    "Colleague handoff",
    "First request"
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Colleague handoff", active_nav: :tenants, steps: @steps)
     |> reset(nil)}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, socket) do
    socket = if socket.assigns.workspace_id == id, do: socket, else: reset(socket, id)

    socket =
      if connected?(socket) and socket.assigns.status == :loading, do: load(socket), else: socket

    step =
      min(requested_step(params["step"], socket.assigns.step), navigation_limit(socket.assigns))

    socket = if step == 5, do: socket, else: clear_invite(socket)
    {:noreply, assign(socket, step: step)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, socket |> clear_invite() |> load()}

  def handle_event("choose_model", %{"model" => %{"id" => id}}, socket) do
    case Enum.find(socket.assigns.rows, &(&1.model.id == id)) do
      nil ->
        {:noreply,
         socket
         |> clear_invite()
         |> assign(selected: nil, model_id: nil, unlocked: 2)
         |> put_flash(:error, "Choose a model from this Workspace's current catalog read.")}

      row ->
        {:noreply,
         socket
         |> clear_invite()
         |> assign(
           model_id: row.model.id,
           selected: row,
           unlocked: max(3, socket.assigns.unlocked),
           portal_url: portal_url(socket.assigns.workspace, row)
         )}
    end
  end

  def handle_event("colleague_change", %{"colleague" => %{"email" => email}}, socket) do
    {:noreply, socket |> clear_invite() |> assign(email: email, user: nil, unlocked: 3)}
  end

  def handle_event("prepare_colleague", %{"colleague" => %{"email" => email}}, socket) do
    socket = socket |> clear_invite() |> assign(email: email, user: nil, unlocked: 3)

    if socket.assigns.status == :ok and socket.assigns.selected do
      {:noreply, prepare_colleague(socket, String.downcase(String.trim(email)))}
    else
      {:noreply, put_flash(socket, :error, "Refresh Workspace data and choose a model first.")}
    end
  end

  def handle_event("next", _params, socket) do
    next = socket.assigns.step + 1

    if next <= 6 and can_advance?(socket.assigns) do
      {:noreply, socket |> assign(unlocked: max(next, socket.assigns.unlocked)) |> go(next)}
    else
      {:noreply, put_flash(socket, :error, "Complete the current selection before continuing.")}
    end
  end

  def handle_event("issue_invite", _params, socket) do
    if socket.assigns.step == 5 and socket.assigns.status == :ok and
         not is_nil(socket.assigns.selected) and
         match?(%{status: "invited"}, socket.assigns.user) do
      {:noreply, issue_invite(clear_invite(socket))}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Only an invited Portal User in this Workspace can receive an invite link. Refresh to check their status."
       )}
    end
  end

  def handle_event("generated_secret_copied", _params, socket),
    do: {:noreply, assign(socket, copy_status: :copied)}

  def handle_event("generated_secret_copy_failed", _params, socket),
    do: {:noreply, assign(socket, copy_status: :failed)}

  @impl true
  def handle_info({:expire_invite, expires_at}, socket) do
    if socket.assigns.invite && socket.assigns.invite.expires_at == expires_at do
      {:noreply,
       socket
       |> clear_invite()
       |> put_flash(
         :info,
         "The invite URL expired. Refresh and issue a new link if the user is still invited."
       )}
    else
      {:noreply, socket}
    end
  end

  defp reset(socket, id) do
    socket
    |> clear_invite()
    |> assign(
      workspace_id: id,
      workspace: nil,
      status: :loading,
      rows: [],
      selected: nil,
      model_id: nil,
      email: "",
      user: nil,
      step: 2,
      unlocked: 2,
      portal_url: nil
    )
  end

  defp load(socket) do
    with {:ok, workspace} <- Governance.get_tenant(socket.assigns.workspace_id),
         {:ok, rows} <- WorkspaceAccess.list(workspace),
         {:ok, users} <- Governance.list_portal_user_summaries(workspace) do
      selected = Enum.find(rows, &(&1.model.id == socket.assigns.model_id))
      user = if socket.assigns.user, do: Enum.find(users, &(&1.id == socket.assigns.user.id))

      socket
      |> assign(
        workspace: workspace,
        rows: rows,
        selected: selected,
        model_id: if(selected, do: selected.model.id),
        user: user,
        status: :ok,
        portal_url: portal_url(workspace, selected)
      )
      |> reconcile_navigation()
    else
      {:error, :tenant_not_found} ->
        assign(socket, status: :not_found, workspace: nil, selected: nil, user: nil)

      {:error, _reason} ->
        assign(socket, status: :error)
    end
  rescue
    _error in [Ecto.Query.CastError, Ecto.NoResultsError] -> assign(socket, status: :not_found)
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> assign(socket, status: :error)
  end

  defp prepare_colleague(socket, email) do
    case Governance.list_portal_user_summaries(socket.assigns.workspace) do
      {:ok, users} ->
        case Enum.find(users, &(&1.email == email)) do
          %{status: "disabled"} ->
            put_flash(
              socket,
              :error,
              "This Portal User is disabled. Use Workspace management to resolve access; no new invitation was created."
            )

          %{} = user ->
            accept_user(socket, user)

          nil ->
            create_user(socket, email)
        end

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          "Unable to check Portal Users. Retry without changing Workspace."
        )
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      put_flash(
        socket,
        :error,
        "Unable to save Portal User state. Retry to check whether the identity was saved; your model and email are retained."
      )
  end

  defp create_user(socket, email) do
    case Governance.create_portal_invite(socket.assigns.workspace, %{email: email}) do
      {:ok, user} ->
        accept_user(socket, user)

      {:error, %Ecto.Changeset{}} ->
        put_flash(
          socket,
          :error,
          "Enter a valid colleague email. If the user was just created elsewhere, retry to use their existing identity."
        )

      {:error, :https_required} ->
        put_flash(socket, :error, "Configure public HTTPS before creating Portal invitations.")

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          "Unable to create the Portal User. Your model and email are retained for retry."
        )
    end
  end

  defp accept_user(socket, user), do: socket |> assign(user: user, unlocked: 4) |> go(4)

  defp issue_invite(socket) do
    base = PortalActivationCurl.public_base_url()

    if base do
      issue_invite(socket, base)
    else
      put_flash(
        socket,
        :error,
        "Configure a public HTTPS Portal address before issuing a link for delivery."
      )
    end
  end

  defp issue_invite(socket, base) do
    case Governance.copy_portal_invite(socket.assigns.workspace, socket.assigns.user.id) do
      {:ok, invite} ->
        timer =
          Process.send_after(
            self(),
            {:expire_invite, invite.expires_at},
            max(DateTime.diff(invite.expires_at, DateTime.utc_now(), :millisecond), 0)
          )

        query = URI.encode_query(%{"model" => identity(socket.assigns.selected.model)})

        visible = %{
          url: String.trim_trailing(base, "/") <> invite.url <> "?" <> query,
          expires_at: invite.expires_at
        }

        assign(socket, invite: visible, invite_timer: timer, copy_status: :pending)

      {:error, _reason} ->
        put_flash(
          socket,
          :error,
          "Unable to issue the invite link. The Portal User is already saved; retry link issuance without recreating them."
        )
    end
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      put_flash(
        socket,
        :error,
        "Unable to issue the invite link. The Portal User is already saved; retry link issuance without recreating them."
      )
  end

  defp clear_invite(socket) do
    if ref = socket.assigns[:invite_timer], do: Process.cancel_timer(ref)
    assign(socket, invite: nil, invite_timer: nil, copy_status: :pending)
  end

  defp can_advance?(%{status: status}) when status != :ok, do: false
  defp can_advance?(%{step: 1}), do: true
  defp can_advance?(%{step: 2, selected: selected}), do: not is_nil(selected)

  defp can_advance?(%{step: step, user: user, selected: selected}) when step in [4, 5],
    do: not is_nil(selected) and not is_nil(user) and user.status != "disabled"

  defp can_advance?(_assigns), do: false

  defp navigation_limit(%{selected: nil}), do: 2
  defp navigation_limit(%{user: %{status: "disabled"}, unlocked: unlocked}), do: min(3, unlocked)
  defp navigation_limit(%{user: nil, unlocked: unlocked}), do: min(3, unlocked)
  defp navigation_limit(%{unlocked: unlocked}), do: unlocked

  defp reconcile_navigation(socket) do
    previous_step = socket.assigns.step
    limit = navigation_limit(socket.assigns)
    step = min(previous_step, limit)
    socket = assign(socket, step: step, unlocked: limit)

    if step < previous_step do
      message =
        if socket.assigns.selected,
          do: "Portal User is unavailable or disabled. Review the colleague before continuing.",
          else: "Selected model is no longer in Catalog. Choose a model to continue."

      socket |> put_flash(:info, message) |> go(step)
    else
      socket
    end
  end

  defp go(socket, step),
    do: push_patch(socket, to: handoff_path(socket.assigns.workspace_id, step))

  defp handoff_path(id, step), do: "/console/access/workspaces/#{id}/handoff?step=#{step}"

  defp requested_step(value, fallback) do
    case Integer.parse(value || "") do
      {step, ""} when step in 1..6 -> step
      _ -> fallback
    end
  end

  defp identity(model), do: "#{model.model_id}@#{model.version}"
  defp grant_label(:enabled), do: "Granted"
  defp grant_label(:disabled), do: "Disabled"
  defp grant_label(:not_granted), do: "Not granted"

  defp portal_url(workspace, selected) do
    if base = PortalActivationCurl.public_base_url() do
      query =
        if selected, do: "?" <> URI.encode_query(%{"model" => identity(selected.model)}), else: ""

      String.trim_trailing(base, "/") <>
        "/portal/" <> URI.encode(workspace.slug, &URI.char_unreserved?/1) <> query
    end
  end

  defp request_example(row) do
    body =
      Jason.encode!(%{
        model: identity(row.model),
        messages: [%{role: "user", content: "Say hello in one sentence."}]
      })

    "POST /v1/chat/completions\nAuthorization: Bearer <YOUR_OWN_API_KEY>\nContent-Type: application/json\n\n" <>
      body
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.link navigate="/console/access" class="text-sm text-navy dark:text-sky-400">Back to Access</.link>
      <.card>
        <:title>Help a colleague use a model</:title>
        <:subtitle>One Workspace, one exact model, and a separate personal Portal sign-in.</:subtitle>
        <div :if={@workspace} id="handoff-scope" class="text-sm">
          <span class="font-semibold">{WorkspacePresentation.display_name(@workspace)}</span>
          <span class="mt-1 block font-mono break-all text-slate-500 dark:text-slate-400">{@workspace.slug}</span>
          <p :if={@selected} class="mt-2 font-mono break-all">{identity(@selected.model)}</p>
        </div>
      </.card>
      <nav aria-label="Colleague handoff steps" class="rounded-lg border border-slate-200 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
        <p class="mb-3 text-sm font-semibold">Step {@step} of 6: {Enum.at(@steps, @step - 1)}</p>
        <ol class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
          <li :for={{label, number} <- Enum.with_index(@steps, 1)}>
            <.link :if={number <= @unlocked} patch={handoff_path(@workspace_id, number)} aria-current={if number == @step, do: "step"} class={["flex items-center gap-2 rounded-md p-2 text-sm", if(number == @step, do: "bg-navy/10 font-semibold text-navy dark:text-sky-400", else: "text-slate-600 dark:text-slate-300")]}>
              <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full border">{number}</span>{label}
            </.link>
            <span :if={number > @unlocked} aria-disabled="true" class="flex items-center gap-2 p-2 text-sm text-slate-400 dark:text-slate-500"><span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full border">{number}</span>{label}</span>
          </li>
        </ol>
        <p class="mt-3 text-xs text-slate-500">Steps orient this handoff. Visiting a step does not prove an invitation was accepted or a request succeeded.</p>
      </nav>
      <div :if={@status != :ok} id="handoff-load-state" role="status" class="rounded-lg border border-slate-200 bg-white p-6 dark:border-slate-700 dark:bg-slate-800">
        <p>{case @status do
          :loading -> "Loading Workspace…"
          :not_found -> "Workspace not found. Return to Access to choose an existing Workspace."
          :error -> "Unable to read Workspace access. Previous selections are retained, but actions are unavailable until refresh succeeds."
        end}</p>
        <.button :if={@status != :loading} phx-click="refresh" class="mt-4">Retry read</.button>
      </div>
      <section :if={@status == :ok} id={"handoff-step-#{@step}"} aria-labelledby={"handoff-heading-#{@step}"} class="rounded-lg border border-slate-200 bg-white p-6 dark:border-slate-700 dark:bg-slate-800" phx-mounted={Phoenix.LiveView.JS.focus(to: "#handoff-heading-#{@step}")}>
        <h2 id={"handoff-heading-#{@step}"} tabindex="-1" class="text-xl font-semibold">{Enum.at(@steps, @step - 1)}</h2>
        <div :if={@step == 1} class="mt-4 space-y-3">
          <p>This handoff is scoped to {WorkspacePresentation.display_name(@workspace)}. Available Workspaces are destinations you can choose, not the colleague's permissions.</p>
          <p :if={WorkspacePresentation.default?(@workspace)}>The built-in Default Workspace is already selected. This does not grant model access.</p>
          <.link navigate="/console/access" class="text-navy dark:text-sky-400">Choose a different Workspace and start a new handoff</.link>
        </div>
        <div :if={@step == 2} class="mt-4 space-y-4">
          <p>Choose an exact catalog model for this Workspace. Runtime readiness is checked separately.</p>
          <p :if={@rows == []}>No catalog models are available. Import a model from Models, then return and refresh.</p>
          <.form :if={@rows != []} for={to_form(%{"id" => @model_id || ""}, as: :model)} id="handoff-model-form" phx-change="choose_model">
            <label for="handoff-model-id" class="block text-sm font-medium">Catalog model</label>
            <select id="handoff-model-id" name="model[id]" class="mt-2 w-full rounded-md border border-slate-200 bg-slate-50 p-3 text-sm shadow-inner focus-visible:outline-none focus-visible:border-navy focus-visible:ring-2 focus-visible:ring-navy/40 focus-visible:ring-offset-2 focus-visible:ring-offset-white dark:border-slate-700 dark:bg-slate-900/60 dark:focus-visible:border-sky-400 dark:focus-visible:ring-sky-400/40 dark:focus-visible:ring-offset-slate-900">
              <option value="">Choose a model</option>
              <option :for={row <- @rows} value={row.model.id} selected={@model_id == row.model.id}>{identity(row.model)} - {grant_label(row.grant_state)}</option>
            </select>
          </.form>
          <div :if={@selected} id="handoff-model-access" class="space-y-3">
            <p>Model access: <strong>{grant_label(@selected.grant_state)}</strong>. Catalog state: {@selected.model.state}.</p>
            <div :if={@selected.grant_state != :enabled} class="space-y-2">
              <p>An authorized administrator must grant access. You may prepare the colleague handoff while access is pending; continuing does not grant it.</p>
              <pre class="overflow-x-auto rounded-md bg-slate-50 p-3 text-xs dark:bg-slate-900/60">{WorkspaceAccess.commands(@workspace, @selected.model, @selected.grant).grant}</pre>
              <p>After the administrator runs the command, refresh to read the actual grant.</p>
            </div>
            <pre class="overflow-x-auto rounded-md bg-slate-50 p-3 text-xs dark:bg-slate-900/60">{WorkspaceAccess.commands(@workspace, @selected.model, @selected.grant).inspect}</pre>
          </div>
        </div>
        <div :if={@step == 3} class="mt-4 space-y-4">
          <p>Identify the colleague in this Workspace. Existing active Portal Users are reused; an invitation grants no model permissions and sends no email.</p>
          <.form for={to_form(%{"email" => @email}, as: :colleague)} id="handoff-colleague-form" phx-change="colleague_change" phx-submit="prepare_colleague">
            <.input id="handoff-colleague-email" name="colleague[email]" value={@email} type="email" label="Colleague email" required />
            <.button type="submit" class="mt-4">Continue with this colleague</.button>
          </.form>
        </div>
        <div :if={@step == 4} class="mt-4 space-y-4">
          <p>Check each independent part of the handoff before sharing anything.</p>
          <p>Cluster administration and API credentials are not included in this invitation.</p>
          <dl class="space-y-3 text-sm">
            <div><dt class="font-semibold">Workspace</dt><dd>{WorkspacePresentation.display_name(@workspace)} ({@workspace.slug})</dd></div>
            <div><dt class="font-semibold">Model access</dt><dd>{if @selected, do: grant_label(@selected.grant_state), else: "Model no longer in catalog; return to Model access"}</dd></div>
            <div :if={@selected}><dt class="font-semibold">Catalog model</dt><dd>{@selected.model.state}; separate from runtime readiness.</dd></div>
            <div><dt class="font-semibold">Portal User</dt><dd>{if @user, do: "#{@user.email} - #{@user.status}", else: "User no longer available; return to Portal invitation"}</dd></div>
            <div><dt class="font-semibold">Personal API Key</dt><dd>The colleague creates their own key in the actual Portal. This Console flow does not create or inspect it.</dd></div>
            <div><dt class="font-semibold">Runtime and request</dt><dd>Not verified by this handoff.</dd></div>
          </dl>
          <.link :if={@selected && @selected.model.state != :active} navigate="/console/models/catalog" class="text-navy dark:text-sky-400">Review the model's lifecycle in Catalog</.link>
        </div>
        <div :if={@step == 5} class="mt-4 space-y-4">
          <p>No email is sent. Deliver the Portal link separately to the intended colleague.</p>
          <p :if={!@user || @user.status == "disabled"}>This Portal User is unavailable or disabled. Return to Portal invitation to resolve the colleague's access before sharing a link.</p>
          <p :if={@user && @user.status == "active"}>This Portal User is already active. They can sign in with their existing account; no new invitation is needed.</p>
          <div :if={@selected && @user && @user.status == "invited"} class="space-y-3">
            <p>The Portal User is saved. Issue an invite link separately. Each issuance invalidates any earlier unused invite link.</p>
            <.button id="handoff-issue-invite" phx-click="issue_invite">{if @invite, do: "Issue replacement invite", else: "Issue invite link"}</.button>
          </div>
          <div :if={@invite} id="handoff-invite" class="space-y-3 rounded-md bg-slate-50 p-4 dark:bg-slate-900/60">
            <p id="handoff-invite-value" class="break-all font-mono text-sm">{@invite.url}</p>
            <p>Expires <.local_time id="handoff-invite-expiry" value={@invite.expires_at} format={:datetime_minute} />. Copy before leaving; plaintext cannot be recovered on reload.</p>
            <button id="handoff-copy-invite" type="button" phx-hook="CopyGeneratedSecret" data-secret-source="handoff-invite-value" data-api-key-id="handoff-invite" class="rounded-md bg-navy px-3 py-2 text-sm text-white dark:bg-sky-500">Copy invite URL</button>
            <p role="status">{case @copy_status do :copied -> "Invite URL copied. Delivery and acceptance are not verified."; :failed -> "Copy failed. Select and copy the visible URL, or retry."; _ -> "Not yet copied." end}</p>
          </div>
          <p :if={!@portal_url}>A public HTTPS Portal address is not configured. Resolve this before delivering a usable Portal handoff.</p>
          <.link :if={@portal_url} href={@portal_url} target="_blank" rel="noopener noreferrer" class="text-navy dark:text-sky-400">Open this Workspace's Developer Portal</.link>
          <p>The colleague manages their own credential in the Portal. Return to Model access if their model grant is still missing.</p>
        </div>
        <div :if={@step == 6} class="mt-4 space-y-4">
          <p>The colleague sends a request from their own client to the configured public HTTPS endpoint using their own API Key. This is an inert example, not an executed request.</p>
          <pre :if={@selected} id="handoff-request-example" class="overflow-x-auto rounded-md bg-slate-50 p-3 text-xs dark:bg-slate-900/60">{request_example(@selected)}</pre>
          <p id="handoff-request-result">Request result: not observed. A valid key and model grant do not prove that a compatible Node is ready.</p>
          <p :if={@selected && @selected.grant_state != :enabled}>Model access is still {grant_label(@selected.grant_state)}. Return to Model access and complete the administrator handoff first.</p>
          <p :if={@selected && @selected.model.state == :deprecated}>This catalog model is deprecated. Deprecation does not by itself block inference; model access and runtime readiness still apply.</p>
          <p :if={@selected && @selected.model.state in [:registered, :retired]}>This catalog model is {@selected.model.state}, so it is not currently available for Public Inference.</p>
          <p>Console Playground uses its own default Workspace context; it does not execute this selected Workspace's handoff.</p>
        </div>
        <div class="mt-6 flex flex-wrap items-center gap-3 border-t border-slate-200 pt-4 dark:border-slate-700">
          <.link :if={@step > 1} patch={handoff_path(@workspace_id, @step - 1)} class="text-sm text-navy dark:text-sky-400">Back</.link>
          <.button :if={@step in [1, 2, 4, 5]} id="handoff-next" phx-click="next" disabled={!can_advance?(assigns)}>Continue</.button>
          <.button phx-click="refresh" variant={:secondary}>Refresh actual access and user state</.button>
        </div>
      </section>
    </div>
    """
  end
end
