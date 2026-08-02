defmodule Orchard.API.HealthController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.HealthEvaluation

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    {status, body} = HealthEvaluation.evaluate() |> HealthEvaluation.public_response()

    conn
    |> put_status(status)
    |> json(body)
  end
end
