defmodule Orchard.API.ModelsController do
  @moduledoc """
  OpenAI-compatible model listing.

  Stub — full implementation in A2.
  """

  use Phoenix.Controller, formats: [:json]

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{object: "list", data: []})
  end
end
