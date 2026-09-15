defmodule Orchard.Node.WorkerRecoveryControlListener do
  @moduledoc "Enables certificate-pinned recovery control independently of BEAM runtime transport."
  alias Orchard.Node.RuntimeTLS
  alias Orchard.TransportTLS.PeerVerifier

  @doc "Explicit control enablement never inherits the plaintext compatibility default."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.fetch_env!(:orchard_node_agent, :runtime)[:worker_recovery_control_enabled] ==
      true
  end

  @doc "Requires the registered Controller certificate pin before starting the listener."
  @spec credential!() :: Orchard.GRPCTypes.credential()
  def credential! do
    runtime = Application.fetch_env!(:orchard_node_agent, :runtime)

    case RuntimeTLS.load_registered_identity(runtime[:node_identity_root],
           require_controller_certificate: true
         ) do
      {:ok, identity} ->
        GRPC.Credential.new(
          ssl: [
            certfile: identity.certfile,
            keyfile: identity.keyfile,
            cacertfile: identity.cacertfile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true,
            verify_fun:
              PeerVerifier.new(identity.controller_uri_san,
                fingerprint: identity.controller_certificate_fingerprint
              )
          ]
        )

      {:error, reason} ->
        raise "Worker recovery control requires registered mTLS identity: #{reason}"
    end
  end
end
