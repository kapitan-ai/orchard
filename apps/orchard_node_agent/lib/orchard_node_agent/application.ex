defmodule Orchard.NodeAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [Orchard.Node.Supervisor],
      strategy: :one_for_one,
      name: Orchard.NodeAgent.Supervisor
    )
  end
end
