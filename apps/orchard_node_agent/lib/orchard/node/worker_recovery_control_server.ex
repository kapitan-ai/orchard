defmodule Orchard.Node.WorkerRecoveryControlServer do
  @moduledoc "Certificate-bound Controller-to-Node recovery control (SPEC §12.2)."
  use GRPC.Server, service: Orchard.Cluster.V1.NodeWorkerRecoveryService.Service

  alias Orchard.Cluster.V1.{WorkerRecoveryCommand, WorkerRecoveryKey, WorkerRecoveryResult}
  alias Orchard.Node.{ModelManager, RuntimeTLS}
  alias Orchard.RuntimeEndpoint.WorkerRecoveryWire, as: Wire
  alias Orchard.TransportTLS.CertificateIdentity

  @doc "Inspects an exact placement only after authenticating the registered Controller."
  @spec inspect_worker_recovery_placement(
          WorkerRecoveryKey.t(),
          Orchard.GRPCTypes.server_stream()
        ) ::
          WorkerRecoveryResult.t()
  def inspect_worker_recovery_placement(request, stream) do
    result =
      with {:ok, node_id} <- authenticate(stream),
           {:ok, key} <- bound_key(request, node_id) do
        manager().inspect_worker_recovery(key.model_id, key.version)
      end

    Wire.evidence_result(result)
  end

  @doc "Forwards a dedicated recovery command without changing its epoch or revision."
  @spec recover_worker_placement(WorkerRecoveryCommand.t(), Orchard.GRPCTypes.server_stream()) ::
          WorkerRecoveryResult.t()
  def recover_worker_placement(request, stream) do
    result =
      with {:ok, node_id} <- authenticate(stream),
           {:ok, key} <- bound_key(request.key, node_id),
           {:ok, command} <- command(request, key, node_id) do
        manager().recover_worker_placement(command)
      end

    Wire.evidence_result(result)
  end

  defp command(request, key, node_id) do
    command = %{
      key: key,
      expected_epoch: request.expected_epoch,
      expected_revision: request.expected_revision,
      command_id: request.command_id,
      action: request.action,
      reason: request.reason,
      load_request: request.load_request
    }

    Orchard.Node.WorkerRecoveryCommand.validate(command, node_id)
  end

  defp bound_key(request, node_id) do
    with {:ok, key} <- Wire.key(request),
         true <- key.node_id == node_id do
      if Enum.all?(Map.values(key), &(String.trim(&1) != "")),
        do: {:ok, key},
        else: {:error, :invalid_key}
    else
      false -> {:error, :permission_denied}
      error -> error
    end
  end

  defp authenticate(%GRPC.Server.Stream{adapter: adapter, payload: payload}) do
    with {:ok, identity} <- registered_identity(),
         true <- identity.node_id == Orchard.Node.node_id(),
         der when is_binary(der) <- adapter.get_cert(payload),
         {:ok, certificate} <- CertificateIdentity.from_der(der),
         true <- certificate.uri_sans == [identity.controller_uri_san],
         true <- "serial:#{certificate.serial}" == identity.controller_certificate_identifier,
         true <- certificate.fingerprint == identity.controller_certificate_fingerprint do
      {:ok, identity.node_id}
    else
      _ -> {:error, :permission_denied}
    end
  end

  defp authenticate(_), do: {:error, :permission_denied}

  defp registered_identity do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    case Keyword.get(runtime, :runtime_tls_identity) do
      %{controller_certificate_fingerprint: fingerprint} = identity
      when is_binary(fingerprint) and fingerprint != "" ->
        {:ok, identity}

      _ ->
        RuntimeTLS.load_registered_identity(Keyword.get(runtime, :node_identity_root),
          require_controller_certificate: true
        )
    end
  end

  if Mix.env() == :test do
    defp manager,
      do: Application.get_env(:orchard_node_agent, :worker_recovery_control_manager, ModelManager)
  else
    defp manager, do: ModelManager
  end
end
