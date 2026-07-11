defmodule OrchardCLI.PinnedHTTPS do
  @moduledoc false

  alias OrchardCLI.HTTP

  @connect_timeout 5_000
  @receive_timeout 15_000

  @spec redeem(map(), map()) :: {:ok, map()} | {:error, atom()}
  def redeem(bundle, %{runtime_endpoint: runtime_endpoint} = identity) do
    url =
      bundle.https_endpoint <>
        "/bootstrap/v1/node-enrollments/#{bundle.enrollment_id}/redeem"

    request = [
      method: :post,
      url: url,
      json: %{
        "cluster_id" => bundle.cluster_id,
        "controller_id" => bundle.controller_id,
        "csr_pem" => identity.csr_pem,
        "node_id" => bundle.node_id,
        "runtime_endpoint" => runtime_endpoint,
        "token" => bundle.token
      },
      retry: false,
      redirect: false,
      connect_options: [
        timeout: @connect_timeout,
        transport_opts: tls_options(bundle)
      ]
    ]

    case HTTP.request(request, receive_timeout: @receive_timeout) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} when status in 400..499 ->
        {:error, :node_enrollment_rejected}

      {:ok, %Req.Response{}} ->
        {:error, :node_enrollment_unavailable}

      {:error, _reason} ->
        {:error, :controller_trust_or_connection_failed}
    end
  end

  def redeem(_bundle, _identity), do: {:error, :node_enrollment_rejected}

  defp tls_options(bundle) do
    uri = URI.parse(bundle.https_endpoint)

    [
      verify: :verify_peer,
      cacerts: [bundle.https_trust_anchor_der],
      server_name_indication: String.to_charlist(uri.host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end
end
