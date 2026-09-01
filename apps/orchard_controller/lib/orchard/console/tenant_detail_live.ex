defmodule OrchardConsole.TenantDetailLive do
  @moduledoc """
  Console Organization detail page with API Token and API Client management.
  """

  use OrchardConsole, :live_view

  alias Orchard.API.Transport
  alias Orchard.Governance
  alias Orchard.Governance.{ApiKey, RoleBinding}

  @console_audit_opts [actor_type: "operator", surface: "console"]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(
        tenant_id: id,
        page_title: "Organization",
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
      title="Organization Detail"
      body="Loading Organization…"
    />
    """
  end

  def render(%{detail_status: :not_found} = assigns) do
    ~H"""
    <div id="tenant-not-found-card" class="space-y-4">
      <.link
        id="tenant-back-to-list"
        navigate="/console/tenants"
        class="inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Organizations
      </.link>
      <.state_message
        id="tenant-not-found-message"
        kind={:empty}
        layout={:panel}
        title="Organization not found"
        body="The requested Organization does not exist or the ID is invalid."
      />
    </div>
    """
  end

  def render(%{detail_status: :error} = assigns) do
    ~H"""
    <div id="tenant-error-card" class="space-y-4">
      <.link
        id="tenant-back-to-list"
        navigate="/console/tenants"
        class="inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Organizations
      </.link>
      <.state_message
        id="tenant-error-message"
        kind={:error}
        layout={:panel}
        title="Organization details unavailable"
        body={@load_error}
      />
    </div>
    """
  end

  def render(%{detail_status: :ok} = assigns) do
    ~H"""
    <div class="space-y-6">
      <.link
        id="tenant-back-to-list"
        navigate="/console/tenants"
        class="inline-flex items-center gap-1 text-sm text-slate-500 hover:text-slate-700 dark:text-slate-400 dark:hover:text-slate-200"
      >
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Organizations
      </.link>

      <%!-- Organization Summary --%>
      <div id="tenant-summary-card">
        <.card>
          <:title>{@tenant.name}</:title>
          <:subtitle>Organization details</:subtitle>

          <.detail_grid
            gap_class="gap-x-6 gap-y-3"
            class="grid-cols-2"
          >
            <.detail_field id="tenant-detail-name" label="Name" value_class="font-medium">
              {@tenant.name}
            </.detail_field>
            <.detail_field id="tenant-detail-slug" label="Slug" mono>
              {@tenant.slug}
            </.detail_field>
            <.detail_field id="tenant-detail-id" label="Organization ID" mono break_all>
              {@tenant.id}
            </.detail_field>
            <.detail_field id="tenant-detail-created-at" label="Created" mono>
              <.local_time value={@tenant.inserted_at} format={:datetime_minute} />
            </.detail_field>
          </.detail_grid>
        </.card>
      </div>
      <div id="tenant-portal-invite-card">
        <.card>
          <:title>Invite Portal User</:title>
          <:subtitle>Create a named Developer Portal identity. Orchard does not send email.</:subtitle>
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
          <:subtitle>Named identities for this Organization.</:subtitle>
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
          <:subtitle>TLS-only isolated surface without Console chrome.</:subtitle>
          <code class="font-mono text-sm">/portal/{@tenant.slug}</code>
        </.card>
      </div>

      <%!-- One-Time Secret Card --%>
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
      <div id="tenant-api-key-create-card">
        <.card>
          <:title>Create API Token</:title>
          <:subtitle>Issue a new API Token for this Organization.</:subtitle>

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

      <%!-- Organization API Tokens table --%>
      <div id="tenant-api-keys-card">
        <.card>
          <:title>Organization API Tokens</:title>

          <.table id="tenant-api-keys-table" rows={@api_keys} row_id={&"api-key-#{&1.id}"}>
            <:col :let={key} label="Name">{key.name}</:col>
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
                  Create an API Token above to issue direct Organization access.
                </:action>
              </.state_message>
            </:empty>
          </.table>
        </.card>
      </div>

      <div id="tenant-api-clients-card">
        <.card>
          <:title>API Clients</:title>
          <:subtitle>Non-interactive access, ownership context, and owned API Tokens.</:subtitle>

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
                        :if={present?(client.team)}
                        class="mt-1 flex min-w-0 max-w-full flex-wrap items-center gap-x-1 gap-y-0.5 text-xs text-slate-500 dark:text-slate-400"
                      >
                        <span class="font-medium uppercase tracking-wide">Team</span>
                        <span class="min-w-0 break-words">{client.team}</span>
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
         {:ok, api_keys} <- Governance.list_api_keys_for_tenant(tenant),
         {:ok, api_clients} <- Governance.list_api_clients_for_tenant(tenant),
         {:ok, portal_users} <- Governance.list_portal_user_summaries(tenant) do
      assign(socket,
        detail_status: :ok,
        tenant: tenant,
        api_keys: api_keys,
        api_clients: api_clients,
        portal_users: portal_users,
        page_title: "Organization #{tenant.slug}",
        load_error: nil
      )
    else
      {:error, :tenant_not_found} ->
        assign(socket, detail_status: :not_found)
    end
  rescue
    _ ->
      assign(socket,
        detail_status: :error,
        load_error: "Organization details unavailable."
      )
  end

  defp inference_client_access?(api_client) do
    Enum.any?(api_client.role_bindings, fn
      %RoleBinding{role: :inference_client} -> true
      _role_binding -> false
    end)
  end

  defp active_api_token?(%ApiKey{} = api_key), do: ApiKey.status(api_key, utc_now()) == :active

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  attr(:api_key, :map, required: true)

  defp api_token_status_badge(assigns) do
    assigns = assign(assigns, :status, ApiKey.status(assigns.api_key, utc_now()))

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
