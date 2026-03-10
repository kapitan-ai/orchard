defmodule Orchard.API.ChatCompletionsController do
  @moduledoc """
  OpenAI-compatible chat completions.

  Stub — full implementation in A2.
  """

  use Phoenix.Controller, formats: [:json]

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    conn
    |> put_status(:not_implemented)
    |> json(%{
      error: %{
        message: "Not implemented yet",
        type: "api_error",
        param: nil,
        code: "not_implemented"
      }
    })
  end
end
