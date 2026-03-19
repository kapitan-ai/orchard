import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)

repo_root = Path.expand("..", __DIR__)
test_root = Path.join([repo_root, "tmp", "test"])

config :orchard_controller, Orchard.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: System.get_env("PGDATABASE_TEST") || "orchard_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :orchard_controller,
  start_repo: false,
  start_endpoint: false,
  enable_db_checks: false,
  inference:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.controller_inference(test_root),
      tokenizer_mode: :fake,
      tokenizer_executable:
        Path.join([repo_root, "native", "orchard_tokenizer", "bin", "orchard-tokenizer"]),
      runtime_client_target: [host: "127.0.0.1", port: 50_071],
      request_timeout_ms: 5_000,
      model_load_timeout_ms: 5_000
    ),
  hf: Orchard.Config.M1RuntimeDefaults.hf()

config :orchard_node_agent,
  runtime:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.node_runtime(test_root),
      listen_address: [host: "127.0.0.1", port: 50_071],
      worker_executable:
        Path.join([repo_root, "native", "orchard_worker_mlx", "bin", "orchard-worker-mlx"]),
      worker_backend: "stub",
      worker_log_dir: Path.join([test_root, "logs", "workers"]),
      worker_ready_timeout_ms: 5_000,
      worker_load_timeout_ms: 5_000,
      worker_shutdown_timeout_ms: 1_000,
      fake_runtime?: true
    )

# Console: enabled with no auth for deterministic test behavior.
config :orchard_controller, :console,
  enabled: true,
  auth: :none,
  username: nil,
  password: nil,
  model_hub_impl: OrchardConsole.ModelHub,
  model_hub_client_impl: Orchard.Models.HubClient

config :orchard_controller, Orchard.API.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  cors_origins: [],
  secret_key_base: String.duplicate("test-secret-", 8),
  server: false

config :logger, level: :warning
