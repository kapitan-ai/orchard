import Config

env_int = fn env_name, default ->
  case System.get_env(env_name) || default do
    value when is_integer(value) ->
      value

    value ->
      case Integer.parse(value) do
        {parsed, ""} ->
          parsed

        _other ->
          raise "environment variable #{env_name} must be an integer, got: #{inspect(value)}"
      end
  end
end

env_bool = fn env_name, default ->
  case System.get_env(env_name) do
    nil -> default
    value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
    value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
    value -> raise "environment variable #{env_name} must be a boolean, got: #{inspect(value)}"
  end
end

# Keep these release-safe defaults aligned with config/m1_runtime_defaults.exs.
default_controller_inference = fn root ->
  [
    tokenizer_mode: :port,
    tokenizer_executable: "orchard-tokenizer",
    artifacts_root: Path.join(root, "bundles"),
    runtime_client_target: [host: "127.0.0.1", port: 50_061],
    request_timeout_ms: 120_000
  ]
end

default_node_runtime = fn root ->
  [
    listen_address: [host: "127.0.0.1", port: 50_061],
    models_root: Path.join(root, "models"),
    worker_socket_dir: Path.join([root, "data", "worker-sockets"]),
    fake_runtime?: false
  ]
end

if config_env() == :prod do
  orchard_support_root =
    System.get_env("ORCHARD_SUPPORT_ROOT") || "/Library/Application Support/Orchard"

  case System.get_env("RELEASE_NAME") || System.get_env("MIX_RELEASE_NAME") do
    "orchard_controller" ->
      database_url =
        System.get_env("DATABASE_URL") ||
          raise "environment variable DATABASE_URL is missing for Orchard controller releases"

      secret_key_base =
        System.get_env("SECRET_KEY_BASE") ||
          raise "environment variable SECRET_KEY_BASE is missing for Orchard controller releases"

      host = System.get_env("PHX_HOST") || "localhost"
      port = env_int.("PORT", "4000")

      config :orchard_controller, Orchard.Repo,
        url: database_url,
        pool_size: env_int.("POOL_SIZE", "10"),
        socket_options: if(System.get_env("ECTO_IPV6") in ["true", "1"], do: [:inet6], else: [])

      config :orchard_controller,
        inference:
          Keyword.merge(
            default_controller_inference.(orchard_support_root),
            tokenizer_executable:
              System.get_env("ORCHARD_TOKENIZER_EXECUTABLE") || "orchard-tokenizer",
            artifacts_root:
              System.get_env("ORCHARD_ARTIFACTS_ROOT") ||
                Path.join(orchard_support_root, "bundles"),
            runtime_client_target: [
              host: System.get_env("ORCHARD_RUNTIME_CLIENT_HOST") || "127.0.0.1",
              port: env_int.("ORCHARD_RUNTIME_CLIENT_PORT", "50061")
            ],
            request_timeout_ms: env_int.("ORCHARD_REQUEST_TIMEOUT_MS", "120000")
          )

      config :orchard_controller, Orchard.API.Endpoint,
        server: true,
        http: [ip: {0, 0, 0, 0}, port: port],
        url: [host: host, port: 443, scheme: "https"],
        secret_key_base: secret_key_base

    "orchard_node_agent" ->
      config :orchard_node_agent,
        runtime:
          Keyword.merge(
            default_node_runtime.(orchard_support_root),
            listen_address: [
              host: System.get_env("ORCHARD_NODE_AGENT_LISTEN_HOST") || "127.0.0.1",
              port: env_int.("ORCHARD_NODE_AGENT_LISTEN_PORT", "50061")
            ],
            models_root:
              System.get_env("ORCHARD_MODELS_ROOT") || Path.join(orchard_support_root, "models"),
            worker_socket_dir:
              System.get_env("ORCHARD_WORKER_SOCKET_DIR") ||
                Path.join([orchard_support_root, "data", "worker-sockets"]),
            fake_runtime?: env_bool.("ORCHARD_FAKE_RUNTIME", false)
          )

    _other_release ->
      :ok
  end
end
