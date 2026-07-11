defmodule Orchard.RuntimeEndpoint.GrpcMTLS do
  @moduledoc """
  Builds certificate-backed gRPC client state for trusted inventory targets.
  """

  alias Orchard.NodeTrust
  alias Orchard.RuntimeEndpoint.{AuthenticatedPeer, Target}
  alias Orchard.TransportTLS.PeerVerifier

  @type connection_security ::
          :plaintext_compatibility
          | {:mutual_tls, GRPC.Credential.t(), AuthenticatedPeer.t()}

  @spec for_target(Target.t()) ::
          {:ok, connection_security()} | {:error, :runtime_endpoint_identity_invalid}
  def for_target(%Target{} = target) do
    if trusted_inventory_target?(target) do
      trusted_target_security(target)
    else
      {:ok, :plaintext_compatibility}
    end
  end

  defp trusted_target_security(target) do
    with {:ok, controller} <- NodeTrust.runtime_client_generation_paths(),
         {:ok, binding} <- target_binding(target, controller),
         credential <- credential(controller, binding) do
      {:ok, {:mutual_tls, credential, authenticated_peer(binding)}}
    else
      _other -> {:error, :runtime_endpoint_identity_invalid}
    end
  end

  defp target_binding(%Target{node_id: node_id, metadata: metadata}, controller) do
    enrollment_id = value(metadata, :enrollment_id)
    certificate_identifier = value(metadata, :certificate_identifier)
    certificate_serial = value(metadata, :certificate_serial)
    certificate_fingerprint = value(metadata, :certificate_fingerprint)
    node_uri_san = value(metadata, :node_uri_san)
    runtime_trust_spki_sha256 = value(metadata, :runtime_trust_spki_sha256)
    expected_node_uri = "urn:orchard:cluster:#{controller.cluster_id}:node:#{node_id}"

    valid =
      valid_uuid?(node_id) and
        valid_uuid?(enrollment_id) and
        node_uri_san == expected_node_uri and
        runtime_trust_spki_sha256 == controller.runtime_trust_spki_sha256 and
        Enum.all?(
          [certificate_identifier, certificate_serial, certificate_fingerprint],
          &non_empty?/1
        )

    if valid do
      {:ok,
       %{
         node_id: node_id,
         node_uri_san: node_uri_san,
         enrollment_id: enrollment_id,
         certificate_identifier: certificate_identifier,
         certificate_serial: certificate_serial,
         certificate_fingerprint: certificate_fingerprint,
         runtime_trust_spki_sha256: runtime_trust_spki_sha256
       }}
    else
      {:error, :runtime_endpoint_identity_invalid}
    end
  end

  defp credential(controller, binding) do
    GRPC.Credential.new(
      ssl: [
        certfile: controller.certfile,
        keyfile: controller.keyfile,
        cacertfile: controller.cacertfile,
        verify: :verify_peer,
        server_name_indication: :disable,
        verify_fun:
          PeerVerifier.new(binding.node_uri_san,
            serial: binding.certificate_serial,
            fingerprint: binding.certificate_fingerprint
          )
      ]
    )
  end

  defp authenticated_peer(binding) do
    struct!(AuthenticatedPeer, Map.put(binding, :scheme, :mtls))
  end

  defp trusted_inventory_target?(%Target{metadata: metadata}) do
    value(metadata, :source) in [:trusted_node_inventory, "trusted_node_inventory"]
  end

  defp value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp value(_metadata, _key), do: nil

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))
  defp non_empty?(value), do: is_binary(value) and value != ""
end
