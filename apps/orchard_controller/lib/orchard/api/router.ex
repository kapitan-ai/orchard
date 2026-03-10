defmodule Orchard.API.Router do
  @moduledoc false

  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :authenticated_api do
    plug(:accepts, ["json"])
    plug(Orchard.API.RequestContext)
  end

  scope "/" do
    pipe_through(:api)

    get("/health/live", Orchard.API.HealthController, :live)
    get("/health/ready", Orchard.API.HealthController, :ready)
  end

  scope "/v1", Orchard.API do
    pipe_through(:authenticated_api)

    get("/models", ModelsController, :index)
    post("/chat/completions", ChatCompletionsController, :create)
  end
end
