defmodule Orchard.Node.TestWorkerRecoveryCheckpointClient do
  @moduledoc false

  @spec read(map()) :: {:ok, :absent}
  def read(_key), do: {:ok, :absent}

  @spec commit(map(), String.t() | nil, non_neg_integer(), String.t(), map()) :: {:ok, map()}
  def commit(_key, _epoch, revision, transition_id, record) do
    {:ok,
     %{
       epoch: record["epoch"],
       revision: revision + 1,
       transition_id: transition_id,
       record: record
     }}
  end
end
