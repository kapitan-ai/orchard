defmodule OrchardConsole.TenantsLive do
  @moduledoc """
  Console Workspaces page.
  """

  use OrchardConsole, :live_view

  alias Orchard.Governance
  alias OrchardConsole.WorkspacePresentation

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Access",
        active_nav: :tenants,
        create_mode: socket.assigns.live_action == :new
      )
      |> assign_loading_state()
      |> assign_blank_form()

    if connected?(socket) do
      {:ok, load_tenants(socket)}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("refresh_workspaces", _params, socket), do: {:noreply, load_tenants(socket)}

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
      title="Workspaces"
      body="Loading Workspaces…"
    />
    """
  end

  def render(%{tenants_status: :error} = assigns) do
    ~H"""
    <.state_message
      id="tenants-error-card"
      kind={:error}
      layout={:panel}
      title="Workspaces unavailable"
      body={@load_error}
    ><:action><.button phx-click="refresh_workspaces" variant={:secondary}>Retry</.button></:action></.state_message>
    """
  end

  def render(%{tenants_status: :ok} = assigns) do
    ~H"""
    <div class="space-y-6">
      <header id="tenants-page-header" class="space-y-2">
        <h2 class="text-2xl font-semibold text-slate-900 dark:text-slate-100">Manage Workspace access</h2>
        <p class="max-w-3xl text-sm leading-6 text-slate-600 dark:text-slate-300">
          A Workspace is the scope for model access, Portal Users, API credentials, requests, and usage.
          Choose a Workspace to manage its access, or create a separate scope for new work.
        </p>
      </header>

      <.link :if={!@create_mode} navigate="/console/access/workspaces/new" class="text-sm text-navy underline">Create Workspace</.link>
      <.link :if={@create_mode} navigate="/console/access" class="text-sm text-navy underline">Back to Workspaces</.link>
      <p :if={!@create_mode && !Enum.any?(@tenants, &WorkspacePresentation.default?/1)} id="workspace-default-missing" role="status">Default workspace is unavailable. Refresh after checking the controller setup; no replacement scope has been created.</p>
      <.button :if={!@create_mode} phx-click="refresh_workspaces" variant={:secondary}>Refresh Workspaces</.button>
      <div :if={!@create_mode} id="tenants-list-card">
        <.card>
          <:title>Choose a Workspace</:title>
          <:subtitle>Access and credentials are managed independently inside each Workspace.</:subtitle>

          <.table id="tenants-table" rows={@tenants} row_id={&"tenant-#{&1.id}"}>
            <:col :let={tenant} label="Name">{WorkspacePresentation.display_name(tenant)} <span :if={WorkspacePresentation.default?(tenant)} class="text-xs text-slate-500">Default</span></:col>
            <:col :let={tenant} label="Slug" mono>{tenant.slug}</:col>
            <:col :let={tenant} label="Workspace ID" mono>
              <span class="text-xs">{tenant.id}</span>
            </:col>
            <:col :let={tenant} label="Created" mono><.local_time value={tenant.inserted_at} format={:datetime_minute} /></:col>

            <:action :let={tenant}>
              <.link
                id={"tenant-open-#{tenant.id}"}
                navigate={"/console/access/workspaces/#{tenant.id}"}
                class="inline-flex rounded-md px-2 py-1 text-sm font-medium text-navy hover:bg-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-navy dark:text-sky-400 dark:hover:bg-slate-700 dark:focus-visible:ring-sky-400"
              >
                Open workspace
              </.link>
            </:action>

            <:empty>
              <.state_message
                id="tenants-empty-state"
                kind={:empty}
                layout={:compact}
                title="No Workspaces created yet."
              >
                <:action>
                  Use Create Workspace to establish an isolated scope.
                </:action>
              </.state_message>
            </:empty>
          </.table>
        </.card>
      </div>

      <div :if={@create_mode} id="tenant-create-card">
        <.card>
          <:title>Create a separate Workspace</:title>
          <:subtitle>
            This creates the scope only. It does not grant model access, invite a Portal User, or issue an API credential.
          </:subtitle>

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
              <.button type="submit" phx-disable-with="Creating…">Create Workspace</.button>
            </:actions>
          </.simple_form>
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
         |> put_flash(:info, "Created Workspace #{tenant.slug}.")
         |> assign_blank_form()
         |> push_navigate(to: "/console/access/workspaces/#{tenant.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        form = changeset_to_form(changeset, :tenant, %{"slug" => "", "name" => ""})
        {:noreply, assign(socket, tenant_form: form)}
    end
  rescue
    _ ->
      {:noreply, put_flash(socket, :error, "Unable to create Workspace.")}
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
      tenants:
        Enum.sort_by(
          Governance.list_tenants(),
          &{!WorkspacePresentation.default?(&1), WorkspacePresentation.display_name(&1), &1.id}
        ),
      load_error: nil
    )
  rescue
    _ ->
      assign(socket,
        tenants_status: :error,
        tenants: [],
        load_error: "Workspace data unavailable."
      )
  end
end
