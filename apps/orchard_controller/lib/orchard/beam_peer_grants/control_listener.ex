defmodule Orchard.BeamPeerGrants.ControlListener do
  @moduledoc """
  Starts the explicit mTLS-only Controller grant control listener.
  """

  alias Orchard.BeamPeerGrants.ControlEndpoint
  alias Orchard.NodeTrust
  alias Orchard.RuntimeEndpoint.BeamNodeName
  alias Orchard.TransportTLS.CertificateIdentity

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    case server_options(opts) do
      {:ok, server_options} -> GRPC.Server.Supervisor.start_link(server_options)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec server_options(keyword()) :: {:ok, keyword()} | {:error, atom()}
  def server_options(opts) when is_list(opts) do
    with {:ok, ip} <- listen_ipv4(Keyword.get(opts, :host), opts),
         {:ok, port} <- port(Keyword.get(opts, :port)),
         {:ok, identity} <- NodeTrust.peer_grant_runtime_generation_paths(),
         {:ok, certificate_pem} <- File.read(identity.certfile),
         {:ok, certificate} <- CertificateIdentity.from_pem(certificate_pem),
         true <- listener_certificate?(certificate) do
      credential =
        GRPC.Credential.new(
          ssl: [
            certfile: identity.certfile,
            keyfile: identity.keyfile,
            cacertfile: identity.cacertfile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true,
            versions: [:"tlsv1.3"]
          ]
        )

      {:ok,
       [
         endpoint: ControlEndpoint,
         port: port,
         start_server: true,
         adapter_opts: [ip: ip, cred: credential]
       ]}
    else
      {:error, :beam_controller_identity_upgrade_required} = error -> error
      _other -> {:error, :beam_peer_grant_control_configuration_invalid}
    end
  end

  defp listen_ipv4("127.0.0.1", opts) do
    if test_loopback_allowed?(opts) do
      {:ok, {127, 0, 0, 1}}
    else
      {:error, :invalid_private_ipv4}
    end
  end

  defp listen_ipv4(host, _opts), do: private_ipv4(host)

  defp test_loopback_allowed?(opts) do
    Keyword.get(opts, :allow_test_loopback, false) and Code.ensure_loaded?(Mix) and
      Mix.env() == :test
  end

  defp private_ipv4(host) when is_binary(host) do
    with {:ok, ip} <- BeamNodeName.private_ipv4(host) do
      {:ok, ip}
    else
      _other -> {:error, :invalid_private_ipv4}
    end
  end

  defp private_ipv4(_host), do: {:error, :invalid_private_ipv4}

  defp port(port) when is_integer(port) and port in 1..65_535, do: {:ok, port}
  defp port(_port), do: {:error, :invalid_port}

  defp listener_certificate?(certificate) do
    :server_auth in certificate.extended_key_usages and
      :client_auth in certificate.extended_key_usages
  end
end
