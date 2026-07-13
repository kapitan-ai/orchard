defmodule Orchard.Node.BeamPeerGrantPreflight do
  @moduledoc """
  Prepares one admitted Node for exact BEAM Peer Grant Distribution.

  Retrieval runs before Distribution starts and never creates peer-name or
  cookie atoms.
  """

  alias Orchard.BeamPeerGrantDescriptor
  alias Orchard.Node.BeamPeerGrantBootstrap
  alias Orchard.Node.{BeamPeerGrantStore, RuntimeTLS}

  alias Orchard.RuntimeEndpoint.{DistributionLaunch, DistributionTLS}
  alias Orchard.TransportTLS.CertificateIdentity

  @spec retrieve_and_store(keyword()) :: {:ok, map()} | {:error, atom()}
  def retrieve_and_store(opts) when is_list(opts) do
    current_node = Keyword.get(opts, :current_node, Node.self())
    bootstrap = Keyword.get(opts, :bootstrap, BeamPeerGrantBootstrap)

    if current_node == :nonode@nohost do
      opts
      |> Keyword.delete(:current_node)
      |> Keyword.delete(:bootstrap)
      |> Keyword.put(:cookie_installer, __MODULE__.NoopCookieInstaller)
      |> bootstrap.bootstrap()
    else
      {:error, :beam_distribution_preflight_requires_nondistributed_vm}
    end
  rescue
    _error -> {:error, :beam_peer_grant_bootstrap_invalid}
  catch
    _kind, _reason -> {:error, :beam_peer_grant_bootstrap_invalid}
  end

  @spec prepare_distribution(keyword()) :: {:ok, map()} | {:error, atom()}
  def prepare_distribution(opts) when is_list(opts) do
    if Keyword.get(opts, :current_node, Node.self()) == :nonode@nohost do
      prepare_distribution_nondistributed(opts)
    else
      {:error, :beam_distribution_preflight_requires_nondistributed_vm}
    end
  rescue
    _error -> {:error, :beam_distribution_preflight_invalid}
  catch
    _kind, _reason -> {:error, :beam_distribution_preflight_invalid}
  end

  defp prepare_distribution_nondistributed(opts) do
    identity_root = Keyword.get(opts, :identity_root)
    descriptor_path = Keyword.get(opts, :descriptor_path)
    node_beam_name = Keyword.get(opts, :node_beam_name)
    optfile_path = Keyword.get(opts, :optfile_path)
    manifest_path = Keyword.get(opts, :manifest_path)
    identity_loader = Keyword.get(opts, :identity_loader, RuntimeTLS)
    descriptor_loader = Keyword.get(opts, :descriptor_loader, BeamPeerGrantDescriptor)
    grant_store = Keyword.get(opts, :grant_store, BeamPeerGrantStore)
    certificate_identity = Keyword.get(opts, :certificate_identity, CertificateIdentity)
    distribution_tls = Keyword.get(opts, :distribution_tls, DistributionTLS)
    distribution_launch = Keyword.get(opts, :distribution_launch, DistributionLaunch)

    with true <- required_paths?(identity_root, descriptor_path, optfile_path, manifest_path),
         true <- nonempty?(node_beam_name),
         {:ok, identity} <-
           identity_loader.load_registered_identity(identity_root,
             require_controller_certificate: true
           ),
         {:ok, descriptor} <- descriptor_loader.load(descriptor_path),
         :ok <- validate_identity_descriptor(identity, descriptor),
         :ok <- validate_node_name(identity, node_beam_name),
         {:ok, grant} <- grant_store.load(identity_root, identity, node_beam_name),
         :ok <- grant_store.ensure_current(grant),
         :ok <- validate_grant(grant, descriptor, identity, node_beam_name),
         {:ok, local_certificate} <-
           certificate_from_file(certificate_identity, identity.certfile),
         {:ok, peer_certificate} <-
           certificate_from_file(certificate_identity, identity.controller_certfile),
         :ok <- validate_certificates(identity, local_certificate, peer_certificate),
         local = local_tls_identity(identity),
         peer = peer_tls_identity(identity, peer_certificate),
         :ok <- distribution_tls.write_options(optfile_path, local, peer),
         :ok <- distribution_tls.verify_options(optfile_path, local, peer),
         :ok <-
           distribution_launch.write(
             manifest_path,
             launch_attrs(grant, identity, optfile_path)
           ) do
      {:ok,
       %{
         grant_id: value(grant, :grant_id),
         manifest_path: Path.expand(manifest_path),
         optfile_path: Path.expand(optfile_path)
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_distribution_preflight_invalid}
    end
  end

  defp required_paths?(identity_root, descriptor_path, optfile_path, manifest_path) do
    Enum.all?(
      [identity_root, descriptor_path, optfile_path, manifest_path],
      &nonempty?/1
    )
  end

  defp validate_identity_descriptor(identity, descriptor) do
    if value(identity, :controller_id) == value(descriptor, :controller_id) do
      :ok
    else
      {:error, :beam_peer_credential_mismatch}
    end
  end

  defp validate_node_name(identity, node_beam_name) do
    canonical_name?("orchard_node_agent_", value(identity, :node_id), node_beam_name)
  end

  defp validate_grant(grant, descriptor, identity, node_beam_name) do
    checks =
      [
        value(grant, :grant_id) == value(descriptor, :grant_id),
        value(grant, :generation) == value(descriptor, :generation),
        value(grant, :cluster_id) == value(identity, :cluster_id),
        value(grant, :controller_id) == value(identity, :controller_id),
        value(grant, :node_id) == value(identity, :node_id),
        value(grant, :node_beam_name) == node_beam_name,
        value(grant, :controller_certificate_identifier) ==
          value(identity, :controller_certificate_identifier),
        value(grant, :controller_certificate_fingerprint_sha256) ==
          value(identity, :controller_certificate_fingerprint),
        value(grant, :node_certificate_identifier) == value(identity, :certificate_identifier),
        value(grant, :node_certificate_fingerprint_sha256) ==
          value(identity, :certificate_fingerprint),
        canonical_name?(
          "orchard_controller_",
          value(identity, :controller_id),
          value(grant, :controller_beam_name)
        ) == :ok
      ]

    if Enum.all?(checks), do: :ok, else: {:error, :beam_peer_credential_mismatch}
  end

  defp certificate_from_file(certificate_identity, path) do
    with true <- nonempty?(path),
         {:ok, pem} <- File.read(path) do
      certificate_identity.from_pem(pem)
    else
      _other -> {:error, :beam_distribution_tls_configuration_invalid}
    end
  end

  defp validate_certificates(identity, local, peer) do
    valid =
      exact_certificate?(
        local,
        value(identity, :node_uri_san),
        value(identity, :certificate_serial),
        value(identity, :certificate_fingerprint)
      ) and
        exact_certificate?(
          peer,
          value(identity, :controller_uri_san),
          controller_certificate_serial(identity),
          value(identity, :controller_certificate_fingerprint)
        )

    if valid, do: :ok, else: {:error, :beam_distribution_tls_configuration_invalid}
  end

  defp exact_certificate?(certificate, uri_san, serial, fingerprint)
       when is_binary(serial) and serial != "" do
    certificate.serial == serial and certificate.fingerprint == fingerprint and
      certificate.uri_sans == [uri_san] and
      :server_auth in certificate.extended_key_usages and
      :client_auth in certificate.extended_key_usages
  end

  defp exact_certificate?(_certificate, _uri_san, _identifier, _fingerprint), do: false

  defp controller_certificate_serial(identity) do
    case value(identity, :controller_certificate_identifier) do
      "serial:" <> serial when serial != "" -> serial
      _other -> nil
    end
  end

  defp local_tls_identity(identity) do
    %{
      certfile: identity.certfile,
      keyfile: identity.keyfile,
      cacertfile: identity.cacertfile
    }
  end

  defp peer_tls_identity(identity, peer_certificate) do
    %{
      uri_san: identity.controller_uri_san,
      certificate_serial: peer_certificate.serial,
      certificate_fingerprint: peer_certificate.fingerprint
    }
  end

  defp launch_attrs(grant, identity, optfile_path) do
    %{
      role: :node_agent,
      grant_id: value(grant, :grant_id),
      generation: value(grant, :generation),
      contract_version: value(grant, :contract_version),
      purpose: value(grant, :purpose),
      cluster_id: value(grant, :cluster_id),
      controller_id: value(grant, :controller_id),
      node_id: value(grant, :node_id),
      controller_beam_name: value(grant, :controller_beam_name),
      node_beam_name: value(grant, :node_beam_name),
      controller_certificate_identifier: value(grant, :controller_certificate_identifier),
      controller_certificate_fingerprint_sha256:
        value(grant, :controller_certificate_fingerprint_sha256),
      node_certificate_identifier: value(grant, :node_certificate_identifier),
      node_certificate_fingerprint_sha256: value(grant, :node_certificate_fingerprint_sha256),
      beam_authorization_root_id: value(grant, :beam_authorization_root_id),
      not_before_at: value(grant, :not_before_at),
      expires_at: value(grant, :expires_at),
      optfile_path: optfile_path,
      local_identity_generation_id: value(identity, :generation_id)
    }
  end

  defp canonical_name?(prefix, id, name) when is_binary(id) and is_binary(name) do
    expected = prefix <> String.replace(id, "-", "")

    case String.split(name, "@", parts: 2) do
      [^expected, host] -> private_ipv4(host)
      _other -> {:error, :beam_peer_credential_mismatch}
    end
  end

  defp canonical_name?(_prefix, _id, _name),
    do: {:error, :beam_peer_credential_mismatch}

  defp private_ipv4(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, {10, _b, _c, _d}} -> :ok
      {:ok, {172, b, _c, _d}} when b in 16..31 -> :ok
      {:ok, {192, 168, _c, _d}} -> :ok
      _other -> {:error, :beam_peer_credential_mismatch}
    end
  end

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end

defmodule Orchard.Node.BeamPeerGrantPreflight.NoopCookieInstaller do
  @moduledoc false

  @spec install(map(), String.t()) :: :ok
  def install(_grant, _node_beam_name), do: :ok
end
