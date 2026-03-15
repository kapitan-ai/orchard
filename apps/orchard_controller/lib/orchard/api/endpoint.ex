defmodule Orchard.API.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :orchard_controller

  @session_options [
    store: :cookie,
    key: "_orchard_console_key",
    signing_salt: "orchard_console",
    same_site: "Lax"
  ]

  # LiveView WebSocket
  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  # Serve static assets (CSS, JS, images, fonts) from priv/static
  plug(Plug.Static,
    at: "/",
    from: :orchard_controller,
    gzip: false,
    only: OrchardConsole.static_paths()
  )

  # Code reloading in development
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:orchard, :api])
  plug(Plug.Head)
  plug(Orchard.API.CORS)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)

  plug(Plug.Session, @session_options)

  plug(Orchard.API.Router)
end
