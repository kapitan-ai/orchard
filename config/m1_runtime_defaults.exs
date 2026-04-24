defmodule Orchard.Config.M1RuntimeDefaults do
  @moduledoc false

  # Keep these source-config defaults aligned with the release-safe copies in
  # config/runtime.exs.

  @default_runtime_host "127.0.0.1"
  @default_runtime_port 50_061
  @default_request_timeout_ms 120_000
  @default_model_load_timeout_ms 120_000
  @default_worker_ready_timeout_ms 5_000
  @default_worker_load_timeout_ms 120_000
  @default_worker_shutdown_timeout_ms 1_000
  @default_keygen_api_base_url "https://api.keygen.sh"
  @orchard_keygen_account_id "6f872d6f-52ce-4bbe-8b3f-b57669753f34"
  @orchard_keygen_public_key "f1a328edc3d42967e8545c1361d2dc22622fad52aad0dc8e5d3b3cb95d7cb18a"

  def hf do
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

  def controller_inference(root) do
    [
      tokenizer_mode: :port,
      tokenizer_executable: "orchard-tokenizer",
      artifacts_root: Path.join(root, "bundles"),
      runtime_client_target: [host: @default_runtime_host, port: @default_runtime_port],
      runtime_client_targets: [],
      request_timeout_ms: @default_request_timeout_ms,
      model_load_timeout_ms: @default_model_load_timeout_ms,
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
        max_recent_requests: 32,
        hmac_secret: nil
      ],
      cache_introspection: [
        enabled: false
      ],
      memory_admission: [
        enabled: false
      ]
    ]
  end

  def node_runtime(root) do
    [
      node_id: nil,
      node_identity_path: Path.join([root, "data", "node-id"]),
      display_name: nil,
      listen_address: [host: @default_runtime_host, port: @default_runtime_port],
      models_root: Path.join(root, "models"),
      worker_socket_dir: Path.join([root, "data", "worker-sockets"]),
      worker_executable: "orchard-worker-mlx",
      worker_backend: "mlx",
      worker_ready_timeout_ms: @default_worker_ready_timeout_ms,
      worker_load_timeout_ms: @default_worker_load_timeout_ms,
      worker_shutdown_timeout_ms: @default_worker_shutdown_timeout_ms,
      worker_log_dir: Path.join([root, "logs", "workers"]),
      worker_prefix_cache_mode: "kv",
      worker_prefix_cache_max_entries: 8,
      worker_prefix_cache_max_bytes: 0,
      worker_generation_mode: "stream",
      worker_max_concurrent_requests_per_model: 1,
      worker_memory_budget_mode: "observe",
      worker_memory_budget_utilization: 0.90,
      worker_memory_budget_overhead_bytes: 1_073_741_824,
      license_enforcement: :warn,
      hosted_tools: [],
      max_loaded_models: 0,
      fake_runtime?: false,
      hf: hf(),
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

  def licensing(root) do
    [
      bundle_path: Path.join([root, "config", "licensing", "current.json"]),
      node_identity_path: Path.join([root, "data", "node-id"]),
      keygen_api_base_url: @default_keygen_api_base_url,
      keygen_account_id: @orchard_keygen_account_id,
      keygen_public_key: @orchard_keygen_public_key
    ]
  end
end
