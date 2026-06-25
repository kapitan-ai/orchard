defmodule Orchard.RuntimeEndpoint.Target do
  @moduledoc """
  Addressable Runtime Endpoint target selected by the scheduler.
  """

  @enforce_keys [:id, :transport, :address]
  defstruct id: nil,
            transport: nil,
            address: nil,
            node_id: nil,
            metadata: %{}

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @type transport :: :grpc_compat | :beam
  @type t :: %__MODULE__{
          id: String.t(),
          transport: transport(),
          address: term(),
          node_id: String.t() | nil,
          metadata: map()
        }

  @spec normalize(t() | keyword() | map()) :: t()
  def normalize(%__MODULE__{transport: :beam} = target),
    do: %{target | node_id: normalize_optional_node_id(target.node_id)}

  def normalize(%__MODULE__{} = target), do: target

  def normalize(target) when is_list(target) or is_map(target) do
    attrs = attrs_map(target)

    case normalize_transport(value(attrs, :transport)) do
      :beam -> beam_target(attrs)
      :grpc_compat -> grpc_compat(attrs)
    end
  end

  @spec grpc_compat(keyword() | map()) :: t()
  def grpc_compat(target) do
    attrs = attrs_map(target)
    host = value(attrs, :host)
    port = value(attrs, :port)

    unless is_binary(host) and is_integer(port) and port > 0 do
      raise ArgumentError,
            "grpc compatibility target requires binary host and positive integer port"
    end

    %__MODULE__{
      id: "grpc_compat:#{host}:#{port}",
      transport: :grpc_compat,
      address: [host: host, port: port],
      node_id: value(attrs, :node_id),
      metadata: metadata(attrs)
    }
  end

  @spec beam(String.t(), keyword() | map()) :: t()
  def beam(node_id, opts \\ [])

  def beam(node_id, opts) when is_binary(node_id) and node_id != "" do
    attrs = attrs_map(opts)
    node_id = normalize_required_node_id(node_id)

    %__MODULE__{
      id: value(attrs, :id) || "beam:#{node_id}",
      transport: :beam,
      address: value(attrs, :address) || node_id,
      node_id: node_id,
      metadata: metadata(attrs)
    }
  end

  def beam(_node_id, _opts),
    do: raise(ArgumentError, "beam target node_id must be a UUID")

  defp beam_target(attrs) do
    node_id = normalize_optional_node_id(value(attrs, :node_id))
    address = normalize_beam_address(value(attrs, :address))

    %__MODULE__{
      id: to_string(value(attrs, :id) || default_beam_id(node_id, address)),
      transport: :beam,
      address: address,
      node_id: node_id,
      metadata: metadata(attrs)
    }
  end

  defp normalize_transport(transport) when transport in [:beam, "beam"], do: :beam
  defp normalize_transport(_transport), do: :grpc_compat

  defp normalize_optional_node_id(nil), do: nil

  defp normalize_optional_node_id(node_id) when is_binary(node_id) and node_id != "",
    do: normalize_required_node_id(node_id)

  defp normalize_optional_node_id(_node_id) do
    raise ArgumentError, "beam target node_id must be a UUID when provided"
  end

  defp normalize_required_node_id(node_id) do
    if String.match?(node_id, @uuid_pattern) do
      String.downcase(node_id)
    else
      raise ArgumentError, "beam target node_id must be a UUID"
    end
  end

  defp normalize_beam_address(address) when is_atom(address), do: address

  defp normalize_beam_address(address) when is_binary(address) do
    unless valid_beam_node_name?(address) do
      raise ArgumentError,
            "beam target address must be a valid node name, got: #{inspect(address)}"
    end

    String.to_atom(address)
  end

  defp normalize_beam_address(address) do
    raise ArgumentError,
          "beam target address must be an atom or binary node name, got: #{inspect(address)}"
  end

  defp default_beam_id(node_id, _address) when is_binary(node_id), do: "beam:#{node_id}"
  defp default_beam_id(nil, address) when is_atom(address), do: "beam:#{Atom.to_string(address)}"

  defp valid_beam_node_name?(address) do
    byte_size(address) in 3..255 and String.match?(address, ~r/^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$/)
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(%{} = attrs), do: attrs

  defp metadata(attrs) do
    case value(attrs, :metadata) do
      %{} = metadata -> metadata
      nil -> %{}
      other -> %{raw_metadata: other}
    end
  end

  defp value(%{} = attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end
end
