defmodule Orchard.Config.SourceDevBeam do
  @moduledoc false

  @transport_env "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT"
  @targets_env "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
  @role_env "ORCHARD_SOURCE_DEV_ROLE"
  @node_name_env "ORCHARD_BEAM_NODE_NAME"
  @max_legacy_beam_targets 64

  def transport!(value) do
    case optional_trimmed(value) do
      nil ->
        :grpc

      "grpc" ->
        :grpc

      "beam" ->
        :beam

      other ->
        raise "environment variable #{@transport_env} must be grpc|beam, got: #{inspect(other)}"
    end
  end

  def source_dev_role(value) do
    case optional_trimmed(value) do
      nil ->
        :controller

      "controller" ->
        :controller

      "node_agent" ->
        :node_agent

      "all_in_one" ->
        :all_in_one

      other ->
        raise "environment variable #{@role_env} must be controller|node_agent|all_in_one, got: #{inspect(other)}"
    end
  end

  def validate_transport_role!(:beam, :all_in_one) do
    raise "all_in_one BEAM source-dev mode is not supported; use bin/dev-controller and bin/dev-node-agent"
  end

  def validate_transport_role!(_transport, _source_dev_role), do: :ok

  def controller_beam_targets!(value, env_name \\ @targets_env) do
    segments = csv_segments(value)

    if length(segments) > @max_legacy_beam_targets do
      raise "environment variable #{env_name} supports at most #{@max_legacy_beam_targets} BEAM targets"
    end

    targets = Enum.map(segments, &beam_target!(&1, env_name))

    case targets do
      [] ->
        raise "environment variable #{env_name} must include at least one BEAM target for controller BEAM source-dev mode"

      _ ->
        targets
    end
  end

  @doc """
  Resolves the Controller membership host and its loopback classification.

  Membership identity never reads the BEAM Peer Grant control listener, so
  toggling grants cannot move a Controller's durable canonical BEAM name.
  """
  def controller_membership_identity!(:grpc, _node_name), do: {"127.0.0.1", :local_only}

  def controller_membership_identity!(:beam, node_name) do
    {_service, host} = local_controller_service_host!(node_name)
    ip = parse_ipv4!(host, @node_name_env, node_name)

    cond do
      loopback_ip?(ip) ->
        {host, :local_only}

      private_ipv4?(ip) ->
        {host, :remote_beam}

      true ->
        raise "environment variable #{@node_name_env} Controller membership host must be a private IPv4 address, got #{inspect(node_name)}"
    end
  end

  defp loopback_ip?({127, _b, _c, _d}), do: true
  defp loopback_ip?(_ip), do: false

  defp private_ipv4?({10, _b, _c, _d}), do: true
  defp private_ipv4?({172, b, _c, _d}) when b in 16..31, do: true
  defp private_ipv4?({192, 168, _c, _d}), do: true
  defp private_ipv4?(_ip), do: false

  def beam_guardrail_config!(node_name, cookie_file, targets) do
    {_service, listen_host} = local_controller_service_host!(node_name)

    [
      enabled: true,
      node_name: node_name,
      cookie_file: cookie_file,
      listen_host: listen_host,
      admitted_services: ["orchard_node_agent"],
      allowed_cidrs: allowed_cidrs(targets)
    ]
  end

  def peer_grant_guardrail_config!(node_name) do
    {service, listen_host} = local_controller_service_host!(node_name)

    unless Regex.match?(~r/^orchard_controller_[0-9a-f]{32}$/, service) do
      raise "environment variable #{@node_name_env} peer-grant Controller service must be canonical orchard_controller_<controller-id>"
    end

    [
      enabled: true,
      node_name: node_name,
      cookie_file: nil,
      listen_host: listen_host,
      admitted_services: [],
      allowed_cidrs: []
    ]
  end

  defp local_controller_service_host!(node_name) do
    {service, host} = beam_service_host!(node_name, @node_name_env)

    unless service =~ ~r/^[A-Za-z0-9_.-]+$/ do
      raise "environment variable #{@node_name_env} local controller BEAM node service contains invalid characters"
    end

    unless String.starts_with?(service, "orchard_controller") do
      raise "environment variable #{@node_name_env} local controller BEAM node service must start with orchard_controller"
    end

    require_local_controller_ipv4_literal!(host, node_name)
    {service, host}
  end

  defp beam_target!(segment, env_name) do
    {service, host} = beam_service_host!(segment, env_name)

    unless service == "orchard_node_agent" do
      raise "environment variable #{env_name} has unsupported BEAM target service in segment #{inspect(segment)}"
    end

    require_ipv4_literal!(host, env_name, segment)

    %{
      transport: :beam,
      address: String.to_atom("#{service}@#{host}"),
      metadata: %{source_dev: true}
    }
  end

  defp allowed_cidrs(targets) do
    targets
    |> Enum.map(fn %{address: address} ->
      {_service, host} = beam_service_host!(address, @targets_env)
      ip = parse_ipv4!(host, @targets_env, address)
      {ip, "#{host}/32"}
    end)
    |> Enum.uniq_by(fn {ip, _cidr} -> ip end)
    |> Enum.map(fn {_ip, cidr} -> cidr end)
  end

  defp beam_service_host!(value, env_name) do
    case String.split(to_string(value), "@") do
      [service, host] when service != "" and host != "" ->
        {service, host}

      _ ->
        raise "environment variable #{env_name} has invalid BEAM node-name segment #{inspect(value)}"
    end
  end

  defp require_ipv4_literal!(host, env_name, segment) do
    parse_ipv4!(host, env_name, segment)
    :ok
  end

  defp require_local_controller_ipv4_literal!(host, node_name) do
    parse_ipv4!(host, @node_name_env, node_name)
    :ok
  end

  defp parse_ipv4!(host, env_name, segment) do
    case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
      {:ok, ip} ->
        reject_unspecified_ip!(ip, env_name, segment)
        ip

      {:error, _reason} ->
        raise_ipv4_error!(env_name, segment)
    end
  end

  defp raise_ipv4_error!(@node_name_env, node_name) do
    raise "environment variable #{@node_name_env} requires IPv4-literal local controller host, got #{inspect(node_name)}"
  end

  defp raise_ipv4_error!(env_name, segment) do
    raise "environment variable #{env_name} requires IPv4-literal BEAM target hosts, got segment #{inspect(segment)}"
  end

  defp reject_unspecified_ip!(ip, env_name, segment) do
    if ip |> Tuple.to_list() |> Enum.all?(&(&1 == 0)) do
      raise "environment variable #{env_name} must not use unspecified or wildcard BEAM hosts, got segment #{inspect(segment)}"
    end
  end

  defp csv_segments(nil), do: []

  defp csv_segments(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp optional_trimmed(nil), do: nil

  defp optional_trimmed(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end
end
