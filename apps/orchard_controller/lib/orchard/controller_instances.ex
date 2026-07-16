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
  alias Orchard.RuntimeEndpoint.BeamNodeName
  alias Orchard.TransportTLS.CertificateIdentity

  import Ecto.Query, only: [from: 2]

  @advisory_lock_name "orchard.controller_instances.ensure_local"

  @spec ensure_local(keyword()) :: {:ok, ControllerInstance.t()} | {:error, term()}
  def ensure_local(opts) when is_list(opts) do
    with :ok <- ControlPlane.authorize_membership_self_publication(),
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

  @doc """
  Atomically refreshes membership and dispatch-capacity capability evidence for
  one authenticated local Controller identity.
  """
  @spec heartbeat_local(keyword(), map()) ::
          {:ok, ControllerInstance.t()} | {:error, term()}
  def heartbeat_local(opts, attrs) when is_list(opts) and is_map(attrs) do
    attrs = force_consumers_not_ready(attrs)

    with :ok <- ControlPlane.authorize_membership_self_publication(),
         {:ok, local_identity} <- ensure_local(opts) do
      Repo.transaction(fn -> refresh_local_identity(local_identity, attrs) end)
      |> case do
        {:ok, %ControllerInstance{} = instance} -> {:ok, instance}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp force_consumers_not_ready(attrs) do
    if Enum.any?(Map.keys(attrs), &is_atom/1) do
      attrs
      |> Map.delete("dispatch_capacity_consumers_ready")
      |> Map.put(:dispatch_capacity_consumers_ready, false)
    else
      Map.put(attrs, "dispatch_capacity_consumers_ready", false)
    end
  end

  defp refresh_local_identity(local_identity, attrs) do
    persisted =
      Repo.one(
        from(instance in ControllerInstance,
          where: instance.id == ^local_identity.id,
          lock: "FOR UPDATE"
        )
      )

    case persisted do
      nil ->
        Repo.rollback(:beam_controller_instance_not_found)

      %ControllerInstance{} = instance ->
        ensure_heartbeat_identity_matches(instance, local_identity, attrs)
    end
  end

  defp ensure_heartbeat_identity_matches(instance, local_identity, attrs) do
    expected = local_identity |> Map.from_struct() |> Map.take(immutable_fields())
    actual = instance |> Map.from_struct() |> Map.take(immutable_fields())

    if actual == expected do
      instance
      |> ControllerInstance.heartbeat_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, refreshed} -> refreshed
        {:error, changeset} -> Repo.rollback(changeset)
      end
    else
      Repo.rollback(:beam_controller_instance_mismatch)
    end
  end

  defp ensure_persisted(attrs) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
        @advisory_lock_name <> "." <> attrs.id
      ])

      instance =
        Repo.one(
          from(instance in ControllerInstance,
            where: instance.id == ^attrs.id,
            lock: "FOR UPDATE"
          )
        )

      case instance do
        nil ->
          insert_instance(attrs)

        %ControllerInstance{} = instance ->
          ensure_instance_matches(instance, attrs)
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
      :authorization_root_custody_ref
    ]
  end

  defp canonical_name(controller_id, private_ipv4) do
    compact_id = String.replace(controller_id, "-", "")
    "orchard_controller_#{compact_id}@#{private_ipv4}"
  end

  defp private_ipv4(opts) do
    with value when is_binary(value) <- Keyword.get(opts, :private_ipv4),
         {:ok, _address} <- BeamNodeName.private_ipv4(value) do
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
