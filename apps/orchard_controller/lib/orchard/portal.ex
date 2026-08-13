defmodule Orchard.Portal do
  @moduledoc """
  Isolated developer-portal web namespace.

  Portal layouts, pipelines, and LiveView sessions must not consult Console
  auth markers or render Console chrome.
  """

  alias Orchard.Governance
  alias Orchard.Portal.Auth
  alias Phoenix.LiveView

  @spec static_paths() :: [String.t()]
  def static_paths, do: OrchardConsole.static_paths()

  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_portal_session, params, session, socket) do
    slug = Map.get(params, "organization_slug", "")
    token = Auth.session_token(session)

    case Governance.validate_portal_session(token || "", slug) do
      {:ok, %{tenant: tenant, session: portal_session}} ->
        {:cont,
         socket
         |> Phoenix.Component.assign(:organization_slug, slug)
         |> Phoenix.Component.assign(:current_tenant, tenant)
         |> Phoenix.Component.assign(:portal_session, portal_session)
         |> Phoenix.Component.assign(:portal_token, token)}

      {:error, :invalid_session} ->
        {:halt, LiveView.redirect(socket, to: "/portal/#{slug}")}
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html],
        layouts: [html: {Orchard.Portal.Layouts, :app}]

      import Plug.Conn
      unquote(html_helpers())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {Orchard.Portal.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0, get_flash: 1, get_flash: 2]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import OrchardConsole.CoreComponents

      use Phoenix.VerifiedRoutes,
        endpoint: Orchard.API.Endpoint,
        router: Orchard.API.Router,
        statics: Orchard.Portal.static_paths()
    end
  end
end
