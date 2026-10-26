defmodule Orchard.Node.WorkerRecoveryCheckpointClient do
  @moduledoc """
  Node-originated, certificate-authenticated SPEC §12.2 checkpoint client.

  The manager invokes this client in supervised continuations, not its receive
  loop. No local journal or database credential is used.
  """

  alias Orchard.Cluster.V1.ControllerWorkerRecoveryService.Stub
  alias Orchard.Cluster.V1.{WorkerRecoveryKey, WorkerRecoveryMutation, WorkerRecoveryResult}
  alias Orchard.Node.{BeamPeerGrantClient, RuntimeTLS}
  alias Orchard.RuntimeEndpoint.WorkerRecoveryCheckpoint, as: Record
  alias Orchard.RuntimeEndpoint.WorkerRecoveryWire, as: Wire

  @callback read(Record.key()) :: {:ok, map() | :absent} | {:error, term()}
  @callback commit(Record.key(), String.t() | nil, non_neg_integer(), String.t(), Record.t()) ::
              {:ok, map()} | {:error, term()}

  @spec read(Record.key()) :: {:ok, map() | :absent} | {:error, term()}
  def read(key),
    do: request(:read_worker_recovery_checkpoint, struct!(WorkerRecoveryKey, key), key)

  @spec commit(Record.key(), String.t() | nil, non_neg_integer(), String.t(), Record.t()) ::
          {:ok, map()} | {:error, term()}
  def commit(key, epoch, revision, transition, record) do
    request(
      :commit_worker_recovery_checkpoint,
      %WorkerRecoveryMutation{
        key: struct!(WorkerRecoveryKey, key),
        expected_epoch: epoch || "",
        expected_revision: revision,
        transition_id: transition,
        record_json: Jason.encode!(record)
      },
      key
    )
  end

  @spec identity() :: {:ok, RuntimeTLS.identity()} | {:error, atom()}
  def identity do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    case Keyword.get(runtime, :runtime_tls_identity) do
      %{} = identity ->
        {:ok, identity}

      nil ->
        RuntimeTLS.load_registered_identity(Keyword.get(runtime, :node_identity_root),
          require_controller_certificate: true
        )
    end
  end

  defp request(operation, request, key) do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)
    target = Keyword.get(runtime, :worker_recovery_control_endpoint)

    with true <- is_binary(target) and target != "",
         {:ok, identity} <- identity(),
         true <- identity.node_id == key.node_id,
         {:ok, credential} <- BeamPeerGrantClient.client_credential(identity),
         {:ok, channel} <-
           GRPC.Stub.connect(target,
             cred: credential,
             adapter_opts: [transport_opts: [timeout: 5_000]]
           ) do
      try do
        case apply(Stub, operation, [channel, request, [timeout: 5_000]]) do
          {:ok, response} -> decode(response)
          {:error, _reason} -> {:error, :unavailable}
        end
      after
        disconnect_after_operation(channel)
      end
    else
      _unavailable -> {:error, :unavailable}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # Disconnect is cleanup only; it must not replace an acknowledged durable result.
  defp disconnect_after_operation(channel) do
    GRPC.Stub.disconnect(channel)
  catch
    _, _ -> :ok
  end

  defp decode(%WorkerRecoveryResult{status: 200, reason: "absent"}), do: {:ok, :absent}

  defp decode(%WorkerRecoveryResult{status: 200, record_json: json}) do
    with {:ok,
          %{
            "epoch" => epoch,
            "revision" => revision,
            "record" => record,
            "transition_id" => transition
          }} <- Wire.decode_record(json),
         :ok <- Record.validate(record),
         true <- epoch == record["epoch"] and is_integer(revision) and revision > 0 do
      {:ok, %{epoch: epoch, revision: revision, record: record, transition_id: transition}}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  defp decode(%WorkerRecoveryResult{status: 409}), do: {:error, :stale_checkpoint}
  defp decode(_response), do: {:error, :unavailable}
end
