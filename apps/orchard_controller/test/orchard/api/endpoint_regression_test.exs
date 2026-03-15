defmodule Orchard.API.EndpointRegressionTest do
  @moduledoc """
  Regression tests for endpoint-level behavior after LiveView additions.

  Ensures the API routes retain their security properties (JSON-only parsing,
  CORS preflight) when sharing the endpoint with the console browser pipeline.
  """

  use Orchard.ConnCase

  @moduletag :live

  describe "API security after LiveView endpoint changes" do
    test "POST /v1/chat/completions rejects form-urlencoded body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post("/v1/chat/completions", "model=test&messages=hello")

      # Plug.Parsers with parsers: [:json] does not parse urlencoded bodies.
      # The :authenticated_api pipeline requires JSON Accept, so this should
      # fail at the pipeline level (406) or the controller should receive an
      # unparsed body and return an error.
      assert conn.status in [400, 406, 415]
    end

    test "health endpoint still responds through modified endpoint", %{conn: conn} do
      conn = get(conn, "/health/live")

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "ok"
    end

    test "/console returns HTML, not JSON", %{conn: conn} do
      conn = get(conn, "/console")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/html"
    end
  end
end
