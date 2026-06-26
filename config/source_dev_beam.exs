defmodule Orchard.Config.SourceDevBeam do
  @moduledoc false

  @transport_env "ORCHARD_RUNTIME_ENDPOINT_TRANSPORT"
  @targets_env "ORCHARD_RUNTIME_ENDPOINT_TARGETS"
  @role_env "ORCHARD_SOURCE_DEV_ROLE"
  @node_name_env "ORCHARD_BEAM_NODE_NAME"

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

  def controller_beam_targets!(value, env_name \\ @targets_env) do
    targets =
      value
      |> csv_segments()
      |> Enum.map(&beam_target!(&1, env_name))

    case targets do
      [] ->
        raise "environment variable #{env_name} must include at least one BEAM target for controller BEAM source-dev mode"

      _ ->
        targets
    end
  end

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

  defp local_controller_service_host!(node_name) do
    {service, host} = beam_service_host!(node_name, @node_name_env)

    unless service =~ ~r/^[A-Za-z0-9_.-]+$/ do
      raise "environment variable #{@node_name_env} local controller BEAM node service contains invalid characters"
    end

    unless String.starts_with?(service, "orchard_controller") do
      raise "environment variable #{@node_name_env} local controller BEAM node service must start with orchard_controller"
    end

    require_local_controller_ip_literal!(host, node_name)
    {service, host}
  end

  defp beam_target!(segment, env_name) do
    {service, host} = beam_service_host!(segment, env_name)

    unless service == "orchard_node_agent" do
      raise "environment variable #{env_name} has unsupported BEAM target service in segment #{inspect(segment)}"
    end

    require_ip_literal!(host, env_name, segment)

    %{
      transport: :beam,
      address: "#{service}@#{host}",
      metadata: %{source_dev: true}
    }
  end

  defp allowed_cidrs(targets) do
    targets
    |> Enum.map(fn %{address: address} ->
      {_service, host} = beam_service_host!(address, @targets_env)
      {ip, cidr_suffix} = ip_and_cidr_suffix!(host, @targets_env, address)
      {ip, "#{host}/#{cidr_suffix}"}
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

  defp require_ip_literal!(host, env_name, segment) do
    ip_and_cidr_suffix!(host, env_name, segment)
    :ok
  end

  defp require_local_controller_ip_literal!(host, node_name) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} when tuple_size(ip) in [4, 8] ->
        :ok

      {:error, _reason} ->
        raise "environment variable #{@node_name_env} requires IP-literal local controller host, got #{inspect(node_name)}"
    end
  end

  defp ip_and_cidr_suffix!(host, env_name, segment) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} when tuple_size(ip) == 4 ->
        {ip, 32}

      {:ok, ip} when tuple_size(ip) == 8 ->
        {ip, 128}

      {:error, _reason} ->
        raise "environment variable #{env_name} requires IP-literal BEAM target hosts, got segment #{inspect(segment)}"
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
