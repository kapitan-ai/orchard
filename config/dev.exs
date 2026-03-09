import Config

config :orchard_controller, Orchard.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  database: System.get_env("PGDATABASE") || "orchard_dev",
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :orchard_controller, Orchard.API.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: String.duplicate("dev-secret-", 8),
  server: false
