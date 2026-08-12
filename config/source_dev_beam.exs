defmodule Orchard.Config.SourceDevBeam do
  @moduledoc false

  import Bitwise

  @transport_env "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT"
  @targets_env "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
  @role_env "ORCHARD_SOURCE_DEV_ROLE"
  @node_name_env "ORCHARD_BEAM_NODE_NAME"
  @max_legacy_beam_targets 64
  @allowed_cidrs_env "ORCHARD_SOURCE_DEV_BEAM_ALLOWED_CIDRS"
  @built_in_cidrs [
    {{127, 0, 0, 1}, 32},
    {{10, 0, 0, 0}, 8},
    {{172, 16, 0, 0}, 12},
    {{192, 168, 0, 0}, 16},
    {{100, 64, 0, 0}, 10}
  ]

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

  def address_policy!(value) do
    additional_cidrs =
      value
      |> csv_segments()
      |> Enum.map(&parse_policy_cidr!/1)

    %{additional_cidrs: additional_cidrs, allowed_cidrs: @built_in_cidrs ++ additional_cidrs}
  end

  def host_allowed?(host, %{allowed_cidrs: allowed_cidrs})
      when is_binary(host) and is_list(allowed_cidrs) do
    case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
      {:ok, ip} ->
        valid_host_class?(ip) and Enum.any?(allowed_cidrs, &cidr_contains?(&1, ip))

      {:error, _reason} ->
        false
    end
  end

  def host_allowed?(_host, _policy), do: false

  def warn_expanded_network(%{additional_cidrs: []}), do: :ok

  def warn_expanded_network(%{additional_cidrs: additional_cidrs})
      when is_list(additional_cidrs) do
    IO.warn(
      "#{@allowed_cidrs_env} expands the trusted Source-dev network boundary; shared-cookie BEAM may expose EPMD and BEAM Distribution; restrict their ports to configured peers"
    )

    :ok
  end

  def validate_transport_role!(:beam, :all_in_one) do
    raise "all_in_one BEAM source-dev mode is not supported; use bin/dev-controller and bin/dev-node-agent"
  end

  def validate_transport_role!(_transport, _source_dev_role), do: :ok

  def validate_node_name!(role, node_name, policy)
      when role in [:controller, :node_agent] and is_binary(node_name) do
    {service, host} = beam_service_host!(node_name, @node_name_env)
    require_source_dev_service!(role, service)
    require_source_dev_host!(host, @node_name_env, node_name, policy)
    host
  end

  def controller_beam_targets!(value, env_name \\ @targets_env, policy \\ address_policy!(nil)) do
    segments = csv_segments(value)

    if length(segments) > @max_legacy_beam_targets do
      raise "environment variable #{env_name} supports at most #{@max_legacy_beam_targets} BEAM targets"
    end

    targets = Enum.map(segments, &beam_target!(&1, env_name, policy))

    case targets do
      [] ->
        raise "environment variable #{env_name} must include at least one BEAM target for controller BEAM source-dev mode"

      _ ->
        targets
    end
  end

  def beam_guardrail_config!(node_name, cookie_file, targets, policy \\ address_policy!(nil)) do
    listen_host = validate_node_name!(:controller, node_name, policy)

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

    require_controller_service_characters!(service)

    unless String.starts_with?(service, "orchard_controller") do
      raise "environment variable #{@node_name_env} local controller BEAM node service must start with orchard_controller"
    end

    require_local_controller_ipv4_literal!(host, node_name)
    {service, host}
  end

  defp beam_target!(segment, env_name, policy) do
    {service, host} = beam_service_host!(segment, env_name)

    unless service == "orchard_node_agent" do
      raise "environment variable #{env_name} has unsupported BEAM target service in segment #{inspect(segment)}"
    end

    require_source_dev_host!(host, env_name, segment, policy)

    %{
      transport: :beam,
      address: String.to_atom("#{service}@#{host}"),
      metadata: %{source_dev: true}
    }
  end

  defp require_source_dev_service!(:controller, service) do
    require_controller_service_characters!(service)

    unless String.starts_with?(service, "orchard_controller") do
      raise "environment variable #{@node_name_env} local controller BEAM node service must start with orchard_controller"
    end

    :ok
  end

  defp require_source_dev_service!(:node_agent, "orchard_node_agent"), do: :ok

  defp require_source_dev_service!(:node_agent, _service) do
    raise "environment variable #{@node_name_env} node-agent service must be exactly orchard_node_agent"
  end

  defp require_controller_service_characters!(service) do
    unless service =~ ~r/^[A-Za-z0-9_.-]+$/ do
      raise "environment variable #{@node_name_env} local controller BEAM node service contains invalid characters"
    end
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

  defp require_source_dev_host!(host, env_name, segment, policy) do
    require_ipv4_literal!(host, env_name, segment)

    unless host_allowed?(host, policy) do
      raise "environment variable #{env_name} BEAM host must use same-host loopback, RFC1918, Tailscale CGNAT 100.64.0.0/10, or #{@allowed_cidrs_env}; got segment #{inspect(segment)}"
    end

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
    raise "environment variable #{@node_name_env} host must be an IPv4 literal, got #{inspect(node_name)}"
  end

  defp raise_ipv4_error!(env_name, segment) do
    raise "environment variable #{env_name} requires IPv4-literal BEAM target hosts, got segment #{inspect(segment)}"
  end

  defp reject_unspecified_ip!(ip, env_name, segment) do
    if ip |> Tuple.to_list() |> Enum.all?(&(&1 == 0)) do
      raise "environment variable #{env_name} must not use unspecified or wildcard BEAM hosts, got segment #{inspect(segment)}"
    end
  end

  defp parse_policy_cidr!(cidr) do
    with [host, prefix_string] <- String.split(cidr, "/", parts: 2),
         {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(host)),
         {prefix, ""} <- Integer.parse(prefix_string),
         true <- prefix in 1..32 do
      {ip, prefix}
    else
      _other ->
        raise "environment variable #{@allowed_cidrs_env} contains invalid IPv4 CIDR #{inspect(cidr)}"
    end
  end

  # Config is evaluated before compiled app modules are available, so this predicate mirrors
  # the runtime policy evaluator and the parity test guards their behavior.
  # ex_dna:disable-for-lines:4
  defp valid_host_class?({0, 0, 0, 0}), do: false
  defp valid_host_class?({first, _b, _c, _d}) when first in 224..239, do: false
  defp valid_host_class?({255, 255, 255, 255}), do: false
  defp valid_host_class?(_ip), do: true

  defp cidr_contains?({network, prefix}, ip) do
    mask = ((1 <<< prefix) - 1) <<< (32 - prefix)
    band(ipv4_integer(network), mask) == band(ipv4_integer(ip), mask)
  end

  defp ipv4_integer({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

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
