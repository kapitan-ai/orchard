defmodule Orchard.RuntimeEndpoint.BeamConfig do
  @moduledoc """
  Guardrail validation for first-party BEAM Runtime Endpoint transport.

  Enabled BEAM transport requires an identity-bound local node, admitted target
  services, restricted listen host, and allowed target CIDRs.
  """

  import Bitwise

  alias Orchard.RuntimeEndpoint.Target

  defstruct enabled: false,
            node_name: nil,
            cookie_file: nil,
            listen_host: nil,
            admitted_services: [],
            allowed_cidrs: []

  @type t :: %__MODULE__{
          enabled: boolean(),
          node_name: String.t() | nil,
          cookie_file: String.t() | nil,
          listen_host: String.t() | nil,
          admitted_services: [String.t()],
          allowed_cidrs: [String.t()]
        }

  @type error ::
          :beam_distribution_disabled
          | {:invalid_beam_distribution_config, [atom()]}

  @type target_error ::
          :beam_distribution_unavailable
          | :beam_node_identity_mismatch
          | :invalid_beam_target_address
          | :beam_target_service_not_admitted
          | :beam_target_outside_allowed_cidrs

  @type cidr :: {:inet.ip_address(), non_neg_integer()}

  @spec config() :: keyword()
  def config do
    :orchard_controller
    |> Application.get_env(:runtime_endpoint, [])
    |> Keyword.get(:beam, [])
  end

  @spec validate(keyword() | map(), atom()) :: {:ok, t()} | {:error, error()}
  def validate(config \\ config(), env \\ runtime_env()) do
    attrs = attrs_map(config)

    if enabled?(attrs) do
      validate_enabled_attrs(attrs, env)
    else
      {:ok, %__MODULE__{enabled: false}}
    end
  end

  @spec validate_enabled(keyword() | map(), atom()) :: {:ok, t()} | {:error, error()}
  def validate_enabled(config \\ config(), env \\ runtime_env()) do
    attrs = attrs_map(config)

    if enabled?(attrs) do
      validate_enabled_attrs(attrs, env)
    else
      {:error, :beam_distribution_disabled}
    end
  end

  @spec validate_target(t(), Target.t(), keyword()) :: :ok | {:error, target_error()}
  def validate_target(config, target, opts \\ [])

  def validate_target(%__MODULE__{enabled: false}, _target, _opts), do: :ok

  def validate_target(
        %__MODULE__{enabled: true} = config,
        %Target{transport: :beam} = target,
        opts
      ) do
    current_node = Keyword.get(opts, :current_node, node())

    with :ok <- require_current_node(config, current_node),
         {:ok, service, host} <- beam_service_host(target.address),
         :ok <- require_admitted_service(config, service) do
      require_allowed_host(config, host)
    end
  end

  def validate_target(%__MODULE__{enabled: true}, %Target{}, _opts),
    do: {:error, :invalid_beam_target_address}

  defp validate_enabled_attrs(attrs, _env) do
    errors =
      []
      |> require_non_empty(attrs, :node_name, :missing_node_name)
      |> require_non_empty(attrs, :cookie_file, :missing_cookie_file)
      |> require_restricted_list(attrs, :admitted_services, :missing_admitted_services)
      |> require_restricted_list(attrs, :allowed_cidrs, :missing_allowed_cidrs)
      |> require_valid_cidrs(attrs, :allowed_cidrs)
      |> require_list_without_global_cidrs(attrs, :allowed_cidrs)
      |> require_restricted_listen_host(attrs)

    case errors do
      [] -> {:ok, struct_from_attrs(attrs)}
      _ -> {:error, {:invalid_beam_distribution_config, Enum.reverse(errors)}}
    end
  end

  defp struct_from_attrs(attrs) do
    %__MODULE__{
      enabled: true,
      node_name: string_value(attrs, :node_name),
      cookie_file: string_value(attrs, :cookie_file),
      listen_host: string_value(attrs, :listen_host),
      admitted_services: list_value(attrs, :admitted_services),
      allowed_cidrs: list_value(attrs, :allowed_cidrs)
    }
  end

  defp require_current_node(_config, :nonode@nohost),
    do: {:error, :beam_distribution_unavailable}

  defp require_current_node(%__MODULE__{node_name: node_name}, current_node)
       when is_atom(current_node) do
    if Atom.to_string(current_node) == node_name do
      :ok
    else
      {:error, :beam_node_identity_mismatch}
    end
  end

  defp require_current_node(_config, _current_node), do: {:error, :beam_node_identity_mismatch}

  defp beam_service_host(address) when is_atom(address) do
    address
    |> Atom.to_string()
    |> beam_service_host()
  end

  defp beam_service_host(address) when is_binary(address) do
    case String.split(address, "@") do
      [service, host] when service != "" and host != "" -> {:ok, service, host}
      _other -> {:error, :invalid_beam_target_address}
    end
  end

  defp beam_service_host(_address), do: {:error, :invalid_beam_target_address}

  defp require_admitted_service(%__MODULE__{admitted_services: services}, service) do
    if service in services do
      :ok
    else
      {:error, :beam_target_service_not_admitted}
    end
  end

  defp require_allowed_host(%__MODULE__{allowed_cidrs: cidrs}, host) do
    case parse_ip(host) do
      {:ok, ip} ->
        if Enum.any?(cidrs, &cidr_contains?(&1, ip)) do
          :ok
        else
          {:error, :beam_target_outside_allowed_cidrs}
        end

      :error ->
        {:error, :beam_target_outside_allowed_cidrs}
    end
  end

  defp require_non_empty(errors, attrs, key, error) do
    if non_empty_string?(value(attrs, key)), do: errors, else: [error | errors]
  end

  defp require_restricted_list(errors, attrs, key, error) do
    values = list_value(attrs, key)

    if values != [] and Enum.all?(values, &non_empty_string?/1) do
      errors
    else
      [error | errors]
    end
  end

  defp require_valid_cidrs(errors, attrs, key) do
    cidrs = list_value(attrs, key)

    if cidrs != [] and Enum.any?(cidrs, &(parse_cidr(&1) == :error)) do
      [:invalid_allowed_cidr | errors]
    else
      errors
    end
  end

  defp require_list_without_global_cidrs(errors, attrs, key) do
    cidrs = list_value(attrs, key)

    if Enum.any?(cidrs, &global_cidr?/1) do
      [:global_beam_distribution_cidr | errors]
    else
      errors
    end
  end

  defp require_restricted_listen_host(errors, attrs) do
    case value(attrs, :listen_host) do
      host when host in ["0.0.0.0", "::"] -> [:unrestricted_listen_host | errors]
      host when is_binary(host) and host != "" -> errors
      _ -> [:missing_listen_host | errors]
    end
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(%{} = attrs), do: attrs

  defp cidr_contains?(cidr, ip) do
    case parse_cidr(cidr) do
      {:ok, parsed_cidr} -> ip_in_cidr?(ip, parsed_cidr)
      :error -> false
    end
  end

  defp global_cidr?(cidr) do
    case parse_cidr(cidr) do
      {:ok, {_ip, 0}} -> true
      _other -> false
    end
  end

  defp parse_cidr(cidr) when is_binary(cidr) do
    with [ip_string, prefix_string] <- String.split(cidr, "/", parts: 2),
         {:ok, ip} <- parse_ip(ip_string),
         {prefix, ""} <- Integer.parse(prefix_string),
         true <- prefix >= 0 and prefix <= ip_bits(ip) do
      {:ok, {ip, prefix}}
    else
      _other -> :error
    end
  end

  defp parse_cidr(_cidr), do: :error

  defp parse_ip(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> :error
    end
  end

  defp ip_in_cidr?(ip, {network, prefix}) when tuple_size(ip) == tuple_size(network) do
    bits = ip_bits(ip)
    mask = ((1 <<< prefix) - 1) <<< (bits - prefix)
    (ip_to_integer(ip) &&& mask) == (ip_to_integer(network) &&& mask)
  end

  defp ip_in_cidr?(_ip, _cidr), do: false

  defp ip_bits(ip) when tuple_size(ip) == 4, do: 32
  defp ip_bits(ip) when tuple_size(ip) == 8, do: 128

  defp ip_to_integer(ip) when tuple_size(ip) == 4 do
    Enum.reduce(Tuple.to_list(ip), 0, fn octet, acc -> acc * 256 + octet end)
  end

  defp ip_to_integer(ip) when tuple_size(ip) == 8 do
    Enum.reduce(Tuple.to_list(ip), 0, fn segment, acc -> acc * 65_536 + segment end)
  end

  defp enabled?(attrs), do: value(attrs, :enabled) == true

  defp string_value(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp list_value(attrs, key) do
    case value(attrs, key) do
      values when is_list(values) -> values
      nil -> []
      value -> [value]
    end
  end

  defp value(attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp runtime_env do
    if Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod
  end
end
