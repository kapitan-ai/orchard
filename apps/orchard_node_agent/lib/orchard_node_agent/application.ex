defmodule Orchard.NodeAgent.Application do
  @moduledoc false

  use Application

  alias Orchard.Node.{Identity, LicenseEnforcer}
  alias Orchard.Node.Supervisor, as: NodeSupervisor

  @impl true
  def start(_type, _args) do
    # Resolve and persist node identity before starting the supervision tree.
    # This ensures GetStatus can report stable metadata from first request.
    Identity.ensure_identity!()
    LicenseEnforcer.enforce_startup!()

    Supervisor.start_link(
      [NodeSupervisor],
      strategy: :one_for_one,
      name: Orchard.NodeAgent.Supervisor
    )
  end
end
