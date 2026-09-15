defmodule Orchard.API.Router do
  @moduledoc false

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :authenticated_api do
    plug(Orchard.API.RequestContext)
  end

  pipeline :inference_api do
    plug(Orchard.API.InferenceAccepts)
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
    pipe_through([:api, :authenticated_api])
    get("/models", ModelsController, :index)
  end

  scope "/v1", Orchard.API do
    pipe_through([:inference_api, :authenticated_api])

    post("/chat/completions", ChatCompletionsController, :create)
    post("/responses", ResponsesController, :create)
  end

  scope "/ops/v1", Orchard.API.Ops do
    pipe_through(:operator_api)

    get("/health", HealthController, :show)
    post("/requests/:id/retry", RequestRetriesController, :create)
    get("/scheduler/explanations/:request_id", SchedulerExplanationsController, :show)
    get("/circuit-breakers/nodes/:node_id", CircuitBreakersController, :show_node)
    post("/circuit-breakers/nodes/:node_id/clear", CircuitBreakersController, :clear_node)

    get(
      "/circuit-breakers/placements/:node_id/:model_id",
      CircuitBreakersController,
      :show_placement
    )

    post(
      "/circuit-breakers/placements/:node_id/:model_id/clear",
      CircuitBreakersController,
      :clear_placement
    )
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
      live("/nodes/new", OrchardConsole.NodeEnrollmentLive, :new)
      live("/nodes/new/:enrollment_id", OrchardConsole.NodeEnrollmentLive, :status)
      live("/nodes/pending/:candidate_id", OrchardConsole.NodeDetailLive, :candidate)
      live("/nodes/:node_id", OrchardConsole.NodeDetailLive, :node)
      live("/playground", OrchardConsole.PlaygroundLive, :index)
      live("/models", OrchardConsole.ModelsLive, :index)
      live("/models/catalog", OrchardConsole.ModelsLive, :index)
      live("/models/catalog/import", OrchardConsole.ModelHubLive, :catalog_job)
      live("/models/discover", OrchardConsole.ModelHubLive, :index)
      live("/model-hub", OrchardConsole.ModelHubLive, :index)
      live("/settings", OrchardConsole.SettingsLive, :index)
      live("/requests", OrchardConsole.RequestsLive, :index)
      live("/requests/:public_id", OrchardConsole.RequestLive, :show)
      live("/access", OrchardConsole.TenantsLive, :index)
      live("/access/workspaces", OrchardConsole.TenantsLive, :index)
      live("/access/workspaces/new", OrchardConsole.TenantsLive, :new)
      live("/access/workspaces/:id/handoff", OrchardConsole.WorkspaceHandoffLive, :show)
      live("/access/workspaces/:id", OrchardConsole.TenantDetailLive, :show)
      live("/tenants", OrchardConsole.TenantsLive, :index)
      live("/tenants/:id", OrchardConsole.TenantDetailLive, :show)
    end
  end

  pipeline :portal do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(Orchard.Portal.TransportGuard)
    plug(:put_root_layout, html: {Orchard.Portal.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/portal" do
    pipe_through(:portal)

    get("/:organization_slug", Orchard.Portal.SessionController, :new)
    post("/:organization_slug/session", Orchard.Portal.SessionController, :create)
    post("/:organization_slug/logout", Orchard.Portal.SessionController, :delete)
    get("/:organization_slug/invites/:token", Orchard.Portal.SessionController, :invite)
    post("/:organization_slug/invites/:token", Orchard.Portal.SessionController, :redeem)

    live_session :developer_portal,
      on_mount: [{Orchard.Portal, :ensure_portal_session}],
      layout: {Orchard.Portal.Layouts, :app},
      root_layout: {Orchard.Portal.Layouts, :root} do
      live("/:organization_slug/keys", Orchard.Portal.KeysLive, :index)
    end
  end
end
