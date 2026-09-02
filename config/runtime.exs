import Config

require Logger

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

env_port = fn env_name, default ->
  port = env_int.(env_name, default)

  unless port in 1..65_535 do
    raise "environment variable #{env_name} must be a TCP port in 1..65535, got: #{inspect(port)}"
  end

  port
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

default_worker_generation_mode = fn
  "stub" -> "stream"
  _backend -> "batch"
end

env_tokenizer_safe_mode = fn env_name, default ->
  case System.get_env(env_name) || default do
    value when value in [:off, "off"] ->
      :off

    value when value in [:on, "on"] ->
      :on

    value when value in [:reject, "reject"] ->
      :reject

    value ->
      raise "#{env_name} must be off|on|reject, got: #{inspect(value)}"
  end
end

env_ip = fn env_name, default_string ->
  ip_string = System.get_env(env_name) || default_string

  case :inet.parse_address(String.to_charlist(ip_string)) do
    {:ok, ip_tuple} ->
      ip_tuple

    {:error, _reason} ->
      raise "environment variable #{env_name} must be a valid IP address, got: #{inspect(ip_string)}"
  end
end

loopback_ip? = fn
  {127, _b, _c, _d} -> true
  {0, 0, 0, 0, 0, 0, 0, 1} -> true
  _other -> false
end

private_ipv4? = fn
  {10, _b, _c, _d} -> true
  {172, b, _c, _d} when b in 16..31 -> true
  {192, 168, _c, _d} -> true
  _other -> false
end

loopback_listen_host? = fn host ->
  case :inet.parse_address(String.to_charlist(host)) do
    {:ok, ip_tuple} -> loopback_ip?.(ip_tuple)
    {:error, _reason} -> host == "localhost"
  end
end

parse_trusted_proxy_cidr! = fn cidr ->
  with [ip_string, prefix_string] <- String.split(cidr, "/", parts: 2),
       {:ok, ip_tuple} <- :inet.parse_address(String.to_charlist(ip_string)),
       {prefix, ""} <- Integer.parse(prefix_string),
       max_prefix = if(tuple_size(ip_tuple) == 4, do: 32, else: 128),
       true <- prefix in 0..max_prefix do
    {ip_tuple, prefix}
  else
    _other ->
      raise "ORCHARD_TRUSTED_PROXIES contains invalid CIDR #{inspect(cidr)}"
  end
end

trusted_proxy_cidrs = fn ->
  case System.get_env("ORCHARD_TRUSTED_PROXIES") do
    nil ->
      [{{127, 0, 0, 1}, 32}, {{0, 0, 0, 0, 0, 0, 0, 1}, 128}]

    _raw ->
      values = env_csv.("ORCHARD_TRUSTED_PROXIES", [])

      if values == [] do
        raise "ORCHARD_TRUSTED_PROXIES must contain at least one CIDR when set"
      end

      Enum.map(values, parse_trusted_proxy_cidr!)
  end
end

trusted_proxies_set? = fn ->
  case System.get_env("ORCHARD_TRUSTED_PROXIES") do
    nil -> false
    value -> String.trim(value) != ""
  end
end

origin_host = fn host ->
  case :inet.parse_address(String.to_charlist(host)) do
    {:ok, ip} when tuple_size(ip) == 8 -> "[#{host}]"
    _other -> host
  end
end

reverse_proxy_config = fn public_host ->
  backend_port = env_port.("PORT", "4000")
  bind_ip = env_ip.("ORCHARD_API_BIND_IP", "127.0.0.1")
  trusted_proxies = trusted_proxy_cidrs.()

  if not loopback_ip?.(bind_ip) and not trusted_proxies_set?.() do
    raise "ORCHARD_TRUSTED_PROXIES must be set when reverse_proxy binds to a non-loopback address"
  end

  public_port = env_port.("ORCHARD_PUBLIC_PORT", "443")
  formatted_public_host = origin_host.(public_host)

  public_origin =
    if public_port == 443,
      do: "https://#{formatted_public_host}",
      else: "https://#{formatted_public_host}:#{public_port}"

  %{
    listener: [http: [ip: bind_ip, port: backend_port]],
    url: [host: public_host, port: public_port, scheme: "https"],
    check_origin: [public_origin],
    trusted_proxies: trusted_proxies
  }
end

source_dev_transport_mode! = fn
  nil ->
    :plain_http_localhost

  "plain_http_localhost" ->
    :plain_http_localhost

  "reverse_proxy" ->
    :reverse_proxy

  "direct_https" ->
    raise "ORCHARD_TRANSPORT_MODE=direct_https is release-only; source dev supports plain_http_localhost|reverse_proxy"

  value ->
    raise "ORCHARD_TRANSPORT_MODE must be plain_http_localhost|reverse_proxy in source dev, got: #{inspect(value)}"
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

decode_certificate_pem! = fn pem_path, material_name ->
  material_label = if material_name == "", do: "", else: material_name <> " "
  cert_pem = File.read!(pem_path)
  cert_entries = :public_key.pem_decode(cert_pem)

  cert_entry =
    Enum.find(cert_entries, fn
      {:Certificate, _, :not_encrypted} -> true
      _ -> false
    end)

  unless cert_entry do
    raise "TLS #{material_label}certificate file contains no certificate PEM entry: #{pem_path}"
  end

  {:Certificate, cert_der, :not_encrypted} = cert_entry

  otp_cert =
    try do
      :public_key.pkix_decode_cert(cert_der, :otp)
    rescue
      _ ->
        reraise RuntimeError,
                [message: "TLS #{material_label}certificate PEM is malformed: #{pem_path}"],
                __STACKTRACE__
    end

  {cert_der, otp_cert}
end

certificate_public_key! = fn otp_cert, certfile ->
  public_key_info = otp_cert |> elem(1) |> elem(7)

  case public_key_info do
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 113_549, 1, 1, 1}, _},
     {:RSAPublicKey, _, _} = public_key} ->
      {:rsa, public_key}

    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, {1, 2, 840, 10_045, 2, 1}, parameters},
     {:ECPoint, _} = public_key} ->
      {:ec, parameters, public_key}

    _other ->
      raise "TLS certificate contains an unsupported public key algorithm: #{certfile}"
  end
end

private_key_public_key! = fn key_entry, keyfile ->
  decoded_key =
    try do
      :public_key.pem_entry_decode(key_entry)
    rescue
      _ ->
        reraise RuntimeError,
                [
                  message:
                    "TLS private key file contains no supported private key PEM entry: #{keyfile}"
                ],
                __STACKTRACE__
    end

  case decoded_key do
    {:RSAPrivateKey, _version, modulus, public_exponent, _private_exponent, _prime1, _prime2,
     _exponent1, _exponent2, _coefficient, _other_prime_infos} ->
      {:rsa, {:RSAPublicKey, modulus, public_exponent}}

    {:ECPrivateKey, _version, _private_key, parameters, public_key, _attributes} ->
      {:ec, parameters, {:ECPoint, public_key}}

    _other ->
      raise "TLS private key file contains no supported private key PEM entry: #{keyfile}"
  end
end

validate_ca_material! = fn cacertfile ->
  unless File.exists?(cacertfile) do
    raise "TLS CA certificate file not found: #{cacertfile}"
  end

  unless File.regular?(cacertfile) do
    raise "TLS CA certificate path is not a regular file: #{cacertfile}"
  end

  decode_certificate_pem!.(cacertfile, "CA")
  :ok
end

validate_tls_material! = fn certfile, keyfile, cacertfile ->
  # --- Validate certificate file ---
  unless File.exists?(certfile) do
    raise "TLS certificate file not found: #{certfile}\nGenerate with: orchardctl tls init"
  end

  unless File.regular?(certfile) do
    raise "TLS certificate path is not a regular file: #{certfile}"
  end

  {_cert_der, otp_cert} = decode_certificate_pem!.(certfile, "")

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

  cert_public_key = certificate_public_key!.(otp_cert, certfile)
  key_public_key = private_key_public_key!.(key_entry, keyfile)

  unless cert_public_key == key_public_key do
    raise "TLS certificate and private key do not match: #{certfile} / #{keyfile}"
  end

  if is_binary(cacertfile) do
    validate_ca_material!.(cacertfile)
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
    tokenizer_safe_mode: :off,
    tokenizer_safe_mode_prefer_capable: false,
    artifacts_root: Path.join(root, "bundles"),
    runtime_client_target: [host: "127.0.0.1", port: 50_061],
    runtime_client_targets: [],
    request_timeout_ms: 120_000,
    max_request_deadline_ms: 360_000,
    model_load_timeout_ms: 120_000,
    node_freshness_threshold_ms: 30_000,
    node_unreachable_threshold_ms: 15_000,
    queue_admission: [
      enabled: false,
      max_wait_ms: 3_000,
      max_queued_per_tenant: 32,
      poll_interval_ms: 100,
      capacity: 1,
      owner_runtime: false,
      single_controller_ack: false
    ],
    cache_affinity: [
      enabled: false,
      live_fingerprint_match_enabled: false,
      max_prefix_bytes: 8_192,
      max_age_ms: 300_000,
      max_recent_requests: 32
    ],
    cache_introspection: [
      enabled: false
    ],
    prefix_cache_scoring: [
      enabled: false,
      timeout_ms: 150,
      ranking_mode: :observe_only,
      max_ranking_candidates: 2
    ],
    memory_admission: [
      enabled: false
    ]
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
    node_identity_root: Path.join([root, "config", "node-identity"]),
    grpc_security: :plaintext_compatibility,
    runtime_grpc_listener_enabled: true,
    display_name: nil,
    listen_address: [host: "127.0.0.1", port: 50_061],
    models_root: Path.join(root, "models"),
    force_full_model_verification: false,
    worker_socket_dir: Path.join([root, "data", "worker-sockets"]),
    worker_executable: "orchard-worker-mlx",
    worker_backend: "mlx",
    worker_ready_timeout_ms: 5_000,
    worker_load_timeout_ms: 120_000,
    worker_shutdown_timeout_ms: 1_000,
    worker_capabilities_freshness_window_ms: 15_000,
    worker_log_dir: Path.join([root, "logs", "workers"]),
    worker_prefix_cache_mode: "kv",
    worker_prefix_cache_max_entries: 8,
    worker_prefix_cache_max_bytes: 0,
    worker_generation_mode: "batch",
    worker_max_concurrent_requests_per_model: "auto",
    worker_auto_max_concurrent_requests_per_model: 3,
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

sentry_enrichment_enabled? = env_bool.("ORCHARD_SENTRY_ENRICHMENT_ENABLED", false)
sentry_hash_secret = env_optional_string.("ORCHARD_SENTRY_HASH_SECRET")

if sentry_enrichment_enabled? and is_nil(sentry_hash_secret) do
  Logger.warning("ORCHARD_SENTRY_HASH_SECRET is unset; Sentry identifier hashes will be omitted")
end

config :orchard_shared,
       :sentry_enrichment,
       enabled?: sentry_enrichment_enabled?,
       controller_enabled?:
         env_bool.("ORCHARD_SENTRY_CONTROLLER_ENRICHMENT_ENABLED", sentry_enrichment_enabled?),
       node_agent_enabled?:
         env_bool.("ORCHARD_SENTRY_NODE_ENRICHMENT_ENABLED", sentry_enrichment_enabled?),
       telemetry_breadcrumbs_enabled?:
         env_bool.("ORCHARD_SENTRY_TELEMETRY_BREADCRUMBS_ENABLED", false),
       hash_secret: sentry_hash_secret

if sentry_dsn = env_optional_string.("ORCHARD_SENTRY_DSN") do
  release_name = System.get_env("RELEASE_NAME") || System.get_env("MIX_RELEASE_NAME") || "mix"

  sentry_options =
    [
      dsn: sentry_dsn,
      environment_name: env_optional_string.("ORCHARD_SENTRY_ENV") || to_string(config_env())
    ] ++ Orchard.SentryRelease.runtime_options(release_name)

  config :sentry, sentry_options
end

bundle_build_preflight_timeout_ms =
  (fn ->
     timeout_ms = env_int.("ORCHARD_BUNDLE_BUILD_PREFLIGHT_TIMEOUT_MS", "60000")

     if timeout_ms <= 0 do
       raise "ORCHARD_BUNDLE_BUILD_PREFLIGHT_TIMEOUT_MS must be > 0, got: #{timeout_ms}"
     end

     timeout_ms
   end).()

node_heartbeat_payload_max_bytes =
  (fn ->
     max_bytes = env_int.("ORCHARD_NODE_HEARTBEAT_PAYLOAD_MAX_BYTES", "262144")

     if max_bytes < 128 do
       raise "ORCHARD_NODE_HEARTBEAT_PAYLOAD_MAX_BYTES must be >= 128, got: #{max_bytes}"
     end

     max_bytes
   end).()

config :orchard_controller,
  bundle_build_eager_preflight_enabled:
    env_bool.("ORCHARD_BUNDLE_BUILD_EAGER_PREFLIGHT_ENABLED", true),
  bundle_build_preflight_timeout_ms: bundle_build_preflight_timeout_ms,
  node_heartbeat_payload_max_bytes: node_heartbeat_payload_max_bytes,
  trust_manifest_compatibility_declarations:
    env_bool.("ORCHARD_TRUST_MANIFEST_COMPATIBILITY_DECLARATIONS", true)

if config_env() == :prod do
  orchard_support_root =
    System.get_env("ORCHARD_SUPPORT_ROOT") || "/Library/Application Support/Orchard"

  runtime_worker_backend = System.get_env("ORCHARD_WORKER_BACKEND") || "mlx"

  config :orchard_controller, :node_trust,
    root:
      System.get_env("ORCHARD_NODE_TRUST_ROOT") ||
        Path.join([orchard_support_root, "config", "node-trust"])

  runtime_endpoint_transport = fn env_name, default ->
    case System.get_env(env_name) do
      nil ->
        default

      value ->
        case String.trim(value) do
          "" -> default
          "beam" -> :beam
          "grpc" -> :grpc
          other -> raise "#{env_name} must be beam|grpc, got: #{inspect(other)}"
        end
    end
  end

  beam_service_host = fn value, env_name ->
    case value |> to_string() |> String.split("@") do
      [service, host] when service != "" and host != "" ->
        {service, host}

      _other ->
        raise "#{env_name} has invalid BEAM node-name segment #{inspect(value)}"
    end
  end

  validate_beam_service_name = fn service, env_name, segment ->
    unless String.match?(service, ~r/^[A-Za-z0-9_.-]+$/) do
      raise "#{env_name} has invalid BEAM service name in segment #{inspect(segment)}"
    end
  end

  parse_beam_ipv4 = fn host, env_name, segment ->
    case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
      {:ok, {0, 0, 0, 0}} ->
        raise "#{env_name} must not use unspecified or wildcard BEAM hosts, got segment #{inspect(segment)}"

      {:ok, ip} ->
        ip

      {:error, _reason} ->
        raise "#{env_name} requires IPv4-literal BEAM hosts, got segment #{inspect(segment)}"
    end
  end

  beam_target = fn segment, env_name ->
    {service, host} = beam_service_host.(segment, env_name)
    validate_beam_service_name.(service, env_name, segment)

    unless service == "orchard_node_agent" do
      raise "#{env_name} has unsupported BEAM target service in segment #{inspect(segment)}"
    end

    parse_beam_ipv4.(host, env_name, segment)

    %{
      transport: :beam,
      address: String.to_atom("#{service}@#{host}"),
      metadata: %{packaged: true}
    }
  end

  max_legacy_beam_targets = 64

  beam_targets = fn env_name, required? ->
    segments = env_csv.(env_name, [])

    if length(segments) > max_legacy_beam_targets do
      raise "#{env_name} supports at most #{max_legacy_beam_targets} BEAM targets"
    end

    targets = Enum.map(segments, &beam_target.(&1, env_name))

    if required? and targets == [] do
      raise "#{env_name} must include at least one BEAM target when ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=beam"
    end

    targets
  end

  beam_allowed_cidrs = fn targets, env_name ->
    targets
    |> Enum.map(fn %{address: address} ->
      {_service, host} = beam_service_host.(address, env_name)
      ip = parse_beam_ipv4.(host, env_name, address)
      {ip, "#{host}/32"}
    end)
    |> Enum.uniq_by(fn {ip, _cidr} -> ip end)
    |> Enum.map(fn {_ip, cidr} -> cidr end)
  end

  local_beam_config = fn role, targets ->
    node_name =
      env_optional_string.("ORCHARD_BEAM_NODE_NAME") ||
        case role do
          :controller -> "orchard_controller@127.0.0.1"
          :node_agent -> "orchard_node_agent@127.0.0.1"
        end

    {service, host} = beam_service_host.(node_name, "ORCHARD_BEAM_NODE_NAME")
    validate_beam_service_name.(service, "ORCHARD_BEAM_NODE_NAME", node_name)
    local_ip = parse_beam_ipv4.(host, "ORCHARD_BEAM_NODE_NAME", node_name)

    case role do
      :controller ->
        unless String.starts_with?(service, "orchard_controller") do
          raise "ORCHARD_BEAM_NODE_NAME local controller BEAM node service must start with orchard_controller"
        end

        remote_target? =
          Enum.any?(targets, fn %{address: address} ->
            {_service, target_host} =
              beam_service_host.(address, "ORCHARD_RUNTIME_ENDPOINT_TARGETS")

            target_host
            |> parse_beam_ipv4.("ORCHARD_RUNTIME_ENDPOINT_TARGETS", address)
            |> then(&(not loopback_ip?.(&1)))
          end)

        if remote_target? and loopback_ip?.(local_ip) do
          raise "ORCHARD_BEAM_NODE_NAME controller host must not be loopback when ORCHARD_RUNTIME_ENDPOINT_TARGETS includes remote BEAM targets"
        end

      :node_agent ->
        grant_descriptor = env_optional_string.("ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR")

        valid_service? =
          if grant_descriptor,
            do: String.match?(service, ~r/^orchard_node_agent_[0-9a-f]{32}$/),
            else: service == "orchard_node_agent"

        unless valid_service? do
          raise "ORCHARD_BEAM_NODE_NAME node-agent BEAM node service is invalid for the selected authorization mode"
        end
    end

    [
      enabled: true,
      node_name: node_name,
      cookie_file:
        env_optional_string.("ORCHARD_BEAM_COOKIE_FILE") ||
          Path.join([orchard_support_root, "config", "beam.cookie"]),
      listen_host: host,
      admitted_services: ["orchard_node_agent"],
      allowed_cidrs: beam_allowed_cidrs.(targets, "ORCHARD_RUNTIME_ENDPOINT_TARGETS")
    ]
  end

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

      runtime_endpoint_transport_mode =
        runtime_endpoint_transport.("ORCHARD_RUNTIME_ENDPOINT_TRANSPORT", :beam)

      beam_peer_grants_enabled? =
        env_bool.("ORCHARD_BEAM_PEER_GRANTS_ENABLED", false)

      beam_peer_grant_mode =
        if beam_peer_grants_enabled? do
          case env_optional_string.("ORCHARD_BEAM_PEER_GRANT_MODE") do
            "grant_control" ->
              :grant_control

            "distributed" ->
              :distributed

            nil ->
              raise "ORCHARD_BEAM_PEER_GRANT_MODE is required when production grants are enabled"

            other ->
              raise "ORCHARD_BEAM_PEER_GRANT_MODE must be grant_control|distributed, got: #{other}"
          end
        end

      if beam_peer_grants_enabled? and runtime_endpoint_transport_mode != :beam do
        raise "ORCHARD_BEAM_PEER_GRANTS_ENABLED requires BEAM Runtime Endpoint transport"
      end

      runtime_endpoint_targets =
        case runtime_endpoint_transport_mode do
          :beam ->
            beam_targets.(
              "ORCHARD_RUNTIME_ENDPOINT_TARGETS",
              not beam_peer_grants_enabled?
            )

          :grpc ->
            []
        end

      beam_peer_grants_config =
        if beam_peer_grants_enabled? do
          control_host =
            env_optional_string.("ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST") ||
              raise "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST is required when production grants are enabled"

          control_ip =
            parse_beam_ipv4.(
              control_host,
              "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST",
              control_host
            )

          if loopback_ip?.(control_ip) or not private_ipv4?.(control_ip) do
            raise "ORCHARD_BEAM_PEER_GRANT_CONTROL_HOST must be a private non-loopback IPv4 address"
          end

          control_port =
            env_optional_string.("ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT") ||
              raise "ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT is required when production grants are enabled"

          authorization_root_path =
            env_optional_string.("ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH") ||
              raise "ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH is required when production grants are enabled"

          manifest_path =
            case beam_peer_grant_mode do
              :distributed ->
                env_optional_string.("ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST") ||
                  raise "ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST is required in distributed mode"

              :grant_control ->
                nil
            end

          [
            enabled: true,
            mode: beam_peer_grant_mode,
            authorization_root_path: authorization_root_path,
            manifest_path: manifest_path,
            cookie_file: nil,
            static_targets: [],
            control_listener: [
              host: control_host,
              port: env_port.("ORCHARD_BEAM_PEER_GRANT_CONTROL_PORT", control_port)
            ]
          ]
        else
          [enabled: false]
        end

      config :orchard_controller, :beam_peer_grants, beam_peer_grants_config

      {membership_private_ipv4, membership_scope} =
        Orchard.Config.ControllerMembership.identity!(
          runtime_endpoint_transport_mode,
          env_optional_string.("ORCHARD_BEAM_NODE_NAME"),
          membership_host: env_optional_string.("ORCHARD_CONTROLLER_MEMBERSHIP_HOST"),
          peer_grants_enabled?: beam_peer_grants_enabled?
        )

      config :orchard_controller, :controller_membership,
        private_ipv4: membership_private_ipv4,
        scope: membership_scope,
        authorization_root_path:
          env_optional_string.("ORCHARD_BEAM_AUTHORIZATION_ROOT_PATH") ||
            Path.join([orchard_support_root, "support", "beam-authorization-root"])

      runtime_endpoint_inference_config =
        case {runtime_endpoint_transport_mode, runtime_endpoint_targets} do
          {:beam, []} ->
            [runtime_endpoint_client_impl: Orchard.RuntimeEndpoint.BeamClient]

          {:beam, targets} ->
            [
              runtime_endpoint_client_impl: Orchard.RuntimeEndpoint.BeamClient,
              runtime_endpoint_targets: targets
            ]

          {:grpc, _targets} ->
            []
        end

      runtime_client_targets =
        case runtime_endpoint_transport_mode do
          :beam -> []
          :grpc -> parse_runtime_targets.("ORCHARD_RUNTIME_CLIENT_TARGETS")
        end

      runtime_client_target =
        case runtime_endpoint_transport_mode do
          :beam ->
            nil

          :grpc ->
            [
              host: System.get_env("ORCHARD_RUNTIME_CLIENT_HOST") || "127.0.0.1",
              port: env_int.("ORCHARD_RUNTIME_CLIENT_PORT", "50061")
            ]
        end

      if runtime_endpoint_transport_mode == :beam and
           (not beam_peer_grants_enabled? or beam_peer_grant_mode == :distributed) do
        beam_config = local_beam_config.(:controller, runtime_endpoint_targets)

        beam_config =
          if beam_peer_grants_enabled? do
            {service, _host} =
              beam_service_host.(
                Keyword.fetch!(beam_config, :node_name),
                "ORCHARD_BEAM_NODE_NAME"
              )

            unless String.match?(service, ~r/^orchard_controller_[0-9a-f]{32}$/) do
              raise "ORCHARD_BEAM_NODE_NAME peer-grant Controller service must be canonical orchard_controller_<controller-id>"
            end

            [
              enabled: true,
              node_name: Keyword.fetch!(beam_config, :node_name),
              cookie_file: nil,
              listen_host: Keyword.fetch!(beam_config, :listen_host),
              admitted_services: [],
              allowed_cidrs: []
            ]
          else
            beam_config
          end

        config :orchard_controller, :runtime_endpoint, beam: beam_config
      end

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
      public_host =
        System.get_env("ORCHARD_PUBLIC_HOST") || System.get_env("PHX_HOST") || "localhost"

      # CORS origins — strict validation at boot
      cors_origins =
        env_csv.("ORCHARD_CORS_ORIGINS", [])
        |> Enum.uniq()

      Enum.each(cors_origins, validate_cors_origin!)

      # TLS file paths
      tls_dir = Path.join([orchard_support_root, "config", "tls"])
      default_certfile = Path.join(tls_dir, "controller.crt")
      default_keyfile = Path.join(tls_dir, "controller.key")
      default_cacertfile = Path.join(tls_dir, "ca.crt")

      if is_binary(System.get_env("ORCHARD_TLS_CACERTFILE")) and
           String.trim(System.get_env("ORCHARD_TLS_CACERTFILE")) == "" do
        raise "ORCHARD_TLS_CACERTFILE must not be empty"
      end

      certfile = System.get_env("ORCHARD_TLS_CERTFILE") || default_certfile
      keyfile = System.get_env("ORCHARD_TLS_KEYFILE") || default_keyfile
      cacertfile = System.get_env("ORCHARD_TLS_CACERTFILE") || default_cacertfile
      ca_meta_path = Path.join(tls_dir, ".orchard-tls-meta.json")

      cert_override? = not is_nil(System.get_env("ORCHARD_TLS_CERTFILE"))
      key_override? = not is_nil(System.get_env("ORCHARD_TLS_KEYFILE"))

      if cert_override? != key_override? do
        raise "ORCHARD_TLS_CERTFILE and ORCHARD_TLS_KEYFILE must both be set or both unset"
      end

      if cert_override? and (certfile == "" or keyfile == "") do
        raise "ORCHARD_TLS_CERTFILE and ORCHARD_TLS_KEYFILE must not be empty"
      end

      legacy_tls_disabled? =
        if is_nil(System.get_env("ORCHARD_TLS_DISABLED")) do
          nil
        else
          env_bool.("ORCHARD_TLS_DISABLED", false)
        end

      transport_mode =
        case System.get_env("ORCHARD_TRANSPORT_MODE") do
          nil ->
            cond do
              legacy_tls_disabled? == true ->
                IO.puts(
                  :stderr,
                  "ORCHARD_TLS_DISABLED is deprecated; use ORCHARD_TRANSPORT_MODE=plain_http_localhost"
                )

                :plain_http_localhost

              legacy_tls_disabled? == false ->
                IO.puts(
                  :stderr,
                  "ORCHARD_TLS_DISABLED=false is deprecated; use ORCHARD_TRANSPORT_MODE=direct_https"
                )

                :direct_https

              cert_override? ->
                IO.puts(
                  :stderr,
                  "ORCHARD_TLS_CERTFILE/ORCHARD_TLS_KEYFILE are deprecated transport shims; use ORCHARD_TRANSPORT_MODE=direct_https"
                )

                :direct_https

              true ->
                :plain_http_localhost
            end

          "reverse_proxy" ->
            :reverse_proxy

          "direct_https" ->
            :direct_https

          "plain_http_localhost" ->
            :plain_http_localhost

          value ->
            raise "ORCHARD_TRANSPORT_MODE must be reverse_proxy|direct_https|plain_http_localhost, got: #{inspect(value)}"
        end

      conflicting_legacy_transport? =
        System.get_env("ORCHARD_TRANSPORT_MODE") &&
          ((legacy_tls_disabled? == true and transport_mode != :plain_http_localhost) or
             (legacy_tls_disabled? == false and transport_mode == :plain_http_localhost) or
             (cert_override? and transport_mode != :direct_https))

      if conflicting_legacy_transport? do
        IO.puts(
          :stderr,
          "ORCHARD_TRANSPORT_MODE=#{transport_mode} is authoritative; conflicting legacy TLS envs are deprecated and ignored when inconsistent; new transport mode wins"
        )
      end

      using_default_tls_paths? = certfile == default_certfile and keyfile == default_keyfile

      generated_local_ca? =
        with {:ok, meta_json} <- File.read(ca_meta_path),
             {:ok, %{"source" => "generated_local_ca"}} <- Jason.decode(meta_json) do
          File.regular?(certfile) and File.regular?(keyfile)
        else
          _ -> false
        end

      transport_cert_source =
        case transport_mode do
          :direct_https when cert_override? ->
            :operator_provided

          :direct_https ->
            if generated_local_ca? and using_default_tls_paths?,
              do: :generated_local_ca,
              else: :unknown

          _other ->
            :unknown
        end

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
            tokenizer_safe_mode: env_tokenizer_safe_mode.("ORCHARD_TOKENIZER_SAFE_MODE", "off"),
            tokenizer_safe_mode_prefer_capable:
              env_bool.("ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE", false),
            artifacts_root:
              System.get_env("ORCHARD_ARTIFACTS_ROOT") ||
                Path.join(orchard_support_root, "bundles"),
            runtime_client_target: runtime_client_target,
            runtime_client_targets: runtime_client_targets,
            allow_static_runtime_target_fallback:
              env_bool.("ORCHARD_ALLOW_STATIC_RUNTIME_TARGET_FALLBACK", false),
            request_timeout_ms: env_int.("ORCHARD_REQUEST_TIMEOUT_MS", "120000"),
            max_request_deadline_ms: env_int.("ORCHARD_MAX_REQUEST_DEADLINE_MS", "360000"),
            model_load_timeout_ms: env_int.("ORCHARD_MODEL_LOAD_TIMEOUT_MS", "120000"),
            node_freshness_threshold_ms: env_int.("ORCHARD_NODE_FRESHNESS_THRESHOLD_MS", "30000"),
            node_unreachable_threshold_ms:
              env_int.("ORCHARD_NODE_UNREACHABLE_THRESHOLD_MS", "15000"),
            queue_admission: [
              enabled: env_bool.("ORCHARD_QUEUE_ADMISSION_ENABLED", false),
              max_wait_ms: env_int.("ORCHARD_QUEUE_ADMISSION_MAX_WAIT_MS", "3000"),
              max_queued_per_tenant:
                env_int.("ORCHARD_QUEUE_ADMISSION_MAX_QUEUED_PER_TENANT", "32"),
              poll_interval_ms: env_int.("ORCHARD_QUEUE_ADMISSION_POLL_INTERVAL_MS", "100"),
              capacity: env_int.("ORCHARD_QUEUE_ADMISSION_CAPACITY", "1"),
              owner_runtime: env_bool.("ORCHARD_QUEUE_ADMISSION_OWNER_RUNTIME", false),
              single_controller_ack:
                env_bool.("ORCHARD_QUEUE_ADMISSION_SINGLE_CONTROLLER_ACK", false)
            ],
            cache_affinity: [
              enabled: env_bool.("ORCHARD_CACHE_AFFINITY_ENABLED", false),
              live_fingerprint_match_enabled:
                env_bool.("ORCHARD_CACHE_AFFINITY_LIVE_FINGERPRINT_MATCH_ENABLED", false),
              max_prefix_bytes: env_int.("ORCHARD_CACHE_AFFINITY_MAX_PREFIX_BYTES", "8192"),
              max_age_ms: env_int.("ORCHARD_CACHE_AFFINITY_MAX_AGE_MS", "300000"),
              max_recent_requests: env_int.("ORCHARD_CACHE_AFFINITY_MAX_RECENT_REQUESTS", "32"),
              # Explicit secret for cache-affinity key HMAC derivation.
              # If omitted, cache-affinity falls back to endpoint secret_key_base.
              hmac_secret: env_optional_string.("ORCHARD_CACHE_AFFINITY_HMAC_SECRET")
            ],
            cache_introspection: [
              enabled: env_bool.("ORCHARD_CACHE_INTROSPECTION_ENABLED", false)
            ],
            prefix_cache_scoring: [
              enabled: env_bool.("ORCHARD_PREFIX_CACHE_SCORING_ENABLED", false),
              timeout_ms:
                (fn ->
                   timeout_ms = env_int.("ORCHARD_PREFIX_CACHE_SCORING_TIMEOUT_MS", "150")

                   if timeout_ms <= 0 do
                     raise "ORCHARD_PREFIX_CACHE_SCORING_TIMEOUT_MS must be > 0, got: #{timeout_ms}"
                   end

                   timeout_ms
                 end).(),
              ranking_mode:
                (fn ->
                   case System.get_env("ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE") ||
                          "observe_only" do
                     "observe_only" ->
                       :observe_only

                     "tie_only" ->
                       :tie_only

                     value ->
                       raise "ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE must be observe_only|tie_only, got: #{inspect(value)}"
                   end
                 end).(),
              max_ranking_candidates:
                (fn ->
                   max_ranking_candidates =
                     env_int.("ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES", "2")

                   if max_ranking_candidates <= 0 do
                     raise "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES must be > 0, got: #{max_ranking_candidates}"
                   end

                   max_ranking_candidates
                 end).()
            ],
            memory_admission: [
              enabled: env_bool.("ORCHARD_MEMORY_ADMISSION_ENABLED", false)
            ]
          )
          |> Keyword.merge(runtime_endpoint_inference_config)

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

      if (transport_cert_source == :generated_local_ca and
            System.get_env("ORCHARD_TLS_CACERTFILE")) &&
           Path.expand(cacertfile) != Path.expand(default_cacertfile) do
        raise "ORCHARD_TLS_CACERTFILE cannot override generated-local CA publication; unset it or use direct HTTPS operator-provided certificates"
      end

      cacertfile_for_validation =
        if System.get_env("ORCHARD_TLS_CACERTFILE") ||
             transport_cert_source == :generated_local_ca,
           do: cacertfile,
           else: nil

      # --- Transport listener configuration ---
      {transport_config, url_config, transport_degraded?, trusted_proxies, check_origin} =
        case transport_mode do
          :plain_http_localhost ->
            http_port = env_port.("PORT", "4000")

            IO.puts(:stderr, """

            ╔══════════════════════════════════════════════════════════════╗
            ║  ⚠️  PLAIN HTTP LOCALHOST MODE                            ║
            ║                                                            ║
            ║  ORCHARD_TRANSPORT_MODE=plain_http_localhost               ║
            ║  Controller listening on HTTP 127.0.0.1:#{String.pad_trailing(to_string(http_port), 5)}             ║
            ║  This is NOT secure for production use.                    ║
            ╚══════════════════════════════════════════════════════════════╝
            """)

            {[http: [ip: {127, 0, 0, 1}, port: http_port]],
             [host: "localhost", port: http_port, scheme: "http"], true, [], nil}

          :reverse_proxy ->
            proxy = reverse_proxy_config.(public_host)

            {proxy.listener, proxy.url, false, proxy.trusted_proxies, proxy.check_origin}

          :direct_https ->
            https_port = env_port.("ORCHARD_API_HTTPS_PORT", "8443")
            bind_ip = env_ip.("ORCHARD_API_BIND_IP", "0.0.0.0")

            validate_tls_material!.(certfile, keyfile, cacertfile_for_validation)

            {[
               https: [
                 ip: bind_ip,
                 port: https_port,
                 certfile: certfile,
                 keyfile: keyfile,
                 cipher_suite: :strong
               ]
             ], [host: public_host, port: https_port, scheme: "https"], false, [], nil}
        end

      config :orchard_controller,
        transport_mode: transport_mode,
        transport_cert_source: transport_cert_source,
        transport_degraded: transport_degraded?

      ca_endpoint_config =
        if transport_cert_source == :generated_local_ca do
          [ca_certfile: cacertfile, ca_cert_metadata_path: ca_meta_path]
        else
          [ca_certfile: nil, ca_cert_metadata_path: nil]
        end

      check_origin_config =
        case check_origin do
          nil -> [trusted_proxies: trusted_proxies]
          origins -> [check_origin: origins, trusted_proxies: trusted_proxies]
        end

      config :orchard_controller,
             Orchard.API.Endpoint,
             transport_config ++
               [
                 server: true,
                 url: url_config,
                 secret_key_base: secret_key_base,
                 cors_origins: cors_origins
               ] ++ check_origin_config ++ ca_endpoint_config

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
      node_runtime_endpoint_transport =
        runtime_endpoint_transport.("ORCHARD_RUNTIME_ENDPOINT_TRANSPORT", :beam)

      grpc_security =
        if node_runtime_endpoint_transport == :grpc,
          do: :mutual_tls,
          else: :plaintext_compatibility

      node_agent_listen_host = System.get_env("ORCHARD_NODE_AGENT_LISTEN_HOST") || "127.0.0.1"

      node_identity_root =
        System.get_env("ORCHARD_NODE_IDENTITY_ROOT") ||
          Path.join([orchard_support_root, "config", "node-identity"])

      beam_peer_grant_descriptor =
        env_optional_string.("ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR")

      beam_peer_grant_node_name =
        if beam_peer_grant_descriptor do
          env_optional_string.("ORCHARD_BEAM_NODE_NAME") ||
            raise "ORCHARD_BEAM_NODE_NAME is required when a BEAM Peer Grant descriptor is configured"
        end

      beam_distribution_launch_manifest =
        if beam_peer_grant_descriptor do
          env_optional_string.("ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST") ||
            raise "ORCHARD_BEAM_DISTRIBUTION_LAUNCH_MANIFEST is required when a BEAM Peer Grant descriptor is configured"
        end

      if beam_peer_grant_descriptor && node_runtime_endpoint_transport == :grpc do
        raise "ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR requires BEAM Runtime Endpoint transport"
      end

      if grpc_security == :plaintext_compatibility and
           not loopback_listen_host?.(node_agent_listen_host) do
        raise "ORCHARD_NODE_AGENT_LISTEN_HOST=#{node_agent_listen_host} exposes an unauthenticated plaintext gRPC runtime endpoint on a non-loopback interface; set ORCHARD_RUNTIME_ENDPOINT_TRANSPORT=grpc for mutual TLS or bind the node agent to a loopback host"
      end

      config :orchard_node_agent,
        beam_peer_grants:
          if(beam_peer_grant_descriptor,
            do: [
              enabled: true,
              identity_root: node_identity_root,
              descriptor_path: beam_peer_grant_descriptor,
              node_beam_name: beam_peer_grant_node_name,
              manifest_path: beam_distribution_launch_manifest
            ],
            else: [enabled: false]
          ),
        runtime:
          Keyword.merge(
            default_node_runtime.(orchard_support_root),
            node_id: System.get_env("ORCHARD_NODE_ID"),
            node_identity_path:
              System.get_env("ORCHARD_NODE_IDENTITY_PATH") ||
                Path.join([orchard_support_root, "data", "node-id"]),
            node_identity_root: node_identity_root,
            grpc_security: grpc_security,
            display_name: System.get_env("ORCHARD_NODE_DISPLAY_NAME"),
            listen_address: [
              host: node_agent_listen_host,
              port: env_int.("ORCHARD_NODE_AGENT_LISTEN_PORT", "50061")
            ],
            models_root:
              System.get_env("ORCHARD_MODELS_ROOT") || Path.join(orchard_support_root, "models"),
            force_full_model_verification:
              env_bool.("ORCHARD_FORCE_FULL_MODEL_VERIFICATION", false),
            worker_socket_dir:
              System.get_env("ORCHARD_WORKER_SOCKET_DIR") ||
                Path.join([orchard_support_root, "data", "worker-sockets"]),
            worker_executable:
              System.get_env("ORCHARD_WORKER_EXECUTABLE") || "orchard-worker-mlx",
            worker_backend: runtime_worker_backend,
            worker_ready_timeout_ms: env_int.("ORCHARD_WORKER_READY_TIMEOUT_MS", "5000"),
            worker_load_timeout_ms: env_int.("ORCHARD_WORKER_LOAD_TIMEOUT_MS", "120000"),
            worker_shutdown_timeout_ms: env_int.("ORCHARD_WORKER_SHUTDOWN_TIMEOUT_MS", "1000"),
            worker_capabilities_freshness_window_ms:
              env_int.("ORCHARD_WORKER_CAPABILITIES_FRESHNESS_WINDOW_MS", "15000"),
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
                 mode =
                   System.get_env("ORCHARD_WORKER_GENERATION_MODE") ||
                     default_worker_generation_mode.(runtime_worker_backend)

                 unless mode in ["stream", "batch"] do
                   raise "ORCHARD_WORKER_GENERATION_MODE must be stream|batch, got: #{inspect(mode)}"
                 end

                 mode
               end).(),
            worker_max_concurrent_requests_per_model:
              (fn ->
                 value =
                   System.get_env("ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL") || "auto"

                 if value == "auto" do
                   "auto"
                 else
                   v = env_int.("ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL", "auto")

                   if v < 1 do
                     raise "ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL must be auto or >= 1, got: #{v}"
                   end

                   v
                 end
               end).(),
            worker_auto_max_concurrent_requests_per_model:
              (fn ->
                 v = env_int.("ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL", "3")

                 if v < 1 do
                   raise "ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL must be >= 1, got: #{v}"
                 end

                 v
               end).(),
            worker_memory_budget_mode:
              (fn ->
                 mode = System.get_env("ORCHARD_WORKER_MEMORY_BUDGET_MODE") || "observe"

                 unless mode in ["disabled", "observe", "enforce"] do
                   raise "ORCHARD_WORKER_MEMORY_BUDGET_MODE must be disabled|observe|enforce, got: #{inspect(mode)}"
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

if config_env() == :dev do
  # Source dev resolves membership identity here rather than in config/dev.exs,
  # because compile-time config cannot reach the compiled shared resolver.
  # Only Controller-hosting roles carry a Controller membership identity;
  # ORCHARD_BEAM_NODE_NAME names the node-agent on a node-agent-only host.
  source_dev_role =
    Orchard.Config.SourceDevBeam.source_dev_role(env_optional_string.("ORCHARD_SOURCE_DEV_ROLE"))

  runtime_endpoint_transport =
    Orchard.Config.SourceDevBeam.transport!(
      env_optional_string.("ORCHARD_RUNTIME_ENDPOINT_TRANSPORT")
    )

  peer_grants_enabled? =
    env_bool.("ORCHARD_BEAM_PEER_GRANTS_ENABLED", false) or
      (source_dev_role == :node_agent and
         not is_nil(env_optional_string.("ORCHARD_BEAM_PEER_GRANT_DESCRIPTOR")))

  source_dev_node_name =
    env_optional_string.("ORCHARD_BEAM_NODE_NAME") ||
      case source_dev_role do
        :node_agent -> "orchard_node_agent@127.0.0.1"
        _other -> "orchard_controller@127.0.0.1"
      end

  source_dev_address_policy =
    if runtime_endpoint_transport == :beam and not peer_grants_enabled? do
      Orchard.Config.SourceDevBeam.address_policy!(
        env_optional_string.("ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS")
      )
    end

  if runtime_endpoint_transport == :beam and not peer_grants_enabled? and
       source_dev_role in [:controller, :node_agent] do
    Orchard.Config.SourceDevBeam.validate_node_name!(
      source_dev_role,
      source_dev_node_name,
      source_dev_address_policy
    )
  end

  if source_dev_role in [:controller, :all_in_one] do
    transport_mode = source_dev_transport_mode!.(System.get_env("ORCHARD_TRANSPORT_MODE"))

    case transport_mode do
      :plain_http_localhost ->
        config :orchard_controller,
          transport_mode: :plain_http_localhost,
          transport_cert_source: :unknown,
          transport_degraded: true

      :reverse_proxy ->
        public_host =
          System.get_env("ORCHARD_PUBLIC_HOST") || System.get_env("PHX_HOST") || "localhost"

        proxy = reverse_proxy_config.(public_host)

        config :orchard_controller,
          transport_mode: :reverse_proxy,
          transport_cert_source: :unknown,
          transport_degraded: false

        config :orchard_controller,
               Orchard.API.Endpoint,
               proxy.listener ++
                 [
                   url: proxy.url,
                   check_origin: proxy.check_origin,
                   trusted_proxies: proxy.trusted_proxies
                 ]
    end

    {membership_private_ipv4, membership_scope} =
      Orchard.Config.ControllerMembership.identity!(
        runtime_endpoint_transport,
        source_dev_node_name,
        membership_host: env_optional_string.("ORCHARD_CONTROLLER_MEMBERSHIP_HOST"),
        peer_grants_enabled?: peer_grants_enabled?,
        source_dev_address_policy: source_dev_address_policy
      )

    config :orchard_controller, :controller_membership,
      private_ipv4: membership_private_ipv4,
      scope: membership_scope,
      source_dev_address_policy: source_dev_address_policy
  end
end
