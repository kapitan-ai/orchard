defmodule Orchard.Cluster.V1.RetrieveBeamPeerGrantRequest do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.RetrieveBeamPeerGrantRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:grant_id, 1, type: :string, json_name: "grantId")
  field(:generation, 2, type: :uint64)
  field(:controller_id, 3, type: :string, json_name: "controllerId")
end

defmodule Orchard.Cluster.V1.RetrieveBeamPeerGrantResponse do
  @moduledoc false

  use Protobuf,
    full_name: "cluster.v1.RetrieveBeamPeerGrantResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field(:grant_id, 1, type: :string, json_name: "grantId")
  field(:cluster_id, 2, type: :string, json_name: "clusterId")
  field(:controller_id, 3, type: :string, json_name: "controllerId")
  field(:controller_beam_name, 4, type: :string, json_name: "controllerBeamName")

  field(:controller_certificate_identifier, 5,
    type: :string,
    json_name: "controllerCertificateIdentifier"
  )

  field(:controller_certificate_fingerprint_sha256, 6,
    type: :string,
    json_name: "controllerCertificateFingerprintSha256"
  )

  field(:beam_authorization_root_id, 7, type: :string, json_name: "beamAuthorizationRootId")
  field(:node_id, 8, type: :string, json_name: "nodeId")
  field(:node_beam_name, 9, type: :string, json_name: "nodeBeamName")
  field(:node_certificate_identifier, 10, type: :string, json_name: "nodeCertificateIdentifier")

  field(:node_certificate_fingerprint_sha256, 11,
    type: :string,
    json_name: "nodeCertificateFingerprintSha256"
  )

  field(:contract_version, 12, type: :uint32, json_name: "contractVersion")
  field(:purpose, 13, type: :string)
  field(:generation, 14, type: :uint64)
  field(:issued_at, 15, type: :string, json_name: "issuedAt")
  field(:not_before_at, 16, type: :string, json_name: "notBeforeAt")
  field(:cutover_at, 17, type: :string, json_name: "cutoverAt")
  field(:expires_at, 18, type: :string, json_name: "expiresAt")
  field(:encoded_secret, 19, type: :string, json_name: "encodedSecret")
  field(:secret_hash, 20, type: :bytes, json_name: "secretHash")
end

defmodule Orchard.Cluster.V1.ControllerPeerGrantService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "cluster.v1.ControllerPeerGrantService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(
    :RetrieveBeamPeerGrant,
    Orchard.Cluster.V1.RetrieveBeamPeerGrantRequest,
    Orchard.Cluster.V1.RetrieveBeamPeerGrantResponse
  )
end

defmodule Orchard.Cluster.V1.ControllerPeerGrantService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Orchard.Cluster.V1.ControllerPeerGrantService.Service
end
