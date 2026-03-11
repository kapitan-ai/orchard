defmodule Orchard.Node do
  @moduledoc """
  Runtime configuration helpers for the node-agent inference boundary.
  """

  alias Orchard.Cluster.V1.ModelRef
  alias Orchard.Node.{FakeRuntimeAdapter, WorkerRuntimeAdapter}

  @default_worker_executable "orchard-worker-mlx"
  @default_worker_backend "mlx"
  @default_worker_ready_timeout_ms 5_000
  @default_worker_load_timeout_ms 120_000
  @default_worker_shutdown_timeout_ms 1_000
  @worker_socket_prefix "orchard-worker-"
  @worker_socket_suffix ".sock"
  @worker_socket_hash_length 16

  def runtime_config do
    Application.fetch_env!(:orchard_node_agent, :runtime)
  end

  def listen_address, do: runtime_config()[:listen_address]
  def listen_host, do: listen_address()[:host]
  def listen_port, do: listen_address()[:port]
  def models_root, do: runtime_config()[:models_root]
  def worker_socket_dir, do: runtime_config()[:worker_socket_dir]
  def worker_executable, do: runtime_config()[:worker_executable] || @default_worker_executable
  def worker_backend, do: runtime_config()[:worker_backend] || @default_worker_backend

  def worker_ready_timeout_ms do
    runtime_config()[:worker_ready_timeout_ms] || @default_worker_ready_timeout_ms
  end

  def worker_load_timeout_ms do
    runtime_config()[:worker_load_timeout_ms] || @default_worker_load_timeout_ms
  end

  def worker_shutdown_timeout_ms do
    runtime_config()[:worker_shutdown_timeout_ms] || @default_worker_shutdown_timeout_ms
  end

  def fake_runtime?, do: runtime_config()[:fake_runtime?]

  def hf_config, do: runtime_config()[:hf] || []

  def s3_config, do: runtime_config()[:s3] || []

  def runtime_adapter_impl do
    runtime_config()[:runtime_adapter_impl] || default_runtime_adapter_impl()
  end

  def worker_socket_path(%ModelRef{model_id: model_id, version: version}) do
    worker_socket_path(model_id, version)
  end

  def worker_socket_path(model_id, version) when is_binary(model_id) and is_binary(version) do
    digest =
      :crypto.hash(:sha256, model_id <> "@" <> version)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @worker_socket_hash_length)

    Path.join(
      worker_socket_dir(),
      @worker_socket_prefix <> digest <> @worker_socket_suffix
    )
  end

  defp default_runtime_adapter_impl do
    if fake_runtime?() do
      FakeRuntimeAdapter
    else
      WorkerRuntimeAdapter
    end
  end
end
