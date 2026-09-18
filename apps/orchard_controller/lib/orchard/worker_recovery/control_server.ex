defmodule Orchard.WorkerRecovery.ControlServer do
  @moduledoc "Identity-bound Node-to-Controller SPEC §12.2 checkpoint operations."
  use GRPC.Server, service: Orchard.Cluster.V1.ControllerWorkerRecoveryService.Service

  alias Orchard.Cluster.V1.{WorkerRecoveryKey, WorkerRecoveryMutation, WorkerRecoveryResult}
  alias Orchard.RuntimeEndpoint.WorkerRecoveryWire, as: Wire
  alias Orchard.WorkerRecovery.Checkpoints

  @spec read_worker_recovery_checkpoint(WorkerRecoveryKey.t(), Orchard.GRPCTypes.server_stream()) ::
          WorkerRecoveryResult.t()
  def read_worker_recovery_checkpoint(request, stream) do
    result =
      with {:ok, certificate} <- certificate(stream),
           {:ok, key} <- Wire.key(request),
           do: Checkpoints.read(key, certificate)

    Wire.result(result)
  end

  @spec commit_worker_recovery_checkpoint(
          WorkerRecoveryMutation.t(),
          Orchard.GRPCTypes.server_stream()
        ) :: WorkerRecoveryResult.t()
  def commit_worker_recovery_checkpoint(request, stream) do
    result =
      with {:ok, certificate} <- certificate(stream),
           {:ok, key} <- Wire.key(request.key),
           {:ok, record} <- Wire.decode_record(request.record_json) do
        Checkpoints.commit(
          key,
          empty_epoch(request.expected_epoch),
          request.expected_revision,
          request.transition_id,
          record,
          certificate
        )
      end

    Wire.result(result)
  end

  defp certificate(%GRPC.Server.Stream{adapter: adapter, payload: payload}) do
    case adapter.get_cert(payload) do
      certificate when is_binary(certificate) -> {:ok, certificate}
      _missing -> {:error, :permission_denied}
    end
  end

  defp empty_epoch(""), do: nil
  defp empty_epoch(epoch), do: epoch
end
