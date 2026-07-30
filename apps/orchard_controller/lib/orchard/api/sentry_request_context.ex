defmodule Orchard.API.SentryRequestContext do
  @moduledoc """
  Adds method-only request context to optional Sentry crash events.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn.method
    |> Orchard.SentryFilter.request_context()
    |> Sentry.Context.set_request_context()

    conn
  end
end
