defmodule Orchard.BeamPeerGrants do
  @moduledoc """
  Owns exact Controller-to-Node BEAM Peer Grant persistence and authorization.

  Plaintext grant material is derived only after current scope and lifecycle
  authority are revalidated. Normal rotation remains outside this tracer.
  """

  import Ecto.Query

  alias Orchard.BeamAuthorizationRoot.Store, as: AuthorizationRootStore
  alias Orchard.BeamDisconnectObligations
  alias Orchard.BeamDisconnectObligations.Obligation
  alias Orchard.BeamPeerGrantDescriptor
  alias Orchard.BeamPeerGrants.{Grant, Secret}
  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.ControlPlane
  alias Orchard.Governance.AuditWriter
  alias Orchard.NodeCredentials
  alias Orchard.NodeCredentials.Generation, as: CredentialGeneration
  alias Orchard.Nodes.{Enrollment, Node}
  alias Orchard.NodeTrust
  alias Orchard.Repo
  alias Orchard.RuntimeEndpoint.AuthenticatedPeer
  alias Orchard.RuntimeEndpoint.BeamNodeName
  alias Orchard.RuntimeEndpoint.Target
  alias Orchard.TransportTLS.CertificateIdentity

  @contract_version 1
  @purpose "runtime_endpoint"
  @initial_validity_days 30
  @minimum_generation_interval_seconds 3_600
  @tracer_admission_lock "orchard.beam_peer_grants.tracer_admission"

  @spec list_for_node(Ecto.UUID.t()) :: [Grant.t()]
  def list_for_node(node_id) do
    Grant
    |> where([grant], grant.node_id == ^node_id)
    |> order_by([grant], asc: grant.generation)
    |> Repo.all()
  end

  @doc """
  Writes the nonsecret retrieval descriptor for one admitted Node grant.
  """
  @spec write_admitted_descriptor(Ecto.UUID.t(), String.t(), String.t()) ::
          :ok | {:error, atom()}
  def write_admitted_descriptor(node_id, path, control_endpoint) do
    with :ok <- ControlPlane.authorize_write_path(:beam_peer_grant),
         true <- enabled?(),
         {:ok, node_id} <- Ecto.UUID.cast(node_id),
         [%Grant{} = grant] <- descriptor_grants(node_id) do
      BeamPeerGrantDescriptor.write(path, %{
        grant_id: grant.id,
        generation: grant.generation,
        controller_id: grant.controller_id,
        control_endpoint: control_endpoint
      })
    else
      _other -> {:error, :beam_peer_grant_descriptor_unavailable}
    end
  end

  @spec production_enabled?() :: boolean()
  def production_enabled?, do: enabled?()

  @type distribution_launch_material :: %{
          required(:scope) => map(),
          required(:local_identity) => map(),
          required(:peer_identity) => map()
        }

  @doc """
  Revalidates and returns the nonsecret exact-pair Controller launch material.

  This tracer intentionally fails closed unless exactly one Controller and one
  currently active Node grant are in scope.
  """
  @spec distribution_launch_material(Ecto.UUID.t(), keyword()) ::
          {:ok, distribution_launch_material()} | {:error, atom()}
  def distribution_launch_material(grant_id, opts) when is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:beam_peer_grant),
         true <- enabled?(),
         {:ok, grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, opts} <- put_preloaded_authorization_root(opts) do
      Repo.transaction(fn -> distribution_launch_material_locked(grant_id, opts) end)
    else
      _other -> {:error, :beam_distribution_launch_scope_invalid}
    end
  end

  @type target_authorization :: %{
          required(:authenticated_peer) => AuthenticatedPeer.t(),
          required(:encoded_secret) => String.t(),
          required(:grant) => Grant.t(),
          required(:node_name) => String.t(),
          required(:secret_hash) => binary()
        }

  @spec authorize_target(Target.t(), keyword()) ::
          {:ok, target_authorization() | nil} | {:error, atom()}
  def authorize_target(%Target{} = target, opts \\ []) when is_list(opts) do
    with true <- enabled?(),
         {:ok, grant_id} <- Ecto.UUID.cast(value(target.metadata, :grant_id)),
         {:ok, opts} <- put_preloaded_authorization_root(opts) do
      Repo.transaction(fn -> authorize_target_locked(grant_id, target, opts) end)
    else
      false -> {:ok, nil}
      :error -> {:error, :beam_peer_grant_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_active_grant_current(Ecto.UUID.t(), keyword()) :: :ok | {:error, atom()}
  def ensure_active_grant_current(grant_id, opts \\ []) when is_list(opts) do
    with {:ok, grant_id} <- Ecto.UUID.cast(grant_id),
         %Grant{} = grant <- Repo.get(Grant, grant_id),
         :ok <- ensure_predecessor_disconnected(grant) do
      ensure_grant_current(grant, [:active], opts)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_peer_grant_missing}
    end
  end

  defp ensure_predecessor_disconnected(%Grant{generation: 1}), do: :ok

  defp ensure_predecessor_disconnected(%Grant{} = grant) do
    pending? =
      Obligation
      |> where([obligation], obligation.node_id == ^grant.node_id)
      |> where([obligation], obligation.reason == "grant_cutover")
      |> where([obligation], obligation.state in [:pending, :attempted])
      |> Repo.exists?()

    if pending?, do: {:error, :beam_predecessor_disconnect_incomplete}, else: :ok
  end

  @spec ensure_authorization_current(target_authorization() | nil, keyword()) ::
          :ok | {:error, atom()}
  def ensure_authorization_current(authorization, opts \\ [])

  def ensure_authorization_current(%{grant: %Grant{id: grant_id}}, opts),
    do: ensure_active_grant_current(grant_id, opts)

  def ensure_authorization_current(nil, _opts), do: :ok

  def ensure_authorization_current(_authorization, _opts),
    do: {:error, :beam_peer_grant_missing}

  @type delivery_request :: %{
          required(:grant_id) => Ecto.UUID.t(),
          required(:generation) => pos_integer(),
          required(:controller_id) => Ecto.UUID.t()
        }

  @type delivery :: map()

  @spec deliver(delivery_request(), AuthenticatedPeer.t(), keyword()) ::
          {:ok, delivery()} | {:error, atom()}
  def deliver(request, peer, opts \\ [])

  def deliver(request, %AuthenticatedPeer{} = peer, opts) do
    with :ok <- ControlPlane.authorize_write_path(:beam_peer_grant_delivery),
         {:ok, request} <- normalize_delivery_request(request),
         {:ok, opts} <- put_preloaded_authorization_root(opts) do
      Repo.transaction(fn -> deliver_locked(request, peer, opts) end)
    end
  end

  def deliver(_request, _peer, _opts), do: {:error, :beam_peer_credential_mismatch}

  @doc """
  Delivers the requested grant after deriving peer identity from the presented certificate.
  """
  @spec deliver_from_peer_certificate(delivery_request(), binary(), keyword()) ::
          {:ok, delivery()} | {:error, atom()}
  def deliver_from_peer_certificate(request, certificate_der, opts \\ []) do
    with {:ok, peer} <- authenticated_peer_from_certificate(certificate_der) do
      deliver(request, peer, opts)
    end
  end

  @doc """
  Records authenticated proof that the Node durably published the delivered grant.
  """
  @spec acknowledge_persisted(map(), AuthenticatedPeer.t(), keyword()) ::
          {:ok, Grant.t()} | {:error, atom()}
  def acknowledge_persisted(request, %AuthenticatedPeer{} = peer, opts \\ []) do
    with :ok <- ControlPlane.authorize_write_path(:beam_peer_grant_delivery),
         {:ok, request} <- normalize_acknowledgement_request(request) do
      Repo.transaction(fn -> acknowledge_persisted_locked(request, peer, opts) end)
    end
  end

  @spec acknowledge_from_peer_certificate(map(), binary(), keyword()) ::
          {:ok, Grant.t()} | {:error, atom()}
  def acknowledge_from_peer_certificate(request, certificate_der, opts \\ []) do
    with {:ok, peer} <- authenticated_peer_from_certificate(certificate_der) do
      acknowledge_persisted(request, peer, opts)
    end
  end

  @doc """
  Issues the initial Controller-to-Node grant inside the caller's admission transaction.
  """
  @spec issue_initial_for_admission(Node.t(), keyword()) ::
          {:ok, {Node.t(), [Grant.t()]}} | {:error, term()}
  def issue_initial_for_admission(%Node{state: :registered} = node, opts) do
    if enabled?() do
      do_issue_initial_for_admission(node, opts)
    else
      {:ok, {node, []}}
    end
  end

  def issue_initial_for_admission(%Node{}, _opts),
    do: {:error, :beam_peer_grant_admission_invalid}

  @doc """
  Stages the next exact-pair grant for the Node's already-staged certificate generation.
  """
  @spec stage_successor(Ecto.UUID.t(), keyword()) :: {:ok, Grant.t()} | {:error, term()}
  def stage_successor(node_id, opts \\ []) when is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:beam_peer_grant),
         true <- enabled?(),
         {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, opts} <- put_preloaded_authorization_root(opts) do
      Repo.transaction(fn -> stage_successor_locked(node_id, opts) end)
    else
      _other -> {:error, :beam_peer_grant_rotation_invalid}
    end
  end

  @doc """
  Atomically commits the staged certificate and Peer Grant generations.
  """
  @spec commit_successor(Ecto.UUID.t(), pos_integer(), keyword()) ::
          {:ok, Grant.t()} | {:error, term()}
  def commit_successor(node_id, generation, opts \\ [])
      when is_integer(generation) and generation > 0 and is_list(opts) do
    with :ok <- ControlPlane.authorize_write_path(:beam_peer_grant),
         true <- enabled?(),
         {:ok, node_id} <- Ecto.UUID.cast(node_id) do
      AuditWriter.transaction(fn -> commit_successor_locked(node_id, generation, opts) end)
    else
      _other -> {:error, :beam_peer_grant_rotation_invalid}
    end
  end

  @doc false
  @spec lock_initial_admission_node(Ecto.UUID.t(), keyword()) ::
          {:ok, Node.t()} | {:error, term()}
  def lock_initial_admission_node(node_id, opts) when is_list(opts) do
    case Ecto.UUID.cast(node_id) do
      {:ok, node_id} -> lock_initial_admission_node_by_mode(node_id, opts)
      _other -> {:error, :node_not_found}
    end
  end

  defp lock_initial_admission_node_by_mode(node_id, opts) do
    if enabled?() do
      lock_grant_then_node(node_id, opts)
    else
      lock_admission_node(node_id)
    end
  end

  defp do_issue_initial_for_admission(node, opts) do
    with {:ok, enrollment, node_certificate} <- lock_enrollment_binding(node),
         :ok <- run_lock_observer(opts, :enrollment),
         {:ok, controller} <- lock_local_controller(),
         :ok <- run_lock_observer(opts, :controller),
         :ok <- validate_enrollment_controller(enrollment, controller),
         :ok <- validate_controller_binding(controller),
         {:ok, authorization_root} <- load_authorization_root(controller, opts),
         {:ok, node_beam_name} <- canonical_node_name(node),
         {:ok, node} <- persist_canonical_node_name(node, node_beam_name),
         attrs <-
           initial_attrs(
             node,
             node_beam_name,
             controller,
             enrollment,
             node_certificate,
             authorization_root,
             opts
           ),
         {:ok, secret} <- Secret.derive(attrs, authorization_root.key),
         {:ok, grant} <- insert_grant(Map.put(attrs, :secret_hash, secret.secret_hash)),
         :ok <- run_fault_checkpoint(opts, :after_grant_insert) do
      {:ok, {node, [grant]}}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_peer_grant_admission_invalid}
    end
  end

  defp stage_successor_locked(node_id, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    with %Node{} = node <- lock_node(node_id),
         true <- node.state in [:admitted, :active],
         %CredentialGeneration{} = credential <- lock_rotation_credential(node_id),
         %Grant{} = active <- lock_pair_grant(node_id, :active),
         nil <- lock_pair_grant(node_id, :pending_delivery),
         nil <- lock_pair_grant(node_id, :staged),
         :ok <- ensure_generation_interval(active, now),
         %ControllerInstance{} = controller <- lock_controller(active.controller_id),
         {:ok, authorization_root} <- load_authorization_root(controller, opts),
         attrs <- successor_attrs(active, credential, now),
         {:ok, secret} <- Secret.derive(attrs, authorization_root.key),
         {:ok, grant} <- insert_grant(Map.put(attrs, :secret_hash, secret.secret_hash)) do
      grant
    else
      %Grant{} -> Repo.rollback(:beam_peer_grant_rotation_in_progress)
      nil -> Repo.rollback(:beam_peer_grant_rotation_invalid)
      false -> Repo.rollback(:beam_peer_grant_rotation_invalid)
      {:error, reason} -> Repo.rollback(reason)
      _other -> Repo.rollback(:beam_peer_grant_rotation_invalid)
    end
  end

  defp commit_successor_locked(node_id, generation, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    with %Grant{} = active_scope <- pair_grant(node_id, :active),
         %Grant{generation: ^generation} = staged_scope <- pair_grant(node_id, :staged),
         %Node{} <- lock_node(node_id),
         %CredentialGeneration{} = predecessor_credential <-
           lock_grant_credential(active_scope),
         %CredentialGeneration{} = credential <- lock_grant_credential(staged_scope),
         %Grant{} = active <- lock_pair_grant(node_id, :active),
         %Grant{generation: ^generation} = staged <- lock_pair_grant(node_id, :staged),
         {:ok, credential} <- maybe_activate_credential(credential, opts),
         true <- staged.node_certificate_identifier == credential.certificate_identifier,
         true <-
           staged.node_certificate_fingerprint_sha256 ==
             credential.certificate_fingerprint_sha256,
         {1, _rows} <- transition_grant(active, :superseded, now),
         {1, _rows} <- transition_grant(staged, :active, now),
         {:ok, _obligation} <-
           BeamDisconnectObligations.enqueue_in_transaction(
             active,
             predecessor_credential.id,
             "grant_cutover",
             now
           ) do
      Repo.get!(Grant, staged.id)
    else
      {:error, reason} -> Repo.rollback(reason)
      _other -> Repo.rollback(:beam_peer_grant_rotation_invalid)
    end
  end

  defp successor_attrs(active, credential, now) do
    expires_at =
      earliest(DateTime.add(now, @initial_validity_days, :day), credential.not_after_at)

    active
    |> Map.from_struct()
    |> Map.take([
      :cluster_id,
      :controller_id,
      :controller_beam_name,
      :controller_certificate_identifier,
      :controller_certificate_fingerprint_sha256,
      :beam_authorization_root_id,
      :node_id,
      :node_beam_name,
      :contract_version,
      :purpose
    ])
    |> Map.merge(%{
      id: Ecto.UUID.generate(),
      generation: active.generation + 1,
      node_certificate_identifier: credential.certificate_identifier,
      node_certificate_fingerprint_sha256: credential.certificate_fingerprint_sha256,
      state: :pending_delivery,
      issued_at: now,
      not_before_at: now,
      cutover_at: now,
      expires_at: expires_at,
      delivery_evidence: %{},
      activation_evidence: %{},
      supersession_evidence: %{},
      failure_evidence: %{},
      revocation_evidence: %{}
    })
  end

  defp ensure_generation_interval(active, now) do
    boundary = DateTime.add(active.issued_at, @minimum_generation_interval_seconds, :second)

    if DateTime.compare(now, boundary) in [:eq, :gt],
      do: :ok,
      else: {:error, :beam_peer_grant_generation_rate_limited}
  end

  defp maybe_activate_credential(%CredentialGeneration{state: :current} = credential, _opts),
    do: {:ok, credential}

  defp maybe_activate_credential(%CredentialGeneration{state: :staged} = credential, opts),
    do:
      NodeCredentials.activate_staged_in_transaction(
        credential.node_id,
        credential.generation,
        opts
      )

  defp transition_grant(grant, :superseded, now) do
    grant
    |> where_id()
    |> where([candidate], candidate.state == :active)
    |> update([candidate],
      set: [state: :superseded, superseded_at: ^now]
    )
    |> Repo.update_all([])
  end

  defp transition_grant(grant, :active, now) do
    grant
    |> where_id()
    |> where([candidate], candidate.state == :staged)
    |> update([candidate],
      set: [state: :active, activated_at: ^now]
    )
    |> Repo.update_all([])
  end

  defp where_id(%Grant{id: id}), do: where(Grant, [grant], grant.id == ^id)

  defp earliest(left, right) do
    if DateTime.compare(left, right) == :lt, do: left, else: right
  end

  defp distribution_launch_material_locked(grant_id, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    with %Grant{} = scope <- Repo.get(Grant, grant_id),
         %Node{} = node <- lock_node(scope.node_id),
         :ok <- run_lock_observer(opts, :node),
         {:ok, grant} <- lock_only_current_active_grant(grant_id, now),
         :ok <- run_lock_observer(opts, :grant),
         {:ok, enrollment} <- lock_only_launch_enrollment(node.id),
         :ok <- run_lock_observer(opts, :enrollment),
         {:ok, controller} <- lock_grant_controller(grant.controller_id),
         :ok <- run_lock_observer(opts, :controller),
         {:ok, peer} <- authenticated_peer(enrollment),
         :ok <- validate_delivery_scope(grant, node, enrollment, controller, peer, opts),
         :ok <- validate_controller_binding(controller),
         {:ok, local_identity} <- NodeTrust.peer_grant_runtime_generation_paths(),
         true <- local_identity.cluster_id == grant.cluster_id,
         true <- local_identity.controller_id == controller.id,
         true <- is_binary(local_identity.runtime_trust_spki_sha256),
         true <- is_binary(peer.runtime_trust_spki_sha256),
         true <- local_identity.runtime_trust_spki_sha256 == peer.runtime_trust_spki_sha256,
         {:ok, authorization_root} <- load_authorization_root(controller, opts),
         {:ok, secret} <- Secret.derive(Map.from_struct(grant), authorization_root.key),
         true <- secret.secret_hash == grant.secret_hash,
         :ok <- ensure_grant_current(grant, [:active], opts) do
      %{
        local_identity: local_identity,
        peer_identity: %{
          uri_san: peer.node_uri_san,
          certificate_serial: peer.certificate_serial,
          certificate_fingerprint: peer.certificate_fingerprint
        },
        scope: launch_scope(grant)
      }
    else
      nil -> Repo.rollback(:beam_distribution_launch_scope_invalid)
      {:error, reason} -> Repo.rollback(reason)
      _other -> Repo.rollback(:beam_distribution_launch_scope_invalid)
    end
  end

  defp lock_grant_controller(controller_id) do
    case lock_controller(controller_id) do
      %ControllerInstance{status: :operational} = controller -> {:ok, controller}
      _other -> {:error, :beam_distribution_launch_scope_invalid}
    end
  end

  defp lock_only_current_active_grant(grant_id, now) do
    grants =
      Grant
      |> where([grant], grant.state == :active)
      |> where([grant], grant.not_before_at <= ^now)
      |> where([grant], grant.expires_at > ^now)
      |> order_by([grant], asc: grant.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    case grants do
      [%Grant{id: ^grant_id} = grant] -> {:ok, grant}
      _other -> {:error, :beam_distribution_launch_scope_invalid}
    end
  end

  defp lock_only_launch_enrollment(node_id) do
    enrollments =
      Enrollment
      |> where([enrollment], enrollment.node_id == ^node_id)
      |> where([enrollment], enrollment.state == :consumed)
      |> where([enrollment], enrollment.certificate_issuance_outcome == :issued)
      |> order_by([enrollment], asc: enrollment.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    case enrollments do
      [%Enrollment{} = enrollment] -> {:ok, enrollment}
      _other -> {:error, :beam_distribution_launch_scope_invalid}
    end
  end

  defp launch_scope(grant) do
    grant
    |> Map.from_struct()
    |> Map.take([
      :generation,
      :cluster_id,
      :controller_id,
      :controller_beam_name,
      :controller_certificate_identifier,
      :controller_certificate_fingerprint_sha256,
      :beam_authorization_root_id,
      :node_id,
      :node_beam_name,
      :node_certificate_identifier,
      :node_certificate_fingerprint_sha256,
      :contract_version,
      :purpose,
      :not_before_at,
      :expires_at
    ])
    |> Map.put(:grant_id, grant.id)
  end

  defp enabled? do
    :orchard_controller
    |> Application.get_env(:beam_peer_grants, [])
    |> Keyword.get(:enabled, false)
  end

  defp descriptor_grants(node_id) do
    Grant
    |> join(:inner, [grant], node in Node, on: node.id == grant.node_id)
    |> where([grant, node], grant.node_id == ^node_id)
    |> where([grant, node], node.state in [:admitted, :active])
    |> where(
      [grant, _node],
      grant.state in [:pending_delivery, :delivery_failed, :staged, :active]
    )
    |> order_by([grant, _node], desc: grant.generation)
    |> limit(2)
    |> Repo.all()
  end

  defp lock_local_controller do
    with {:ok, trust} <- NodeTrust.public_material(),
         %ControllerInstance{status: :operational} = controller <-
           lock_controller(trust.controller_id) do
      {:ok, controller}
    else
      _other -> {:error, :beam_peer_grant_controller_scope_invalid}
    end
  end

  defp lock_tracer_admission_slot do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [@tracer_admission_lock])
    :ok
  end

  defp lock_grant_then_node(node_id, opts) do
    with :ok <- lock_tracer_admission_slot(),
         :ok <- ensure_tracer_capacity(),
         :ok <- run_lock_observer(opts, :grant),
         {:ok, node} <- lock_admission_node(node_id),
         :ok <- run_lock_observer(opts, :node) do
      {:ok, node}
    end
  end

  defp lock_admission_node(node_id) do
    case lock_node(node_id) do
      %Node{} = node -> {:ok, node}
      nil -> {:error, :node_not_found}
    end
  end

  defp ensure_tracer_capacity do
    existing_grants =
      Grant
      |> order_by([grant], asc: grant.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    if existing_grants == [] do
      :ok
    else
      {:error, :beam_peer_grant_tracer_capacity_reached}
    end
  end

  defp deliver_locked(request, peer, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    with %Grant{} = scope <- Repo.get(Grant, request.grant_id),
         %Node{} = node <- lock_node(scope.node_id),
         :ok <- run_lock_observer(opts, :node),
         %Grant{} = grant <- lock_grant(request.grant_id),
         :ok <- run_lock_observer(opts, :grant),
         :ok <- validate_delivery_request(grant, request),
         :ok <- validate_delivery_lifecycle(grant, now),
         %Enrollment{} = enrollment <- lock_enrollment(peer.enrollment_id),
         :ok <- run_lock_observer(opts, :enrollment),
         %ControllerInstance{} = controller <- lock_controller(grant.controller_id),
         :ok <- run_lock_observer(opts, :controller),
         :ok <- validate_delivery_scope(grant, node, enrollment, controller, peer, opts),
         :ok <- validate_controller_binding(controller),
         {:ok, authorization_root} <- load_authorization_root(controller, opts),
         {:ok, secret} <- Secret.derive(Map.from_struct(grant), authorization_root.key),
         true <- secret.secret_hash == grant.secret_hash,
         {:ok, grant} <- mark_delivered(grant, peer, now, opts) do
      delivery_payload(grant, secret)
    else
      nil -> Repo.rollback(:beam_peer_grant_missing)
      {:error, reason} -> Repo.rollback(reason)
      false -> Repo.rollback(:beam_peer_credential_mismatch)
      _other -> Repo.rollback(:beam_peer_credential_mismatch)
    end
  end

  defp acknowledge_persisted_locked(request, peer, opts) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    with %Grant{} = scope <- Repo.get(Grant, request.grant_id),
         %Node{} = node <- lock_node(scope.node_id),
         %Grant{} = grant <- lock_grant(request.grant_id),
         :ok <- validate_delivery_request(grant, request),
         true <- grant.secret_hash == request.secret_hash,
         %Enrollment{} = enrollment <- lock_enrollment(peer.enrollment_id),
         %ControllerInstance{} = controller <- lock_controller(grant.controller_id),
         :ok <- validate_delivery_scope(grant, node, enrollment, controller, peer, opts),
         {:ok, acknowledged} <- acknowledge_grant(grant, request, now, opts) do
      acknowledged
    else
      nil -> Repo.rollback(:beam_peer_grant_missing)
      {:error, reason} -> Repo.rollback(reason)
      false -> Repo.rollback(:beam_peer_credential_mismatch)
      _other -> Repo.rollback(:beam_peer_credential_mismatch)
    end
  end

  defp normalize_delivery_request(request) when is_map(request) do
    grant_id = value(request, :grant_id)
    controller_id = value(request, :controller_id)
    generation = value(request, :generation)

    with {:ok, grant_id} <- Ecto.UUID.cast(grant_id),
         {:ok, controller_id} <- Ecto.UUID.cast(controller_id),
         true <- is_integer(generation) and generation > 0 do
      {:ok, %{grant_id: grant_id, controller_id: controller_id, generation: generation}}
    else
      _other -> {:error, :beam_peer_grant_generation_mismatch}
    end
  end

  defp normalize_delivery_request(_request),
    do: {:error, :beam_peer_grant_generation_mismatch}

  defp normalize_acknowledgement_request(request) when is_map(request) do
    with {:ok, delivery} <- normalize_delivery_request(request),
         {:ok, installation_id} <- Ecto.UUID.cast(value(request, :installation_id)),
         {:ok, local_identity_generation_id} <-
           Ecto.UUID.cast(value(request, :local_identity_generation_id)),
         secret_hash when is_binary(secret_hash) and byte_size(secret_hash) == 32 <-
           value(request, :secret_hash) do
      {:ok,
       Map.merge(delivery, %{
         installation_id: installation_id,
         local_identity_generation_id: local_identity_generation_id,
         secret_hash: secret_hash
       })}
    else
      _other -> {:error, :beam_peer_grant_staging_proof_invalid}
    end
  end

  defp normalize_acknowledgement_request(_request),
    do: {:error, :beam_peer_grant_staging_proof_invalid}

  defp validate_delivery_request(grant, request) do
    cond do
      grant.generation != request.generation ->
        {:error, :beam_peer_grant_generation_mismatch}

      grant.controller_id != request.controller_id ->
        {:error, :beam_peer_credential_mismatch}

      true ->
        :ok
    end
  end

  defp validate_delivery_lifecycle(%Grant{state: :revoked}, _now),
    do: {:error, :beam_peer_grant_revoked}

  defp validate_delivery_lifecycle(%Grant{state: :expired}, _now),
    do: {:error, :beam_peer_grant_expired}

  defp validate_delivery_lifecycle(%Grant{state: state} = grant, now)
       when state in [:pending_delivery, :staged, :active, :delivery_failed] do
    cond do
      DateTime.compare(now, grant.not_before_at) == :lt ->
        {:error, :beam_peer_grant_not_active}

      DateTime.compare(now, grant.expires_at) != :lt ->
        {:error, :beam_peer_grant_expired}

      true ->
        :ok
    end
  end

  defp validate_delivery_lifecycle(%Grant{}, _now),
    do: {:error, :beam_peer_grant_not_active}

  defp validate_delivery_scope(grant, node, enrollment, controller, peer, opts) do
    with true <- peer.scheme == :mtls,
         true <- node.id == grant.node_id and node.state in [:admitted, :active],
         true <- controller.status == :operational,
         true <- node.canonical_beam_name == grant.node_beam_name,
         true <- enrollment.id == peer.enrollment_id,
         true <- enrollment.node_id == node.id,
         true <- enrollment.cluster_id == grant.cluster_id,
         true <- enrollment.expected_controller_id == controller.id,
         true <- enrollment.state == :consumed,
         true <- enrollment.certificate_issuance_outcome == :issued,
         true <- peer.node_id == node.id,
         {:ok, credential} <-
           NodeCredentials.authorize_peer(
             node.id,
             peer.certificate_identifier,
             peer.certificate_fingerprint,
             opts
           ),
         result = credential.certificate_result,
         true <- peer.node_uri_san == value(result, :node_uri_san),
         true <- peer.certificate_serial == value(result, :certificate_serial),
         true <- is_binary(peer.runtime_trust_spki_sha256),
         true <- is_binary(value(result, :runtime_trust_spki_sha256)),
         true <- peer.runtime_trust_spki_sha256 == value(result, :runtime_trust_spki_sha256),
         certificate_pem when is_binary(certificate_pem) <- value(result, :node_certificate_pem),
         {:ok, certificate} <- CertificateIdentity.from_pem(certificate_pem),
         true <- certificate.uri_sans == [peer.node_uri_san],
         true <- certificate.serial == peer.certificate_serial,
         true <- certificate.fingerprint == peer.certificate_fingerprint,
         true <- grant.node_certificate_identifier == peer.certificate_identifier,
         true <-
           grant.node_certificate_fingerprint_sha256 == peer.certificate_fingerprint,
         true <- grant.controller_beam_name == controller.canonical_beam_name,
         true <-
           grant.controller_certificate_identifier == controller.certificate_identifier,
         true <-
           grant.controller_certificate_fingerprint_sha256 ==
             controller.certificate_fingerprint_sha256,
         true <-
           grant.beam_authorization_root_id == controller.beam_authorization_root_id do
      :ok
    else
      _other -> {:error, :beam_peer_credential_mismatch}
    end
  end

  defp mark_delivered(%Grant{state: state} = grant, _peer, _now, opts)
       when state in [:active, :staged] do
    with :ok <- ensure_grant_current(grant, [state], opts) do
      {:ok, grant}
    end
  end

  defp mark_delivered(%Grant{} = grant, peer, _now, opts) do
    evidence = %{
      "certificate_identifier" => peer.certificate_identifier,
      "generation" => grant.generation,
      "node_id" => peer.node_id,
      "scheme" => "mtls"
    }

    with :ok <- ensure_grant_current(grant, [:pending_delivery, :delivery_failed], opts),
         {1, _rows} <-
           update_delivery_transition(grant, evidence, opts) do
      {:ok, Repo.get!(Grant, grant.id)}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_peer_grant_expired}
    end
  end

  defp acknowledged_state(%Grant{generation: 1}), do: :active
  defp acknowledged_state(%Grant{}), do: :staged

  defp update_delivery_transition(grant, evidence, opts) do
    query = current_grant_query(grant, [:pending_delivery, :delivery_failed])

    case Keyword.get(opts, :test_database_now) do
      database_now when is_function(database_now, 0) ->
        delivered_at = database_now.() |> DateTime.truncate(:microsecond)

        query
        |> update([candidate],
          set: [
            delivered_at: ^delivered_at,
            delivery_evidence: ^evidence
          ]
        )
        |> Repo.update_all([])

      nil ->
        query
        |> update([candidate],
          set: [
            delivered_at: fragment("clock_timestamp()"),
            delivery_evidence: ^evidence
          ]
        )
        |> Repo.update_all([])

      _invalid ->
        {0, nil}
    end
  rescue
    _error -> {:error, :beam_peer_grant_delivery_unavailable}
  end

  defp acknowledge_grant(%Grant{state: state} = grant, request, _now, _opts)
       when state in [:active, :staged] do
    evidence = grant.node_staging_evidence

    if evidence["installation_id"] == request.installation_id and
         evidence["local_identity_generation_id"] == request.local_identity_generation_id do
      {:ok, grant}
    else
      {:error, :beam_peer_grant_staging_proof_invalid}
    end
  end

  defp acknowledge_grant(%Grant{} = grant, request, now, opts) do
    evidence = %{
      "generation" => grant.generation,
      "installation_id" => request.installation_id,
      "local_identity_generation_id" => request.local_identity_generation_id,
      "node_id" => grant.node_id,
      "proof" => "mtls_after_atomic_local_publication"
    }

    state = acknowledged_state(grant)
    query = current_grant_query(grant, [:pending_delivery, :delivery_failed])

    with :ok <- ensure_grant_current(grant, [:pending_delivery, :delivery_failed], opts),
         {1, _rows} <-
           query
           |> update([candidate],
             set: [
               state: ^state,
               node_staged_at: ^now,
               node_staging_evidence: ^evidence
             ]
           )
           |> Repo.update_all([]) do
      {:ok, Repo.get!(Grant, grant.id)}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :beam_peer_grant_staging_proof_invalid}
    end
  end

  defp ensure_grant_current(grant, allowed_states, opts) do
    case Keyword.get(opts, :test_database_now) do
      database_now when is_function(database_now, 0) ->
        validate_current_grant(grant, allowed_states, database_now.())

      nil ->
        if grant |> current_grant_query(allowed_states) |> Repo.exists?() do
          :ok
        else
          {:error, :beam_peer_grant_expired}
        end

      _invalid ->
        {:error, :beam_peer_grant_expired}
    end
  end

  defp validate_current_grant(grant, allowed_states, %DateTime{} = database_now) do
    if grant.state in allowed_states do
      validate_delivery_lifecycle(grant, DateTime.truncate(database_now, :microsecond))
    else
      {:error, :beam_peer_grant_not_active}
    end
  end

  defp validate_current_grant(_grant, _allowed_states, _database_now),
    do: {:error, :beam_peer_grant_expired}

  defp current_grant_query(%Grant{id: grant_id}, allowed_states),
    do: current_grant_query(grant_id, allowed_states)

  defp current_grant_query(grant_id, allowed_states) do
    Grant
    |> where([candidate], candidate.id == ^grant_id)
    |> where([candidate], candidate.state in ^allowed_states)
    |> where([candidate], fragment("? <= clock_timestamp()", candidate.not_before_at))
    |> where([candidate], fragment("? > clock_timestamp()", candidate.expires_at))
  end

  defp delivery_payload(grant, secret) do
    grant
    |> Map.from_struct()
    |> Map.take([
      :cluster_id,
      :controller_id,
      :controller_beam_name,
      :controller_certificate_identifier,
      :controller_certificate_fingerprint_sha256,
      :beam_authorization_root_id,
      :node_id,
      :node_beam_name,
      :node_certificate_identifier,
      :node_certificate_fingerprint_sha256,
      :contract_version,
      :purpose,
      :generation,
      :issued_at,
      :not_before_at,
      :cutover_at,
      :expires_at
    ])
    |> Map.put(:grant_id, grant.id)
    |> Map.put(:encoded_secret, secret.encoded_secret)
    |> Map.put(:secret_hash, secret.secret_hash)
  end

  defp lock_grant(grant_id) do
    Grant
    |> where([grant], grant.id == ^grant_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp authorize_target_locked(grant_id, target, opts) do
    with %Grant{} = scope <- Repo.get(Grant, grant_id),
         %Node{} = node <- lock_node(scope.node_id),
         %Grant{} = grant <- lock_grant(grant_id) do
      authorize_existing_target(grant, node, target, opts)
    else
      _other -> Repo.rollback(:beam_peer_grant_missing)
    end
  end

  defp authorize_existing_target(grant, node, target, opts) do
    with :ok <- validate_target_beam_name(grant, target),
         :ok <- validate_target_generation(grant, target),
         {:ok, grant} <- authorize_target_lifecycle(grant, DateTime.utc_now()),
         :ok <- ensure_predecessor_disconnected(grant),
         %Enrollment{} = enrollment <- lock_target_enrollment(target),
         %ControllerInstance{} = controller <- lock_controller(grant.controller_id),
         {:ok, peer} <- authenticated_peer(enrollment),
         :ok <- validate_target_peer_binding(target, peer),
         :ok <- validate_target_controller_binding(target, controller),
         :ok <- validate_delivery_scope(grant, node, enrollment, controller, peer, opts),
         :ok <- validate_controller_binding(controller),
         {:ok, authorization_root} <- load_authorization_root(controller, opts),
         {:ok, secret} <- Secret.derive(Map.from_struct(grant), authorization_root.key),
         true <- secret.secret_hash == grant.secret_hash,
         :ok <- ensure_grant_current(grant, [:active], opts) do
      %{
        authenticated_peer: peer,
        encoded_secret: secret.encoded_secret,
        grant: grant,
        node_name: grant.node_beam_name,
        secret_hash: secret.secret_hash
      }
    else
      nil -> Repo.rollback(:beam_peer_credential_mismatch)
      {:error, reason} -> Repo.rollback(reason)
      false -> Repo.rollback(:beam_peer_credential_mismatch)
      _other -> Repo.rollback(:beam_peer_credential_mismatch)
    end
  end

  defp lock_target_enrollment(%Target{metadata: metadata}) do
    case Ecto.UUID.cast(value(metadata, :enrollment_id)) do
      {:ok, enrollment_id} -> lock_enrollment(enrollment_id)
      :error -> nil
    end
  end

  defp authenticated_peer(%Enrollment{} = enrollment) do
    with {:ok, credential} <- NodeCredentials.current(enrollment.node_id),
         result = credential.certificate_result,
         certificate_pem when is_binary(certificate_pem) <- value(result, :node_certificate_pem),
         {:ok, certificate} <- CertificateIdentity.from_pem(certificate_pem) do
      {:ok,
       %AuthenticatedPeer{
         node_id: enrollment.node_id,
         node_uri_san: value(result, :node_uri_san),
         enrollment_id: enrollment.id,
         certificate_identifier: credential.certificate_identifier,
         certificate_serial: certificate.serial,
         certificate_fingerprint: certificate.fingerprint,
         runtime_trust_spki_sha256: value(result, :runtime_trust_spki_sha256)
       }}
    else
      _other -> {:error, :beam_peer_credential_mismatch}
    end
  end

  defp authenticated_peer_from_certificate(certificate_der) do
    with {:ok, certificate} <- CertificateIdentity.from_der(certificate_der),
         [node_uri_san] <- certificate.uri_sans,
         {:ok, cluster_id, node_id} <- parse_node_uri_san(node_uri_san),
         [%AuthenticatedPeer{} = peer] <-
           matching_certificate_peers(cluster_id, node_id, certificate) do
      {:ok, peer}
    else
      _other -> {:error, :beam_peer_credential_mismatch}
    end
  end

  defp parse_node_uri_san(node_uri_san) do
    case String.split(node_uri_san, ":") do
      ["urn", "orchard", "cluster", cluster_id, "node", node_id] ->
        with {:ok, cluster_id} <- Ecto.UUID.cast(cluster_id),
             {:ok, node_id} <- Ecto.UUID.cast(node_id) do
          {:ok, cluster_id, node_id}
        end

      _parts ->
        {:error, :beam_peer_credential_mismatch}
    end
  end

  defp matching_certificate_peers(cluster_id, node_id, certificate) do
    CredentialGeneration
    |> where([generation], generation.cluster_id == ^cluster_id)
    |> where([generation], generation.node_id == ^node_id)
    |> where([generation], generation.state in [:current, :staged])
    |> Repo.all()
    |> Enum.flat_map(&matching_generation_peer(&1, certificate))
  end

  defp matching_generation_peer(generation, certificate) do
    result = generation.certificate_result

    with true <- generation.certificate_fingerprint_sha256 == certificate.fingerprint,
         true <- value(result, :certificate_serial) == certificate.serial,
         [node_uri_san] <- certificate.uri_sans,
         {:ok, _accepted} <-
           NodeCredentials.authorize_peer(
             generation.node_id,
             generation.certificate_identifier,
             certificate.fingerprint
           ) do
      [
        %AuthenticatedPeer{
          node_id: generation.node_id,
          node_uri_san: node_uri_san,
          enrollment_id: generation.enrollment_id,
          certificate_identifier: generation.certificate_identifier,
          certificate_serial: certificate.serial,
          certificate_fingerprint: certificate.fingerprint,
          runtime_trust_spki_sha256: value(result, :runtime_trust_spki_sha256)
        }
      ]
    else
      _other -> []
    end
  end

  defp validate_target_peer_binding(%Target{} = target, peer) do
    metadata = target.metadata

    valid =
      [
        target.id == "beam:#{peer.node_id}",
        target.transport == :beam,
        target.node_id == peer.node_id,
        value(metadata, :source) in [:trusted_node_inventory, "trusted_node_inventory"],
        value(metadata, :enrollment_id) == peer.enrollment_id,
        value(metadata, :certificate_identifier) == peer.certificate_identifier,
        value(metadata, :certificate_serial) == peer.certificate_serial,
        value(metadata, :certificate_fingerprint) == peer.certificate_fingerprint,
        value(metadata, :node_uri_san) == peer.node_uri_san,
        value(metadata, :runtime_trust_spki_sha256) == peer.runtime_trust_spki_sha256
      ]
      |> Enum.all?()

    if valid do
      :ok
    else
      {:error, :beam_peer_credential_mismatch}
    end
  end

  defp validate_target_controller_binding(%Target{metadata: metadata}, controller) do
    if controller.status == :operational and
         value(metadata, :controller_id) == controller.id and
         value(metadata, :controller_beam_name) == controller.canonical_beam_name and
         value(metadata, :controller_certificate_identifier) ==
           controller.certificate_identifier and
         value(metadata, :controller_certificate_fingerprint_sha256) ==
           controller.certificate_fingerprint_sha256 and
         value(metadata, :beam_authorization_root_id) ==
           controller.beam_authorization_root_id do
      :ok
    else
      {:error, :beam_peer_credential_mismatch}
    end
  end

  defp validate_target_beam_name(%Grant{node_beam_name: beam_name}, %Target{address: beam_name}),
    do: :ok

  defp validate_target_beam_name(%Grant{}, %Target{}),
    do: {:error, :beam_peer_credential_mismatch}

  defp validate_target_generation(%Grant{generation: generation}, %Target{metadata: metadata}) do
    if value(metadata, :generation) == generation do
      :ok
    else
      {:error, :beam_peer_grant_generation_mismatch}
    end
  end

  defp authorize_target_lifecycle(%Grant{state: :revoked}, _now),
    do: {:error, :beam_peer_grant_revoked}

  defp authorize_target_lifecycle(%Grant{state: :expired}, _now),
    do: {:error, :beam_peer_grant_expired}

  defp authorize_target_lifecycle(%Grant{state: :active} = grant, now) do
    cond do
      DateTime.compare(now, grant.not_before_at) == :lt ->
        {:error, :beam_peer_grant_not_active}

      DateTime.compare(now, grant.expires_at) != :lt ->
        {:error, :beam_peer_grant_expired}

      true ->
        {:ok, grant}
    end
  end

  defp authorize_target_lifecycle(%Grant{}, _now),
    do: {:error, :beam_peer_grant_not_active}

  defp lock_node(node_id) do
    Node
    |> where([node], node.id == ^node_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_enrollment(enrollment_id) do
    Enrollment
    |> where([enrollment], enrollment.id == ^enrollment_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_controller(controller_id) do
    ControllerInstance
    |> where([controller], controller.id == ^controller_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_pair_grant(node_id, state) do
    Grant
    |> where([grant], grant.node_id == ^node_id and grant.state == ^state)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp pair_grant(node_id, state) do
    Repo.get_by(Grant, node_id: node_id, state: state)
  end

  defp lock_rotation_credential(node_id) do
    CredentialGeneration
    |> where([generation], generation.node_id == ^node_id)
    |> where([generation], generation.state in [:current, :staged])
    |> order_by([generation], desc: generation.generation)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_grant_credential(grant) do
    CredentialGeneration
    |> where([generation], generation.node_id == ^grant.node_id)
    |> where([generation], generation.state in [:current, :staged])
    |> where(
      [generation],
      generation.certificate_identifier == ^grant.node_certificate_identifier
    )
    |> where(
      [generation],
      generation.certificate_fingerprint_sha256 ==
        ^grant.node_certificate_fingerprint_sha256
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_enrollment_binding(node) do
    enrollment =
      Enrollment
      |> where([enrollment], enrollment.node_id == ^node.id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    with %Enrollment{
           state: :consumed,
           certificate_issuance_outcome: :issued,
           expected_controller_id: controller_id
         } = enrollment <- enrollment,
         true <- is_binary(controller_id),
         true <- is_binary(enrollment.certificate_identifier),
         result when is_map(result) <- enrollment.certificate_result,
         certificate_pem when is_binary(certificate_pem) <- value(result, :node_certificate_pem),
         {:ok, certificate} <- CertificateIdentity.from_pem(certificate_pem),
         true <- certificate.serial == value(result, :certificate_serial),
         true <-
           certificate.uri_sans == [
             "urn:orchard:cluster:#{enrollment.cluster_id}:node:#{node.id}"
           ],
         true <- enrollment.certificate_identifier == value(result, :certificate_identifier) do
      {:ok, enrollment, certificate}
    else
      _other -> {:error, :beam_peer_grant_node_certificate_invalid}
    end
  end

  defp validate_enrollment_controller(enrollment, controller) do
    if enrollment.expected_controller_id == controller.id do
      :ok
    else
      {:error, :beam_peer_grant_node_certificate_invalid}
    end
  end

  defp validate_controller_binding(controller) do
    with {:ok, trust} <- NodeTrust.public_material(),
         {:ok, certificate} <- CertificateIdentity.from_pem(trust.controller_certificate_pem),
         true <- controller.id == trust.controller_id,
         true <- controller.certificate_uri_san == trust.controller_uri_san,
         true <- certificate.uri_sans == [controller.certificate_uri_san],
         true <- certificate.fingerprint == controller.certificate_fingerprint_sha256,
         true <- controller.certificate_identifier == "serial:#{certificate.serial}" do
      :ok
    else
      _other -> {:error, :beam_peer_grant_controller_certificate_invalid}
    end
  end

  defp put_preloaded_authorization_root(opts) do
    # Preload off the DB lock when available; when it is not, defer to the
    # in-transaction load so grant-scope failures (e.g. missing grant) keep
    # precedence over the authorization-root-unavailable failure.
    case load_authorization_root_material() do
      {:ok, authorization_root} ->
        {:ok, Keyword.put(opts, :preloaded_authorization_root, authorization_root)}

      {:error, _reason} ->
        {:ok, opts}
    end
  end

  defp load_authorization_root(controller, opts) do
    with {:ok, authorization_root} <- resolve_authorization_root(opts),
         true <- authorization_root.root_id == controller.beam_authorization_root_id do
      {:ok, authorization_root}
    else
      _other -> {:error, :beam_authorization_root_unavailable}
    end
  end

  defp resolve_authorization_root(opts) do
    case Keyword.fetch(opts, :preloaded_authorization_root) do
      {:ok, authorization_root} -> {:ok, authorization_root}
      :error -> load_authorization_root_material()
    end
  end

  defp load_authorization_root_material do
    with {:ok, path} <- authorization_root_path(),
         {:ok, authorization_root} <- AuthorizationRootStore.load(path) do
      {:ok, authorization_root}
    else
      _other -> {:error, :beam_authorization_root_unavailable}
    end
  end

  defp authorization_root_path do
    :orchard_controller
    |> Application.get_env(:beam_peer_grants, [])
    |> Keyword.get(:authorization_root_path)
    |> case do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _other -> {:error, :beam_authorization_root_unavailable}
    end
  end

  defp canonical_node_name(node) do
    with host when is_binary(host) <- node.connect_host || node.advertise_addr,
         {:ok, _address} <- BeamNodeName.private_ipv4(host) do
      compact_id = String.replace(node.id, "-", "")
      {:ok, "orchard_node_agent_#{compact_id}@#{host}"}
    else
      _other -> {:error, :beam_node_canonical_name_invalid}
    end
  end

  defp persist_canonical_node_name(node, canonical_name) do
    node
    |> Node.changeset(%{canonical_beam_name: canonical_name})
    |> Repo.update()
  end

  defp initial_attrs(
         node,
         node_beam_name,
         controller,
         enrollment,
         node_certificate,
         authorization_root,
         opts
       ) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    %{
      id: Ecto.UUID.generate(),
      generation: 1,
      cluster_id: enrollment.cluster_id,
      controller_id: controller.id,
      controller_beam_name: controller.canonical_beam_name,
      controller_certificate_identifier: controller.certificate_identifier,
      controller_certificate_fingerprint_sha256: controller.certificate_fingerprint_sha256,
      beam_authorization_root_id: authorization_root.root_id,
      node_id: node.id,
      node_beam_name: node_beam_name,
      node_certificate_identifier: enrollment.certificate_identifier,
      node_certificate_fingerprint_sha256: node_certificate.fingerprint,
      contract_version: @contract_version,
      purpose: @purpose,
      state: :pending_delivery,
      issued_at: now,
      not_before_at: now,
      cutover_at: nil,
      expires_at: DateTime.add(now, @initial_validity_days, :day),
      delivery_evidence: %{},
      activation_evidence: %{},
      supersession_evidence: %{},
      failure_evidence: %{},
      revocation_evidence: %{}
    }
  end

  defp insert_grant(attrs) do
    %Grant{}
    |> Grant.insert_changeset(attrs)
    |> Repo.insert()
  end

  defp run_fault_checkpoint(opts, checkpoint) do
    case Keyword.get(opts, :test_fault_injector) do
      injector when is_function(injector, 1) -> injector.(checkpoint)
      _other -> :ok
    end
  end

  defp run_lock_observer(opts, lock_name) do
    case Keyword.get(opts, :test_lock_observer) do
      observer when is_function(observer, 1) -> observer.(lock_name)
      _other -> :ok
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
