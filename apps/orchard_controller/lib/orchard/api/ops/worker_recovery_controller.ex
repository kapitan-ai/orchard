defmodule Orchard.API.Ops.WorkerRecoveryController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.AdminErrorHelpers
  alias Orchard.{ControlPlane, Governance, Inference, Repo}
  alias Orchard.Models.Model
  alias Orchard.Nodes.Node
  alias Orchard.RuntimeEndpoint.{ModelRef, Operation}

  @fields ~w(version action expected_epoch expected_revision command_id reason)
  @evidence_fields ~w(key epoch owner_epoch revision state hydrated eligible reason)a

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, params) do
    result =
      with :ok <- ControlPlane.authorize_write_path(:worker_recovery),
           {:ok, target, model} <- resolve(params) do
        forward(target, :inspect_worker_recovery, ModelRef.new!(model.model_id, model.version))
      end

    render_result(conn, result)
  end

  @spec recover(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def recover(conn, params) do
    result =
      with :ok <- ControlPlane.authorize_write_path(:worker_recovery),
           :ok <- validate_body(conn.body_params),
           {:ok, target, model} <-
             resolve(Map.put(params, "version", conn.body_params["version"])),
           command <- command(target.node_id, model, conn.body_params),
           :ok <- audit(conn, command, "accepted") do
        complete(conn, target, command)
      end

    render_result(conn, result)
  end

  defp resolve(%{"node_id" => node_id, "model_id" => model_id, "version" => version}) do
    with {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, model_id} <- Ecto.UUID.cast(model_id),
         true <- bounded?(version, 256),
         %Node{} <- Repo.get(Node, node_id),
         %Model{version: ^version, state: :active} = model <- Repo.get(Model, model_id),
         [target] <- Enum.filter(Inference.runtime_endpoint_targets(), &(&1.node_id == node_id)) do
      {:ok, target, model}
    else
      nil -> {:error, :not_found}
      %Model{} -> {:error, :invalid_command}
      [] -> {:error, :unavailable}
      _invalid -> {:error, :invalid_command}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  defp resolve(_params), do: {:error, :invalid_command}

  defp validate_body(body) when is_map(body) do
    if Enum.sort(Map.keys(body)) == Enum.sort(@fields) and
         body["action"] in ["clear", "unload", "reload"] and
         bounded?(body["version"], 256) and bounded?(body["reason"], 512) and
         bounded?(body["expected_epoch"], 128) and bounded?(body["command_id"], 128) and
         is_integer(body["expected_revision"]) and body["expected_revision"] >= 0 do
      :ok
    else
      {:error, :invalid_command}
    end
  end

  defp validate_body(_body), do: {:error, :invalid_command}

  defp bounded?(value, max) do
    is_binary(value) and byte_size(value) <= max and String.valid?(value) and
      String.trim(value) != ""
  end

  defp command(node_id, model, body) do
    %{
      key: %{node_id: node_id, model_id: model.model_id, version: model.version},
      expected_epoch: body["expected_epoch"],
      expected_revision: body["expected_revision"],
      command_id: body["command_id"],
      action: body["action"],
      reason: String.trim(body["reason"]),
      load_request: load_request(node_id, model, body["action"])
    }
  end

  defp load_request(node_id, model, "reload") do
    %Operation.EnsureModelLoadedRequest{
      node_id: node_id,
      model_ref: ModelRef.new!(model.model_id, model.version),
      artifact_sha256: model.artifact_sha256,
      artifact_source_uri: model.artifact_source_uri,
      deadline_unix_ms: System.system_time(:millisecond) + Inference.model_load_timeout_ms()
    }
  end

  defp load_request(_node_id, _model, _action), do: nil

  defp complete(conn, target, command) do
    result = forward(target, :recover_worker_placement, command)
    phase = if match?({:ok, _}, result), do: "completed", else: "failed"

    case audit(conn, command, phase) do
      :ok -> result
      error -> error
    end
  end

  defp forward(target, operation, input) do
    client = Inference.runtime_endpoint_client()

    with {:ok, connection} <- client.connect(target) do
      try do
        client
        |> apply(operation, [connection, input, [timeout: Inference.model_load_timeout_ms()]])
        |> validate_evidence(target.node_id, input)
      after
        disconnect_after_operation(client, connection)
      end
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  # Transport cleanup cannot change the acknowledged operation outcome.
  defp disconnect_after_operation(client, connection) do
    client.disconnect(connection)
  catch
    _kind, _reason -> :ok
  end

  defp validate_evidence(result, node_id, %ModelRef{} = ref) do
    validate_evidence(result, node_id, %{
      key: %{node_id: node_id, model_id: ref.model_id, version: ref.version}
    })
  end

  defp validate_evidence({:ok, evidence}, _node_id, %{key: key}) when is_map(evidence) do
    if evidence[:key] == key and valid_evidence?(evidence) do
      {:ok, Map.take(evidence, @evidence_fields)}
    else
      {:error, :unavailable}
    end
  end

  defp validate_evidence({:error, _reason} = error, _node_id, _input), do: error
  defp validate_evidence(_result, _node_id, _input), do: {:error, :unavailable}

  defp valid_evidence?(evidence) do
    bounded?(evidence[:epoch], 128) and valid_revision?(evidence[:revision]) and
      evidence[:hydrated] == true and is_boolean(evidence[:eligible]) and
      valid_evidence_state?(evidence[:state]) and valid_evidence_reason?(evidence[:reason]) and
      valid_owner_epoch?(evidence[:owner_epoch])
  end

  defp valid_revision?(revision), do: is_integer(revision) and revision >= 0
  defp valid_owner_epoch?(nil), do: true
  defp valid_owner_epoch?(owner_epoch), do: bounded?(owner_epoch, 128)

  defp valid_evidence_state?(state),
    do: state in ~w(armed backoff restarting open recovery_required)

  defp valid_evidence_reason?(nil), do: true

  defp valid_evidence_reason?(reason),
    do:
      reason in ~w(worker_restart_backoff worker_restart_in_progress placement_crash_breaker_open placement_recovery_required)

  defp audit(conn, command, phase) do
    case Governance.insert_cluster_audit_log(%{
           actor_type: "service_account",
           actor_id: conn.assigns[:service_account_id] || conn.assigns[:principal_id],
           action: "worker_recovery.#{phase}",
           target_type: "worker_placement",
           target_id: "#{command.key.node_id}:#{command.key.model_id}:#{command.key.version}",
           occurred_at: DateTime.utc_now(),
           payload: %{
             "node_id" => command.key.node_id,
             "model_id" => command.key.model_id,
             "version" => command.key.version,
             "action" => command.action,
             "reason" => command.reason,
             "command_id" => command.command_id,
             "expected_epoch" => command.expected_epoch,
             "expected_revision" => command.expected_revision
           }
         }) do
      {:ok, _entry} -> :ok
      {:error, _reason} -> {:error, :audit_unavailable}
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :audit_unavailable}
  end

  defp render_result(conn, {:ok, evidence}) when is_map(evidence) do
    json(conn, Map.take(evidence, @evidence_fields))
  end

  defp render_result(conn, {:error, reason}) do
    {status, code, message} = error(reason)
    AdminErrorHelpers.send_error(conn, status, code, message)
  end

  defp error(:conflict),
    do:
      {:conflict, "worker_recovery_conflict",
       "Recovery state changed or conflicts with this command. Inspect status before retrying."}

  defp error(:invalid_command),
    do:
      {:unprocessable_entity, "invalid_worker_recovery_command",
       "An exact catalog version and valid bounded recovery command are required."}

  defp error(:permission_denied),
    do: {:forbidden, "worker_recovery_permission_denied", "Worker recovery is not authorized."}

  defp error(:not_found),
    do: {:not_found, "worker_recovery_target_not_found", "Worker recovery target was not found."}

  defp error(:controller_standby),
    do: {:service_unavailable, "controller_standby", "This controller is in standby mode."}

  defp error(:controller_leadership_unproven),
    do:
      {:service_unavailable, "controller_leadership_unproven",
       "This controller has not proven local leadership."}

  defp error(:audit_unavailable),
    do:
      {:service_unavailable, "worker_recovery_audit_unavailable",
       "Recovery audit is unavailable. Inspect status before retrying."}

  defp error(_reason),
    do:
      {:service_unavailable, "worker_recovery_unavailable",
       "Recovery outcome is unavailable. Inspect status before retrying."}
end
