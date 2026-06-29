defmodule Orchard.API.AdminErrorHelpers do
  @moduledoc """
  Stable JSON error envelope for Admin API surfaces.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [put_status: 2]

  @spec send_error(Plug.Conn.t(), atom() | integer(), String.t(), String.t(), keyword()) ::
          Plug.Conn.t()
  def send_error(conn, status, code, message, opts \\ []) do
    error =
      %{code: code, message: message}
      |> maybe_put_details(Keyword.get(opts, :details))

    conn
    |> put_status(status)
    |> json(%{error: error})
  end

  defp maybe_put_details(error, nil), do: error
  defp maybe_put_details(error, details), do: Map.put(error, :details, details)
end
