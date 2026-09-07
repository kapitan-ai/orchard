defmodule OrchardConsole.TenantDetailLive do
  @moduledoc """
  Console Workspace detail page with API Token and API Client management.
  """

  use OrchardConsole, :live_view

  alias Orchard.API.Transport
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, PortalActivationCurl, RoleBinding, TenantApiKeySummary}

  alias OrchardConsole.{WorkspaceAccess, WorkspacePresentation}

  @sections ~w(overview model_access portal_users api_credentials)
  @console_audit_opts [actor_type: "operator", surface: "console"]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(
        tenant_id: id,
        section: "overview",
        model_access: [],
        model_access_error: nil,
        page_title: "Workspace",
        active_nav: :tenants,
        detail_status: :loading,
        tenant: nil,
        api_keys: [],
        api_clients: [],
        portal_users: [],
        portal_invite_url: nil,
        portal_invite_user_id: nil,
        portal_invite_expires_at: nil,
        portal_invite_expiry_timer_ref: nil,
        portal_https?: Transport.public_api_https_enabled?(),
        portal_base_url: PortalActivationCurl.public_base_url(),
        load_error: nil,
        generated_secret: nil
      )
      |> assign_blank_form()

    if connected?(socket) do
      {:ok, load_tenant_detail(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    section = valid_section(params["section"])

    socket =
      if params["id"] == socket.assigns.tenant_id do
        assign(socket, section: section)
      else
        socket
        |> clear_portal_invite()
        |> assign_blank_form()
        |> assign(
          tenant_id: params["id"],
          tenant: nil,
          generated_secret: nil,
          section: section,
          detail_status: :loading,
          model_access: [],
          model_access_error: nil
        )
        |> load_if_connected()
      end

    {:noreply, socket}
  end

  defp load_if_connected(socket) do
    if connected?(socket), do: load_tenant_detail(socket), else: socket
  end

  defp valid_section(section) when section in @sections, do: section
  defp valid_section(_section), do: "overview"

  @impl true
  def handle_event("legacy_section", %{"section" => section}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         "/console/access/workspaces/#{socket.assigns.tenant_id}?section=#{valid_section(section)}"
     )}
  end

  def handle_event("refresh_model_access", _params, socket) do
    {:noreply, load_model_access(socket)}
  end

  def handle_event("create_api_key", %{"api_key" => params}, socket) do
    create_api_key(socket, params)
  end

  def handle_event("revoke_api_key", %{"id" => api_key_id}, socket) do
    revoke_api_key(socket, api_key_id)
  end

  def handle_event("disable_api_client", %{"id" => api_client_id}, socket) do
    disable_api_client(socket, api_client_id)
  end

  def handle_event("dismiss_generated_secret", _params, socket) do
    {:noreply, assign(socket, generated_secret: nil)}
  end

  def handle_event("generated_secret_copied", %{"api_key_id" => id}, socket) do
    case socket.assigns.generated_secret do
      %{api_key_id: ^id} = secret ->
        {:noreply, assign(socket, generated_secret: %{secret | copy_status: :copied})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("generated_secret_copy_failed", %{"api_key_id" => id}, socket) do
    case socket.assigns.generated_secret do
      %{api_key_id: ^id} = secret ->
        {:noreply, assign(socket, generated_secret: %{secret | copy_status: :failed})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("create_portal_invite", %{"portal_invite" => params}, socket) do
    case Governance.create_portal_invite(socket.assigns.tenant, params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(portal_invite_form: to_form(%{"email" => ""}, as: :portal_invite))
         |> load_tenant_detail()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           portal_invite_form: changeset_to_form(changeset, :portal_invite, %{"email" => ""})
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to invite Portal User.")}
    end
  end

  def handle_event("copy_portal_invite", %{"portal_user_id" => user_id}, socket) do
    case Governance.copy_portal_invite(socket.assigns.tenant, user_id) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> show_portal_invite(user_id, invite)
         |> mark_portal_invite_pending(user_id, invite.expires_at)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to copy invite.")}
    end
  end

  def handle_event("disable_portal_user", %{"portal_user_id" => user_id}, socket) do
    case Governance.disable_portal_user(socket.assigns.tenant, user_id) do
      {:ok, _user} ->
        {:noreply, socket |> dismiss_invite_url_for(user_id) |> load_tenant_detail()}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to disable Portal User.")}
    end
  end

  defp dismiss_invite_url_for(socket, user_id) do
    if socket.assigns.portal_invite_user_id == user_id do
      clear_portal_invite(socket)
    else
      socket
    end
  end

  @impl true
  def handle_info(
        {:portal_invite_expired, user_id, expires_at},
        %{
          assigns: %{
            portal_invite_user_id: user_id,
            portal_invite_expires_at: expires_at
          }
        } = socket
      ) do
    {:noreply, socket |> clear_portal_invite() |> load_tenant_detail()}
  end

  def handle_info({:portal_invite_expired, _user_id, _expires_at}, socket),
    do: {:noreply, socket}

  defp show_portal_invite(socket, user_id, invite) do
    socket = cancel_portal_invite_timer(socket)

    timer_ref =
      Process.send_after(
        self(),
        {:portal_invite_expired, user_id, invite.expires_at},
        invite_expiry_delay_ms(invite.expires_at)
      )

    assign(socket,
      portal_invite_url: invite.url,
      portal_invite_user_id: user_id,
      portal_invite_expires_at: invite.expires_at,
      portal_invite_expiry_timer_ref: timer_ref
    )
  end

  defp mark_portal_invite_pending(socket, user_id, expires_at) do
    portal_users =
      Enum.map(socket.assigns.portal_users, fn
        %{id: ^user_id} = user ->
          %{user | invite_context: :pending, invite_expires_at: expires_at}

        user ->
          user
      end)

    assign(socket, portal_users: portal_users)
  end

  defp clear_portal_invite(socket) do
    socket
    |> cancel_portal_invite_timer()
    |> assign(
      portal_invite_url: nil,
      portal_invite_user_id: nil,
      portal_invite_expires_at: nil,
      portal_invite_expiry_timer_ref: nil
    )
  end

  defp cancel_portal_invite_timer(socket) do
    case socket.assigns.portal_invite_expiry_timer_ref do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _other -> false
    end

    socket
  end

  defp invite_expiry_delay_ms(expires_at) do
    expires_at
    |> DateTime.diff(DateTime.utc_now(), :microsecond)
    |> max(0)
    |> then(&div(&1 + 999, 1_000))
  end

  # -- Render --

  @impl true
  def render(%{detail_status: :loading} = assigns) do
    ~H"""
    <.state_message
      id="tenant-loading-card"
      kind={:loading}
      layout={:panel}
      title="Workspace Detail"
      body="Loading Workspace…"
    />
    """
  end

  def render(%{detail_status: :not_found} = assigns) do
    ~H"""
    <div id="tenant-not-found-card" class="space-y-4">
      <.link
        id="tenant-back-to-list"
        navigate="/console/access"
        class="inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Workspaces
      </.link>
      <.state_message
        id="tenant-not-found-message"
        kind={:empty}
        layout={:panel}
        title="Workspace not found"
        body="The requested Workspace does not exist or the ID is invalid."
      />
    </div>
    """
  end

  def render(%{detail_status: :error} = assigns) do
    ~H"""
    <div id="tenant-error-card" class="space-y-4">
      <.link
        id="tenant-back-to-list"
        navigate="/console/access"
        class="inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Workspaces
      </.link>
      <.state_message
        id="tenant-error-message"
        kind={:error}
        layout={:panel}
        title="Workspace details unavailable"
        body={@load_error}
      />
    </div>
    """
  end

  def render(%{detail_status: :ok} = assigns) do
    ~H"""
    <div id="workspace-detail" phx-hook="WorkspaceSections" class="space-y-6">
      <.link
        id="tenant-back-to-list"
        navigate="/console/access"
        class="inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Workspaces
      </.link>

      <header id="tenant-access-header" class="space-y-2">
        <p class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
          Current Workspace
        </p>
        <h2 class="text-2xl font-semibold text-slate-900 dark:text-slate-100">Access for {WorkspacePresentation.display_name(@tenant)}</h2>
        <p class="max-w-3xl text-sm leading-6 text-slate-600 dark:text-slate-300">
          Everything on this page applies to <span class="font-medium text-slate-900 dark:text-slate-100">{WorkspacePresentation.display_name(@tenant)}</span> only.
          Portal membership, model access, and inference credentials are separate controls. Model grants are inspected here and changed with operator tooling.
        </p>
      </header>

    <p class="text-xs text-slate-500 break-all">{@tenant.slug} · {@tenant.id} <span :if={WorkspacePresentation.default?(@tenant)}>· Default</span></p>
    <.link navigate={"/console/access/workspaces/#{@tenant.id}/handoff"} class="text-sm text-navy underline">Guide workspace access</.link>
    <nav id="tenant-access-navigation" aria-label="Workspace access sections" class="flex flex-wrap gap-2">
    <.link :for={{key, label} <- [{"overview", "Overview"}, {"model_access", "Model access"}, {"portal_users", "Portal Users"}, {"api_credentials", "API credentials"}]}
    patch={"/console/access/workspaces/#{@tenant.id}?section=#{key}"}
    aria-current={if @section == key, do: "page"}
    class={["rounded-md border px-3 py-2 text-sm focus-visible:ring-2 focus-visible:ring-navy", if(@section == key, do: "bg-navy text-white", else: "border-slate-300 text-navy dark:text-sky-400")]}>{label}</.link>
    </nav>
    <div id="workspace-section-model_access" hidden={@section != "model_access"} class="space-y-4">
    <div id="tenant-model-access-card"><.card>
    <:title>Model access</:title>
    <:subtitle>Grants apply only to this Workspace. Enabled access does not mean a Model is placed, loaded, or ready for inference.</:subtitle>
    <.button phx-click="refresh_model_access" variant={:secondary}>Refresh grants</.button>
    <p :if={@model_access_error} role="alert">Model grants unavailable. Refresh to try again.</p>
    <p :if={!@model_access_error && @model_access == []}>No catalog Models. Import a Model in Catalog before granting access.</p>
    <div :for={row <- @model_access} id={"workspace-model-#{row.model.id}"} class="mt-4 space-y-2 rounded-lg border border-slate-200 p-4">
      <p class="break-all font-mono text-sm">{row.model.model_id}@{row.model.version}</p>
      <p>Grant: {grant_label(row.grant_state)} · Model state: {row.model.state}</p>
      <p class="text-xs text-slate-500 break-all">Catalog ID: {row.model.id}</p>
      <details><summary class="cursor-pointer text-sm text-navy">Operator commands</summary>
        <p class="mt-2 text-sm">Run with authorized operator tooling. These commands use the existing Tenant scope identifier.</p>
        <pre class="overflow-x-auto p-2 text-xs">{WorkspaceAccess.commands(@tenant, row.model, row.grant).grant}</pre>
        <pre class="overflow-x-auto p-2 text-xs">{WorkspaceAccess.commands(@tenant, row.model, row.grant).inspect}</pre>
      </details>
    </div>
    </.card></div>
    </div>
    <div id="workspace-section-overview" hidden={@section != "overview"} class="space-y-6">


      <section
        id="tenant-access-boundaries"
        aria-labelledby="tenant-access-boundaries-title"
        class="rounded-lg border border-slate-200 bg-slate-50 p-4 dark:border-slate-700 dark:bg-slate-900/60"
      >
        <h2 id="tenant-access-boundaries-title" class="font-medium text-slate-900 dark:text-slate-100">
          Keep these access paths separate
        </h2>
        <div class="mt-3 grid gap-4 text-sm sm:grid-cols-3">
          <div>
            <p class="font-medium text-slate-900 dark:text-slate-100">Portal User</p>
            <p class="mt-1 text-slate-600 dark:text-slate-300">
              Signs in to this Workspace's Developer Portal. An invitation does not create an inference credential.
            </p>
          </div>
          <div>
            <p class="font-medium text-slate-900 dark:text-slate-100">Direct API Token</p>
            <p class="mt-1 text-slate-600 dark:text-slate-300">
              Authorizes Public Inference for this Workspace, subject to its separate model access and policy.
            </p>
          </div>
          <div>
            <p class="font-medium text-slate-900 dark:text-slate-100">API Client</p>
            <p class="mt-1 text-slate-600 dark:text-slate-300">
              Represents non-interactive application access and owns separately provisioned API Tokens.
            </p>
          </div>
        </div>
      </section>

      <%!-- Workspace Summary --%>
      <div id="tenant-summary-card">
        <.card>
          <:title>{WorkspacePresentation.display_name(@tenant)}</:title>
          <:subtitle>Stable identity for this access and request scope.</:subtitle>

          <.detail_grid
            gap_class="gap-x-6 gap-y-3"
            class="grid-cols-2"
          >
            <.detail_field id="tenant-detail-name" label="Name" value_class="font-medium">
              {WorkspacePresentation.display_name(@tenant)}
            </.detail_field>
            <.detail_field id="tenant-detail-slug" label="Slug" mono>
              {@tenant.slug}
            </.detail_field>
            <.detail_field id="tenant-detail-id" label="Workspace ID" mono break_all>
              {@tenant.id}
            </.detail_field>
            <.detail_field id="tenant-detail-created-at" label="Created" mono>
              <.local_time value={@tenant.inserted_at} format={:datetime_minute} />
            </.detail_field>
          </.detail_grid>
        </.card>
      </div>
      </div>
      <div id="workspace-section-portal_users" hidden={@section != "portal_users"} class="space-y-6">
      <div id="tenant-portal-invite-card" class="scroll-mt-6">
        <.card>
          <:title>Invite a Portal User</:title>
          <:subtitle>
            Create a named identity for this Workspace's Developer Portal. Orchard does not send email or create an API credential. After creation, use Copy invite and deliver the URL out of band.
          </:subtitle>
          <div
            :if={!@portal_https?}
            id="tenant-portal-tls-required"
            class="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900"
          >
            Developer Portal requires public API HTTPS.
          </div>
          <.form
            :if={@portal_https?}
            for={@portal_invite_form}
            id="tenant-portal-invite-form"
            phx-submit="create_portal_invite"
            class="flex gap-3"
          >
            <.input field={@portal_invite_form[:email]} type="email" label="Email" required />
            <button
              type="submit"
              class="bg-navy mt-7 rounded-md px-4 py-2 text-sm font-semibold text-white hover:bg-navy-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy/40 focus-visible:ring-offset-2 dark:bg-sky-500 dark:hover:bg-sky-400 dark:focus-visible:ring-sky-400/40"
            >
              Invite
            </button>
          </.form>
        </.card>
      </div>

      <div :if={@portal_invite_url} id="tenant-portal-invite-url-card">
        <.card>
          <:title>Invite URL - copy now</:title>
          <:subtitle>This URL is shown only for this Copy invite action.</:subtitle>
          <div
            id={"tenant-portal-invite-reveal-#{DateTime.to_unix(@portal_invite_expires_at, :microsecond)}"}
            phx-mounted={
              Phoenix.LiveView.JS.focus(to: "#tenant-portal-invite-url-copy")
            }
          >
            <p
              id="tenant-portal-invite-url-guidance"
              class="sr-only"
              role="status"
              aria-live="polite"
            >
              One-time invite URL ready. Copy it before leaving this page.
            </p>
            <code
              id="tenant-portal-invite-url-value"
              class="block break-all rounded bg-slate-100 p-3 font-mono text-sm text-slate-900 dark:bg-slate-800 dark:text-slate-100"
            >
              {@portal_invite_url}
            </code>
            <p class="mt-2 text-xs text-slate-500 dark:text-slate-400">
              Expires <.local_time
                id="tenant-portal-invite-url-expires-at"
                value={@portal_invite_expires_at}
                format={:datetime_minute}
              />
            </p>
            <button
              id="tenant-portal-invite-url-copy"
              type="button"
              phx-hook="CopyGeneratedSecret"
              data-secret-source="tenant-portal-invite-url-value"
              data-api-key-id="portal-invite"
              aria-describedby="tenant-portal-invite-url-guidance"
              class="mt-3 rounded-md bg-navy px-3 py-1.5 text-sm font-medium text-white hover:bg-navy-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy/40 focus-visible:ring-offset-2 dark:bg-sky-500 dark:hover:bg-sky-400 dark:focus-visible:ring-sky-400/40"
            >
              Copy invite URL
            </button>
          </div>
        </.card>
      </div>

      <div id="tenant-portal-users-card">
        <.card>
          <:title>Portal Users</:title>
          <:subtitle>
            Named Developer Portal identities for this Workspace only. Portal access does not grant Console or cluster administration.
          </:subtitle>
          <p :if={@portal_users == []} class="text-sm text-slate-500 dark:text-slate-400">
            No Portal Users invited yet.
          </p>
          <div
            :for={user <- @portal_users}
            id={"portal-user-#{user.id}"}
            class="flex flex-col gap-3 border-t py-3 sm:flex-row sm:items-center sm:justify-between"
          >
            <div class="min-w-0">
              <p class="break-all font-medium">{user.email}</p>
              <p class="text-sm text-slate-500 dark:text-slate-400">
                {String.capitalize(user.status)}
              </p>
              <p
                :if={user.invite_context == :not_issued}
                id={"portal-user-invite-context-#{user.id}"}
                class="text-xs text-slate-500 dark:text-slate-400"
                role="status"
                aria-live="polite"
                aria-atomic="true"
              >
                Not issued
              </p>
              <p
                :if={user.invite_context == :pending}
                id={"portal-user-invite-context-#{user.id}"}
                class="text-xs text-slate-500 dark:text-slate-400"
                role="status"
                aria-live="polite"
                aria-atomic="true"
              >
                Pending - Expires <.local_time
                  id={"portal-user-invite-expires-at-#{user.id}"}
                  value={user.invite_expires_at}
                  format={:datetime_minute}
                />
              </p>
              <p
                :if={user.invite_context == :expired}
                id={"portal-user-invite-context-#{user.id}"}
                class="text-xs text-slate-500 dark:text-slate-400"
                role="status"
                aria-live="polite"
                aria-atomic="true"
              >
                Expired - Expired at <.local_time
                  id={"portal-user-invite-expires-at-#{user.id}"}
                  value={user.invite_expires_at}
                  format={:datetime_minute}
                />
              </p>
              <p
                :if={user.invite_context == :redeemed}
                id={"portal-user-invite-context-#{user.id}"}
                class="text-xs text-slate-500 dark:text-slate-400"
                role="status"
                aria-live="polite"
                aria-atomic="true"
              >
                Redeemed
              </p>
            </div>
            <div class="flex shrink-0 gap-2 self-end sm:self-auto">
              <button
                :if={user.status == "invited"}
                type="button"
                phx-click="copy_portal_invite"
                phx-value-portal_user_id={user.id}
                aria-label={"Copy invite for #{user.email}"}
                class="rounded border px-3 py-1.5 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy/40 focus-visible:ring-offset-2 dark:focus-visible:ring-sky-400/40"
              >
                Copy invite
              </button>
              <button
                :if={user.status != "disabled"}
                type="button"
                phx-click="disable_portal_user"
                phx-value-portal_user_id={user.id}
                aria-label={"Disable #{user.email}"}
                class="rounded border border-red-300 px-3 py-1.5 text-sm text-red-700 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-500/40 focus-visible:ring-offset-2 dark:text-red-300"
              >
                Disable
              </button>
            </div>
          </div>
        </.card>
      </div>

      <div id="tenant-portal-access-card">
        <.card>
          <:title>Portal access</:title>
          <:subtitle>
            TLS-only sign-in for this Workspace. The Developer Portal is separate from Console and does not authorize inference by itself.
          </:subtitle>
          <div class="flex flex-wrap items-center gap-3">
            <code class="font-mono text-sm">/portal/{@tenant.slug}</code>
            <.link
              :if={@portal_base_url}
              id="tenant-open-portal"
              href={portal_url(@portal_base_url, @tenant.slug)}
              class="text-sm font-medium text-navy underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:text-sky-400 dark:focus-visible:ring-sky-400"
            >
              Open Developer Portal
            </.link>
            <span :if={is_nil(@portal_base_url)} class="text-xs text-amber-700 dark:text-amber-300">
              {portal_unavailable_label(@portal_https?)}
            </span>
          </div>
        </.card>
      </div>

      <%!-- One-Time Secret Card --%>
      </div>
      <div id="workspace-section-api_credentials" hidden={@section != "api_credentials"} class="space-y-6">
      <div :if={@generated_secret} id="tenant-api-key-secret-card">
        <.card>
          <:title>API Token Created - Copy Your Secret</:title>
          <:subtitle>
            This secret is shown <strong>only once</strong>. It cannot be retrieved after you navigate
            away or dismiss this card.
          </:subtitle>

          <div class="space-y-3">
            <div class="text-sm text-slate-500 dark:text-slate-400">
              <span class="font-medium text-slate-700 dark:text-slate-200">{@generated_secret.name}</span>
              <span class="ml-2 font-mono text-xs">({@generated_secret.token_prefix})</span>
            </div>

            <div class="relative">
              <code
                id="tenant-api-key-secret-value"
                class="block w-full rounded-md border border-slate-300 bg-slate-50 px-3 py-2 font-mono text-sm break-all dark:border-slate-600 dark:bg-slate-800"
              >
                {@generated_secret.token}
              </code>
            </div>

            <div class="flex items-center gap-3">
              <button
                id="tenant-api-key-secret-copy"
                type="button"
                phx-hook="CopyGeneratedSecret"
                data-secret-source="tenant-api-key-secret-value"
                data-api-key-id={@generated_secret.api_key_id}
                class="inline-flex items-center gap-1.5 rounded-md bg-forest-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-forest-700 dark:bg-emerald-600 dark:hover:bg-emerald-700"
              >
                Copy Secret
              </button>
              <button
                id="tenant-api-key-secret-dismiss"
                type="button"
                phx-click="dismiss_generated_secret"
                class="text-sm text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
              >
                Dismiss
              </button>
              <span id="tenant-api-key-secret-status" class="text-sm">
                <span :if={@generated_secret.copy_status == :idle} class="text-amber-600 dark:text-amber-400">
                  ⚠ Not yet copied
                </span>
                <span :if={@generated_secret.copy_status == :copied} class="text-forest-600 dark:text-emerald-400">
                  ✓ Copied to clipboard
                </span>
                <span :if={@generated_secret.copy_status == :failed} class="text-red-600 dark:text-red-400">
                  Copy failed — select and copy the token manually
                </span>
              </span>
            </div>
          </div>
        </.card>
      </div>

      <%!-- Create tenant-direct API Token --%>
      <div id="tenant-api-key-create-card" class="scroll-mt-6">
        <.card>
          <:title>Create a direct API Token</:title>
          <:subtitle>
            Issue a Public Inference credential for this Workspace. It does not sign a person in to the Developer Portal or grant model access.
          </:subtitle>

          <.simple_form
            for={@api_key_form}
            as={:api_key}
            id="tenant-api-key-create-form"
            phx-submit="create_api_key"
          >
            <.input field={@api_key_form[:name]} label="Token Name" placeholder="production-token…" size={:lg} />
            <:actions>
              <.button type="submit" phx-disable-with="Creating…">Create API Token</.button>
            </:actions>
          </.simple_form>
        </.card>
      </div>

      <%!-- Workspace API Tokens table --%>
      <div id="tenant-api-keys-card">
        <.card>
          <:title>Workspace API Tokens</:title>
          <:subtitle>
            Tenant-direct credentials minted by operator tooling or by Portal Users. Revoking a token does not change Portal membership.
          </:subtitle>

          <.table id="tenant-api-keys-table" rows={@api_keys} row_id={&"api-key-#{&1.id}"}>
            <:col :let={key} label="Name">{key.name}</:col>
            <:col :let={key} label="Minted via" class="min-w-40 max-w-[16rem] whitespace-normal">
              <p>{minted_via_label(key)}</p>
              <p
                :if={key.issuance_surface == "developer_portal"}
                class="mt-1 break-words text-xs text-slate-500 dark:text-slate-400"
              >
                {key.portal_user_email || "Attribution unavailable"}
              </p>
            </:col>
            <:col :let={key} label="Prefix" mono>{key.token_prefix}</:col>
            <:col :let={key} label="Created" mono><.local_time value={key.inserted_at} format={:datetime_minute} /></:col>
              <:col :let={key} label="Last Used" mono><.local_time value={key.last_used_at} format={:datetime_minute} /></:col>
            <:col :let={key} label="Status">
              <.api_token_status_badge api_key={key} />
            </:col>

            <:action :let={key}>
              <.button
                :if={key.revoked_at == nil}
                id={"tenant-api-key-revoke-#{key.id}"}
                variant={:danger}
                size={:sm}
                phx-click="revoke_api_key"
                phx-value-id={key.id}
                phx-disable-with="Revoking…"
              >
                Revoke
              </.button>
              <span
                :if={key.revoked_at != nil}
                class="text-slate-400 dark:text-slate-500"
              >
                —
              </span>
            </:action>

            <:empty>
              <.state_message
                id="tenant-api-keys-empty-state"
                kind={:empty}
                layout={:compact}
                title="No API Tokens created yet."
              >
                <:action>
                  Create a direct API Token above, or let a Portal User mint one from the Developer Portal.
                </:action>
              </.state_message>
            </:empty>
          </.table>
        </.card>
      </div>

      <div id="tenant-api-clients-card" class="scroll-mt-6">
        <.card>
          <:title>API Clients</:title>
          <:subtitle>
            Non-interactive application identities and their owned API Tokens. API Clients are provisioned separately from Portal Users.
          </:subtitle>

          <div
            id="tenant-api-clients-list"
            class="-mx-6 -my-4 divide-y divide-slate-200 dark:divide-slate-700"
          >
            <div :if={@api_clients == []} class="px-6 py-8">
              <.state_message
                id="tenant-api-clients-empty-state"
                kind={:empty}
                layout={:compact}
                title="No API Clients provisioned yet."
              >
                <:action>
                  Use orchardctl bulk provisioning to create API Clients and one-time API Token output.
                </:action>
              </.state_message>
            </div>

            <article
              :for={client <- @api_clients}
              id={"api-client-#{client.id}"}
              class="px-6 py-4"
            >
              <div class="flex flex-col gap-4 md:flex-row md:items-start md:justify-between">
                <div class="min-w-0 flex-1 space-y-4">
                  <div class="space-y-1">
                    <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                      <h3 class="min-w-0 break-words font-medium text-slate-900 dark:text-slate-100">
                        {client.name}
                      </h3>
                      <.badge :if={client.disabled_at == nil} tone={:success}>Active</.badge>
                      <.badge :if={client.disabled_at != nil} tone={:neutral}>Disabled</.badge>
                    </div>
                    <p :if={present?(client.purpose)} class="break-words text-xs text-slate-600 dark:text-slate-300">
                      {client.purpose}
                    </p>
                    <p :if={present?(client.description)} class="break-words text-xs text-slate-500 dark:text-slate-400">
                      {client.description}
                    </p>
                  </div>

                  <.detail_grid
                    gap_class="gap-x-6 gap-y-3"
                    class="grid-cols-1 sm:grid-cols-2 xl:grid-cols-4"
                  >
                    <.detail_field id={"api-client-owner-#{client.id}"} label="Owner">
                      <div :if={present?(client.owner_name)} class="break-words font-medium">
                        {client.owner_name}
                      </div>
                      <div class="break-all text-slate-700 dark:text-slate-200">
                        {client.owner_contact}
                      </div>
                      <div
                        class="mt-1 flex min-w-0 max-w-full flex-wrap items-center gap-x-1 gap-y-0.5 text-xs text-slate-500 dark:text-slate-400"
                      >
                        <span class="font-medium uppercase tracking-wide">Team</span>
                        <span class="min-w-0 break-words">{if present?(client.team), do: client.team, else: "Ungrouped"}</span>
                      </div>
                    </.detail_field>
                    <.detail_field
                      id={"api-client-external-ref-#{client.id}"}
                      label="External Ref"
                      mono
                      break_all
                    >
                      {client.external_ref || "None"}
                    </.detail_field>
                    <.detail_field id={"api-client-access-#{client.id}"} label="Access">
                      <div class="flex flex-wrap items-center gap-1.5">
                        <.badge :if={inference_client_access?(client)} tone={:neutral}>
                          Inference Client
                        </.badge>
                        <.badge :if={!inference_client_access?(client)} tone={:neutral}>
                          No Access
                        </.badge>
                      </div>
                    </.detail_field>
                    <.detail_field id={"api-client-state-#{client.id}"} label="State">
                      <div class="space-y-1.5">
                        <div class="flex flex-wrap items-center gap-1.5">
                          <.badge :if={client.disabled_at == nil} tone={:success}>Active</.badge>
                          <.badge :if={client.disabled_at != nil} tone={:neutral}>Disabled</.badge>
                        </div>
                        <div
                          :if={client.disabled_at != nil}
                          class="text-xs text-slate-500 dark:text-slate-400"
                        >
                          Disabled <.local_time value={client.disabled_at} format={:datetime_minute} class="font-mono" />
                        </div>
                      </div>
                    </.detail_field>
                  </.detail_grid>

                  <div
                    id={"api-client-tokens-#{client.id}"}
                    class="space-y-2 rounded-md border border-slate-200 bg-slate-50 p-3 dark:border-slate-700 dark:bg-slate-900/60"
                  >
                    <div class="text-xs font-medium uppercase tracking-wide text-slate-500 dark:text-slate-400">
                      API Tokens
                    </div>
                    <div
                      :for={token <- client.api_keys}
                      id={"api-client-token-#{token.id}"}
                      class={[
                        "space-y-1 text-sm",
                        ApiKey.revoked?(token) && "opacity-75"
                      ]}
                    >
                      <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
                        <span class="min-w-0 max-w-full break-words font-medium text-slate-700 dark:text-slate-200">
                          {token.name}
                        </span>
                        <span class="break-all font-mono text-xs text-slate-500 dark:text-slate-400">
                          {token.token_prefix}
                        </span>
                        <.api_token_status_badge api_key={token} />
                        <.badge :if={client.disabled_at != nil && active_api_token?(token)} tone={:warning}>
                          Blocked by client
                        </.badge>
                        <button
                          :if={token.revoked_at == nil}
                          id={"tenant-api-client-token-revoke-#{token.id}"}
                          type="button"
                          phx-click="revoke_api_key"
                          phx-value-id={token.id}
                          phx-disable-with="Revoking…"
                          class="text-xs font-medium text-red-600 hover:text-red-700 dark:text-red-400 dark:hover:text-red-300"
                        >
                          Revoke
                        </button>
                      </div>
                      <div class="flex flex-wrap gap-x-3 gap-y-1 text-xs text-slate-500 dark:text-slate-400">
                        <span>
                          Created <.local_time
                            id={"api-client-token-created-at-#{token.id}"}
                            value={token.inserted_at}
                            format={:datetime_minute}
                            class="font-mono"
                          />
                        </span>
                        <span>
                          Last Used <.local_time
                            id={"api-client-token-last-used-at-#{token.id}"}
                            value={token.last_used_at}
                            format={:datetime_minute}
                            class="font-mono"
                          />
                        </span>
                      </div>
                    </div>
                    <span
                      :if={client.api_keys == []}
                      class="text-sm text-slate-500 dark:text-slate-400"
                    >
                      No API Tokens
                    </span>
                  </div>
                </div>

                <div class="flex shrink-0 items-center justify-start md:justify-end">
                  <.button
                    :if={client.disabled_at == nil}
                    id={"tenant-api-client-disable-#{client.id}"}
                    variant={:danger}
                    size={:sm}
                    phx-click="disable_api_client"
                    phx-value-id={client.id}
                    phx-disable-with="Disabling…"
                    data-confirm="Disable this API Client? Active owned API Tokens will be blocked, but tokens are not revoked."
                  >
                    Disable
                  </.button>
                </div>
              </div>
            </article>
          </div>
        </.card>
      </div>
      </div>
    </div>
    """
  end

  # -- Private helpers --

  defp create_api_key(socket, params) do
    case Governance.create_api_key(socket.assigns.tenant.id, params) do
      {:ok, %{api_key: api_key, token: token}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created API Token #{api_key.name}.")
         |> assign(
           generated_secret: %{
             api_key_id: api_key.id,
             name: api_key.name,
             token_prefix: api_key.token_prefix,
             token: token,
             copy_status: :idle
           }
         )
         |> assign_blank_form()
         |> load_tenant_detail()}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = changeset_to_form(changeset, :api_key, %{"name" => ""})
        {:noreply, assign(socket, api_key_form: form)}

      {:error, :tenant_not_found} ->
        {:noreply, assign(socket, detail_status: :not_found)}
    end
  rescue
    _ ->
      {:noreply, put_flash(socket, :error, "Unable to create API Token.")}
  end

  defp revoke_api_key(socket, api_key_id) do
    case Governance.revoke_api_key(socket.assigns.tenant, api_key_id, @console_audit_opts) do
      {:ok, api_key} ->
        {:noreply,
         socket
         |> put_flash(:info, "Revoked API Token #{api_key.name}.")
         |> load_tenant_detail()}

      {:error, :api_key_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "API Token not found.")
         |> load_tenant_detail()}

      {:error, :tenant_not_found} ->
        {:noreply, assign(socket, detail_status: :not_found)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to revoke API Token.")
         |> load_tenant_detail()}
    end
  rescue
    _ ->
      {:noreply,
       socket
       |> put_flash(:error, "Unable to revoke API Token.")
       |> load_tenant_detail()}
  end

  defp disable_api_client(socket, api_client_id) do
    case Governance.disable_api_client(socket.assigns.tenant, api_client_id, @console_audit_opts) do
      {:ok, api_client} ->
        {:noreply,
         socket
         |> put_flash(:info, "Disabled API Client #{api_client.name}.")
         |> load_tenant_detail()}

      {:error, :api_client_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "API Client not found.")
         |> load_tenant_detail()}

      {:error, :tenant_not_found} ->
        {:noreply, assign(socket, detail_status: :not_found)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to disable API Client.")
         |> load_tenant_detail()}
    end
  rescue
    _ ->
      {:noreply,
       socket
       |> put_flash(:error, "Unable to disable API Client.")
       |> load_tenant_detail()}
  end

  defp assign_blank_form(socket) do
    assign(socket,
      api_key_form: to_form(%{"name" => ""}, as: :api_key),
      portal_invite_form: to_form(%{"email" => ""}, as: :portal_invite)
    )
  end

  defp changeset_to_form(%Ecto.Changeset{} = changeset, as, defaults) do
    params =
      case changeset.params do
        params when is_map(params) -> Map.merge(defaults, params)
        _ -> defaults
      end

    errors =
      Enum.map(changeset.errors, fn {field, {msg, opts}} ->
        {field, {msg, opts}}
      end)

    to_form(params, as: as, errors: errors)
  end

  defp load_tenant_detail(socket) do
    tenant_id = socket.assigns.tenant_id

    with {:ok, tenant} <- Governance.get_tenant(tenant_id),
         {:ok, api_keys} <- Governance.list_tenant_api_key_summaries(tenant),
         {:ok, api_clients} <- Governance.list_api_clients_for_tenant(tenant),
         {:ok, portal_users} <- Governance.list_portal_user_summaries(tenant) do
      assign(socket,
        detail_status: :ok,
        tenant: tenant,
        api_keys: api_keys,
        api_clients: api_clients,
        portal_users: portal_users,
        page_title: WorkspacePresentation.display_name(tenant),
        load_error: nil
      )
      |> load_model_access()
    else
      {:error, :tenant_not_found} ->
        assign(socket, detail_status: :not_found)
    end
  rescue
    _ ->
      assign(socket,
        detail_status: :error,
        load_error: "Workspace details unavailable."
      )
  end

  defp load_model_access(%{assigns: %{tenant: nil}} = socket), do: socket

  defp load_model_access(socket) do
    case WorkspaceAccess.list(socket.assigns.tenant) do
      {:ok, rows} -> assign(socket, model_access: rows, model_access_error: nil)
      {:error, reason} -> assign(socket, model_access: [], model_access_error: reason)
    end
  end

  defp grant_label(:enabled), do: "Enabled"
  defp grant_label(:disabled), do: "Disabled"
  defp grant_label(:not_granted), do: "Not granted"

  defp inference_client_access?(api_client) do
    Enum.any?(api_client.role_bindings, fn
      %RoleBinding{role: :inference_client} -> true
      _role_binding -> false
    end)
  end

  defp active_api_token?(%ApiKey{} = api_key), do: ApiKey.status(api_key, utc_now()) == :active

  defp portal_url(base_url, slug) do
    String.trim_trailing(base_url, "/") <> "/portal/" <> slug
  end

  defp portal_unavailable_label(false), do: "Unavailable until public API HTTPS is enabled."

  defp portal_unavailable_label(true),
    do: "The configured public HTTPS Portal address is unavailable."

  defp minted_via_label(%TenantApiKeySummary{issuance_surface: "developer_portal"}),
    do: "Developer Portal"

  defp minted_via_label(%TenantApiKeySummary{}), do: "Operator tooling"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  attr(:api_key, :map, required: true)

  defp api_token_status_badge(assigns) do
    status =
      case assigns.api_key do
        %ApiKey{} = api_key -> ApiKey.status(api_key, utc_now())
        %TenantApiKeySummary{} = api_key -> TenantApiKeySummary.status(api_key, utc_now())
      end

    assigns = assign(assigns, :status, status)

    ~H"""
    <.badge :if={@status == :active} tone={:success}>Active</.badge>
    <.badge :if={@status == :expired} tone={:warning}>Expired</.badge>
    <.badge :if={@status == :revoked} tone={:neutral}>Revoked</.badge>
    """
  end

  defp utc_now do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end
