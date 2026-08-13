defmodule Orchard.Portal.TransportGuard do
  @moduledoc """
  Returns 404 for every portal route unless public HTTPS is enabled and the
  effective request scheme is HTTPS.
  """

  @behaviour Plug

  import Plug.Conn

  alias Orchard.API.Transport

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if Transport.public_api_https_enabled?() and conn.scheme == :https do
      conn
      |> put_resp_header("cache-control", "no-store")
    else
      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(404, "Not Found")
      |> halt()
    end
  end
end
