defmodule Orchard.Node.LicenseEnforcer do
  @moduledoc """
  Startup-only licensing enforcement for the Orchard node agent.
  """

  require Logger

  alias Orchard.Licensing
  alias Orchard.Node
  alias Orchard.SentryContext

  @spec enforce_startup!() :: :ok | no_return()
  def enforce_startup! do
    enforcement = Node.license_enforcement()
    status = inspect_startup_license()
    SentryContext.cache_license_status(status)

    case {enforcement, Licensing.startup_decision(status, enforcement)} do
      {:off, :allow} ->
        Logger.info(
          "Node-agent startup license tracking",
          license_metadata(status, enforcement)
        )

        SentryContext.apply_license_status(status, :node_agent)
        :ok

      {_enforcement, :allow} ->
        Logger.info(
          "Node-agent startup license allow",
          license_metadata(status, enforcement)
        )

        SentryContext.apply_license_status(status, :node_agent)
        :ok

      {_enforcement, {:warn, _message}} ->
        Logger.warning(
          "Node-agent startup license warn",
          license_metadata(status, enforcement)
        )

        SentryContext.apply_license_status(status, :node_agent)
        :ok

      {_enforcement, {:deny, _message}} ->
        Logger.error(
          "Node-agent startup license deny",
          license_metadata(status, enforcement)
        )

        SentryContext.apply_license_status(status, :node_agent)
        raise "Node-agent startup blocked by licensing: #{safe_denial_reason(status)}"
    end
  end

  defp inspect_startup_license do
    Node.licensing_impl().inspect_local()
  rescue
    _exception -> missing_license_status()
  catch
    _kind, _reason -> missing_license_status()
  end

  defp missing_license_status do
    %Licensing{
      state: :missing_bundle,
      message: "license inspection failed during node-agent startup",
      bundle_path: ""
    }
  end

  defp license_metadata(status, enforcement) do
    status
    |> SentryContext.build_license_extra()
    |> Map.drop([:orchard_licensee])
    |> Map.to_list()
    |> Keyword.merge(app: :orchard_node_agent, enforcement: enforcement)
  end

  defp safe_denial_reason(%Licensing{} = status) do
    Atom.to_string(status.state)
  end
end
