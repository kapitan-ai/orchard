import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)

repo_root = Path.expand("..", __DIR__)
dev_root = Path.join([repo_root, "tmp", "dev"])

config :orchard_controller, Orchard.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: System.get_env("PGDATABASE") || "orchard_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :orchard_controller,
  inference:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.controller_inference(dev_root),
      tokenizer_executable:
        System.get_env("ORCHARD_TOKENIZER_EXECUTABLE") ||
          Path.join([repo_root, "native", "orchard_tokenizer", "bin", "orchard-tokenizer"])
    )

config :orchard_node_agent,
  runtime:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.node_runtime(dev_root),
      worker_executable:
        System.get_env("ORCHARD_WORKER_EXECUTABLE") ||
          Path.join([repo_root, "native", "orchard_worker_mlx", "bin", "orchard-worker-mlx"])
    )

# Console: enabled with no auth for frictionless local development.
config :orchard_controller, :console,
  enabled: true,
  auth: :none,
  username: nil,
  password: nil

config :orchard_controller, Orchard.API.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  cors_origins: [],
  code_reloader: true,
  debug_errors: true,
  secret_key_base: String.duplicate("dev-secret-", 8),
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:orchard, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:orchard, ~w(--watch)]}
  ],
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"lib/orchard/console/.*(ex)$",
      ~r"lib/orchard/console/.*(heex)$"
    ]
  ]
