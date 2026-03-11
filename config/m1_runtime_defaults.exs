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

  def controller_inference(root) do
    [
      tokenizer_mode: :port,
      tokenizer_executable: "orchard-tokenizer",
      artifacts_root: Path.join(root, "bundles"),
      runtime_client_target: [host: @default_runtime_host, port: @default_runtime_port],
      request_timeout_ms: @default_request_timeout_ms,
      model_load_timeout_ms: @default_model_load_timeout_ms
    ]
  end

  def node_runtime(root) do
    [
      listen_address: [host: @default_runtime_host, port: @default_runtime_port],
      models_root: Path.join(root, "models"),
      worker_socket_dir: Path.join([root, "data", "worker-sockets"]),
      worker_executable: "orchard-worker-mlx",
      worker_backend: "mlx",
      worker_ready_timeout_ms: @default_worker_ready_timeout_ms,
      worker_load_timeout_ms: @default_worker_load_timeout_ms,
      worker_shutdown_timeout_ms: @default_worker_shutdown_timeout_ms,
      fake_runtime?: false
    ]
  end
end
