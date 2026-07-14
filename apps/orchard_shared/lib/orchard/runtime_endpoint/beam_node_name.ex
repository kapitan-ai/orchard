defmodule Orchard.RuntimeEndpoint.BeamNodeName do
  @moduledoc """
  Validates exact peer-grant BEAM names before they cross an atom boundary.
  """

  @prefixes ["orchard_controller_", "orchard_node_agent_"]
  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @spec validate(String.t(), String.t(), String.t()) ::
          :ok | {:error, :invalid_beam_node_name}
  def validate(name, prefix, id)
      when is_binary(name) and prefix in @prefixes and is_binary(id) do
    expected_service = prefix <> String.replace(id, "-", "")

    case String.split(name, "@", parts: 2) do
      [^expected_service, host] -> validate_private_host(host, id)
      _other -> {:error, :invalid_beam_node_name}
    end
  end

  def validate(_name, _prefix, _id), do: {:error, :invalid_beam_node_name}

  @spec private_ipv4(String.t(), keyword()) ::
          {:ok, :inet.ip4_address()} | {:error, :invalid_private_ipv4}
  def private_ipv4(host, opts \\ [])

  def private_ipv4(host, opts) when is_binary(host) and is_list(opts) do
    with {:ok, address} <- :inet.parse_ipv4strict_address(String.to_charlist(host)),
         true <- private?(address) or allowed_loopback?(address, opts) do
      {:ok, address}
    else
      _other -> {:error, :invalid_private_ipv4}
    end
  end

  def private_ipv4(_host, _opts), do: {:error, :invalid_private_ipv4}

  @spec to_atom(String.t(), String.t(), String.t()) ::
          {:ok, node()} | {:error, :beam_target_unknown}
  def to_atom(name, prefix, id) do
    case validate(name, prefix, id) do
      :ok -> {:ok, String.to_atom(name)}
      {:error, :invalid_beam_node_name} -> {:error, :beam_target_unknown}
    end
  end

  defp validate_private_host(host, id) do
    if Regex.match?(@uuid_pattern, id) and match?({:ok, _address}, private_ipv4(host)) do
      :ok
    else
      {:error, :invalid_beam_node_name}
    end
  end

  defp private?({10, _b, _c, _d}), do: true
  defp private?({172, b, _c, _d}) when b in 16..31, do: true
  defp private?({192, 168, _c, _d}), do: true
  defp private?(_address), do: false

  defp allowed_loopback?({127, 0, 0, 1}, opts), do: Keyword.get(opts, :allow_loopback, false)
  defp allowed_loopback?(_address, _opts), do: false
end
