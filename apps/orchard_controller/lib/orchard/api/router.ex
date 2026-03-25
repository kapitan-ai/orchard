defmodule Orchard.API.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :authenticated_api do
    plug(:accepts, ["json"])
    plug(Orchard.API.RequestContext)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(OrchardConsole.Auth)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {OrchardConsole.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  # CA cert download — outside pipelines (no JSON Accept requirement)
  get("/ca.crt", Orchard.API.CACertController, :show)

  scope "/" do
    pipe_through(:api)

    get("/health/live", Orchard.API.HealthController, :live)
    get("/health/ready", Orchard.API.HealthController, :ready)
  end

  scope "/v1", Orchard.API do
    pipe_through(:authenticated_api)

    get("/models", ModelsController, :index)
    post("/chat/completions", ChatCompletionsController, :create)
    post("/responses", ResponsesController, :create)
  end

  # Console — LiveView operator UI
  scope "/console" do
    pipe_through(:browser)

    live_session :console, on_mount: [{OrchardConsole, :ensure_console_access}] do
      live("/", OrchardConsole.OverviewLive, :index)
      live("/nodes", OrchardConsole.NodesLive, :index)
      live("/playground", OrchardConsole.PlaygroundLive, :index)
      live("/models", OrchardConsole.ModelsLive, :index)
      live("/model-hub", OrchardConsole.ModelHubLive, :index)
      live("/requests", OrchardConsole.RequestsLive, :index)
      live("/requests/:public_id", OrchardConsole.RequestLive, :show)
      live("/tenants", OrchardConsole.TenantsLive, :index)
      live("/tenants/:id", OrchardConsole.TenantDetailLive, :show)
    end
  end
end
