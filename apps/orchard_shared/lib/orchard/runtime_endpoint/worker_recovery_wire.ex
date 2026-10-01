defmodule Orchard.RuntimeEndpoint.WorkerRecoveryWire do
  @moduledoc "Bounded encoding for the dedicated SPEC §12.2 control operations."
  alias Orchard.Cluster.V1.{WorkerRecoveryKey, WorkerRecoveryResult}
  alias Orchard.RuntimeEndpoint.WorkerRecoveryEvidence

  @spec key(term()) :: {:ok, map()} | {:error, :invalid_key}
  def key(%WorkerRecoveryKey{node_id: node_id, model_id: model_id, version: version}) do
    if Enum.all?([node_id, model_id, version], &(is_binary(&1) and byte_size(&1) in 1..256)) do
      {:ok, %{node_id: node_id, model_id: model_id, version: version}}
    else
      {:error, :invalid_key}
    end
  end

  def key(_key), do: {:error, :invalid_key}

  @spec decode_record(term()) :: {:ok, map()} | {:error, :invalid_checkpoint}
  def decode_record(value) when is_binary(value) and byte_size(value) <= 4096 do
    case Jason.decode(value) do
      {:ok, record} when is_map(record) -> {:ok, record}
      _invalid -> {:error, :invalid_checkpoint}
    end
  end

  def decode_record(_value), do: {:error, :invalid_checkpoint}

  @spec result({:ok, map() | :absent} | {:error, term()}) :: WorkerRecoveryResult.t()
  def result({:ok, :absent}), do: %WorkerRecoveryResult{status: 200, reason: "absent"}

  def result({:ok, record}),
    do: %WorkerRecoveryResult{status: 200, record_json: Jason.encode!(record)}

  def result({:error, reason}) do
    {status, code} = error(reason)
    %WorkerRecoveryResult{status: status, reason: code}
  end

  @doc "Encodes Node recovery evidence only after the shared exact-key validator accepts it."
  @spec evidence_result({:ok, map()} | {:error, term()}) :: WorkerRecoveryResult.t()
  def evidence_result({:ok, evidence}) do
    case WorkerRecoveryEvidence.encode(evidence) do
      {:ok, json} -> %WorkerRecoveryResult{status: 200, record_json: json}
      {:error, :invalid_worker_recovery_evidence} -> result({:error, :unavailable})
    end
  end

  def evidence_result({:error, reason}), do: result({:error, reason})

  defp error(reason) when reason in [:unauthorized_checkpoint, :permission_denied],
    do: {403, "permission_denied"}

  defp error(reason) when reason in [:stale_checkpoint, :unresolved_epoch_claim, :conflict],
    do: {409, "conflict"}

  defp error(reason) when reason in [:invalid_checkpoint, :invalid_key, :invalid_command],
    do: {422, "invalid_input"}

  defp error(_reason), do: {503, "unavailable"}
end
