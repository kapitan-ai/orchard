defmodule Orchard.Node.LicenseEnforcer do
  @moduledoc """
  Startup-only licensing enforcement for the Orchard node agent.
  """

  require Logger

  alias Orchard.Licensing
  alias Orchard.Node

  @spec enforce_startup!() :: :ok | no_return()
  def enforce_startup! do
    case Node.license_enforcement() do
      :off ->
        :ok

      enforcement ->
        status = Node.licensing_impl().inspect_local()

        case Licensing.startup_decision(status, enforcement) do
          :allow ->
            :ok

          {:warn, message} ->
            Logger.warning("Node-agent startup license warning: #{message}")
            :ok

          {:deny, message} ->
            raise "Node-agent startup blocked by licensing: #{message}"
        end
    end
  end
end
