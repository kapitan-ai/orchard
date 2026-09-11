defmodule Orchard.API.Ops.RequestRetriesController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.AdminErrorHelpers
  alias Orchard.ControlPlane
  alias Orchard.Requests.OperatorRetry

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"id" => request_id}) do
    with :ok <- ControlPlane.authorize_write_path(:operator_request_retry),
         {:ok, request} <- OperatorRetry.retry(request_id) do
      conn
      |> put_status(:created)
      |> json(%{
        id: request.public_id,
        object: "request",
        retry_of_request_id: request.retry_of_request_id,
        state: Atom.to_string(request.state)
      })
    else
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp send_error(conn, :request_not_found) do
    AdminErrorHelpers.send_error(conn, :not_found, "request_not_found", "Request was not found.")
  end

  defp send_error(conn, :retry_source_not_eligible) do
    AdminErrorHelpers.send_error(
      conn,
      :conflict,
      "retry_source_not_eligible",
      "Request is not eligible for operator retry."
    )
  end

  defp send_error(conn, :retry_source_unavailable) do
    AdminErrorHelpers.send_error(
      conn,
      :unprocessable_entity,
      "retry_source_unavailable",
      "Retry source canonical request is unavailable."
    )
  end

  defp send_error(conn, :operator_retry_limit_reached) do
    AdminErrorHelpers.send_error(
      conn,
      :conflict,
      "operator_retry_limit_reached",
      "The original Request has reached the operator retry limit."
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
end
