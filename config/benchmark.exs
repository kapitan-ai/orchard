import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)
Code.require_file("source_postgres.exs", __DIR__)

repo_root = Path.expand("..", __DIR__)
benchmark_root = Path.join([repo_root, "tmp", "benchmark"])

# Benchmark environment: real MLX backend for cold-start measurement
# Based on dev.exs but without watchers/reloaders

config :orchard_controller, Orchard.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  port: Orchard.Config.SourcePostgres.port!(System.get_env("PGPORT")),
  database: System.get_env("PGDATABASE_BENCHMARK") || "orchard_benchmark",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :orchard_controller,
  start_repo: true,
  start_endpoint: false,
  enable_db_checks: true,
  inference:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.controller_inference(benchmark_root),
      tokenizer_mode: :real,
      tokenizer_executable:
        Path.join([repo_root, "native", "orchard_tokenizer", "bin", "orchard-tokenizer"]),
      runtime_client_target: [host: "127.0.0.1", port: 50_071],
      request_timeout_ms: 60_000,
      model_load_timeout_ms: 120_000
    ),
  hf: Orchard.Config.M1RuntimeDefaults.hf()

# Benchmark runs a Repo-owning Controller, so it carries the same loopback
# single-host membership identity the resolver produces for gRPC and dev.
config :orchard_controller, :controller_membership,
  private_ipv4: "127.0.0.1",
  scope: :local_only,
  authorization_root_path: Path.join(benchmark_root, "beam-authorization-root")

config :orchard_controller, :node_trust, root: Path.join(benchmark_root, "node-trust")

# Benchmark runtime: REAL MLX backend (not fake/stub)
config :orchard_node_agent,
  runtime:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.node_runtime(benchmark_root),
      node_id: "00000000-0000-4000-a000-000000000001",
      display_name: "benchmark-node",
      listen_address: [host: "127.0.0.1", port: 50_071],
      worker_executable:
        System.get_env("ORCHARD_WORKER_EXECUTABLE") ||
          Path.join([repo_root, "native", "orchard_worker_mlx", "bin", "orchard-worker-mlx"]),
      worker_backend: "mlx",
      worker_log_dir: Path.join([benchmark_root, "logs", "workers"]),
      worker_ready_timeout_ms: 30_000,
      worker_load_timeout_ms: 120_000,
      worker_shutdown_timeout_ms: 5_000,
      fake_runtime?: false
    )

# Console: disabled for benchmark runs
config :orchard_controller, :console, enabled: false

config :orchard_controller, Orchard.API.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4001],
  check_origin: false,
  code_reloader: false,
  debug_errors: false,
  secret_key_base: String.duplicate("benchmark-secret-", 8)

# Silence logger for cleaner benchmark output
config :logger, :console, level: :warning
