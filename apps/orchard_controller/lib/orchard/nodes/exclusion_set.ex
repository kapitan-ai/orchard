defmodule Orchard.Nodes.ExclusionSet do
  @moduledoc """
  Canonical durable Node identities excluded from a scheduler decision.
  """

  @type t :: MapSet.t(Ecto.UUID.t())

  @spec canonicalize(term()) :: {:ok, t()} | :error
  def canonicalize(node_ids) when is_list(node_ids) do
    Enum.reduce_while(node_ids, {:ok, MapSet.new()}, fn node_id, {:ok, exclusions} ->
      case Ecto.UUID.cast(node_id) do
        {:ok, canonical} -> {:cont, {:ok, MapSet.put(exclusions, canonical)}}
        :error -> {:halt, :error}
      end
    end)
  end

  def canonicalize(_node_ids), do: :error
end
