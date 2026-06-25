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

  @type transport :: :grpc_compat | :beam
  @type t :: %__MODULE__{
          id: String.t(),
          transport: transport(),
          address: term(),
          node_id: String.t() | nil,
          metadata: map()
        }

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

    %__MODULE__{
      id: value(attrs, :id) || "beam:#{node_id}",
      transport: :beam,
      address: value(attrs, :address) || node_id,
      node_id: node_id,
      metadata: metadata(attrs)
    }
  end

  def beam(_node_id, _opts),
    do: raise(ArgumentError, "beam target requires a non-empty binary node_id")

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(%{} = attrs), do: attrs

  defp metadata(attrs) do
    case value(attrs, :metadata) do
      %{} = metadata -> metadata
      nil -> %{}
      other -> %{raw_metadata: other}
    end
  end

  defp value(%{} = attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
