defmodule Orchard.RuntimeEndpoint.BeamIdentity do
  @moduledoc false

  alias Orchard.RuntimeEndpoint.{Observation, Target}

  @spec resolve_candidate_node_id(Target.t() | term(), Observation.t()) ::
          {:ok, String.t()} | :missing | {:rejected, :beam_node_identity_mismatch}
  def resolve_candidate_node_id(
        %Target{transport: :beam, node_id: node_id},
        %Observation{} = observation
      )
      when is_binary(node_id) do
    configured_node_id = valid_node_id(node_id)
    observed_node_id = metadata_node_id(observation)

    cond do
      configured_node_id == nil -> :missing
      observed_node_id == configured_node_id -> {:ok, configured_node_id}
      true -> {:rejected, :beam_node_identity_mismatch}
    end
  end

  def resolve_candidate_node_id(%Target{transport: :beam}, %Observation{} = observation) do
    case metadata_node_id(observation) do
      nil -> :missing
      node_id -> {:ok, node_id}
    end
  end

  def resolve_candidate_node_id(_target, %Observation{} = observation) do
    case valid_node_id(Observation.node_id(observation)) do
      nil -> :missing
      node_id -> {:ok, node_id}
    end
  end

  @spec metadata_node_id(Observation.t()) :: String.t() | nil
  def metadata_node_id(%Observation{metadata: metadata}) when is_map(metadata) do
    metadata
    |> metadata_value(:node_id)
    |> valid_node_id()
  end

  def metadata_node_id(_observation), do: nil

  defp valid_node_id(node_id) when is_binary(node_id) do
    case Ecto.UUID.cast(node_id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp valid_node_id(_node_id), do: nil

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end
end
