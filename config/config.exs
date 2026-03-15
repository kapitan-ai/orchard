import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)

orchard_support_root = "/Library/Application Support/Orchard"

config :phoenix, :json_library, Jason

config :orchard_controller,
  ecto_repos: [Orchard.Repo],
  generators: [binary_id: true],
  transport_degraded: false

# Console feature flag and auth defaults.
# Dev/test: enabled with no auth for frictionless local development.
# Prod: overridden in runtime.exs with Basic Auth and env var credentials.
config :orchard_controller, :console,
  enabled: true,
  auth: :none,
  username: nil,
  password: nil,
  runtime_impl: OrchardConsole.Runtime,
  playground_impl: OrchardConsole.Playground,
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

config :orchard_node_agent,
       :runtime,
       Orchard.Config.M1RuntimeDefaults.node_runtime(orchard_support_root)

# esbuild (JS bundling for LiveView client hooks)
config :esbuild,
  version: "0.25.0",
  orchard: [
    args: ~w(js/app.js --bundle --target=es2020 --outdir=../priv/static/assets),
    cd: Path.expand("../apps/orchard_controller/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# tailwind (CSS compilation with brand palette)
config :tailwind,
  version: "4.1.3",
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
