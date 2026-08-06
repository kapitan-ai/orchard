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
    plug(Orchard.API.LicensePlug)
  end

  pipeline :admin_api do
    plug(:accepts, ["json"])
    plug(Orchard.API.AdminRequestContext)
  end

  pipeline :operator_api do
    plug(:accepts, ["json"])
    plug(Orchard.API.Plugs.NoStore)
    plug(Orchard.API.OperatorRequestContext)
  end

  pipeline :metrics do
    plug(Orchard.API.Plugs.NoStore)
    plug(Orchard.API.OperatorRequestContext)
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    # ThemeInitial only assigns the validated theme cookie; it runs before Auth so
    # the assign is present for any plug that renders, independent of auth outcome.
    plug(OrchardConsole.Plug.ThemeInitial)
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

  scope "/" do
    pipe_through(:metrics)

    get("/metrics", Orchard.API.MetricsController, :show)
    match(:*, "/metrics", Orchard.API.MetricsController, :method_not_allowed)
    match(:*, "/metrics/*path", Orchard.API.MetricsController, :not_found)
  end

  scope "/bootstrap/v1", Orchard.API.Bootstrap do
    pipe_through(:api)

    post("/node-enrollments/:id/redeem", NodeEnrollmentController, :redeem)
  end

  scope "/v1", Orchard.API do
    pipe_through(:authenticated_api)

    get("/models", ModelsController, :index)
    post("/chat/completions", ChatCompletionsController, :create)
    post("/responses", ResponsesController, :create)
  end

  scope "/ops/v1", Orchard.API.Ops do
    pipe_through(:operator_api)

    get("/health", HealthController, :show)
    get("/scheduler/explanations/:request_id", SchedulerExplanationsController, :show)
  end

  scope "/admin/v1", Orchard.API.Admin do
    pipe_through(:admin_api)

    get("/node-admission/candidates", NodeAdmissionController, :index)
    get("/node-admission/candidates/:candidate_id", NodeAdmissionController, :show)
    post("/node-admission/candidates/:candidate_id/reject", NodeAdmissionController, :reject)

    post(
      "/node-admission/candidates/:candidate_id/clear-rejection",
      NodeAdmissionController,
      :clear_rejection
    )

    post("/nodes/:node_id/admit", NodeAdmissionController, :admit)
  end

  # Console — LiveView operator UI
  scope "/console" do
    pipe_through(:browser)

    live_session :console, on_mount: [{OrchardConsole, :ensure_console_access}] do
      live("/", OrchardConsole.OverviewLive, :index)
      live("/nodes", OrchardConsole.NodesLive, :index)
      live("/nodes/pending/:candidate_id", OrchardConsole.NodeDetailLive, :candidate)
      live("/nodes/:node_id", OrchardConsole.NodeDetailLive, :node)
      live("/playground", OrchardConsole.PlaygroundLive, :index)
      live("/models", OrchardConsole.ModelsLive, :index)
      live("/model-hub", OrchardConsole.ModelHubLive, :index)
      live("/settings", OrchardConsole.SettingsLive, :index)
      live("/requests", OrchardConsole.RequestsLive, :index)
      live("/requests/:public_id", OrchardConsole.RequestLive, :show)
      live("/tenants", OrchardConsole.TenantsLive, :index)
      live("/tenants/:id", OrchardConsole.TenantDetailLive, :show)
    end
  end
end
