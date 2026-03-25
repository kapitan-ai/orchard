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

# Dev runtime hosts — separate bind (node-agent) and connect (controller) for
# 2-node source-dev cluster testing. Defaults preserve single-node loopback.
dev_runtime_client_host =
  System.get_env("ORCHARD_RUNTIME_CLIENT_HOST") || "127.0.0.1"

dev_node_agent_listen_host =
  System.get_env("ORCHARD_NODE_AGENT_LISTEN_HOST") || "127.0.0.1"

# Inline parser for ORCHARD_RUNTIME_CLIENT_TARGETS (comma-separated host:port).
# Intentionally inline — RuntimeTargetParser may not be compiled when dev.exs
# evaluates on clean builds. Mirrors RuntimeTargetParser.parse_csv!/2 semantics.
# SYNC NOTE: if RuntimeTargetParser parse rules change, update this parser too.
# See apps/orchard_controller/lib/orchard/config/runtime_target_parser.ex
parse_runtime_targets = fn env_name ->
  case System.get_env(env_name) do
    nil ->
      []

    value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn segment ->
        case String.split(segment, ":") do
          [host, port_str] when host != "" ->
            case Integer.parse(port_str) do
              {port, ""} when port > 0 and port < 65536 ->
                [host: host, port: port]

              _ ->
                raise "environment variable #{env_name} has invalid port in segment #{inspect(segment)}"
            end

          _ ->
            raise "environment variable #{env_name} has invalid host:port segment #{inspect(segment)}"
        end
      end)
  end
end

dev_runtime_targets = parse_runtime_targets.("ORCHARD_RUNTIME_CLIENT_TARGETS")

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
      runtime_client_target: [host: dev_runtime_client_host, port: dev_runtime_port],
      runtime_client_targets: dev_runtime_targets,
      tokenizer_executable:
        System.get_env("ORCHARD_TOKENIZER_EXECUTABLE") ||
          Path.join([repo_root, "native", "orchard_tokenizer", "bin", "orchard-tokenizer"])
    )

config :orchard_node_agent,
  runtime:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.node_runtime(dev_root),
      listen_address: [host: dev_node_agent_listen_host, port: dev_runtime_port],
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
