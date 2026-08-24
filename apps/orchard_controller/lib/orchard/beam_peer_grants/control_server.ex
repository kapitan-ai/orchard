defmodule Orchard.BeamPeerGrants.ControlServer do
  @moduledoc """
  Certificate-authenticated control boundary for idempotent grant retrieval.

  The peer certificate is accepted only from the completed gRPC mTLS stream.
  """

  use GRPC.Server, service: Orchard.Cluster.V1.ControllerPeerGrantService.Service

  require Logger

  alias Orchard.BeamPeerGrants
  alias Orchard.Cluster.V1.{RetrieveBeamPeerGrantRequest, RetrieveBeamPeerGrantResponse}

  @opaque_rejection "permission_denied"

  @spec retrieve_beam_peer_grant(
          RetrieveBeamPeerGrantRequest.t(),
          Orchard.GRPCTypes.server_stream()
        ) ::
          RetrieveBeamPeerGrantResponse.t()
  def retrieve_beam_peer_grant(%RetrieveBeamPeerGrantRequest{} = request, stream) do
    with certificate_der when is_binary(certificate_der) <- peer_certificate(stream),
         {:ok, delivery} <-
           BeamPeerGrants.deliver_from_peer_certificate(request_map(request), certificate_der) do
      response(delivery)
    else
      :undefined -> reject(:beam_peer_certificate_missing)
      {:error, reason} -> reject(reason)
      _other -> reject(:beam_peer_credential_mismatch)
    end
  end

  defp peer_certificate(%GRPC.Server.Stream{adapter: adapter, payload: payload}) do
    adapter.get_cert(payload)
  end

  defp request_map(request) do
    %{
      grant_id: request.grant_id,
      generation: request.generation,
      controller_id: request.controller_id
    }
  end

  defp response(delivery) do
    %RetrieveBeamPeerGrantResponse{
      grant_id: delivery.grant_id,
      cluster_id: delivery.cluster_id,
      controller_id: delivery.controller_id,
      controller_beam_name: delivery.controller_beam_name,
      controller_certificate_identifier: delivery.controller_certificate_identifier,
      controller_certificate_fingerprint_sha256:
        delivery.controller_certificate_fingerprint_sha256,
      beam_authorization_root_id: delivery.beam_authorization_root_id,
      node_id: delivery.node_id,
      node_beam_name: delivery.node_beam_name,
      node_certificate_identifier: delivery.node_certificate_identifier,
      node_certificate_fingerprint_sha256: delivery.node_certificate_fingerprint_sha256,
      contract_version: delivery.contract_version,
      purpose: delivery.purpose,
      generation: delivery.generation,
      issued_at: format_datetime(delivery.issued_at),
      not_before_at: format_datetime(delivery.not_before_at),
      cutover_at: format_datetime(delivery.cutover_at),
      expires_at: format_datetime(delivery.expires_at),
      encoded_secret: delivery.encoded_secret,
      secret_hash: delivery.secret_hash
    }
  end

  defp format_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format_datetime(nil), do: ""

  defp reject(reason) do
    Logger.debug("beam peer grant retrieval rejected: #{inspect(reason)}")
    raise GRPC.RPCError, status: :permission_denied, message: @opaque_rejection
  end
end
