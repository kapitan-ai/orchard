defmodule Orchard.Portal.Auth do
  @moduledoc """
  Portal session token helpers for controller and LiveView.

  The opaque token lives in the existing Phoenix session cookie. Portal code
  never reads `_orchard_console_authenticated`.
  """

  import Plug.Conn

  @session_key "_orchard_portal_token"

  @spec session_token_key() :: String.t()
  def session_token_key, do: @session_key

  @spec session_token(Plug.Conn.t() | map()) :: String.t() | nil
  def session_token(%Plug.Conn{} = conn), do: get_session(conn, @session_key)

  def session_token(session) when is_map(session) do
    Map.get(session, @session_key) || Map.get(session, String.to_atom(@session_key))
  end

  @spec put_session_token(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def put_session_token(%Plug.Conn{} = conn, token) when is_binary(token) do
    put_session(conn, @session_key, token)
  end

  @spec clear_session_token(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_session_token(%Plug.Conn{} = conn) do
    delete_session(conn, @session_key)
  end

  @spec source_ip(Plug.Conn.t()) :: String.t()
  def source_ip(%Plug.Conn{remote_ip: remote_ip}) do
    remote_ip
    |> :inet.ntoa()
    |> to_string()
  end
end
