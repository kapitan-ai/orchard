defmodule Orchard.Config.ControllerMembership do
  @moduledoc """
  Pure resolver for the durable Controller membership host and its scope.

  Extracted from `config/runtime.exs` and `config/source_dev_beam.exs`, which
  each derived this classification independently, so packaged and source-dev
  Controllers cannot drift apart on the identity that names a Controller
  forever.

  `ORCHARD_CONTROLLER_MEMBERSHIP_HOST` is the only external source for the
  durable canonical Controller host. Membership identity never reads the BEAM
  Peer Grant control listener, so toggling grants cannot move a Controller's
  durable canonical BEAM name. When the override is absent, membership defaults
  to the runtime BEAM identity host, and to loopback for gRPC or single-host
  Controllers.

  The resolved scope is explicit rather than defaulted: `Orchard.Application`
  hands it to `Orchard.ControllerInstances`, which only allows a loopback
  canonical host under `:local_only`. Classification therefore delegates to
  `Orchard.RuntimeEndpoint.BeamNodeName`, the same host rule that validates the
  identity at boot, so a host accepted here cannot be rejected there.
  """

  alias Orchard.RuntimeEndpoint.BeamNodeName

  @node_name_env "ORCHARD_BEAM_NODE_NAME"
  @membership_host_env "ORCHARD_CONTROLLER_MEMBERSHIP_HOST"

  @type scope :: :local_only | :remote_beam
  @type transport :: :beam | :grpc

  @doc """
  Resolves the Controller membership host and its loopback classification.

  Raises when the resolved host is public, contradicts `#{@node_name_env}`, or
  is loopback while BEAM Peer Grants require a routable Controller.

  ## Options

    * `:membership_host` - the `#{@membership_host_env}` override.
    * `:peer_grants_enabled?` - whether BEAM Peer Grants are enabled.

  ## Examples

      iex> identity!(:beam, "orchard_controller@10.0.0.10")
      {"10.0.0.10", :remote_beam}

      iex> identity!(:grpc, nil)
      {"127.0.0.1", :local_only}
  """
  @spec identity!(transport(), String.t() | nil, keyword()) :: {String.t(), scope()}
  def identity!(transport, node_name, opts \\ []) do
    membership_host = optional_trimmed(Keyword.get(opts, :membership_host))
    peer_grants_enabled? = Keyword.get(opts, :peer_grants_enabled?, false)
    node_name = optional_trimmed(node_name)

    case membership_host do
      nil -> default_identity!(transport, node_name, peer_grants_enabled?)
      host -> explicit_identity!(host, transport, node_name, peer_grants_enabled?)
    end
  end

  defp explicit_identity!(host, transport, node_name, peer_grants_enabled?) do
    require_node_name_agreement!(host, transport, node_name)

    cond do
      remote_host?(host) ->
        {host, :remote_beam}

      not local_host?(host) ->
        raise "environment variable #{@membership_host_env} Controller membership host must be a private IPv4 address, got #{inspect(host)}"

      peer_grants_enabled? ->
        raise "environment variable #{@membership_host_env} must be a private non-loopback IPv4 address when BEAM Peer Grants are enabled, got #{inspect(host)}"

      true ->
        {host, :local_only}
    end
  end

  defp default_identity!(_transport, _node_name, true) do
    raise "environment variable #{@membership_host_env} is required when BEAM Peer Grants are enabled"
  end

  defp default_identity!(:grpc, _node_name, false), do: {"127.0.0.1", :local_only}
  defp default_identity!(:beam, nil, false), do: {"127.0.0.1", :local_only}

  defp default_identity!(:beam, node_name, false) do
    {_service, host} = controller_service_host!(node_name)

    cond do
      remote_host?(host) ->
        {host, :remote_beam}

      local_host?(host) ->
        {host, :local_only}

      true ->
        raise "environment variable #{@node_name_env} Controller membership host must be a private IPv4 address, got #{inspect(node_name)}"
    end
  end

  defp remote_host?(host), do: match?({:ok, _address}, BeamNodeName.private_ipv4(host))

  defp local_host?(host) do
    match?({:ok, _address}, BeamNodeName.private_ipv4(host, allow_loopback: true))
  end

  defp require_node_name_agreement!(_host, :grpc, _node_name), do: :ok
  defp require_node_name_agreement!(_host, :beam, nil), do: :ok

  defp require_node_name_agreement!(host, :beam, node_name) do
    {_service, node_host} = controller_service_host!(node_name)

    unless node_host == host do
      raise "environment variable #{@membership_host_env} #{inspect(host)} must match the #{@node_name_env} host #{inspect(node_host)}"
    end

    :ok
  end

  @doc """
  Splits a local Controller BEAM node name into its service and IPv4 host.
  """
  @spec controller_service_host!(String.t() | atom()) :: {String.t(), String.t()}
  def controller_service_host!(node_name) do
    {service, host} =
      case node_name |> to_string() |> String.split("@") do
        [service, host] when service != "" and host != "" ->
          {service, host}

        _other ->
          raise "environment variable #{@node_name_env} has invalid BEAM node-name segment #{inspect(node_name)}"
      end

    unless service =~ ~r/^[A-Za-z0-9_.-]+$/ do
      raise "environment variable #{@node_name_env} local controller BEAM node service contains invalid characters"
    end

    unless String.starts_with?(service, "orchard_controller") do
      raise "environment variable #{@node_name_env} local controller BEAM node service must start with orchard_controller"
    end

    {service, host}
  end

  defp optional_trimmed(nil), do: nil

  defp optional_trimmed(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
