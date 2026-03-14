defmodule Orchard.API.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :orchard_controller

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:orchard, :api])
  plug(Plug.Head)
  plug(Orchard.API.CORS)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(Orchard.API.Router)
end
