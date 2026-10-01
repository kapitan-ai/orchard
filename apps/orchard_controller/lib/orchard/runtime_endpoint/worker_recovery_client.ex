defmodule Orchard.RuntimeEndpoint.WorkerRecoveryClient do
  @moduledoc "Pinned mTLS recovery control shared by BEAM and gRPC Runtime Endpoint clients."

  alias Orchard.Cluster.V1.{
    NodeWorkerRecoveryService,
    WorkerRecoveryCommand,
    WorkerRecoveryKey,
    WorkerRecoveryResult
  }

  alias Orchard.Dispatch.GrpcNodeRuntimeClient, as: TransportClient
  alias Orchard.Nodes

  alias Orchard.RuntimeEndpoint.{
    GrpcMapping,
    GrpcMTLS,
    ModelRef,
    Operation,
    Target,
    WorkerRecoveryEvidence,
    WorkerRecoveryWire
  }

  @doc "Uses the registered Node control address, never the BEAM caller's asserted identity."
  @spec control_target(Target.t() | Ecto.UUID.t()) :: {:ok, Target.t()} | {:error, atom()}
  def control_target(selector), do: Nodes.worker_recovery_control_target(selector)

  @doc "Makes one authenticated control exchange; uncertain outcomes are never retried."
  @spec call(Target.t(), atom(), ModelRef.t() | map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def call(target, operation, input, opts) do
    with {:ok, target} <- control_target(target),
         {:ok, {:mutual_tls, credential, _peer}} <- GrpcMTLS.for_target(target),
         {:ok, channel} <- TransportClient.connect(target.address, cred: credential) do
      try do
        call_channel(channel, target, operation, input, opts)
      after
        TransportClient.disconnect(channel)
      end
    else
      {:ok, :plaintext_compatibility} -> {:error, :permission_denied}
      {:error, :permission_denied} = error -> error
      {:error, _} -> {:error, :unavailable}
    end
  end

  @doc "Exchanges a command on a channel whose peer has already been pinned by the caller."
  @spec call_channel(
          Orchard.GRPCTypes.channel(),
          Target.t(),
          atom(),
          ModelRef.t() | map(),
          keyword()
        ) ::
          {:ok, map()} | {:error, atom()}
  def call_channel(channel, target, operation, input, opts) do
    with {:ok, request, key} <- request(target, operation, input),
         {:ok, response} <-
           apply(NodeWorkerRecoveryService.Stub, operation, [
             channel,
             request,
             Keyword.take(opts, [:timeout])
           ]) do
      decode_result(response, key)
    else
      {:error, :invalid_command} = error -> error
      {:error, _} -> {:error, :unavailable}
    end
  end

  @doc "Builds exact-key wire input without accepting request flags as authorization."
  @spec request(Target.t(), atom(), term()) :: {:ok, struct(), map()} | {:error, :invalid_command}
  def request(target, :inspect_worker_recovery_placement, %ModelRef{} = ref) do
    key = %{node_id: target.node_id, model_id: ref.model_id, version: ref.version}
    with {:ok, proto} <- proto_key(key), do: {:ok, proto, key}
  end

  def request(target, :recover_worker_placement, %{key: %{node_id: node_id} = key} = command)
      when node_id == target.node_id do
    with {:ok, proto_key} <- proto_key(key),
         true <- valid_command?(command),
         {:ok, load} <- load_request(command, key) do
      {:ok,
       %WorkerRecoveryCommand{
         key: proto_key,
         expected_epoch: command.expected_epoch,
         expected_revision: command.expected_revision,
         command_id: command.command_id,
         action: command.action,
         reason: command.reason,
         load_request: load
       }, key}
    else
      _ -> {:error, :invalid_command}
    end
  end

  def request(_, _, _), do: {:error, :invalid_command}

  @doc "Rejects malformed or cross-key evidence rather than granting legacy eligibility."
  @spec decode_result(WorkerRecoveryResult.t(), map()) :: {:ok, map()} | {:error, atom()}
  def decode_result(%WorkerRecoveryResult{status: 200, record_json: json}, key) do
    with {:ok, evidence} <- WorkerRecoveryEvidence.decode(json),
         true <- evidence.key == key do
      {:ok, evidence}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  def decode_result(%WorkerRecoveryResult{status: 403}, _key), do: {:error, :permission_denied}
  def decode_result(%WorkerRecoveryResult{status: 409}, _key), do: {:error, :conflict}
  def decode_result(%WorkerRecoveryResult{status: 422}, _key), do: {:error, :invalid_command}
  def decode_result(_, _), do: {:error, :unavailable}

  @doc "Decodes admission refusal before any generic model-load failure conversion."
  @spec ensure_result(Orchard.Cluster.V1.EnsureModelLoadedResponse.t()) ::
          {:ok, Operation.EnsureModelLoadedResult.t()} | {:error, term()}
  def ensure_result(%{recovery_refusal: ""} = response),
    do: {:ok, GrpcMapping.ensure_model_loaded_result_from_response(response)}

  def ensure_result(%{recovery_refusal: refusal}) do
    case WorkerRecoveryEvidence.refusal_reason(refusal) do
      {:ok, reason} -> {:error, {:worker_recovery_refused, reason}}
      :error -> {:error, :invalid_worker_recovery_refusal}
    end
  end

  defp valid_command?(command) do
    bounded?(command[:expected_epoch], 128) and bounded?(command[:command_id], 128) and
      bounded?(command[:reason], 512) and is_integer(command[:expected_revision]) and
      command.expected_revision in 0..18_446_744_073_709_551_615 and
      command[:action] in ["clear", "unload", "reload"]
  end

  defp load_request(
         %{action: "reload", load_request: %Operation.EnsureModelLoadedRequest{} = load},
         key
       ) do
    proto = GrpcMapping.ensure_model_loaded_request_to_proto(load)

    if {proto.node_id, proto.model_id, proto.version} == {key.node_id, key.model_id, key.version},
      do: {:ok, proto},
      else: {:error, :invalid_command}
  end

  defp load_request(%{action: "reload"}, _), do: {:error, :invalid_command}
  defp load_request(_, _), do: {:ok, nil}

  defp proto_key(%{node_id: node_id, model_id: model_id, version: version}) do
    key = %WorkerRecoveryKey{node_id: node_id, model_id: model_id, version: version}

    with {:ok, decoded} <- WorkerRecoveryWire.key(key),
         true <- Enum.all?(Map.values(decoded), &bounded?(&1, 256)) do
      {:ok, key}
    else
      _ -> {:error, :invalid_command}
    end
  end

  defp proto_key(_), do: {:error, :invalid_command}

  defp bounded?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.trim(value) != ""
end
