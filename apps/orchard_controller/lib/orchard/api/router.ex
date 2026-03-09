defmodule Orchard.API.Router do
  @moduledoc false

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/" do
    pipe_through(:api)

    get("/health/live", Orchard.API.HealthController, :live)
    get("/health/ready", Orchard.API.HealthController, :ready)
  end
end
