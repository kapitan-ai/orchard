defmodule Orchard.API.SentryRequestContextTest do
  use ExUnit.Case, async: true

  alias Orchard.API.SentryRequestContext

  setup do
    Sentry.Context.clear_all()
    on_exit(&Sentry.Context.clear_all/0)
  end

  test "collects only the normalized HTTP method" do
    conn =
      :post
      |> Plug.Test.conn(
        "/v1/responses?api_key=ISSUE114_QUERY_SECRET",
        Jason.encode!(%{
          instructions: "ISSUE114_BODY_SECRET",
          tools: [%{name: "ISSUE114_TOOL_SECRET"}]
        })
      )
      |> Plug.Conn.put_req_header("authorization", "Bearer ISSUE114_HEADER_SECRET")
      |> Plug.Conn.put_req_header("cookie", "session=ISSUE114_COOKIE_SECRET")

    returned_conn = SentryRequestContext.call(conn, SentryRequestContext.init([]))

    assert returned_conn == conn
    assert Sentry.Context.get_all().request == %{method: "POST"}
    assert %Plug.Conn.Unfetched{aspect: :query_params} = returned_conn.query_params
    assert %Plug.Conn.Unfetched{aspect: :cookies} = returned_conn.req_cookies

    refute inspect(Sentry.Context.get_all()) =~ "ISSUE114"
  end

  test "does not collect a malformed HTTP method" do
    conn = %{Plug.Test.conn(:get, "/health/live") | method: "GET\r\nx-secret: value"}

    _returned_conn = SentryRequestContext.call(conn, SentryRequestContext.init([]))

    assert Sentry.Context.get_all().request == %{}
  end
end
