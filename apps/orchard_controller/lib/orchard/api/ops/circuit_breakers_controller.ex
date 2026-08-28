defmodule Orchard.API.Ops.CircuitBreakersController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.AdminErrorHelpers
  alias Orchard.API.Ops.CircuitBreakerPresenter
  alias Orchard.CircuitBreakers
  alias Orchard.ControlPlane
  alias Orchard.Governance

  @spec show_node(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show_node(conn, %{"node_id" => node_id}) do
    inspect_breaker(conn, {:node, node_id})
  end

  @spec show_placement(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show_placement(conn, %{"node_id" => node_id, "model_id" => model_id}) do
    inspect_breaker(conn, {:placement, node_id, model_id})
  end

  @spec clear_node(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def clear_node(conn, %{"node_id" => node_id}) do
    clear(conn, {:node, node_id})
  end

  @spec clear_placement(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def clear_placement(conn, %{"node_id" => node_id, "model_id" => model_id}) do
    clear(conn, {:placement, node_id, model_id})
  end

  defp inspect_breaker(conn, target) do
    result =
      with :ok <- ControlPlane.authorize_write_path(:circuit_breaker_inspection) do
        CircuitBreakers.inspect(target)
      end

    render_inspection(conn, result)
  end

  defp render_inspection(conn, {:ok, decision}) do
    json(conn, CircuitBreakerPresenter.breaker(decision))
  end

  defp render_inspection(conn, {:error, reason}), do: send_error(conn, reason)

  defp clear(conn, target) do
    with {:ok, reason} <- clear_reason(conn),
         {:ok, decision} <-
           CircuitBreakers.clear(target,
             reason: reason,
             audit: &insert_clear_audit(&1, reason, conn)
           ) do
      json(conn, CircuitBreakerPresenter.clear_result(decision))
    else
      {:error, error} -> send_error(conn, error)
    end
  end

  defp clear_reason(%Plug.Conn{body_params: %{"reason" => reason}}) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :clear_reason_required}
      normalized -> {:ok, normalized}
    end
  end

  defp clear_reason(_conn), do: {:error, :clear_reason_required}

  defp insert_clear_audit(decision, reason, conn) do
    result = if decision.changed_state?, do: "cleared", else: "already_cleared"

    Governance.insert_cluster_audit_log(%{
      actor_type: "service_account",
      actor_id: conn.assigns[:service_account_id] || conn.assigns[:principal_id],
      action: clear_action(decision.kind),
      target_type: clear_target_type(decision.kind),
      target_id: clear_target_id(decision),
      occurred_at: decision.decision_at,
      payload: %{
        "result" => result,
        "changed" => decision.changed_state?,
        "reason" => reason,
        "previous_state" => Atom.to_string(decision.previous_state),
        "resulting_generation" => decision.generation,
        "node_id" => decision.node_id,
        "model_id" => decision.model_id
      }
    })
    |> case do
      {:ok, _audit_log} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_action(:node), do: "circuit_breaker.node.cleared"
  defp clear_action(:placement), do: "circuit_breaker.placement.cleared"

  defp clear_target_type(:node), do: "node_circuit_breaker"
  defp clear_target_type(:placement), do: "placement_circuit_breaker"

  defp clear_target_id(%{kind: :node, node_id: node_id}), do: node_id

  defp clear_target_id(%{kind: :placement, node_id: node_id, model_id: model_id}) do
    "#{node_id}:#{model_id}"
  end

  defp send_error(conn, :clear_reason_required) do
    AdminErrorHelpers.send_error(
      conn,
      :unprocessable_entity,
      "circuit_breaker_clear_reason_required",
      "A nonblank circuit-breaker clear reason is required."
    )
  end

  defp send_error(conn, reason)
       when reason in [:node_not_found, :model_not_found, :model_not_active] do
    public_reason = if(reason == :node_not_found, do: :node_not_found, else: :model_not_found)

    AdminErrorHelpers.send_error(
      conn,
      :not_found,
      Atom.to_string(public_reason),
      not_found_message(public_reason)
    )
  end

  defp send_error(conn, reason)
       when reason in [
              :invalid_node_id,
              :invalid_node_identity,
              :invalid_model_id,
              :invalid_model_identity,
              :invalid_target
            ] do
    AdminErrorHelpers.send_error(
      conn,
      :unprocessable_entity,
      "invalid_circuit_breaker_target",
      "Circuit-breaker target identity is invalid."
    )
  end

  defp send_error(conn, :controller_standby) do
    AdminErrorHelpers.send_error(
      conn,
      :service_unavailable,
      "controller_standby",
      "This controller is in standby mode."
    )
  end

  defp send_error(conn, :controller_leadership_unproven) do
    AdminErrorHelpers.send_error(
      conn,
      :service_unavailable,
      "controller_leadership_unproven",
      "This controller has not proven local leadership."
    )
  end

  defp send_error(conn, _reason) do
    AdminErrorHelpers.send_error(
      conn,
      :service_unavailable,
      "circuit_breaker_unavailable",
      "Circuit-breaker state is unavailable."
    )
  end

  defp not_found_message(:node_not_found), do: "Node was not found."
  defp not_found_message(:model_not_found), do: "Model was not found."
end
