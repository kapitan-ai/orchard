defmodule Orchard.TestSupport.PortalConn do
  @moduledoc false

  alias Orchard.API.Endpoint

  @spec enable_https_proxy!() :: :ok
  def enable_https_proxy! do
    original_mode = Application.get_env(:orchard_controller, :transport_mode)
    original_endpoint = Application.get_env(:orchard_controller, Endpoint, [])

    Application.put_env(:orchard_controller, :transport_mode, :reverse_proxy)

    Application.put_env(
      :orchard_controller,
      Endpoint,
      Keyword.put(original_endpoint, :trusted_proxies, [
        {{127, 0, 0, 1}, 32},
        {{0, 0, 0, 0, 0, 0, 0, 1}, 128}
      ])
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:orchard_controller, :transport_mode, original_mode)
      Application.put_env(:orchard_controller, Endpoint, original_endpoint)
    end)

    :ok
  end

  @spec https_conn(Plug.Conn.t()) :: Plug.Conn.t()
  def https_conn(conn) do
    conn
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.10")
    |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
    |> Plug.Conn.put_req_header("x-forwarded-host", "www.example.com")
    |> Plug.Conn.put_req_header("x-forwarded-port", "443")
  end
end
