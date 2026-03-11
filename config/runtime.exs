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
    request_timeout_ms: 120_000,
    model_load_timeout_ms: 120_000
  ]
end

default_node_runtime = fn root ->
  [
    listen_address: [host: "127.0.0.1", port: 50_061],
    models_root: Path.join(root, "models"),
    worker_socket_dir: Path.join([root, "data", "worker-sockets"]),
    worker_executable: "orchard-worker-mlx",
    worker_backend: "mlx",
    worker_ready_timeout_ms: 5_000,
    worker_load_timeout_ms: 120_000,
    worker_shutdown_timeout_ms: 1_000,
    fake_runtime?: false,
    hf: [
      base_url: "https://huggingface.co",
      api_base_url: "https://huggingface.co/api",
      token: nil,
      retry_attempts: 3,
      connect_timeout_ms: 10_000,
      receive_timeout_ms: 30_000,
      req_options: []
    ],
    s3: [
      endpoint: nil,
      region: "us-east-1",
      access_key_id: nil,
      secret_access_key: nil,
      session_token: nil,
      force_path_style?: false,
      connect_timeout_ms: 10_000,
      receive_timeout_ms: 60_000,
      req_options: []
    ]
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
            request_timeout_ms: env_int.("ORCHARD_REQUEST_TIMEOUT_MS", "120000"),
            model_load_timeout_ms: env_int.("ORCHARD_MODEL_LOAD_TIMEOUT_MS", "120000")
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
            worker_executable:
              System.get_env("ORCHARD_WORKER_EXECUTABLE") || "orchard-worker-mlx",
            worker_backend: System.get_env("ORCHARD_WORKER_BACKEND") || "mlx",
            worker_ready_timeout_ms: env_int.("ORCHARD_WORKER_READY_TIMEOUT_MS", "5000"),
            worker_load_timeout_ms: env_int.("ORCHARD_WORKER_LOAD_TIMEOUT_MS", "120000"),
            worker_shutdown_timeout_ms: env_int.("ORCHARD_WORKER_SHUTDOWN_TIMEOUT_MS", "1000"),
            fake_runtime?: env_bool.("ORCHARD_FAKE_RUNTIME", false),
            hf:
              Keyword.merge(
                Keyword.get(default_node_runtime.(orchard_support_root), :hf, []),
                Enum.reject(
                  [
                    base_url: System.get_env("ORCHARD_HF_BASE_URL"),
                    api_base_url: System.get_env("ORCHARD_HF_API_BASE_URL"),
                    token: System.get_env("HF_TOKEN"),
                    retry_attempts:
                      if(System.get_env("ORCHARD_HF_RETRY_ATTEMPTS"),
                        do: env_int.("ORCHARD_HF_RETRY_ATTEMPTS", "3")
                      ),
                    connect_timeout_ms:
                      if(System.get_env("ORCHARD_HF_CONNECT_TIMEOUT_MS"),
                        do: env_int.("ORCHARD_HF_CONNECT_TIMEOUT_MS", "10000")
                      ),
                    receive_timeout_ms:
                      if(System.get_env("ORCHARD_HF_RECEIVE_TIMEOUT_MS"),
                        do: env_int.("ORCHARD_HF_RECEIVE_TIMEOUT_MS", "30000")
                      )
                  ],
                  fn {_k, v} -> is_nil(v) end
                )
              ),
            s3:
              Keyword.merge(
                Keyword.get(default_node_runtime.(orchard_support_root), :s3, []),
                Enum.reject(
                  [
                    endpoint: System.get_env("ORCHARD_S3_ENDPOINT"),
                    region: System.get_env("ORCHARD_S3_REGION"),
                    access_key_id: System.get_env("ORCHARD_S3_ACCESS_KEY_ID"),
                    secret_access_key: System.get_env("ORCHARD_S3_SECRET_ACCESS_KEY"),
                    session_token: System.get_env("ORCHARD_S3_SESSION_TOKEN"),
                    force_path_style?:
                      if(System.get_env("ORCHARD_S3_FORCE_PATH_STYLE"),
                        do: env_bool.("ORCHARD_S3_FORCE_PATH_STYLE", false)
                      ),
                    connect_timeout_ms:
                      if(System.get_env("ORCHARD_S3_CONNECT_TIMEOUT_MS"),
                        do: env_int.("ORCHARD_S3_CONNECT_TIMEOUT_MS", "10000")
                      ),
                    receive_timeout_ms:
                      if(System.get_env("ORCHARD_S3_RECEIVE_TIMEOUT_MS"),
                        do: env_int.("ORCHARD_S3_RECEIVE_TIMEOUT_MS", "60000")
                      )
                  ],
                  fn {_k, v} -> is_nil(v) end
                )
              )
          )

    _other_release ->
      :ok
  end
end
