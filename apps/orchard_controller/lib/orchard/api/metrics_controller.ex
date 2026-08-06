defmodule Orchard.API.MetricsController do
  @moduledoc false
  use Phoenix.Controller, formats: []

  alias Orchard.Metrics.Renderer

  @unavailable "metrics unavailable\n"

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case render() do
      {:ok, exposition} ->
        conn
        |> put_resp_content_type(Renderer.content_type(), nil)
        |> send_resp(:ok, exposition)

      {:error, :unavailable} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(:service_unavailable, @unavailable)
    end
  end

  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "GET")
    |> put_resp_content_type("text/plain")
    |> send_resp(:method_not_allowed, "method not allowed\n")
  end

  @spec not_found(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def not_found(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(:not_found, "not found\n")
  end

  defp render do
    case renderer().render() do
      {:ok, exposition} when is_binary(exposition) -> {:ok, exposition}
      _result -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    _kind, _reason -> {:error, :unavailable}
  end

  defp renderer do
    Application.get_env(:orchard_controller, :metrics_renderer, Renderer)
  end
end
