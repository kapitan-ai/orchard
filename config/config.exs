import Config

config :phoenix, :json_library, Jason

config :orchard_controller,
  ecto_repos: [Orchard.Repo],
  generators: [binary_id: true]

config :orchard_controller, Orchard.API.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [json: Orchard.API.ErrorJSON], layout: false],
  pubsub_server: Orchard.PubSub,
  live_view: [signing_salt: "m0signsalt"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
