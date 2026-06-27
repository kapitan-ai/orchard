import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)
Code.require_file("source_dev_beam.exs", __DIR__)

repo_root = Path.expand("..", __DIR__)
dev_root = Path.join([repo_root, "tmp", "dev"])

# Dev runtime port — avoids conflict with packaged BEAM on 50061.
# Matches test.exs precedent (50071). Supports both env var names for parity
# with config/runtime.exs; raises on mismatch to prevent split-brain config.
parse_port = fn val, var_name ->
  case Integer.parse(val) do
    {port, ""} when port > 0 and port < 65_536 -> port
    _ -> raise "Invalid #{var_name}=#{inspect(val)} — expected an integer 1..65535"
  end
end

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

env_optional_string = fn env_name ->
  case System.get_env(env_name) do
    nil ->
      nil

    value ->
      trimmed = String.trim(value)
      if trimmed == "", do: nil, else: trimmed
  end
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

# Inline parser for gRPC-only ORCHARD_RUNTIME_CLIENT_TARGETS
# (comma-separated host:port).
# Source-dev BEAM targets use ORCHARD_RUNTIME_ENDPOINT_TARGETS instead.
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
              {port, ""} when port > 0 and port < 65_536 ->
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

source_dev_role =
  Orchard.Config.SourceDevBeam.source_dev_role(System.get_env("ORCHARD_SOURCE_DEV_ROLE"))

runtime_endpoint_transport =
  Orchard.Config.SourceDevBeam.transport!(System.get_env("ORCHARD_RUNTIME_ENDPOINT_TRANSPORT"))

Orchard.Config.SourceDevBeam.validate_transport_role!(
  runtime_endpoint_transport,
  source_dev_role
)

beam_runtime_endpoint_targets =
  if runtime_endpoint_transport == :beam and source_dev_role == :controller do
    Orchard.Config.SourceDevBeam.controller_beam_targets!(
      System.get_env("ORCHARD_RUNTIME_ENDPOINT_TARGETS")
    )
  else
    []
  end

beam_controller_node_name =
  System.get_env("ORCHARD_BEAM_NODE_NAME") || "orchard_controller@127.0.0.1"

beam_cookie_file =
  System.get_env("ORCHARD_BEAM_COOKIE_FILE") || Path.join(dev_root, "beam.cookie")

runtime_endpoint_inference_config =
  if beam_runtime_endpoint_targets == [] do
    []
  else
    [
      runtime_endpoint_client_impl: Orchard.RuntimeEndpoint.BeamClient,
      runtime_endpoint_targets: beam_runtime_endpoint_targets
    ]
  end

controller_inference_defaults = Orchard.Config.M1RuntimeDefaults.controller_inference(dev_root)
cache_affinity_defaults = Keyword.fetch!(controller_inference_defaults, :cache_affinity)
cache_introspection_defaults = Keyword.fetch!(controller_inference_defaults, :cache_introspection)

prefix_cache_scoring_defaults =
  Keyword.fetch!(controller_inference_defaults, :prefix_cache_scoring)

memory_admission_defaults = Keyword.fetch!(controller_inference_defaults, :memory_admission)

cache_affinity_config =
  Keyword.merge(
    cache_affinity_defaults,
    enabled:
      env_bool.(
        "ORCHARD_CACHE_AFFINITY_ENABLED",
        Keyword.fetch!(cache_affinity_defaults, :enabled)
      ),
    live_fingerprint_match_enabled:
      env_bool.(
        "ORCHARD_CACHE_AFFINITY_LIVE_FINGERPRINT_MATCH_ENABLED",
        Keyword.fetch!(cache_affinity_defaults, :live_fingerprint_match_enabled)
      ),
    max_prefix_bytes:
      env_int.(
        "ORCHARD_CACHE_AFFINITY_MAX_PREFIX_BYTES",
        Keyword.fetch!(cache_affinity_defaults, :max_prefix_bytes)
      ),
    max_age_ms:
      env_int.(
        "ORCHARD_CACHE_AFFINITY_MAX_AGE_MS",
        Keyword.fetch!(cache_affinity_defaults, :max_age_ms)
      ),
    max_recent_requests:
      env_int.(
        "ORCHARD_CACHE_AFFINITY_MAX_RECENT_REQUESTS",
        Keyword.fetch!(cache_affinity_defaults, :max_recent_requests)
      ),
    # Explicit secret for cache-affinity key HMAC derivation.
    # If omitted, cache-affinity falls back to endpoint secret_key_base.
    hmac_secret:
      env_optional_string.("ORCHARD_CACHE_AFFINITY_HMAC_SECRET") ||
        Keyword.get(cache_affinity_defaults, :hmac_secret)
  )

cache_introspection_config =
  Keyword.merge(
    cache_introspection_defaults,
    enabled:
      env_bool.(
        "ORCHARD_CACHE_INTROSPECTION_ENABLED",
        Keyword.fetch!(cache_introspection_defaults, :enabled)
      )
  )

prefix_cache_scoring_config =
  Keyword.merge(
    prefix_cache_scoring_defaults,
    enabled:
      env_bool.(
        "ORCHARD_PREFIX_CACHE_SCORING_ENABLED",
        Keyword.fetch!(prefix_cache_scoring_defaults, :enabled)
      ),
    timeout_ms:
      env_int.(
        "ORCHARD_PREFIX_CACHE_SCORING_TIMEOUT_MS",
        Keyword.fetch!(prefix_cache_scoring_defaults, :timeout_ms)
      ),
    ranking_mode:
      (fn ->
         case System.get_env("ORCHARD_PREFIX_CACHE_SCORING_RANKING_MODE") do
           nil ->
             Keyword.fetch!(prefix_cache_scoring_defaults, :ranking_mode)

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
           env_int.(
             "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES",
             Keyword.fetch!(prefix_cache_scoring_defaults, :max_ranking_candidates)
           )

         if max_ranking_candidates <= 0 do
           raise "ORCHARD_PREFIX_CACHE_SCORING_MAX_RANKING_CANDIDATES must be > 0, got: #{max_ranking_candidates}"
         end

         max_ranking_candidates
       end).()
  )

memory_admission_config =
  Keyword.merge(
    memory_admission_defaults,
    enabled:
      env_bool.(
        "ORCHARD_MEMORY_ADMISSION_ENABLED",
        Keyword.fetch!(memory_admission_defaults, :enabled)
      )
  )

node_runtime_defaults = Orchard.Config.M1RuntimeDefaults.node_runtime(dev_root)

worker_socket_dir_hash =
  :crypto.hash(:sha256, repo_root)
  |> Base.url_encode64(padding: false)
  |> binary_part(0, 8)

# Python gRPC rejects Unix socket paths above roughly 103 bytes on macOS.
# Keep source-dev worker sockets under a short, worktree-specific root.
worker_socket_dir =
  System.get_env("ORCHARD_WORKER_SOCKET_DIR") ||
    Path.join(["/tmp", "od-" <> worker_socket_dir_hash, "ws"])

worker_backend =
  env_optional_string.("ORCHARD_WORKER_BACKEND") ||
    Keyword.fetch!(node_runtime_defaults, :worker_backend)

worker_prefix_cache_mode =
  (fn ->
     mode =
       System.get_env("ORCHARD_WORKER_PREFIX_CACHE_MODE") ||
         Keyword.fetch!(node_runtime_defaults, :worker_prefix_cache_mode)

     unless mode in ["disabled", "kv", "trie"] do
       raise "ORCHARD_WORKER_PREFIX_CACHE_MODE must be disabled|kv|trie, got: #{inspect(mode)}"
     end

     mode
   end).()

worker_generation_mode =
  (fn ->
     mode =
       System.get_env("ORCHARD_WORKER_GENERATION_MODE") ||
         if worker_backend == "stub" do
           "stream"
         else
           Keyword.fetch!(node_runtime_defaults, :worker_generation_mode)
         end

     unless mode in ["stream", "batch"] do
       raise "ORCHARD_WORKER_GENERATION_MODE must be stream|batch, got: #{inspect(mode)}"
     end

     mode
   end).()

worker_max_concurrent_requests_per_model =
  (fn ->
     value =
       System.get_env("ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL") ||
         Keyword.fetch!(node_runtime_defaults, :worker_max_concurrent_requests_per_model)

     if value == "auto" do
       "auto"
     else
       v =
         case value do
           n when is_integer(n) -> n
           n -> env_int.("ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL", n)
         end

       if v < 1 do
         raise "ORCHARD_WORKER_MAX_CONCURRENT_REQUESTS_PER_MODEL must be auto or >= 1, got: #{v}"
       end

       v
     end
   end).()

worker_auto_max_concurrent_requests_per_model =
  (fn ->
     v =
       env_int.(
         "ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL",
         Keyword.fetch!(node_runtime_defaults, :worker_auto_max_concurrent_requests_per_model)
       )

     if v < 1 do
       raise "ORCHARD_WORKER_AUTO_MAX_CONCURRENT_REQUESTS_PER_MODEL must be >= 1, got: #{v}"
     end

     v
   end).()

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
      Keyword.merge(
        controller_inference_defaults,
        runtime_client_target: [host: dev_runtime_client_host, port: dev_runtime_port],
        runtime_client_targets: dev_runtime_targets,
        tokenizer_executable:
          System.get_env("ORCHARD_TOKENIZER_EXECUTABLE") ||
            Path.join([repo_root, "native", "orchard_tokenizer", "bin", "orchard-tokenizer"]),
        tokenizer_safe_mode: env_tokenizer_safe_mode.("ORCHARD_TOKENIZER_SAFE_MODE", :off),
        tokenizer_safe_mode_prefer_capable:
          env_bool.("ORCHARD_TOKENIZER_SAFE_MODE_PREFER_CAPABLE", false),
        cache_affinity: cache_affinity_config,
        cache_introspection: cache_introspection_config,
        prefix_cache_scoring: prefix_cache_scoring_config,
        memory_admission: memory_admission_config
      ),
      runtime_endpoint_inference_config
    )

if beam_runtime_endpoint_targets != [] do
  config :orchard_controller, :runtime_endpoint,
    beam:
      Orchard.Config.SourceDevBeam.beam_guardrail_config!(
        beam_controller_node_name,
        beam_cookie_file,
        beam_runtime_endpoint_targets
      )
end

config :orchard_node_agent,
  runtime:
    Keyword.merge(
      node_runtime_defaults,
      listen_address: [host: dev_node_agent_listen_host, port: dev_runtime_port],
      worker_executable:
        System.get_env("ORCHARD_WORKER_EXECUTABLE") ||
          Path.join([repo_root, "native", "orchard_worker_mlx", "bin", "orchard-worker-mlx"]),
      worker_socket_dir: worker_socket_dir,
      worker_backend: worker_backend,
      worker_prefix_cache_mode: worker_prefix_cache_mode,
      worker_generation_mode: worker_generation_mode,
      worker_max_concurrent_requests_per_model: worker_max_concurrent_requests_per_model,
      worker_auto_max_concurrent_requests_per_model: worker_auto_max_concurrent_requests_per_model
    )

config :orchard_shared,
       :licensing,
       Orchard.Config.M1RuntimeDefaults.licensing(dev_root)
       |> Keyword.put(:enforcement_mode, :off)

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
