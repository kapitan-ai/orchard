defmodule Orchard.API.Endpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :orchard_controller

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:orchard, :api])
  plug(Plug.Head)
  plug(Orchard.API.Router)
end
