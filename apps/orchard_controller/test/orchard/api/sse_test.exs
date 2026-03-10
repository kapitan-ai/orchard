defmodule Orchard.API.SSETest do
  use ExUnit.Case, async: true

  alias Orchard.API.SSE

  # SSE tests use a real chunked connection through the test adapter.
  # We build a minimal Plug pipeline that delegates to a test function
  # stored in the process dictionary, then assert on the raw response.

  defmodule SSEPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      # Read the test scenario from a query param
      conn = fetch_query_params(conn)
      scenario = conn.params["scenario"]

      case scenario do
        "normal_stream" ->
          {:ok, conn} = SSE.start(conn)
          {:ok, conn} = SSE.send_chunk(conn, %{object: "chat.completion.chunk", id: "1"})
          {:ok, conn} = SSE.send_chunk(conn, %{object: "chat.completion.chunk", id: "2"})
          {:ok, conn} = SSE.send_done(conn)
          conn

        "error_after_start" ->
          {:ok, conn} = SSE.start(conn)
          {:ok, conn} = SSE.send_chunk(conn, %{object: "chat.completion.chunk", id: "1"})

          {:ok, conn} =
            SSE.send_error(conn, "Generation failed", "server_error", code: "internal_error")

          conn

        "empty_stream" ->
          {:ok, conn} = SSE.start(conn)
          {:ok, conn} = SSE.send_done(conn)
          conn
      end
    end
  end

  setup do
    conn = Plug.Test.conn(:get, "/sse")
    {:ok, conn: conn}
  end

  describe "normal streaming" do
    test "emits data chunks followed by [DONE]", %{conn: conn} do
      conn = %{conn | query_string: "scenario=normal_stream"}
      conn = SSEPlug.call(conn, [])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]

      body = collect_chunked_body(conn)
      lines = String.split(body, "\n", trim: true)

      assert length(lines) == 3
      assert Enum.at(lines, 0) |> String.starts_with?("data: ")
      assert Enum.at(lines, 1) |> String.starts_with?("data: ")
      assert Enum.at(lines, 2) == "data: [DONE]"

      # Verify JSON structure of data chunks
      chunk_1 = lines |> Enum.at(0) |> parse_sse_data()
      assert chunk_1["object"] == "chat.completion.chunk"
      assert chunk_1["id"] == "1"

      chunk_2 = lines |> Enum.at(1) |> parse_sse_data()
      assert chunk_2["id"] == "2"
    end
  end

  describe "error after stream start" do
    test "emits error envelope without [DONE]", %{conn: conn} do
      conn = %{conn | query_string: "scenario=error_after_start"}
      conn = SSEPlug.call(conn, [])

      assert conn.status == 200

      body = collect_chunked_body(conn)
      lines = String.split(body, "\n", trim: true)

      # Should have: one data chunk + one error chunk, no [DONE]
      assert length(lines) == 2
      refute Enum.any?(lines, &(&1 == "data: [DONE]"))

      error_line = Enum.at(lines, 1)
      error_data = parse_sse_data(error_line)
      assert error_data["error"]["message"] == "Generation failed"
      assert error_data["error"]["type"] == "server_error"
      assert error_data["error"]["code"] == "internal_error"
      assert error_data["error"]["param"] == nil
    end
  end

  describe "empty stream" do
    test "emits only [DONE] for an empty result", %{conn: conn} do
      conn = %{conn | query_string: "scenario=empty_stream"}
      conn = SSEPlug.call(conn, [])

      body = collect_chunked_body(conn)
      lines = String.split(body, "\n", trim: true)

      assert lines == ["data: [DONE]"]
    end
  end

  # -- Helpers --

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end

  defp collect_chunked_body(conn) do
    conn.resp_body
    |> case do
      body when is_binary(body) -> body
      nil -> ""
    end
  end

  defp parse_sse_data("data: " <> json) do
    Jason.decode!(json)
  end
end
