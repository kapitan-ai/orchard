defmodule OrchardConsole.TenantDetailLive do
  @moduledoc """
  Console tenant detail page — tenant summary, API key management,
  and one-time secret display.
  """

  use OrchardConsole, :live_view

  alias Orchard.Governance

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(
        tenant_id: id,
        page_title: "Tenant",
        active_nav: :tenants,
        detail_status: :loading,
        tenant: nil,
        api_keys: [],
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
    OrchardConsole.LicenseGate.guard(socket, fn ->
      create_api_key(socket, params)
    end)
  end

  def handle_event("revoke_api_key", %{"id" => api_key_id}, socket) do
    OrchardConsole.LicenseGate.guard(socket, fn ->
      revoke_api_key(socket, api_key_id)
    end)
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

  # -- Render --

  @impl true
  def render(%{detail_status: :loading} = assigns) do
    ~H"""
    <.state_message
      id="tenant-loading-card"
      kind={:loading}
      layout={:panel}
      title="Tenant Detail"
      body="Loading tenant…"
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
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Tenants
      </.link>
      <.state_message
        id="tenant-not-found-message"
        kind={:empty}
        layout={:panel}
        title="Tenant not found"
        body="The requested tenant does not exist or the ID is invalid."
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
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Tenants
      </.link>
      <.state_message
        id="tenant-error-message"
        kind={:error}
        layout={:panel}
        title="Tenant details unavailable"
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
        <.icon name="hero-arrow-left" class="h-4 w-4" /> Back to Tenants
      </.link>

      <%!-- Tenant Summary --%>
      <div id="tenant-summary-card">
        <.card>
          <:title>{@tenant.name}</:title>
          <:subtitle>Tenant details</:subtitle>

          <.detail_grid class="grid-cols-2 gap-y-3">
            <.detail_field id="tenant-detail-name" label="Name" class="font-medium">
              {@tenant.name}
            </.detail_field>
            <.detail_field id="tenant-detail-slug" label="Slug" mono>
              {@tenant.slug}
            </.detail_field>
            <.detail_field id="tenant-detail-id" label="Tenant ID" mono break_all>
              {@tenant.id}
            </.detail_field>
            <.detail_field id="tenant-detail-created-at" label="Created" mono>
              <.local_time value={@tenant.inserted_at} format={:datetime_minute} />
            </.detail_field>
          </.detail_grid>
        </.card>
      </div>

      <%!-- One-Time Secret Card --%>
      <div :if={@generated_secret} id="tenant-api-key-secret-card">
        <.card>
          <:title>API Key Created — Copy Your Secret</:title>
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

      <%!-- Create API Key --%>
      <div id="tenant-api-key-create-card">
        <.card>
          <:title>Create API Key</:title>
          <:subtitle>Issue a new API key for this tenant.</:subtitle>

          <.simple_form
            for={@api_key_form}
            as={:api_key}
            id="tenant-api-key-create-form"
            phx-submit="create_api_key"
          >
            <.input field={@api_key_form[:name]} label="Key Name" placeholder="production-key…" size={:lg} />
            <:actions>
              <.button type="submit" phx-disable-with="Creating…">Create API Key</.button>
            </:actions>
          </.simple_form>
        </.card>
      </div>

      <%!-- API Keys Table --%>
      <div id="tenant-api-keys-card">
        <.card>
          <:title>API Keys</:title>

          <.table id="tenant-api-keys-table" rows={@api_keys} row_id={&"api-key-#{&1.id}"}>
            <:col :let={key} label="Name">{key.name}</:col>
            <:col :let={key} label="Prefix" mono>{key.token_prefix}</:col>
            <:col :let={key} label="Created" mono><.local_time value={key.inserted_at} format={:datetime_minute} /></:col>
              <:col :let={key} label="Last Used" mono><.local_time value={key.last_used_at} format={:datetime_minute} /></:col>
            <:col :let={key} label="Status">
              <.badge :if={key.revoked_at == nil} tone={:success}>Active</.badge>
              <.badge :if={key.revoked_at != nil} tone={:neutral}>Revoked</.badge>
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
                title="No API keys created yet."
              >
                <:action>
                  Create a key above to issue API access for this tenant.
                </:action>
              </.state_message>
            </:empty>
          </.table>
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
         |> put_flash(:info, "Created API key #{api_key.name}.")
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
      {:noreply, put_flash(socket, :error, "Unable to create API key.")}
  end

  defp revoke_api_key(socket, api_key_id) do
    case Governance.revoke_api_key(socket.assigns.tenant, api_key_id) do
      {:ok, api_key} ->
        {:noreply,
         socket
         |> put_flash(:info, "Revoked API key #{api_key.name}.")
         |> load_tenant_detail()}

      {:error, :api_key_not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "API key not found.")
         |> load_tenant_detail()}

      {:error, :tenant_not_found} ->
        {:noreply, assign(socket, detail_status: :not_found)}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Unable to revoke API key.")
         |> load_tenant_detail()}
    end
  rescue
    _ ->
      {:noreply,
       socket
       |> put_flash(:error, "Unable to revoke API key.")
       |> load_tenant_detail()}
  end

  defp assign_blank_form(socket) do
    assign(socket, api_key_form: to_form(%{"name" => ""}, as: :api_key))
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
         {:ok, api_keys} <- Governance.list_api_keys_for_tenant(tenant) do
      assign(socket,
        detail_status: :ok,
        tenant: tenant,
        api_keys: api_keys,
        page_title: "Tenant #{tenant.slug}",
        load_error: nil
      )
    else
      {:error, :tenant_not_found} ->
        assign(socket, detail_status: :not_found)

      _ ->
        assign(socket,
          detail_status: :error,
          load_error: "Tenant details unavailable."
        )
    end
  rescue
    _ ->
      assign(socket,
        detail_status: :error,
        load_error: "Tenant details unavailable."
      )
  end
end
