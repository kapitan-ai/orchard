defmodule Orchard.API.SentryContextBoundaryTest do
  use ExUnit.Case, async: false

  alias Orchard.API.SentryContextBoundary
  alias Orchard.SentryContext

  setup do
    previous_config = Application.get_env(:orchard_shared, :sentry_enrichment)
    Application.put_env(:orchard_shared, :sentry_enrichment, enabled?: true)
    SentryContext.clear_all()

    on_exit(fn ->
      restore_enrichment(previous_config)
      SentryContext.clear_all()
    end)

    :ok
  end

  test "clears context after completed non-stream responses" do
    conn =
      Plug.Test.conn(:get, "/health/live")
      |> SentryContextBoundary.call([])

    Sentry.Context.set_extra_context(%{orchard_request_id: "req_non_stream"})

    _conn = Plug.Conn.send_resp(conn, 200, "ok")

    assert Sentry.Context.get_all().extra == %{}
  end

  test "keeps context when chunked event-stream starts so controller stream cleanup owns it" do
    conn =
      Plug.Test.conn(:get, "/v1/chat/completions")
      |> SentryContextBoundary.call([])
      |> Plug.Conn.put_resp_content_type("text/event-stream")

    Sentry.Context.set_extra_context(%{orchard_request_id: "req_stream"})

    _conn = Plug.Conn.send_chunked(conn, 200)

    assert Sentry.Context.get_all().extra == %{orchard_request_id: "req_stream"}
  end

  defp restore_enrichment(nil), do: Application.delete_env(:orchard_shared, :sentry_enrichment)

  defp restore_enrichment(config),
    do: Application.put_env(:orchard_shared, :sentry_enrichment, config)
end
