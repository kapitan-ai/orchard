defmodule Orchard.NodeTrust do
  @moduledoc """
  Initializes internal Node trust and exposes its public material.
  """

  import Ecto.Query

  alias Orchard.ControlPlane
  alias Orchard.Governance
  alias Orchard.Governance.AuditWriter
  alias Orchard.NodeEnrollment.PKI, as: EnrollmentPKI
  alias Orchard.Nodes.{ClusterIdentity, TrustAuthority}
  alias Orchard.NodeTrust.{PKI, Store}
  alias Orchard.Repo
  alias Orchard.TransportTLS.CertificateIdentity

  @advisory_lock_name "orchard.node_trust.initialize"

  @type runtime_client_generation :: %{
          certfile: String.t(),
          keyfile: String.t(),
          cacertfile: String.t(),
          generation_id: Ecto.UUID.t(),
          cluster_id: Ecto.UUID.t(),
          controller_id: Ecto.UUID.t(),
          controller_uri_san: String.t(),
          trust_authority_id: Ecto.UUID.t(),
          runtime_trust_spki_sha256: String.t()
        }

  @type public_material :: %{
          ca_certificate_fingerprint: String.t(),
          ca_certificate_pem: String.t(),
          ca_spki_fingerprint: String.t(),
          cluster_id: Ecto.UUID.t(),
          controller_certificate_fingerprint: String.t(),
          controller_certificate_pem: String.t(),
          controller_id: Ecto.UUID.t(),
          controller_uri_san: String.t(),
          trust_authority_id: Ecto.UUID.t()
        }

  @spec initialize(keyword()) :: {:ok, public_material()} | {:error, term()}
  def initialize(opts) when is_list(opts) do
    with {:ok, root} <- trust_root(opts),
         :ok <- ControlPlane.authorize_write_path(:node_trust) do
      root
      |> initialize_transaction(opts)
      |> unwrap_transaction()
    end
  end

  @spec issue_node_certificate(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def issue_node_certificate(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:node_enrollment),
         {:ok, root} <- trust_root(opts),
         %ClusterIdentity{} = identity <- Repo.one(ClusterIdentity),
         %TrustAuthority{} = authority <- active_authority(identity.id),
         {:ok, material} <- Store.load_current(root),
         :ok <- ensure_material_matches(material, identity, authority),
         :ok <- validate_signing_bindings(material, attrs),
         {:ok, certificate} <- sign_node_certificate(material, attrs),
         {:ok, identifier} <- controller_certificate_identifier(material) do
      {:ok, certificate_result(material, certificate, identifier)}
    else
      _reason -> {:error, :node_certificate_issuance_failed}
    end
  end

  defp sign_node_certificate(material, attrs) do
    EnrollmentPKI.issue_node_certificate(
      Map.merge(attrs, %{
        ca_private_key_pem: material.ca_private_key_pem,
        ca_certificate_pem: material.ca_certificate_pem
      })
    )
  end

  defp certificate_result(material, certificate, identifier) do
    Map.merge(certificate, %{
      controller_certificate_identifier: identifier,
      controller_certificate_fingerprint: material.controller_certificate_fingerprint,
      controller_certificate_pem: material.controller_certificate_pem,
      controller_id: material.controller_id,
      controller_uri_san: material.controller_uri_san,
      runtime_ca_certificate_pem: material.ca_certificate_pem,
      runtime_trust_spki_sha256: material.ca_spki_fingerprint,
      trust_authority_id: material.trust_authority_id
    })
  end

  defp controller_certificate_identifier(material) do
    with {:ok, certificate} <- CertificateIdentity.from_pem(material.controller_certificate_pem) do
      {:ok, "serial:#{certificate.serial}"}
    end
  end

  @spec public_material(keyword()) ::
          {:ok, public_material()} | {:error, :node_trust_not_initialized | atom()}
  def public_material(opts \\ []) when is_list(opts) do
    with {:ok, root} <- trust_root(opts),
         %ClusterIdentity{} = identity <- Repo.one(ClusterIdentity),
         %TrustAuthority{} = authority <- active_authority(identity.id),
         {:ok, local_material} <- Store.load_current(root),
         :ok <- ensure_material_matches(local_material, identity, authority) do
      {:ok, to_public_material(identity, authority)}
    else
      nil -> {:error, :node_trust_not_initialized}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec runtime_client_generation_paths(keyword()) ::
          {:ok, runtime_client_generation()} | {:error, atom()}
  def runtime_client_generation_paths(opts \\ []) when is_list(opts) do
    with {:ok, root} <- trust_root(opts),
         %ClusterIdentity{} = identity <- Repo.one(ClusterIdentity),
         %TrustAuthority{} = authority <- active_authority(identity.id),
         {:ok, generation} <- Store.load_current_with_paths(root),
         :ok <- ensure_material_matches(generation.material, identity, authority) do
      {:ok, runtime_client_generation(generation.material, generation)}
    else
      _other -> {:error, :node_runtime_tls_identity_invalid}
    end
  end

  @doc """
  Returns the Controller generation only when it can serve the Peer Grant mTLS listener.
  """
  @spec peer_grant_runtime_generation_paths(keyword()) ::
          {:ok, runtime_client_generation()}
          | {:error, :beam_controller_identity_upgrade_required}
  def peer_grant_runtime_generation_paths(opts \\ []) when is_list(opts) do
    with {:ok, generation} <- runtime_client_generation_paths(opts),
         {:ok, certificate_pem} <- File.read(generation.certfile),
         {:ok, certificate} <- CertificateIdentity.from_pem(certificate_pem),
         true <- :server_auth in certificate.extended_key_usages,
         true <- :client_auth in certificate.extended_key_usages do
      {:ok, generation}
    else
      _other -> {:error, :beam_controller_identity_upgrade_required}
    end
  end

  defp runtime_client_generation(material, generation) do
    %{
      certfile: generation.certfile,
      keyfile: generation.keyfile,
      cacertfile: generation.cacertfile,
      generation_id: material.generation_id,
      cluster_id: material.cluster_id,
      controller_id: material.controller_id,
      controller_uri_san: material.controller_uri_san,
      trust_authority_id: material.trust_authority_id,
      runtime_trust_spki_sha256: material.ca_spki_fingerprint
    }
  end

  defp validate_signing_bindings(material, attrs) do
    valid =
      material.cluster_id == Map.get(attrs, :cluster_id) and
        material.controller_id == Map.get(attrs, :controller_id) and
        material.trust_authority_id == Map.get(attrs, :trust_authority_id)

    if valid, do: :ok, else: {:error, :node_trust_binding_mismatch}
  end

  defp initialize_transaction(root, opts) do
    AuditWriter.transaction(fn ->
      Repo.query!(
        "SELECT pg_advisory_xact_lock(hashtext($1))",
        [@advisory_lock_name]
      )

      initialize_locked(root, opts)
    end)
  end

  defp initialize_locked(root, opts) do
    case Repo.one(ClusterIdentity) do
      nil -> initialize_new(root, opts)
      %ClusterIdentity{} = identity -> load_existing(root, identity)
    end
  end

  defp initialize_new(root, opts) do
    with {:ok, material} <- load_or_generate_material(root, opts),
         :ok <- ensure_material_identifiers(material),
         {:ok, identity} <- insert_identity(material, opts),
         {:ok, authority} <- insert_authority(material),
         {:ok, _audit_log} <- insert_audit_log(identity, authority, opts) do
      to_public_material(identity, authority)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp load_existing(root, identity) do
    with %TrustAuthority{} = authority <- active_authority(identity.id),
         {:ok, local_material} <- Store.load_current(root),
         :ok <- ensure_material_matches(local_material, identity, authority) do
      to_public_material(identity, authority)
    else
      nil -> Repo.rollback(:node_trust_public_material_missing)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp load_or_generate_material(root, opts) do
    case Store.load_current(root) do
      {:ok, material} ->
        {:ok, material}

      {:error, :not_found} ->
        generate_and_publish(root, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_and_publish(root, opts) do
    cluster_id = Ecto.UUID.generate()
    controller_id = Ecto.UUID.generate()
    authority_id = Ecto.UUID.generate()
    generation_id = Ecto.UUID.generate()
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, material} <-
           PKI.generate(cluster_id, controller_id, authority_id, generation_id, now) do
      Store.publish(root, material)
    end
  end

  defp ensure_material_identifiers(material) do
    identifiers = [
      material.cluster_id,
      material.controller_id,
      material.trust_authority_id,
      material.generation_id
    ]

    if Enum.all?(identifiers, &match?({:ok, _uuid}, Ecto.UUID.cast(&1))) do
      :ok
    else
      {:error, :node_trust_local_material_invalid}
    end
  end

  defp insert_identity(material, opts) do
    %ClusterIdentity{}
    |> ClusterIdentity.changeset(%{
      id: material.cluster_id,
      singleton: true,
      name: Keyword.get(opts, :cluster_name),
      runtime_controller_id: material.controller_id
    })
    |> Repo.insert()
  end

  defp insert_authority(material) do
    %TrustAuthority{}
    |> TrustAuthority.changeset(%{
      id: material.trust_authority_id,
      cluster_id: material.cluster_id,
      state: :active,
      material_generation: material.generation_id,
      ca_certificate_pem: material.ca_certificate_pem,
      ca_certificate_fingerprint: material.ca_certificate_fingerprint,
      ca_spki_fingerprint: material.ca_spki_fingerprint,
      controller_certificate_pem: material.controller_certificate_pem,
      controller_certificate_fingerprint: material.controller_certificate_fingerprint,
      controller_uri_san: material.controller_uri_san
    })
    |> Repo.insert()
  end

  defp insert_audit_log(identity, authority, opts) do
    Governance.insert_cluster_audit_log(%{
      actor_type: "operator",
      actor_id: Keyword.get(opts, :actor_id),
      action: "node_trust.initialized",
      target_type: "node_trust_authority",
      target_id: authority.id,
      occurred_at: Keyword.get(opts, :now, DateTime.utc_now()),
      payload: %{
        "cluster_id" => identity.id,
        "controller_id" => identity.runtime_controller_id,
        "trust_authority_id" => authority.id,
        "ca_certificate_fingerprint" => authority.ca_certificate_fingerprint,
        "controller_certificate_fingerprint" => authority.controller_certificate_fingerprint
      }
    })
  end

  defp active_authority(cluster_id) do
    TrustAuthority
    |> where([authority], authority.cluster_id == ^cluster_id)
    |> where([authority], authority.state == :active)
    |> Repo.one()
  end

  defp ensure_material_matches(material, identity, authority) do
    matches? =
      PKI.valid_material?(material) and
        material_identity(material) == persisted_identity(identity) and
        material_authority(material) == persisted_authority(authority)

    if matches?, do: :ok, else: {:error, :node_trust_material_mismatch}
  end

  defp material_identity(material) do
    %{
      cluster_id: material.cluster_id,
      controller_id: material.controller_id
    }
  end

  defp persisted_identity(identity) do
    %{
      cluster_id: identity.id,
      controller_id: identity.runtime_controller_id
    }
  end

  defp material_authority(material) do
    %{
      id: material.trust_authority_id,
      material_generation: material.generation_id,
      controller_uri_san: material.controller_uri_san,
      ca_certificate_pem: material.ca_certificate_pem,
      ca_certificate_fingerprint: material.ca_certificate_fingerprint,
      ca_spki_fingerprint: material.ca_spki_fingerprint,
      controller_certificate_pem: material.controller_certificate_pem,
      controller_certificate_fingerprint: material.controller_certificate_fingerprint
    }
  end

  defp persisted_authority(authority) do
    %{
      id: authority.id,
      material_generation: authority.material_generation,
      controller_uri_san: authority.controller_uri_san,
      ca_certificate_pem: authority.ca_certificate_pem,
      ca_certificate_fingerprint: authority.ca_certificate_fingerprint,
      ca_spki_fingerprint: authority.ca_spki_fingerprint,
      controller_certificate_pem: authority.controller_certificate_pem,
      controller_certificate_fingerprint: authority.controller_certificate_fingerprint
    }
  end

  defp to_public_material(identity, authority) do
    %{
      cluster_id: identity.id,
      controller_id: identity.runtime_controller_id,
      trust_authority_id: authority.id,
      controller_uri_san: authority.controller_uri_san,
      ca_certificate_pem: authority.ca_certificate_pem,
      ca_certificate_fingerprint: authority.ca_certificate_fingerprint,
      ca_spki_fingerprint: authority.ca_spki_fingerprint,
      controller_certificate_pem: authority.controller_certificate_pem,
      controller_certificate_fingerprint: authority.controller_certificate_fingerprint
    }
  end

  defp trust_root(opts) do
    configured_root =
      :orchard_controller
      |> Application.get_env(:node_trust, [])
      |> Keyword.get(:root)

    case Keyword.get(opts, :root, configured_root) do
      root when is_binary(root) and root != "" -> {:ok, Path.expand(root)}
      _root -> {:error, :node_trust_root_required}
    end
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
