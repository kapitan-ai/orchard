defmodule Orchard.API.SentryContextBoundary do
  @moduledoc """
  Clears process-local Sentry context around completed Plug requests.
  """

  alias Orchard.SentryContext

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    SentryContext.clear_all()
    SentryContext.apply_cached_license_status(:controller)

    Plug.Conn.register_before_send(conn, fn conn ->
      unless event_stream_response?(conn) do
        SentryContext.clear_all()
      end

      conn
    end)
  end

  defp event_stream_response?(conn) do
    conn
    |> Plug.Conn.get_resp_header("content-type")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end
end
