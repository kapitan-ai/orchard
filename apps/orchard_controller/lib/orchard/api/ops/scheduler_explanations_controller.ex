defmodule Orchard.API.Ops.SchedulerExplanationsController do
  @moduledoc false

  use Phoenix.Controller

  alias Orchard.API.AdminErrorHelpers
  alias Orchard.API.Ops.SchedulerExplanationPresenter
  alias Orchard.Requests

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"request_id" => request_id}) do
    case Requests.get_request_by_public_id(request_id) do
      nil ->
        send_error(
          conn,
          :not_found,
          "scheduler_explanation_not_found",
          "Scheduler explanation was not found."
        )

      request ->
        render_explanation(conn, request)
    end
  end

  defp render_explanation(conn, request) do
    case SchedulerExplanationPresenter.show(request) do
      {:ok, explanation} ->
        json(conn, explanation)

      {:error, :scheduler_explanation_not_found} ->
        send_error(
          conn,
          :not_found,
          "scheduler_explanation_not_found",
          "Scheduler explanation was not found."
        )

      {:error, reason} ->
        send_error(
          conn,
          :unprocessable_entity,
          "scheduler_explanation_invalid",
          "Persisted scheduler explanation is invalid.",
          details: inspect(reason)
        )
    end
  end

  defp send_error(conn, status, code, message, opts \\ []) do
    AdminErrorHelpers.send_error(conn, status, code, message, opts)
  end
end
