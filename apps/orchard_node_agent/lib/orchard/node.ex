defmodule Orchard.Node do
  @moduledoc """
  Runtime configuration helpers for the node-agent inference boundary.
  """

  def runtime_config do
    Application.fetch_env!(:orchard_node_agent, :runtime)
  end

  def listen_address, do: runtime_config()[:listen_address]
  def listen_host, do: listen_address()[:host]
  def listen_port, do: listen_address()[:port]
  def models_root, do: runtime_config()[:models_root]
  def worker_socket_dir, do: runtime_config()[:worker_socket_dir]
  def fake_runtime?, do: runtime_config()[:fake_runtime?]
end
