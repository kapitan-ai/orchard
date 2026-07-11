defmodule Orchard.API.Bootstrap.NodeEnrollmentController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.NodeEnrollments

  @spec redeem(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redeem(conn, %{"id" => enrollment_id} = params) do
    case NodeEnrollments.redeem(enrollment_id, params, surface: "bootstrap_https") do
      {:ok, response} ->
        conn
        |> put_status(:ok)
        |> json(response)

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  defp send_error(conn, reason)
       when reason in [
              :enrollment_not_found,
              :invalid_node_csr,
              :node_enrollment_rejected
            ] do
    conn
    |> put_status(:unauthorized)
    |> json(%{
      "error" => %{
        "code" => "node_enrollment_rejected",
        "message" => "Node Enrollment redemption was rejected."
      }
    })
  end

  defp send_error(conn, reason)
       when reason in [:controller_standby, :controller_leadership_unproven] do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      "error" => %{
        "code" => Atom.to_string(reason),
        "message" => "The Controller cannot accept enrollment mutations."
      }
    })
  end

  defp send_error(conn, _reason) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{
      "error" => %{
        "code" => "node_enrollment_failed",
        "message" => "Node Enrollment redemption failed."
      }
    })
  end
end
