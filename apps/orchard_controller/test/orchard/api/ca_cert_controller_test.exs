defmodule Orchard.API.CACertControllerTest do
  use ExUnit.Case, async: false

  alias Orchard.API.Router

  # Save and restore endpoint config around each test
  setup do
    original = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])
    on_exit(fn -> Application.put_env(:orchard_controller, Orchard.API.Endpoint, original) end)

    tmp_dir =
      Path.join(System.tmp_dir!(), "orchard_ca_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir, original_config: original}
  end

  defp put_ca_config(ca_certfile, meta_path) do
    config = Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

    config =
      config
      |> Keyword.put(:ca_certfile, ca_certfile)
      |> Keyword.put(:ca_cert_metadata_path, meta_path)

    Application.put_env(:orchard_controller, Orchard.API.Endpoint, config)
  end

  defp call_router(conn) do
    Router.call(conn, Router.init([]))
  end

  describe "GET /ca.crt" do
    test "returns 404 when no config paths are set" do
      put_ca_config(nil, nil)

      conn =
        Plug.Test.conn(:get, "/ca.crt")
        |> call_router()

      assert conn.status == 404
    end

    test "returns 404 when metadata file does not exist" do
      put_ca_config("/nonexistent/ca.crt", "/nonexistent/meta.json")

      conn =
        Plug.Test.conn(:get, "/ca.crt")
        |> call_router()

      assert conn.status == 404
    end

    test "returns 404 when metadata source is not generated_local_ca", %{tmp_dir: tmp_dir} do
      ca_path = Path.join(tmp_dir, "ca.crt")
      meta_path = Path.join(tmp_dir, "meta.json")

      File.write!(ca_path, "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----")
      File.write!(meta_path, Jason.encode!(%{"source" => "external"}))

      put_ca_config(ca_path, meta_path)

      conn =
        Plug.Test.conn(:get, "/ca.crt")
        |> call_router()

      assert conn.status == 404
    end

    test "returns 404 when CA cert file does not exist but metadata is valid", %{tmp_dir: tmp_dir} do
      ca_path = Path.join(tmp_dir, "ca.crt")
      meta_path = Path.join(tmp_dir, "meta.json")

      # Write metadata but NOT the cert file
      File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))

      put_ca_config(ca_path, meta_path)

      conn =
        Plug.Test.conn(:get, "/ca.crt")
        |> call_router()

      assert conn.status == 404
    end

    test "returns 200 with PEM content when valid generated CA exists", %{tmp_dir: tmp_dir} do
      ca_path = Path.join(tmp_dir, "ca.crt")
      meta_path = Path.join(tmp_dir, "meta.json")

      pem_content = "-----BEGIN CERTIFICATE-----\nMIIBfake...\n-----END CERTIFICATE-----\n"
      File.write!(ca_path, pem_content)
      File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))

      put_ca_config(ca_path, meta_path)

      conn =
        Plug.Test.conn(:get, "/ca.crt")
        |> call_router()

      assert conn.status == 200

      content_type =
        Plug.Conn.get_resp_header(conn, "content-type")
        |> List.first()

      assert content_type =~ "application/x-pem-file"

      disposition =
        Plug.Conn.get_resp_header(conn, "content-disposition")
        |> List.first()

      assert disposition =~ "attachment"
      assert disposition =~ "orchard-ca.crt"

      assert conn.resp_body == pem_content
    end

    test "route works without JSON Accept header", %{tmp_dir: tmp_dir} do
      ca_path = Path.join(tmp_dir, "ca.crt")
      meta_path = Path.join(tmp_dir, "meta.json")

      File.write!(ca_path, "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----")
      File.write!(meta_path, Jason.encode!(%{"source" => "generated_local_ca"}))

      put_ca_config(ca_path, meta_path)

      # Explicitly do NOT set Accept: application/json
      conn =
        Plug.Test.conn(:get, "/ca.crt")
        |> Plug.Conn.put_req_header("accept", "text/html")
        |> call_router()

      assert conn.status == 200
    end
  end
end
