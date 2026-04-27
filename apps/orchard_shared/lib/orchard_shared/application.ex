defmodule OrchardShared.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [Orchard.Licensing.GateCache]

    Supervisor.start_link(children, strategy: :one_for_one, name: OrchardShared.Supervisor)
  end
end
