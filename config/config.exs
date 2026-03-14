import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)

orchard_support_root = "/Library/Application Support/Orchard"

config :phoenix, :json_library, Jason

config :orchard_controller,
  ecto_repos: [Orchard.Repo],
  generators: [binary_id: true]

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

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
