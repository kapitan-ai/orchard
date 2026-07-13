defmodule Orchard.ControllerInstances do
  @moduledoc """
  Establishes the durable identity of the local Controller instance.

  The database receives only an opaque reference to Controller-local BEAM
  Authorization Root custody. Root bytes and local filesystem paths stay out
  of durable cluster state.
  """

  alias Orchard.BeamAuthorizationRoot.Store, as: AuthorizationRootStore
  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.{ControlPlane, NodeTrust, Repo}
  alias Orchard.PrivateIpv4
  alias Orchard.TransportTLS.CertificateIdentity

  import Ecto.Query, only: [from: 2]

  @advisory_lock_name "orchard.controller_instances.ensure_local"

  @spec ensure_local(keyword()) :: {:ok, ControllerInstance.t()} | {:error, term()}
  def ensure_local(opts) when is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:beam_peer_grant),
         {:ok, private_ipv4} <- private_ipv4(opts),
         {:ok, trust_root} <- required_path(opts, :node_trust_root),
         {:ok, authorization_root_path} <- required_path(opts, :authorization_root_path),
         {:ok, trust} <- NodeTrust.public_material(root: trust_root),
         {:ok, certificate} <- CertificateIdentity.from_pem(trust.controller_certificate_pem),
         true <- certificate.uri_sans == [trust.controller_uri_san],
         true <- certificate.fingerprint == trust.controller_certificate_fingerprint,
         {:ok, authorization_root} <- AuthorizationRootStore.ensure(authorization_root_path),
         attrs <- instance_attrs(trust, certificate, authorization_root, private_ipv4, opts) do
      ensure_persisted(attrs)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_controller_instance_invalid}
    end
  end

  defp ensure_persisted(attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@advisory_lock_name])

      instances = Repo.all(from(instance in ControllerInstance, lock: "FOR UPDATE"))

      case instances do
        [] ->
          insert_instance(attrs)

        [%ControllerInstance{id: id} = instance] when id == attrs.id ->
          ensure_instance_matches(instance, attrs)

        _other ->
          Repo.rollback(:beam_controller_instance_cardinality_invalid)
      end
    end)
    |> case do
      {:ok, %ControllerInstance{} = instance} -> {:ok, instance}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_instance(attrs) do
    %ControllerInstance{}
    |> ControllerInstance.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, instance} -> instance
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp ensure_instance_matches(instance, attrs) do
    expected = Map.take(attrs, immutable_fields())
    actual = instance |> Map.from_struct() |> Map.take(immutable_fields())

    if actual == expected do
      instance
    else
      Repo.rollback(:beam_controller_instance_mismatch)
    end
  end

  defp instance_attrs(trust, certificate, authorization_root, private_ipv4, opts) do
    %{
      id: trust.controller_id,
      certificate_uri_san: trust.controller_uri_san,
      certificate_identifier: "serial:#{certificate.serial}",
      certificate_fingerprint_sha256: certificate.fingerprint,
      canonical_beam_name: canonical_name(trust.controller_id, private_ipv4),
      beam_authorization_root_id: authorization_root.root_id,
      authorization_root_custody_ref: "owner-only-local:#{authorization_root.root_id}",
      status: :operational,
      first_enrolled_at: Keyword.get(opts, :now, DateTime.utc_now())
    }
  end

  defp immutable_fields do
    [
      :id,
      :certificate_uri_san,
      :certificate_identifier,
      :certificate_fingerprint_sha256,
      :canonical_beam_name,
      :beam_authorization_root_id,
      :authorization_root_custody_ref,
      :status
    ]
  end

  defp canonical_name(controller_id, private_ipv4) do
    compact_id = String.replace(controller_id, "-", "")
    "orchard_controller_#{compact_id}@#{private_ipv4}"
  end

  defp private_ipv4(opts) do
    with value when is_binary(value) <- Keyword.get(opts, :private_ipv4),
         {:ok, address} <- :inet.parse_ipv4_address(String.to_charlist(value)),
         true <- PrivateIpv4.private?(address) do
      {:ok, value}
    else
      _other -> {:error, :beam_controller_private_ipv4_invalid}
    end
  end

  defp required_path(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, Path.expand(value)}
      _other -> {:error, :beam_controller_instance_configuration_invalid}
    end
  end
end
