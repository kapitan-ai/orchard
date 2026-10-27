defmodule Orchard.WorkerRecovery.LocalCheckpointClient do
  @moduledoc """
  In-process SPEC §12.2 checkpoint client for all-in-one source development.

  The Node Agent there runs in the Controller's BEAM, so it reaches Postgres
  through `Orchard.WorkerRecovery.Checkpoints` directly instead of the
  identity-bound control path that split roles use. It returns the same
  results as `Orchard.Node.WorkerRecoveryCheckpointClient`, so the Node Agent
  stays fail-closed whenever a checkpoint cannot be read or written.
  """

  alias Orchard.WorkerRecovery.Checkpoints

  @spec read(map()) :: {:ok, map() | :absent} | {:error, :stale_checkpoint | :unavailable}
  def read(key), do: key |> Checkpoints.read_local() |> result()

  @spec list(String.t()) :: {:ok, [map()]} | {:error, :unavailable}
  def list(node_id) do
    case Checkpoints.list_local(node_id) do
      {:ok, keys} -> {:ok, keys}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  @spec commit(map(), String.t() | nil, non_neg_integer(), String.t(), map()) ::
          {:ok, map()} | {:error, :stale_checkpoint | :unavailable}
  def commit(key, epoch, revision, transition_id, record) do
    key
    |> Checkpoints.commit_local(epoch, revision, transition_id, record)
    |> result()
  end

  defp result({:ok, _checkpoint} = ok), do: ok

  defp result({:error, reason})
       when reason in [:stale_checkpoint, :unresolved_epoch_claim, :conflict],
       do: {:error, :stale_checkpoint}

  defp result({:error, _reason}), do: {:error, :unavailable}
end
