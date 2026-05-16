defmodule Orchard.API.CACertController do
  @moduledoc """
  Serves the Orchard-generated CA certificate for LAN client trust.

  `GET /ca.crt` returns the CA PEM file only when:
  1. Endpoint config provides both `ca_certfile` and `ca_cert_metadata_path`.
  2. The metadata file exists and contains `"source": "generated_local_ca"`.
  3. The CA certificate file exists as a regular file.

  All other cases return 404 — the route intentionally does not
  distinguish between misconfiguration and absent certificates.

  This route is outside the `/v1` API pipeline (no JSON `Accept`
  requirement, no CORS needed — direct browser/curl download).
  """

  use Phoenix.Controller

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    with :ok <- validate_transport_cert_source(),
         {:ok, ca_path, meta_path} <- resolve_paths(),
         {:ok, meta} <- read_metadata(meta_path),
         :ok <- validate_source(meta),
         {:ok, pem_data} <- File.read(ca_path) do
      conn
      |> put_resp_content_type("application/x-pem-file")
      |> put_resp_header("content-disposition", ~s(attachment; filename="orchard-ca.crt"))
      |> send_resp(200, pem_data)
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp validate_transport_cert_source do
    if Application.get_env(:orchard_controller, :transport_cert_source) == :generated_local_ca do
      :ok
    else
      :error
    end
  end

  defp resolve_paths do
    endpoint_config =
      Application.get_env(:orchard_controller, Orchard.API.Endpoint, [])

    ca_path = Keyword.get(endpoint_config, :ca_certfile)
    meta_path = Keyword.get(endpoint_config, :ca_cert_metadata_path)

    if is_binary(ca_path) and is_binary(meta_path) do
      {:ok, ca_path, meta_path}
    else
      :error
    end
  end

  defp read_metadata(path) do
    with {:ok, contents} <- File.read(path) do
      Jason.decode(contents)
    end
  end

  defp validate_source(%{"source" => "generated_local_ca"}), do: :ok
  defp validate_source(_), do: :error
end
