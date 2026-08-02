defmodule Orchard.API.Ops.HealthController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.OperatorHealth

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    {status, body} = OperatorHealth.evaluate()

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(status)
    |> json(body)
  end
end
