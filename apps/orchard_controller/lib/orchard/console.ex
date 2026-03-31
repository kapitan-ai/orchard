defmodule OrchardConsole do
  @moduledoc """
  The Orchard Console web interface.

  Provides a Phoenix LiveView operator console for monitoring and managing
  Orchard inference infrastructure.
  """

  @doc """
  Returns the static file paths served by the console.

  Used by `Plug.Static` in the endpoint to determine which paths to serve.
  """
  @spec static_paths() :: [String.t()]
  def static_paths, do: ~w(assets fonts images favicon.ico favicon.png robots.txt)

  @doc """
  Returns the UI-formatted console version string.

  Reads `Application.spec(:orchard_controller, :vsn)` and normalizes it
  to a display-ready string. Returns `"dev"` when version metadata is absent.
  """
  @spec display_version() :: String.t()
  def display_version do
    case Application.spec(:orchard_controller, :vsn) do
      nil -> "dev"
      vsn when is_list(vsn) -> "v" <> List.to_string(vsn)
      vsn when is_binary(vsn) -> "v" <> vsn
      vsn -> "v" <> to_string(vsn)
    end
  end

  @doc """
  LiveView `on_mount` hook that gates console access on mount/reconnect.

  Checks both the feature flag (`console_enabled`) and the session auth
  marker (for `:basic` auth mode). Redirects to `/console` on denial,
  which re-enters the HTTP plug for proper 404 or 401 handling.
  """
  def on_mount(:ensure_console_access, _params, session, socket) do
    config = OrchardConsole.Auth.console_config()

    case OrchardConsole.Auth.authorize_live_session(session, config) do
      :ok ->
        {:cont, socket}

      {:error, _reason} ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/console")}
    end
  end

  @doc """
  Shared helpers for console LiveViews and components.

  Imports Phoenix LiveView, HTML, and component helpers.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {OrchardConsole.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, get_flash: 1, get_flash: 2]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML

      # Import core UI components
      import OrchardConsole.CoreComponents

      # Shortcut for generating routes
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Orchard.API.Endpoint,
        router: Orchard.API.Router,
        statics: OrchardConsole.static_paths()
    end
  end
end
