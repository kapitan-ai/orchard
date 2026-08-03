defmodule Orchard.API.Plugs.NoStore do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    put_resp_header(conn, "cache-control", "no-store")
  end
end
