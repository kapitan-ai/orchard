import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)

orchard_support_root = "/Library/Application Support/Orchard"

config :phoenix, :json_library, Jason

config :orchard_controller,
  ecto_repos: [Orchard.Repo],
  generators: [binary_id: true],
  transport_mode: :plain_http_localhost,
  transport_cert_source: :unknown,
  transport_degraded: true,
  bundle_build_eager_preflight_enabled: true,
  bundle_build_preflight_timeout_ms: 60_000,
  trust_manifest_compatibility_declarations: true,
  node_heartbeat_payload_max_bytes: 262_144

config :orchard_controller, :portal,
  session_absolute_seconds: 28_800,
  session_idle_seconds: 1_800,
  verifier_workers: 2,
  verifier_queue: 32,
  verifier_timeout_ms: 5_000,
  prune_interval_ms: 3_600_000,
  throttle_stale_seconds: 86_400

# Console feature flag and auth defaults.
# Dev/test: enabled with no auth for frictionless local development.
config :orchard_controller, :console,
  enabled: true,
  auth: :none,
  username: nil,
  password: nil,
  runtime_impl: OrchardConsole.Runtime,
  playground_impl: OrchardConsole.Playground,
  model_hub_impl: OrchardConsole.ModelHub,
  model_hub_client_impl: Orchard.Models.HubClient,
  model_hub_download_impl: Orchard.Models.HubDownloader,
  download_coordinator_impl: OrchardConsole.ModelHubDownloadCoordinator,
  refresh_interval_ms: 5_000

config :orchard_controller, Orchard.API.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: Orchard.API.ErrorJSON], layout: false],
  pubsub_server: Orchard.PubSub,
  live_view: [signing_salt: "m0signsalt"],
  cors_origins: [],
  ca_certfile: nil,
  ca_cert_metadata_path: nil

config :orchard_controller,
       :inference,
       Orchard.Config.M1RuntimeDefaults.controller_inference(orchard_support_root)

config :orchard_controller, :runtime_endpoint,
  beam: [
    enabled: false,
    node_name: nil,
    cookie_file: nil,
    admitted_services: [],
    allowed_cidrs: [],
    listen_host: nil
  ]

config :orchard_controller,
       :hf,
       Orchard.Config.M1RuntimeDefaults.hf()

config :orchard_node_agent,
       :runtime,
       Orchard.Config.M1RuntimeDefaults.node_runtime(orchard_support_root)

config :orchard_shared,
       :licensing,
       Orchard.Config.M1RuntimeDefaults.licensing(orchard_support_root)

# esbuild (JS bundling for LiveView client hooks)
config :esbuild,
  version: "0.25.0",
  version_check: false,
  path: Path.expand("../node_modules/.bin/esbuild", __DIR__),
  orchard: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets),
    cd: Path.expand("../apps/orchard_controller/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# tailwind (CSS compilation with brand palette)
config :tailwind,
  version: "4.1.3",
  version_check: false,
  path: Path.expand("../node_modules/.bin/tailwindcss", __DIR__),
  orchard: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/orchard_controller/assets", __DIR__)
  ]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
