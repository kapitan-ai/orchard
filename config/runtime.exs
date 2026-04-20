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

env_non_neg_int = fn env_name, default ->
  value = env_int.(env_name, default)

  if value < 0 do
    raise "environment variable #{env_name} must be an integer >= 0, got: #{value}"
  end

  value
end

env_float = fn env_name, default ->
  case System.get_env(env_name) || default do
    value when is_float(value) ->
      value

    value when is_integer(value) ->
      value / 1

    value ->
      case Float.parse(value) do
        {parsed, ""} ->
          parsed

        _other ->
          raise "environment variable #{env_name} must be a float, got: #{inspect(value)}"
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

env_csv = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value ->
      value
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end
end

env_optional_string = fn env_name ->
  case System.get_env(env_name) do
    nil ->
      nil

    value ->
      trimmed = String.trim(value)
      if trimmed == "", do: nil, else: trimmed
  end
end

env_license_enforcement = fn env_name, default ->
  case System.get_env(env_name) || default do
    "off" ->
      :off

    "warn" ->
      :warn

    "hard" ->
      :hard

    value ->
      raise "environment variable #{env_name} must be one of off|warn|hard, got: #{inspect(value)}"
  end
end

env_ip = fn env_name, default_string ->
  ip_string = System.get_env(env_name) || default_string

  case :inet.parse_address(String.to_charlist(ip_string)) do
    {:ok, ip_tuple} ->
      ip_tuple

    {:error, _} ->
      raise "environment variable #{env_name} must be a valid IP address, got: #{inspect(ip_string)}"
  end
end

validate_cors_origin! = fn origin ->
  cond do
    origin == "*" ->
      raise "Wildcard '*' CORS origin is not allowed — use explicit origin allowlist in ORCHARD_CORS_ORIGINS"

    origin == "null" ->
      raise "'null' CORS origin is not allowed in ORCHARD_CORS_ORIGINS"

    true ->
      uri = URI.parse(origin)

      unless uri.scheme in ["http", "https"] do
        raise "Invalid CORS origin #{inspect(origin)} — must use http or https scheme"
      end

      unless is_binary(uri.host) and uri.host != "" do
        raise "Invalid CORS origin #{inspect(origin)} — missing host"
      end

      if uri.path not in [nil, "", "/"] do
        raise "Invalid CORS origin #{inspect(origin)} — must not include a path (got #{inspect(uri.path)})"
      end

      if String.ends_with?(origin, "/") do
        raise "Invalid CORS origin #{inspect(origin)} — must not have trailing slash"
      end

      if uri.query do
        raise "Invalid CORS origin #{inspect(origin)} — must not include query string"
      end

      if uri.fragment do
        raise "Invalid CORS origin #{inspect(origin)} — must not include fragment"
      end

      if uri.userinfo do
        raise "Invalid CORS origin #{inspect(origin)} — must not include userinfo"
      end

      :ok
  end
end

# Parse X.509 certificate time value ({:utcTime, charlist} or {:generalTime, charlist})
# into a NaiveDateTime.
parse_cert_time = fn
  {:utcTime, time_chars} ->
    time_str = List.to_string(time_chars)

    <<yy::binary-2, mm::binary-2, dd::binary-2, hh::binary-2, min::binary-2, ss::binary-2, "Z">> =
      time_str

    year = String.to_integer(yy)
    year = if year >= 50, do: 1900 + year, else: 2000 + year

    NaiveDateTime.new!(
      year,
      String.to_integer(mm),
      String.to_integer(dd),
      String.to_integer(hh),
      String.to_integer(min),
      String.to_integer(ss)
    )

  {:generalTime, time_chars} ->
    time_str = List.to_string(time_chars)

    <<yyyy::binary-4, mm::binary-2, dd::binary-2, hh::binary-2, min::binary-2, ss::binary-2, "Z">> =
      time_str

    NaiveDateTime.new!(
      String.to_integer(yyyy),
      String.to_integer(mm),
      String.to_integer(dd),
      String.to_integer(hh),
      String.to_integer(min),
      String.to_integer(ss)
    )
end

validate_tls_material! = fn certfile, keyfile ->
  # --- Validate certificate file ---
  unless File.exists?(certfile) do
    raise "TLS certificate file not found: #{certfile}\nGenerate with: orchardctl tls init"
  end

  unless File.regular?(certfile) do
    raise "TLS certificate path is not a regular file: #{certfile}"
  end

  cert_pem = File.read!(certfile)
  cert_entries = :public_key.pem_decode(cert_pem)

  cert_entry =
    Enum.find(cert_entries, fn
      {:Certificate, _, :not_encrypted} -> true
      _ -> false
    end)

  unless cert_entry do
    raise "TLS certificate file contains no certificate PEM entry: #{certfile}"
  end

  {:Certificate, cert_der, :not_encrypted} = cert_entry
  otp_cert = :public_key.pkix_decode_cert(cert_der, :otp)

  # Navigate OTP record structure (positions are ASN.1-standardized, stable across OTP versions):
  #   OTPCertificate{tbsCertificate, ...}  -> elem 1
  #   OTPTBSCertificate{..., validity, ...} -> elem 5
  #   Validity{notBefore, notAfter}         -> elems 1, 2
  tbs = elem(otp_cert, 1)
  validity = elem(tbs, 5)
  not_before_raw = elem(validity, 1)
  not_after_raw = elem(validity, 2)
  not_before = parse_cert_time.(not_before_raw)
  not_after = parse_cert_time.(not_after_raw)
  now = NaiveDateTime.utc_now()

  if NaiveDateTime.compare(not_before, now) == :gt do
    raise "TLS certificate is not yet valid (notBefore: #{NaiveDateTime.to_iso8601(not_before)}Z): #{certfile}"
  end

  if NaiveDateTime.compare(not_after, now) == :lt do
    raise "TLS certificate has expired (#{NaiveDateTime.to_iso8601(not_after)}Z): #{certfile}"
  end

  seconds_remaining = NaiveDateTime.diff(not_after, now)
  days_remaining = div(seconds_remaining, 86_400)

  if days_remaining < 30 do
    IO.puts(:stderr, """
    ⚠️  TLS certificate expires in #{days_remaining} day(s) \
    (#{NaiveDateTime.to_iso8601(not_after)}Z): #{certfile}
    """)
  end

  # --- Validate private key file ---
  unless File.exists?(keyfile) do
    raise "TLS private key file not found: #{keyfile}\nGenerate with: orchardctl tls init"
  end

  unless File.regular?(keyfile) do
    raise "TLS private key path is not a regular file: #{keyfile}"
  end

  key_pem = File.read!(keyfile)
  key_entries = :public_key.pem_decode(key_pem)

  key_entry =
    Enum.find(key_entries, fn
      {:RSAPrivateKey, _, :not_encrypted} -> true
      {:ECPrivateKey, _, :not_encrypted} -> true
      {:PrivateKeyInfo, _, :not_encrypted} -> true
      _ -> false
    end)

  unless key_entry do
    encrypted? =
      Enum.any?(key_entries, fn
        {_, _, :not_encrypted} -> false
        _ -> true
      end)

    if encrypted? do
      raise "TLS private key is encrypted (passphrase-protected keys are not supported): #{keyfile}"
    else
      raise "TLS private key file contains no supported private key PEM entry: #{keyfile}"
    end
  end

  :ok
end

# Keep these release-safe defaults aligned with config/m1_runtime_defaults.exs.
parse_runtime_targets = fn env_name ->
  env_name
  |> System.get_env()
  |> Orchard.Config.RuntimeTargetParser.parse_csv!(env_name)
end

default_controller_inference = fn root ->
  [
    tokenizer_mode: :port,
    tokenizer_executable: "orchard-tokenizer",
    artifacts_root: Path.join(root, "bundles"),
    runtime_client_target: [host: "127.0.0.1", port: 50_061],
    runtime_client_targets: [],
    request_timeout_ms: 120_000,
    model_load_timeout_ms: 120_000,
    node_freshness_threshold_ms: 30_000,
    node_unreachable_threshold_ms: 15_000
  ]
end

default_hf_config = fn ->
  [
    base_url: "https://huggingface.co",
    api_base_url: "https://huggingface.co/api",
    token: nil,
    retry_attempts: 3,
    connect_timeout_ms: 10_000,
    receive_timeout_ms: 30_000,
    req_options: []
  ]
end

default_node_runtime = fn root ->
  [
    node_id: nil,
    node_identity_path: Path.join([root, "data", "node-id"]),
    display_name: nil,
    listen_address: [host: "127.0.0.1", port: 50_061],
    models_root: Path.join(root, "models"),
    worker_socket_dir: Path.join([root, "data", "worker-sockets"]),
    worker_executable: "orchard-worker-mlx",
    worker_backend: "mlx",
    worker_ready_timeout_ms: 5_000,
    worker_load_timeout_ms: 120_000,
    worker_shutdown_timeout_ms: 1_000,
    worker_log_dir: Path.join([root, "logs", "workers"]),
    worker_prefix_cache_mode: "kv",
    worker_prefix_cache_max_entries: 8,
    worker_prefix_cache_max_bytes: 0,
    worker_generation_mode: "stream",
    worker_max_concurrent_requests_per_model: 1,
    worker_memory_budget_mode: "observe",
    worker_memory_budget_utilization: 0.90,
    worker_memory_budget_overhead_bytes: 1_073_741_824,
    max_loaded_models: 0,
    fake_runtime?: false,
    hf: default_hf_config.(),
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

default_licensing = fn root ->
  [
    bundle_path: Path.join([root, "config", "licensing", "current.json"]),
    node_identity_path: Path.join([root, "data", "node-id"]),
    keygen_api_base_url: "https://api.keygen.sh",
    keygen_account_id: "6f872d6f-52ce-4bbe-8b3f-b57669753f34",
    keygen_public_key: "f1a328edc3d42967e8545c1361d2dc22622fad52aad0dc8e5d3b3cb95d7cb18a"
  ]
end

if sentry_dsn = env_optional_string.("ORCHARD_SENTRY_DSN") do
  release_name = System.get_env("RELEASE_NAME") || System.get_env("MIX_RELEASE_NAME") || "mix"

  config :sentry,
    dsn: sentry_dsn,
    environment_name: env_optional_string.("ORCHARD_SENTRY_ENV") || to_string(config_env()),
    release: "#{release_name}@#{Orchard.BuildInfo.git_sha()}",
    before_send: {Orchard.SentryFilter, :filter},
    tags: %{build_sha: Orchard.BuildInfo.git_sha(), build_date: Orchard.BuildInfo.build_date()}
end

if config_env() == :prod do
  orchard_support_root =
    System.get_env("ORCHARD_SUPPORT_ROOT") || "/Library/Application Support/Orchard"

  licensing_overrides =
    [
      bundle_path: env_optional_string.("ORCHARD_LICENSE_BUNDLE_PATH"),
      node_identity_path: env_optional_string.("ORCHARD_NODE_IDENTITY_PATH"),
      keygen_api_base_url: env_optional_string.("ORCHARD_KEYGEN_API_BASE_URL"),
      keygen_account_id: env_optional_string.("ORCHARD_KEYGEN_ACCOUNT_ID"),
      keygen_public_key: env_optional_string.("ORCHARD_KEYGEN_PUBLIC_KEY")
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)

  config :orchard_shared,
         :licensing,
         Keyword.merge(default_licensing.(orchard_support_root), licensing_overrides)

  config :orchard_controller,
         :upgrade_preflight,
         backup_manifest_path:
           System.get_env("ORCHARD_UPGRADE_BACKUP_MANIFEST_PATH") ||
             Path.join([orchard_support_root, "support", "upgrade-backup.json"]),
         queue_tolerance: env_non_neg_int.("ORCHARD_UPGRADE_QUEUE_TOLERANCE", "0")

  case System.get_env("RELEASE_NAME") || System.get_env("MIX_RELEASE_NAME") do
    "orchard_controller" ->
      database_url =
        System.get_env("DATABASE_URL") ||
          raise "environment variable DATABASE_URL is missing for Orchard controller releases"

      secret_key_base =
        System.get_env("SECRET_KEY_BASE") ||
          raise "environment variable SECRET_KEY_BASE is missing for Orchard controller releases"

      # --- Console configuration ---
      console_enabled? = env_bool.("ORCHARD_CONSOLE_ENABLED", false)

      console_config =
        if console_enabled? do
          username = System.get_env("ORCHARD_CONSOLE_USERNAME") || ""
          password = System.get_env("ORCHARD_CONSOLE_PASSWORD") || ""

          if username == "" or password == "" do
            raise """
            ORCHARD_CONSOLE_ENABLED=true but credentials are missing.

            Set both ORCHARD_CONSOLE_USERNAME and ORCHARD_CONSOLE_PASSWORD \
            environment variables to enable the console with Basic Auth.
            """
          end

          [enabled: true, auth: :basic, username: username, password: password]
        else
          [enabled: false, auth: :basic, username: nil, password: nil]
        end

      config :orchard_controller, :console, console_config

      # --- TLS / HTTPS configuration ---
      tls_disabled? = env_bool.("ORCHARD_TLS_DISABLED", false)

      public_host =
        System.get_env("ORCHARD_PUBLIC_HOST") || System.get_env("PHX_HOST") || "localhost"

      # CORS origins — strict validation at boot
      cors_origins =
        env_csv.("ORCHARD_CORS_ORIGINS", [])
        |> Enum.uniq()

      Enum.each(cors_origins, validate_cors_origin!)

      # TLS file paths
      tls_dir = Path.join([orchard_support_root, "config", "tls"])
      certfile = System.get_env("ORCHARD_TLS_CERTFILE") || Path.join(tls_dir, "controller.crt")
      keyfile = System.get_env("ORCHARD_TLS_KEYFILE") || Path.join(tls_dir, "controller.key")
      cacertfile = System.get_env("ORCHARD_TLS_CACERTFILE") || Path.join(tls_dir, "ca.crt")
      ca_meta_path = Path.join(Path.dirname(cacertfile), ".orchard-tls-meta.json")

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
            runtime_client_targets: parse_runtime_targets.("ORCHARD_RUNTIME_CLIENT_TARGETS"),
            request_timeout_ms: env_int.("ORCHARD_REQUEST_TIMEOUT_MS", "120000"),
            model_load_timeout_ms: env_int.("ORCHARD_MODEL_LOAD_TIMEOUT_MS", "120000"),
            node_freshness_threshold_ms: env_int.("ORCHARD_NODE_FRESHNESS_THRESHOLD_MS", "30000"),
            node_unreachable_threshold_ms:
              env_int.("ORCHARD_NODE_UNREACHABLE_THRESHOLD_MS", "15000")
          )

      controller_hf_token =
        env_optional_string.("ORCHARD_HF_TOKEN") || env_optional_string.("HF_TOKEN")

      controller_hf_base_url = env_optional_string.("ORCHARD_HF_BASE_URL")

      controller_hf_api_base_url =
        env_optional_string.("ORCHARD_HF_API_BASE_URL") ||
          if(controller_hf_base_url,
            do: String.trim_trailing(controller_hf_base_url, "/") <> "/api"
          )

      config :orchard_controller,
             :hf,
             Keyword.merge(
               default_hf_config.(),
               Enum.reject(
                 [
                   base_url: controller_hf_base_url,
                   api_base_url: controller_hf_api_base_url,
                   token: controller_hf_token
                 ],
                 fn {_k, v} -> is_nil(v) end
               )
             )

      # --- Transport listener configuration ---
      {transport_config, url_config, transport_degraded?} =
        if tls_disabled? do
          # Emergency recovery mode — loopback-only HTTP
          http_port = env_int.("PORT", "4000")

          IO.puts(:stderr, """

          ╔══════════════════════════════════════════════════════════════╗
          ║  ⚠️  TLS DISABLED — EMERGENCY RECOVERY MODE               ║
          ║                                                            ║
          ║  ORCHARD_TLS_DISABLED=true                                 ║
          ║  Controller listening on HTTP 127.0.0.1:#{String.pad_trailing(to_string(http_port), 5)}             ║
          ║  This is NOT secure for production use.                    ║
          ║  Generate certificates: orchardctl tls init                ║
          ╚══════════════════════════════════════════════════════════════╝
          """)

          {[http: [ip: {127, 0, 0, 1}, port: http_port]],
           [host: "localhost", port: http_port, scheme: "http"], true}
        else
          # Normal HTTPS mode — validate TLS material before starting
          https_port = env_int.("ORCHARD_API_HTTPS_PORT", "8443")
          bind_ip = env_ip.("ORCHARD_API_BIND_IP", "0.0.0.0")
          validate_tls_material!.(certfile, keyfile)

          {[
             https: [
               ip: bind_ip,
               port: https_port,
               certfile: certfile,
               keyfile: keyfile,
               cipher_suite: :strong
             ]
           ], [host: public_host, port: https_port, scheme: "https"], false}
        end

      config :orchard_controller, transport_degraded: transport_degraded?

      config :orchard_controller,
             Orchard.API.Endpoint,
             transport_config ++
               [
                 server: true,
                 url: url_config,
                 secret_key_base: secret_key_base,
                 cors_origins: cors_origins,
                 ca_certfile: cacertfile,
                 ca_cert_metadata_path: ca_meta_path
               ]

    "orchard_cli" ->
      database_url = System.get_env("DATABASE_URL")

      if database_url do
        config :orchard_controller, Orchard.Repo,
          url: database_url,
          pool_size: env_int.("POOL_SIZE", "10"),
          socket_options:
            if(System.get_env("ECTO_IPV6") in ["true", "1"], do: [:inet6], else: []),
          # The packaged wrapper runs through release eval, so Repo query logs share
          # orchardctl's CLI streams and can corrupt JSON output.
          log: false
      end

      config :orchard_controller,
        start_repo: not is_nil(database_url),
        start_endpoint: false,
        enable_db_checks: true

    "orchard_node_agent" ->
      config :orchard_node_agent,
        runtime:
          Keyword.merge(
            default_node_runtime.(orchard_support_root),
            node_id: System.get_env("ORCHARD_NODE_ID"),
            node_identity_path:
              System.get_env("ORCHARD_NODE_IDENTITY_PATH") ||
                Path.join([orchard_support_root, "data", "node-id"]),
            display_name: System.get_env("ORCHARD_NODE_DISPLAY_NAME"),
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
            worker_log_dir:
              System.get_env("ORCHARD_WORKER_LOG_DIR") ||
                Path.join([orchard_support_root, "logs", "workers"]),
            worker_prefix_cache_mode:
              (fn ->
                 mode = System.get_env("ORCHARD_WORKER_PREFIX_CACHE_MODE") || "kv"

                 unless mode in ["disabled", "kv", "trie"] do
                   raise "ORCHARD_WORKER_PREFIX_CACHE_MODE must be disabled|kv|trie, got: #{inspect(mode)}"
                 end

                 mode
               end).(),
            worker_prefix_cache_max_entries:
              (fn ->
                 v = env_int.("ORCHARD_WORKER_PREFIX_CACHE_MAX_ENTRIES", "8")

                 if v < 1 do
                   raise "ORCHARD_WORKER_PREFIX_CACHE_MAX_ENTRIES must be >= 1, got: #{v}"
                 end

                 v
               end).(),
            worker_prefix_cache_max_bytes:
              (fn ->
                 v = env_int.("ORCHARD_WORKER_PREFIX_CACHE_MAX_BYTES", "0")

                 if v < 0 do
                   raise "ORCHARD_WORKER_PREFIX_CACHE_MAX_BYTES must be >= 0, got: #{v}"
                 end

                 v
               end).(),
            worker_generation_mode:
              (fn ->
                 mode = System.get_env("ORCHARD_WORKER_GENERATION_MODE") || "stream"

                 unless mode in ["stream", "batch"] do
                   raise "ORCHARD_WORKER_GENERATION_MODE must be stream|batch, got: #{inspect(mode)}"
                 end

                 mode
               end).(),
            worker_max_concurrent_requests_per_model:
              (fn ->
                 v = env_int.("ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL", "1")

                 if v < 1 do
                   raise "ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL must be >= 1, got: #{v}"
                 end

                 v
               end).(),
            worker_memory_budget_mode:
              (fn ->
                 mode = System.get_env("ORCHARD_WORKER_MEMORY_BUDGET_MODE") || "observe"

                 unless mode in ["disabled", "observe"] do
                   raise "ORCHARD_WORKER_MEMORY_BUDGET_MODE must be disabled|observe (enforce not yet supported), got: #{inspect(mode)}"
                 end

                 mode
               end).(),
            worker_memory_budget_utilization:
              (fn ->
                 v = env_float.("ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION", "0.90")

                 if v <= 0.0 or v > 1.0 do
                   raise "ORCHARD_WORKER_MEMORY_BUDGET_UTILIZATION must be > 0.0 and <= 1.0, got: #{v}"
                 end

                 v
               end).(),
            worker_memory_budget_overhead_bytes:
              env_non_neg_int.("ORCHARD_WORKER_MEMORY_BUDGET_OVERHEAD_BYTES", "1073741824"),
            license_enforcement: env_license_enforcement.("ORCHARD_LICENSE_ENFORCEMENT", "warn"),
            max_loaded_models: env_int.("ORCHARD_MAX_LOADED_MODELS", "0"),
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
