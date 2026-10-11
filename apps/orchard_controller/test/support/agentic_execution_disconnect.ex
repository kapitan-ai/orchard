defmodule Orchard.TestSupport.AgenticExecutionDisconnect do
  @moduledoc false
  @behaviour Plug.Conn.Adapter

  alias Plug.Adapters.Test.Conn

  @impl true
  defdelegate send_resp(state, status, headers, body), to: Conn
  @impl true
  defdelegate send_file(state, status, headers, path, offset, length), to: Conn
  @impl true
  defdelegate send_chunked(state, status, headers), to: Conn
  @impl true
  defdelegate read_req_body(state, opts), to: Conn
  @impl true
  defdelegate inform(state, status, headers), to: Conn
  @impl true
  defdelegate upgrade(state, protocol, opts), to: Conn
  @impl true
  defdelegate push(state, path, headers), to: Conn
  @impl true
  defdelegate get_peer_data(state), to: Conn
  @impl true
  defdelegate get_sock_data(state), to: Conn
  @impl true
  defdelegate get_ssl_data(state), to: Conn
  @impl true
  defdelegate get_http_protocol(state), to: Conn

  @impl true
  def chunk(state, body) do
    if String.contains?(IO.iodata_to_binary(body), "disconnect-marker"),
      do: {:error, :closed},
      else: Conn.chunk(state, body)
  end
end
