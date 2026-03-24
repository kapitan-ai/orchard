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
      node_unreachable_threshold_ms: 15_000
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
end
