defmodule OrchardConsole.TenantsLive do
  @moduledoc """
  Console Organizations page.
  """

  use OrchardConsole, :live_view

  alias Orchard.Governance

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Organizations", active_nav: :tenants)
      |> assign_loading_state()
      |> assign_blank_form()

    if connected?(socket) do
      {:ok, load_tenants(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("create_tenant", %{"tenant" => params}, socket) do
    create_tenant(socket, params)
  end

  @impl true
  def render(%{tenants_status: :loading} = assigns) do
    ~H"""
    <.state_message
      id="tenants-loading-card"
      kind={:loading}
      layout={:panel}
      title="Organizations"
      body="Loading Organizations…"
    />
    """
  end

  def render(%{tenants_status: :error} = assigns) do
    ~H"""
    <.state_message
      id="tenants-error-card"
      kind={:error}
      layout={:panel}
      title="Organizations unavailable"
      body={@load_error}
    />
    """
  end

  def render(%{tenants_status: :ok} = assigns) do
    ~H"""
    <div class="space-y-6">
      <div id="tenant-create-card">
        <.card>
          <:title>Create Organization</:title>
          <:subtitle>Add a new Organization to issue API Tokens against.</:subtitle>

          <.simple_form
            for={@tenant_form}
            as={:tenant}
            id="tenant-create-form"
            phx-submit="create_tenant"
          >
              <.input
                field={@tenant_form[:slug]}
                label="Slug"
                placeholder="acme-production"
                size={:lg}
                aria-describedby="tenant-slug-hint"
              />
              <p id="tenant-slug-hint" class="-mt-3 text-xs text-slate-500 dark:text-slate-400">
                Suggested format: short lowercase words separated by hyphens, e.g. acme-production.
              </p>
              <.input
                field={@tenant_form[:name]}
                label="Name"
                placeholder="Acme Production"
                size={:lg}
              />
            <:actions>
              <.button type="submit" phx-disable-with="Creating…">Create Organization</.button>
            </:actions>
          </.simple_form>
        </.card>
      </div>

      <div id="tenants-list-card">
        <.card>
          <:title>Organizations</:title>

          <.table id="tenants-table" rows={@tenants} row_id={&"tenant-#{&1.id}"}>
            <:col :let={tenant} label="Name">{tenant.name}</:col>
            <:col :let={tenant} label="Slug" mono>{tenant.slug}</:col>
            <:col :let={tenant} label="Organization ID" mono>
              <span class="text-xs">{tenant.id}</span>
            </:col>
            <:col :let={tenant} label="Created" mono><.local_time value={tenant.inserted_at} format={:datetime_minute} /></:col>

            <:action :let={tenant}>
              <.link
                id={"tenant-open-#{tenant.id}"}
                navigate={"/console/tenants/#{tenant.id}"}
                class="text-forest-600 hover:text-forest-700 dark:text-emerald-400 dark:hover:text-emerald-300 font-medium text-sm"
              >
                Open
              </.link>
            </:action>

            <:empty>
              <.state_message
                id="tenants-empty-state"
                kind={:empty}
                layout={:compact}
                title="No Organizations created yet."
              >
                <:action>
                  Create an Organization above to start issuing API Tokens.
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

  defp create_tenant(socket, params) do
    case Governance.create_tenant(params) do
      {:ok, tenant} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created Organization #{tenant.slug}.")
         |> assign_blank_form()
         |> load_tenants()}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = changeset_to_form(changeset, :tenant, %{"slug" => "", "name" => ""})
        {:noreply, assign(socket, tenant_form: form)}
    end
  rescue
    _ ->
      {:noreply, put_flash(socket, :error, "Unable to create tenant.")}
  end

  defp assign_loading_state(socket) do
    assign(socket,
      tenants_status: :loading,
      tenants: [],
      load_error: nil
    )
  end

  defp assign_blank_form(socket) do
    assign(socket, tenant_form: to_form(%{"slug" => "", "name" => ""}, as: :tenant))
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

  defp load_tenants(socket) do
    assign(socket,
      tenants_status: :ok,
      tenants: Governance.list_tenants(),
      load_error: nil
    )
  rescue
    _ ->
      assign(socket,
        tenants_status: :error,
        tenants: [],
        load_error: "Organization data unavailable."
      )
  end
end
