defmodule Orchard.NodeAgent.Application do
  @moduledoc false

  use Application

  alias Orchard.Node.Supervisor, as: NodeSupervisor

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [NodeSupervisor],
      strategy: :one_for_one,
      name: Orchard.NodeAgent.Supervisor
    )
  end
end
