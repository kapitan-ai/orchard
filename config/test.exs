import Config

Code.require_file("m1_runtime_defaults.exs", __DIR__)
Code.require_file("source_postgres.exs", __DIR__)

repo_root = Path.expand("..", __DIR__)
test_root = Path.join([repo_root, "tmp", "test"])

test_node_agent_port =
  case Integer.parse(System.get_env("ORCHARD_TEST_NODE_AGENT_PORT") || "50071") do
    {port, ""} when port in 1..65_535 ->
      port

    _ ->
      raise "ORCHARD_TEST_NODE_AGENT_PORT must be an integer between 1 and 65535"
  end

worker_socket_dir_hash =
  :crypto.hash(:sha256, repo_root)
  |> Base.url_encode64(padding: false)
  |> binary_part(0, 8)

# Python gRPC rejects Unix socket paths above roughly 103 bytes on macOS.
# Keep test worker sockets under a short, worktree-specific root.
worker_socket_dir = Path.join(["/tmp", "ot-" <> worker_socket_dir_hash, "ws"])

config :orchard_controller, Orchard.Repo,
  username: System.get_env("PGUSER") || "postgres",
  password: System.get_env("PGPASSWORD") || "postgres",
  hostname: System.get_env("PGHOST") || "localhost",
  port: Orchard.Config.SourcePostgres.port!(System.get_env("PGPORT")),
  database: System.get_env("PGDATABASE_TEST") || "orchard_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :orchard_controller,
  multi_node_compatibility_probe_runner: Orchard.TestSupport.InProcessCompatibilityProbeRunner

config :orchard_controller,
  start_repo: false,
  start_endpoint: false,
  enable_db_checks: false,
  inference:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.controller_inference(test_root),
      tokenizer_mode: :fake,
      tokenizer_executable:
        Path.join([repo_root, "native", "orchard_tokenizer", "bin", "orchard-tokenizer"]),
      runtime_client_target: [host: "127.0.0.1", port: test_node_agent_port],
      allow_static_runtime_target_fallback: true,
      request_timeout_ms: 5_000,
      max_request_deadline_ms: 1_000_000,
      model_load_timeout_ms: 5_000
    ),
  hf: Orchard.Config.M1RuntimeDefaults.hf()

config :orchard_node_agent,
  runtime:
    Keyword.merge(
      Orchard.Config.M1RuntimeDefaults.node_runtime(test_root),
      node_id: "00000000-0000-4000-a000-000000000001",
      display_name: "test-node",
      listen_address: [host: "127.0.0.1", port: test_node_agent_port],
      worker_socket_dir: worker_socket_dir,
      worker_executable:
        Path.join([repo_root, "native", "orchard_worker_mlx", "bin", "orchard-worker-mlx"]),
      worker_backend: "stub",
      worker_generation_mode: "stream",
      worker_max_concurrent_requests_per_model: 1,
      worker_auto_max_concurrent_requests_per_model: 3,
      worker_log_dir: Path.join([test_root, "logs", "workers"]),
      worker_ready_timeout_ms: 5_000,
      worker_load_timeout_ms: 5_000,
      worker_shutdown_timeout_ms: 1_000,
      fake_runtime?: true
    )

config :orchard_shared,
       :licensing,
       Orchard.Config.M1RuntimeDefaults.licensing(test_root)
       |> Keyword.put(:enforcement_mode, :off)

# Console: enabled with no auth for deterministic test behavior.
config :orchard_controller, :console,
  enabled: true,
  auth: :none,
  username: nil,
  password: nil,
  model_hub_impl: OrchardConsole.ModelHub,
  model_hub_client_impl: Orchard.Models.HubClient,
  model_hub_download_impl: Orchard.Models.HubDownloader,
  download_coordinator_impl: OrchardConsole.ModelHubDownloadCoordinator

config :orchard_controller, Orchard.API.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  cors_origins: [],
  secret_key_base: String.duplicate("test-secret-", 8),
  server: false

config :logger, level: :warning
