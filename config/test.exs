import Config

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
  enable_db_checks: false

config :orchard_controller, Orchard.API.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: String.duplicate("test-secret-", 8),
  server: false

config :logger, level: :warning
