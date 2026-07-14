defmodule Orchard.BeamPeerGrants.ControllerInitializer do
  @moduledoc """
  Initializes one Controller's local grant authority before admission and delivery start.
  """

  use GenServer

  alias Orchard.{ControllerInstances, NodeTrust}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec initialize(keyword()) ::
          {:ok, Orchard.ControllerInstances.ControllerInstance.t()} | {:error, term()}
  def initialize(opts) when is_list(opts) do
    with {:ok, _generation} <-
           NodeTrust.peer_grant_runtime_generation_paths(
             root: Keyword.get(opts, :node_trust_root)
           ) do
      ControllerInstances.ensure_local(opts)
    end
  end

  @impl true
  def init(opts) do
    case initialize(opts) do
      {:ok, instance} -> {:ok, instance}
      {:error, reason} -> {:stop, reason}
    end
  end
end
