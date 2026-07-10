defmodule Orchard.RuntimeEndpoint.AuthenticatedPeer do
  @moduledoc """
  Certificate identity proven by a completed Runtime Endpoint mTLS exchange.
  """

  @enforce_keys [
    :node_id,
    :node_uri_san,
    :enrollment_id,
    :certificate_identifier,
    :certificate_serial,
    :certificate_fingerprint,
    :runtime_trust_spki_sha256
  ]

  defstruct scheme: :mtls,
            node_id: nil,
            node_uri_san: nil,
            enrollment_id: nil,
            certificate_identifier: nil,
            certificate_serial: nil,
            certificate_fingerprint: nil,
            runtime_trust_spki_sha256: nil

  @type t :: %__MODULE__{
          scheme: :mtls,
          node_id: Ecto.UUID.t(),
          node_uri_san: String.t(),
          enrollment_id: Ecto.UUID.t(),
          certificate_identifier: String.t(),
          certificate_serial: String.t(),
          certificate_fingerprint: String.t(),
          runtime_trust_spki_sha256: String.t()
        }
end
