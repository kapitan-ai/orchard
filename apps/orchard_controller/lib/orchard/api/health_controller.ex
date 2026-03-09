defmodule Orchard.API.HealthController do
  @moduledoc false

  use Phoenix.Controller, formats: [:json]

  alias Orchard.API.Readiness

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    case Readiness.status() do
      {:ok, checks} ->
        json(conn, %{status: "ok", checks: checks})

      {:error, reason, checks} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "error", reason: Atom.to_string(reason), checks: checks})
    end
  end
end
