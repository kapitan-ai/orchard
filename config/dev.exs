import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)

repo_root = Path.expand("..", __DIR__)
dev_root = Path.join([repo_root, "tmp", "dev"])

# Dev runtime port — avoids conflict with packaged BEAM on 50061.
# Matches test.exs precedent (50071). Supports both env var names for parity
# with config/runtime.exs; raises on mismatch to prevent split-brain config.
parse_port = fn val, var_name ->
  case Integer.parse(val) do
    {port, ""} when port > 0 and port < 65536 -> port
    _ -> raise "Invalid #{var_name}=#{inspect(val)} — expected an integer 1..65535"
  end
end

dev_runtime_port =
  case {System.get_env("ORCHARD_NODE_AGENT_LISTEN_PORT"),
        System.get_env("ORCHARD_RUNTIME_CLIENT_PORT")} do
    {nil, nil} ->
      50_071

    {val, nil} ->
      parse_port.(val, "ORCHARD_NODE_AGENT_LISTEN_PORT")

    {nil, val} ->
      parse_port.(val, "ORCHARD_RUNTIME_CLIENT_PORT")

    {a, b} when a == b ->
      parse_port.(a, "ORCHARD_NODE_AGENT_LISTEN_PORT")

    {a, b} ->
      raise "Port mismatch: ORCHARD_NODE_AGENT_LISTEN_PORT=#{a} vs ORCHARD_RUNTIME_CLIENT_PORT=#{b}"
  end

dev_runtime_host = "127.0.0.1"

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
      runtime_client_target: [host: dev_runtime_host, port: dev_runtime_port],
      tokenizer_executable:
        System.get_env("ORCHARD_TOKENIZER_EXECUTABLE") ||
          Path.join([repo_root, "native", "orchard_tokenizer", "bin", "orchard-tokenizer"])
    )

config :orchard_node_agent,
  runtime:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.node_runtime(dev_root),
      listen_address: [host: dev_runtime_host, port: dev_runtime_port],
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
