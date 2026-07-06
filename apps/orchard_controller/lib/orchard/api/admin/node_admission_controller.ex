defmodule Orchard.API.Admin.NodeAdmissionController do
  @moduledoc """
  Admin API endpoints for node admission review and execution.
  """

  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.Admin.NodeAdmissionPresenter
  alias Orchard.API.AdminErrorHelpers
  alias Orchard.ClusterManagement.ActionPreviewBuilder
  alias Orchard.ControlPlane
  alias Orchard.Nodes

  @reserved_request_metadata_keys MapSet.new([
                                    "admission_category",
                                    "audit_log_id",
                                    "candidate_id",
                                    "compatibility_evidence",
                                    "decided_at",
                                    "decision",
                                    "dry_run",
                                    "endpoint",
                                    "endpoint_target",
                                    "endpoint_transport",
                                    "id",
                                    "inserted_at",
                                    "inventory",
                                    "last_observed_at",
                                    "node_id",
                                    "observed_identity",
                                    "source",
                                    "target_ref",
                                    "updated_at"
                                  ])

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, NodeAdmissionPresenter.list_candidates(Nodes.list_admission_candidates()))
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"candidate_id" => candidate_id}) do
    case Nodes.fetch_admission_candidate(candidate_id) do
      {:ok, candidate} ->
        json(conn, NodeAdmissionPresenter.candidate(candidate))

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  @spec reject(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def reject(conn, %{"candidate_id" => candidate_id}) do
    attrs = request_attrs(conn)

    if dry_run?(conn) do
      json(
        conn,
        NodeAdmissionPresenter.action_preview(
          ActionPreviewBuilder.reject_admission(candidate_id, attrs)
        )
      )
    else
      with :ok <- ControlPlane.authorize_write_path(:node_admission),
           {:ok, result} <-
             Nodes.reject_admission_candidate(candidate_id, attrs, audit_opts(conn)) do
        json(conn, NodeAdmissionPresenter.reject_result(result))
      else
        {:error, reason} -> send_error(conn, reason)
      end
    end
  end

  @spec clear_rejection(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def clear_rejection(conn, %{"candidate_id" => candidate_id}) do
    with :ok <- ControlPlane.authorize_write_path(:node_admission),
         {:ok, result} <-
           Nodes.clear_admission_candidate_rejection(
             candidate_id,
             request_attrs(conn),
             audit_opts(conn)
           ) do
      json(conn, NodeAdmissionPresenter.clear_rejection_result(result))
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  @spec admit(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def admit(conn, %{"node_id" => node_id}) do
    attrs = request_attrs(conn)

    if dry_run?(conn) do
      json(
        conn,
        NodeAdmissionPresenter.action_preview(ActionPreviewBuilder.admit_node(node_id, attrs))
      )
    else
      with :ok <- ControlPlane.authorize_write_path(:node_admission),
           {:ok, result} <- Nodes.admit_node(node_id, attrs, audit_opts(conn)) do
        json(conn, NodeAdmissionPresenter.admit_result(result))
      else
        {:error, reason} -> send_error(conn, reason)
      end
    end
  end

  defp dry_run?(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: false

  defp dry_run?(%Plug.Conn{body_params: body_params}) when is_map(body_params) do
    Map.get(body_params, "dry_run") in [true, "true"]
  end

  defp dry_run?(_conn), do: false

  defp audit_opts(conn) do
    [
      actor_type: "operator",
      actor_id: conn.assigns[:service_account_id] || conn.assigns[:principal_id]
    ]
  end

  defp request_attrs(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: %{}

  defp request_attrs(%Plug.Conn{body_params: body_params}) when is_map(body_params) do
    Map.reject(body_params, fn {key, _value} ->
      MapSet.member?(@reserved_request_metadata_keys, key)
    end)
  end

  defp request_attrs(_conn), do: %{}

  defp send_error(conn, :candidate_not_found) do
    AdminErrorHelpers.send_error(
      conn,
      :not_found,
      "candidate_not_found",
      "Node admission candidate was not found."
    )
  end

  defp send_error(conn, :node_not_found) do
    AdminErrorHelpers.send_error(conn, :not_found, "node_not_found", "Node was not found.")
  end

  defp send_error(conn, :reason_required) do
    AdminErrorHelpers.send_error(
      conn,
      :bad_request,
      "reason_required",
      "A nonblank rejection reason is required."
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

  defp send_error(conn, reason)
       when reason in [
              :admission_not_pending,
              :admission_not_rejected,
              :admission_rejected,
              :node_not_registered,
              :node_not_pending_admission,
              :inventory_missing,
              :trust_not_established,
              :pool_required,
              :policy_required
            ] do
    reason = Atom.to_string(reason)
    AdminErrorHelpers.send_error(conn, :conflict, reason, conflict_message(reason))
  end

  defp send_error(conn, _reason) do
    AdminErrorHelpers.send_error(
      conn,
      :internal_server_error,
      "admin_api_error",
      "Admin API request failed."
    )
  end

  defp conflict_message("admission_not_pending"), do: "Admission is not pending."
  defp conflict_message("admission_not_rejected"), do: "Admission is not rejected."
  defp conflict_message("admission_rejected"), do: "Admission rejection must be cleared first."
  defp conflict_message("node_not_registered"), do: "Node is not registered."
  defp conflict_message("node_not_pending_admission"), do: "Node is not pending admission."
  defp conflict_message("inventory_missing"), do: "Registered node inventory is missing."
  defp conflict_message("trust_not_established"), do: "Node trust evidence is required."
  defp conflict_message("pool_required"), do: "Node pool assignment is required."
  defp conflict_message("policy_required"), do: "Required policy inputs are missing."
end
