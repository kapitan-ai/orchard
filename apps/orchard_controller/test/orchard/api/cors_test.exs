defmodule Orchard.API.CORSTest do
  use ExUnit.Case, async: false

  alias Orchard.API.CORS

  # Save and restore full endpoint config around each test
  setup do
    original = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])
    on_exit(fn -> Application.put_env(:orchard_controller, Orchard.API.Endpoint, original) end)
    {:ok, original_config: original}
  end

  defp put_cors_origins(origins) do
    config = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])
    Application.put_env(:orchard_controller, Orchard.API.Endpoint, Keyword.put(config, :cors_origins, origins))
  end

  defp build_conn(method, path, headers) do
    Plug.Test.conn(method, path)
    |> Map.update!(:req_headers, &(&1 ++ headers))
  end

  defp call_cors(conn) do
    CORS.call(conn, CORS.init([]))
  end

  describe "disabled (empty origins)" do
    test "passes through with no CORS headers when origins is empty list" do
      put_cors_origins([])

      conn =
        build_conn(:get, "/v1/models", [{"origin", "http://evil.com"}])
        |> call_cors()

      refute_cors_headers(conn)
      refute conn.halted
    end

    test "passes through with no CORS headers when origins is nil" do
      put_cors_origins(nil)

      conn =
        build_conn(:get, "/v1/models", [{"origin", "http://evil.com"}])
        |> call_cors()

      refute_cors_headers(conn)
      refute conn.halted
    end
  end

  describe "allowed origin (normal request)" do
    test "adds CORS headers for allowed origin" do
      put_cors_origins(["http://trusted.local:3000"])

      conn =
        build_conn(:get, "/v1/models", [{"origin", "http://trusted.local:3000"}])
        |> call_cors()

      assert get_resp_header(conn, "access-control-allow-origin") == ["http://trusted.local:3000"]
      assert get_resp_header(conn, "access-control-expose-headers") == ["x-request-id"]
      refute conn.halted
    end
  end

  describe "allowed origin (preflight)" do
    test "responds 204 and halts on preflight from allowed origin" do
      put_cors_origins(["http://trusted.local:3000"])

      conn =
        build_conn(:options, "/v1/chat/completions", [
          {"origin", "http://trusted.local:3000"},
          {"access-control-request-method", "POST"}
        ])
        |> call_cors()

      assert conn.status == 204
      assert conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == ["http://trusted.local:3000"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET,POST,OPTIONS"]

      allow_headers = get_resp_header(conn, "access-control-allow-headers") |> List.first()
      assert allow_headers =~ "Content-Type"
      assert allow_headers =~ "Authorization"
    end
  end

  describe "disallowed origin" do
    test "no CORS headers for origin not in allowlist" do
      put_cors_origins(["http://trusted.local:3000"])

      conn =
        build_conn(:get, "/v1/models", [{"origin", "http://evil.com"}])
        |> call_cors()

      refute_cors_headers(conn)
      refute conn.halted
    end
  end

  describe "chunked response compatibility" do
    test "CORS headers survive when downstream uses send_chunked" do
      put_cors_origins(["http://trusted.local:3000"])

      conn =
        build_conn(:get, "/v1/chat/completions", [{"origin", "http://trusted.local:3000"}])
        |> call_cors()

      # Simulate what SSE.start does: send_chunked preserves resp_headers
      chunked_conn = Plug.Conn.send_chunked(conn, 200)

      assert get_resp_header(chunked_conn, "access-control-allow-origin") == ["http://trusted.local:3000"]
    end
  end

  # Helpers

  defp get_resp_header(conn, key) do
    for {k, v} <- conn.resp_headers, k == key, do: v
  end

  defp refute_cors_headers(conn) do
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
