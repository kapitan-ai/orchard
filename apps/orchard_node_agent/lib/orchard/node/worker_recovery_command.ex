defmodule Orchard.Node.WorkerRecoveryCommand do
  @moduledoc "Exact-placement recovery command validation and replay identity (SPEC §12.2)."
  alias Orchard.Cluster.V1.EnsureModelLoadedRequest
  alias Orchard.RuntimeEndpoint.WorkerRecoveryCheckpoint

  @spec validate(term(), String.t() | nil) :: {:ok, map()} | {:error, :invalid_command}
  def validate(
        %{
          key: %{node_id: node, model_id: model, version: version},
          expected_epoch: epoch,
          expected_revision: revision,
          command_id: id,
          action: action,
          reason: reason
        } = command,
        node_id
      ) do
    if valid_key?(node, model, version, node_id) and valid_fence?(epoch, revision, id) and
         valid_action?(action, reason, command) do
      payload =
        Map.take(command, [
          :key,
          :expected_epoch,
          :expected_revision,
          :command_id,
          :action,
          :reason
        ])

      load_identity =
        case Map.get(command, :load_request) do
          %EnsureModelLoadedRequest{} = request ->
            request
            |> Map.from_struct()
            |> Map.drop([:deadline_unix_ms, :__unknown_fields__])
            |> WorkerRecoveryCheckpoint.fingerprint()

          _ ->
            nil
        end

      payload = Map.put(payload, :load_identity, load_identity)
      {:ok, Map.put(command, :fingerprint, WorkerRecoveryCheckpoint.fingerprint(payload))}
    else
      {:error, :invalid_command}
    end
  end

  def validate(_, _), do: {:error, :invalid_command}

  defp valid_key?(node, model, version, node_id),
    do: node == node_id and token?(node, 256) and token?(model, 256) and token?(version, 256)

  defp valid_fence?(epoch, revision, id),
    do: token?(epoch, 128) and is_integer(revision) and revision >= 0 and token?(id, 128)

  defp valid_action?(action, reason, command),
    do: token?(reason, 512) and action in ["clear", "unload", "reload"] and valid_load?(command)

  @spec active?(map() | nil) :: boolean()
  def active?(%{"phase" => phase}), do: phase != "completed"
  def active?(_), do: false

  defp valid_load?(%{
         action: "reload",
         key: key,
         load_request: %EnsureModelLoadedRequest{} = request
       }) do
    {request.node_id, request.model_id, request.version} ==
      {key.node_id, key.model_id, key.version}
  end

  defp valid_load?(%{action: "reload"}), do: false
  defp valid_load?(_), do: true

  defp token?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.trim(value) != ""
end
