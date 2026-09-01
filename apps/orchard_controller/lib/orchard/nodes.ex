defmodule Orchard.Nodes do
  @moduledoc """
  Persistence context for node inventory.

  Stores trusted node inventory and admission review state.

  First-observed Runtime Endpoint metadata is persisted as admission candidate
  evidence until a trusted node registration and explicit admission path exists.

  This context is also the queue-source-refresh capacity consumer: observed
  Runtime Endpoint capacity is republished as bounded queue sources only when
  the shared dispatch-capacity evaluation is eligible with positive available
  slots, and Node-owned sources are cleared on trust, lifecycle, health,
  freshness, policy, or runtime-limit loss. Node admission serializes its
  capacity-policy write through the same per-Node acceptance gate dispatch
  holds.
  """

  use Orchard.DispatchCapacity.Consumer, wiring: :node_queue_source_refresh

  import Ecto.Query

  @doc "Refreshes or clears Node-owned queue sources from one shared capacity evaluation."
  @spec refresh_dispatch_capacity_sources(
          map(),
          Evaluator.Input.t(),
          map(),
          keyword()
        ) :: Evaluator.Result.t()
  def refresh_dispatch_capacity_sources(node, input, refresh, opts \\ [])
      when is_map(node) and is_map(refresh) and is_list(opts) do
    authority = Keyword.get(opts, :authority, AllocationAuthority)
    queue_manager = Keyword.get(opts, :queue_manager, Orchard.Inference.queue_manager())
    node_id = Map.get(node, :id) || Map.get(node, "id")

    result = evaluate_dispatch_capacity(authority, node_id, input)

    if Consumer.authorized?(result) do
      refresh
      |> Map.put(:node_active, 0)
      |> Map.put(:node_max, result.available_slots)
      |> Map.put(:dispatch_capacity_evaluation, result)
      |> queue_manager.refresh_node_capacity_sources()
    else
      queue_manager.clear_capacity_sources(Map.fetch!(refresh, :clear_sources), promote?: true)
    end

    result
  end

  require Logger

  @doc "Clears all process-local queue-capacity sources owned by a trusted Node ID."
  @spec clear_dispatch_capacity_sources(Ecto.UUID.t(), keyword()) :: :ok
  def clear_dispatch_capacity_sources(node_id, opts \\ []) do
    with {:ok, node_id} <- Ecto.UUID.cast(node_id) do
      queue_manager = Keyword.get(opts, :queue_manager, Orchard.Inference.queue_manager())

      queue_manager.clear_capacity_sources(
        node_queue_capacity_sources(node_id),
        promote?: Keyword.get(opts, :promote?, true)
      )
    end

    :ok
  rescue
    error ->
      Logger.debug("Queue capacity source clear for node failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("Queue capacity source clear for node exited: #{inspect(reason)}")
      :ok
  end

  alias Orchard.BeamPeerGrants
  alias Orchard.ControllerInstances
  alias Orchard.ControllerInstances.ControllerInstance
  alias Orchard.ControlPlane
  alias Orchard.DispatchCapacity
  alias Orchard.DispatchCapacity.Authorization
  alias Orchard.Governance
  alias Orchard.Governance.{AuditLog, AuditWriter}
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Enrollment, Node}
  alias Orchard.Nodes.ToolCapability
  alias Orchard.Nodes.ToolReadiness
  alias Orchard.Repo

  alias Orchard.RuntimeEndpoint.{
    AuthenticatedPeer,
    GrpcCompatibilityMapper,
    ModelRef,
    Observation,
    Placement,
    PlacementCapacity,
    Target
  }

  alias Orchard.SchemaSupport
  alias Orchard.TransportTLS.CertificateIdentity

  @snapshot_entry_limit 40
  @snapshot_max_depth 4
  @snapshot_string_limit_bytes 512
  @snapshot_truncation_key "__orchard_snapshot_truncation__"
  @authenticated_observation_future_skew_ms 5_000
  @reserved_actor_provenance_keys ~w(actor_id actor_type)
  @dispatch_database_errors [
    DBConnection.ConnectionError,
    DBConnection.OwnershipError,
    Postgrex.Error
  ]

  # -- Read APIs --

  @doc """
  Lists all nodes ordered by display_name, then id.

  Returns `[]` when the repo is unavailable.
  """
  @spec list_nodes() :: [Node.t()]
  def list_nodes do
    if repo_available?() do
      list_nodes_for_upgrade!()
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Lists node inventory for upgrade preflight.

  Unlike `list_nodes/0`, this function lets query failures propagate so safety
  checks can distinguish empty inventory from unavailable inventory.
  """
  @spec list_nodes_for_upgrade!() :: [struct()]
  def list_nodes_for_upgrade! do
    Node
    |> order_by([n], asc: n.display_name, asc: n.id)
    |> Repo.all()
  end

  @doc """
  Returns a summary of node counts grouped by state and health.

  All enum values are present, zero-filled when no rows exist.
  Returns a zero-filled summary when the repo is unavailable.
  """
  @spec summary() :: %{
          total: non_neg_integer(),
          by_state: %{required(atom()) => non_neg_integer()},
          by_health: %{required(atom()) => non_neg_integer()}
        }
  def summary do
    if repo_available?() do
      state_counts =
        Node
        |> group_by([n], n.state)
        |> select([n], {n.state, count(n.id)})
        |> Repo.all()
        |> Map.new()

      health_counts =
        Node
        |> group_by([n], n.health)
        |> select([n], {n.health, count(n.id)})
        |> Repo.all()
        |> Map.new()

      by_state = zero_fill(state_counts, Node.states())
      by_health = zero_fill(health_counts, Node.health_values())

      %{
        total: by_state |> Map.values() |> Enum.sum(),
        by_state: by_state,
        by_health: by_health
      }
    else
      empty_summary()
    end
  rescue
    _ -> empty_summary()
  end

  @doc """
  Returns nodes eligible for multi-node scheduling.

  Eligible nodes must be:
  - state: `:active`
  - health: `:healthy` or `:degraded`
  - `last_heartbeat_at` within the freshness threshold

  Returns `[]` when the repo is unavailable.
  """
  @spec schedulable_nodes() :: [Node.t()]
  def schedulable_nodes do
    if repo_available?() do
      threshold_ms = Orchard.Inference.node_freshness_threshold_ms()
      cutoff = DateTime.add(DateTime.utc_now(), -threshold_ms, :millisecond)

      Node
      |> where([n], n.state == :active)
      |> where([n], n.health in [:healthy, :degraded])
      |> where([n], not is_nil(n.last_heartbeat_at))
      |> where([n], n.last_heartbeat_at >= ^cutoff)
      |> order_by([n], asc: n.id)
      |> Repo.all()
    else
      []
    end
  rescue
    _ -> []
  end

  @doc """
  Returns certificate-backed targets for status-only liveness and activation probes.

  Includes both `:admitted` (activation) and `:active` (idle liveness) Nodes so the
  single supervised probe can refresh heartbeats without a second poller.
  """
  @spec activation_probe_runtime_endpoint_targets() ::
          {:ok, [Target.t()]} | {:error, :node_inventory_unavailable}
  def activation_probe_runtime_endpoint_targets do
    trusted_runtime_endpoint_targets_for_states([:admitted, :active])
  end

  @doc "Returns certificate-backed targets authorized for inference and dispatch."
  @spec active_runtime_endpoint_targets() ::
          {:ok, [Target.t()]} | {:error, :node_inventory_unavailable}
  def active_runtime_endpoint_targets do
    trusted_runtime_endpoint_targets_for_states([:active])
  end

  @spec authorize_inference_target(Target.t()) ::
          :ok | {:error, :runtime_target_not_active | :node_inventory_unavailable}
  def authorize_inference_target(%Target{} = target) do
    case active_runtime_endpoint_targets() do
      {:ok, targets} ->
        if Enum.any?(targets, &(&1 == Target.normalize(target))) do
          :ok
        else
          {:error, :runtime_target_not_active}
        end

      {:error, :node_inventory_unavailable} = error ->
        error
    end
  end

  defp trusted_runtime_endpoint_targets_for_states(states) do
    if repo_available?() do
      targets = trusted_runtime_endpoint_targets(states)

      {:ok, targets}
    else
      {:error, :node_inventory_unavailable}
    end
  rescue
    _ -> {:error, :node_inventory_unavailable}
  end

  defp trusted_runtime_endpoint_targets(states) do
    if BeamPeerGrants.production_enabled?() do
      trusted_beam_runtime_endpoint_targets(states)
    else
      trusted_grpc_runtime_endpoint_targets(states)
    end
  end

  defp trusted_grpc_runtime_endpoint_targets(states) do
    Node
    |> join(:inner, [node], enrollment in Enrollment, on: enrollment.node_id == node.id)
    |> where([node, _enrollment], node.state in ^states)
    |> where([_node, enrollment], enrollment.state == :consumed)
    |> where([_node, enrollment], enrollment.certificate_issuance_outcome == :issued)
    |> where([_node, enrollment], not is_nil(enrollment.certificate_identifier))
    |> order_by([node, _enrollment], asc: node.id)
    |> select([node, enrollment], {node, enrollment})
    |> Repo.all()
    |> Enum.flat_map(&trusted_runtime_endpoint_target/1)
  end

  defp trusted_beam_runtime_endpoint_targets(states) do
    now = DateTime.utc_now()

    Node
    |> join(:inner, [node], enrollment in Enrollment, on: enrollment.node_id == node.id)
    |> join(:inner, [node, _enrollment], grant in Orchard.BeamPeerGrants.Grant,
      on: grant.node_id == node.id
    )
    |> join(:inner, [_node, _enrollment, grant], controller in ControllerInstance,
      on: controller.id == grant.controller_id
    )
    |> where([node, _enrollment, _grant, _controller], node.state in ^states)
    |> where([_node, enrollment, _grant, _controller], enrollment.state == :consumed)
    |> where(
      [_node, enrollment, _grant, _controller],
      enrollment.certificate_issuance_outcome == :issued
    )
    |> where([_node, _enrollment, _grant, controller], controller.status == :operational)
    |> where([_node, _enrollment, grant, _controller], grant.state == :active)
    |> where([_node, _enrollment, grant, _controller], grant.not_before_at <= ^now)
    |> where([_node, _enrollment, grant, _controller], grant.expires_at > ^now)
    |> order_by([node, _enrollment, grant, _controller],
      asc: node.id,
      asc: grant.generation
    )
    |> select([node, enrollment, grant, _controller], {node, enrollment, grant})
    |> Repo.all()
    |> Enum.flat_map(&trusted_beam_runtime_endpoint_target/1)
  end

  @spec unreachable_threshold_ms() :: pos_integer()
  def unreachable_threshold_ms do
    Orchard.Inference.node_unreachable_threshold_ms()
  end

  @doc """
  Fetches a node by ID. Raises on not found.
  """
  @spec get_node!(Ecto.UUID.t()) :: Node.t()
  def get_node!(id), do: Repo.get!(Node, id)

  @doc """
  Fetches a node by ID for API and CLI surfaces.
  """
  @spec fetch_node(Ecto.UUID.t()) :: {:ok, Node.t()} | {:error, :node_not_found}
  def fetch_node(id) do
    with {:ok, id} <- normalize_uuid(id, :node_not_found) do
      case Repo.get(Node, id) do
        %Node{} = node -> {:ok, node}
        nil -> {:error, :node_not_found}
      end
    end
  end

  @doc """
  Lists node admission candidates ordered for operator review.
  """
  @spec list_admission_candidates(keyword()) :: [AdmissionCandidate.t()]
  def list_admission_candidates(opts \\ []) do
    category = Keyword.get(opts, :admission_category)

    AdmissionCandidate
    |> maybe_filter_candidate_category(category)
    |> order_by([candidate], desc_nulls_last: candidate.last_observed_at, asc: candidate.id)
    |> Repo.all()
  end

  @doc """
  Fetches a node admission candidate by ID. Raises on not found.
  """
  @spec get_admission_candidate!(Ecto.UUID.t()) :: AdmissionCandidate.t()
  def get_admission_candidate!(id), do: Repo.get!(AdmissionCandidate, id)

  @doc """
  Fetches a node admission candidate by ID for API surfaces.
  """
  @spec fetch_admission_candidate(Ecto.UUID.t()) ::
          {:ok, AdmissionCandidate.t()} | {:error, :candidate_not_found}
  def fetch_admission_candidate(id) do
    with {:ok, id} <- normalize_uuid(id, :candidate_not_found) do
      case Repo.get(AdmissionCandidate, id) do
        %AdmissionCandidate{} = candidate -> {:ok, candidate}
        nil -> {:error, :candidate_not_found}
      end
    end
  end

  @doc """
  Looks up a node by its connection target.

  Accepts a target keyword list matching the scheduler/dispatch shape:
  `[host: "127.0.0.1", port: 50071]`, or a Runtime Endpoint target.
  BEAM Runtime Endpoint targets resolve by configured `node_id` first, then by
  target metadata containing a connect/listen host and port.

  Returns `nil` when no match, target is malformed, or repo is unavailable.
  """
  @spec lookup_by_target(keyword() | Target.t()) :: Node.t() | nil
  def lookup_by_target(target) do
    case lookup_by_target_result(target) do
      {:ok, node} -> node
      {:error, :node_inventory_unavailable} -> nil
    end
  end

  @doc "Resolves target inventory without conflating absence with repository failure."
  @spec lookup_by_target_result(keyword() | Target.t()) ::
          {:ok, Node.t() | nil} | {:error, :node_inventory_unavailable}
  def lookup_by_target_result(target) do
    with true <- repo_available?(),
         {:ok, target_lookup} <- target_lookup(target) do
      {:ok, lookup_node_by_target_lookup(target_lookup)}
    else
      false -> {:error, :node_inventory_unavailable}
      :error -> {:ok, nil}
    end
  rescue
    _error -> {:error, :node_inventory_unavailable}
  catch
    _kind, _reason -> {:error, :node_inventory_unavailable}
  end

  # -- Observational Write APIs --

  @doc """
  Observes a successful Runtime Endpoint status observation.

  Normalizes metadata from a Runtime Endpoint Observation, `StatusResponse`,
  or compatible map before resolving conflicts (identity, display_name,
  staleness) and updating a trusted node row or admission candidate.

  First observations that do not match a trusted node create or update a
  Runtime Endpoint Admission Candidate and return `:noop`.
  Updates preserve admin-managed lifecycle. The separate authenticated
  observation seam owns `admitted -> active` transitions.
  Successful eligible observations also refresh source-scoped queue capacity
  from aggregate endpoint capacity and loaded placement statuses.
  Fresh invalid metadata, identity conflicts, ineligible nodes, and target
  failures clear stale queue capacity sources for that node/target.
  BEAM Runtime Endpoint observations refresh queue capacity only when the
  target resolves back to the same persisted node identity.

  Options:
  - `:reserve_unassigned_node_grants?` - reserve unassigned active grants
    while reconciling node capacity (default: `true`)
  - `:reserve_unassigned_source_grants?` - reserve unassigned source-backed
    grants while reconciling node capacity (default: `true`)

  Returns:
  - `{:ok, %Node{}}` on insert or update
  - `:noop` when metadata is missing/invalid, repo unavailable,
    observation is stale, or an identity conflict is detected
  """
  @spec observe_status(keyword() | Target.t(), map() | struct(), DateTime.t()) ::
          {:ok, Node.t()} | :noop
  @spec observe_status(keyword() | Target.t(), map() | struct(), DateTime.t(), keyword()) ::
          {:ok, Node.t()} | :noop
  def observe_status(target, status_response, observed_at, opts \\ []) do
    if repo_available?() do
      case normalize_observation(target, status_response, observed_at) do
        {:ok, observation} ->
          handle_observation_result(
            target,
            observed_at,
            execute_observe(observation),
            status_response,
            opts
          )

        :error ->
          clear_existing_target_queue_capacity_sources(target, observed_at)
          :noop
      end
    else
      :noop
    end
  rescue
    _ -> :noop
  end

  @doc """
  Persists unauthenticated Runtime Endpoint observation evidence as an admission candidate only.

  Used by controller discovery bootstrap for configured BEAM targets. This path never
  updates Node rows, never refreshes queue capacity sources, and never clears capacity
  sources. Invalid or conflicting evidence returns `:noop`.
  """
  @spec observe_admission_candidate(keyword() | Target.t(), map() | struct(), DateTime.t()) ::
          :ok | :noop
  def observe_admission_candidate(target, status_response, observed_at) do
    with true <- repo_available?(),
         {:ok, observation} <- normalize_observation(target, status_response, observed_at),
         {:ok, :candidate_persisted} <- execute_candidate_only_observe(observation) do
      :ok
    else
      _other -> :noop
    end
  rescue
    _ -> :noop
  end

  @doc """
  Applies an authenticated Runtime Endpoint observation to trusted inventory.

  The peer identity must come from transport certificate verification and
  contain the certificate-bound Node ID plus its issued certificate identifier.
  The target, reported identity, persisted Node, and consumed enrollment are
  revalidated under row locks before any lifecycle update.
  """
  @spec observe_authenticated_status(
          Target.t(),
          map() | struct(),
          DateTime.t(),
          AuthenticatedPeer.t(),
          keyword()
        ) ::
          {:ok, Node.t()} | :noop
  def observe_authenticated_status(
        target,
        status_response,
        observed_at,
        peer_identity,
        opts \\ []
      ) do
    case normalize_authenticated_peer_identity(peer_identity) do
      {:ok, peer_identity} ->
        observe_with_authenticated_peer(
          target,
          status_response,
          observed_at,
          peer_identity,
          opts
        )

      :error ->
        clear_authenticated_peer_sources(peer_identity, opts)
        :noop
    end
  end

  defp clear_authenticated_peer_sources(
         %AuthenticatedPeer{scheme: :mtls, node_id: node_id},
         opts
       ) do
    case Ecto.UUID.cast(node_id) do
      {:ok, trusted_node_id} -> clear_dispatch_capacity_sources(trusted_node_id, opts)
      :error -> :ok
    end
  end

  defp clear_authenticated_peer_sources(_peer_identity, _opts), do: :ok

  defp observe_with_authenticated_peer(
         target,
         status_response,
         observed_at,
         peer_identity,
         opts
       ) do
    with true <- repo_available?(),
         :ok <- ControlPlane.authorize_write_path(:node_lifecycle),
         true <- authenticated_status_health_present?(status_response),
         {:ok, candidate_observation} <-
           normalize_candidate_observation(target, status_response),
         {:ok, observation} <-
           normalize_observation(target, candidate_observation, observed_at),
         true <- observation.id == peer_identity.node_id do
      handle_authenticated_observation_result(
        target,
        execute_authenticated_observe(
          target,
          observation,
          peer_identity,
          candidate_observation,
          opts
        ),
        candidate_observation,
        peer_identity.node_id,
        opts
      )
    else
      _other ->
        clear_dispatch_capacity_sources(peer_identity.node_id, opts)
        :noop
    end
  rescue
    _error ->
      clear_dispatch_capacity_sources(peer_identity.node_id, opts)
      :noop
  catch
    _kind, _reason ->
      clear_dispatch_capacity_sources(peer_identity.node_id, opts)
      :noop
  end

  @doc """
  Rejects a pending node admission candidate or lifecycle-managed pending node.
  """
  @spec reject_admission(Ecto.UUID.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             candidate: AdmissionCandidate.t(),
             decision: AdmissionDecision.t(),
             audit_log: AuditLog.t()
           }}
          | {:error, term()}
  def reject_admission(candidate_or_node_id, attrs, opts \\ []) do
    do_reject_admission(fn -> lock_admission_target(candidate_or_node_id) end, attrs, opts)
  end

  @doc """
  Rejects a pending node admission candidate by candidate ID only.
  """
  @spec reject_admission_candidate(Ecto.UUID.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             candidate: AdmissionCandidate.t(),
             decision: AdmissionDecision.t(),
             audit_log: AuditLog.t()
           }}
          | {:error, term()}
  def reject_admission_candidate(candidate_id, attrs, opts \\ []) do
    do_reject_admission(fn -> lock_candidate_target(candidate_id) end, attrs, opts)
  end

  @doc """
  Clears a rejected admission candidate by appending a clearance decision.
  """
  @spec clear_admission_rejection(Ecto.UUID.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             candidate: AdmissionCandidate.t(),
             decision: AdmissionDecision.t(),
             audit_log: AuditLog.t()
           }}
          | {:error, term()}
  def clear_admission_rejection(candidate_or_node_id, attrs \\ %{}, opts \\ []) do
    do_clear_admission_rejection(
      fn -> lock_rejected_candidate(candidate_or_node_id) end,
      attrs,
      opts
    )
  end

  @doc """
  Clears a rejected node admission candidate by candidate ID only.
  """
  @spec clear_admission_candidate_rejection(Ecto.UUID.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             candidate: AdmissionCandidate.t(),
             decision: AdmissionDecision.t(),
             audit_log: AuditLog.t()
           }}
          | {:error, term()}
  def clear_admission_candidate_rejection(candidate_id, attrs \\ %{}, opts \\ []) do
    do_clear_admission_rejection(
      fn -> lock_rejected_candidate_by_id(candidate_id) end,
      attrs,
      opts
    )
  end

  @doc """
  Admits a registered node without activating it.

  The capacity-policy write runs while holding that Node's acceptance gate, so
  admission returns `{:error, :dispatch_capacity_acceptance_gate_busy}` when a
  dispatch holds the gate longer than the bounded wait, and
  `{:error, :dispatch_capacity_authority_unavailable}` when the allocation
  authority is not running. Both are retryable.
  """
  @spec admit_node(Ecto.UUID.t(), map() | keyword(), keyword()) ::
          {:ok,
           %{
             node: Node.t(),
             decision: AdmissionDecision.t(),
             audit_log: AuditLog.t(),
             policy: Orchard.DispatchCapacity.Policy.t()
           }}
          | {:error, term()}
  def admit_node(node_id, attrs \\ %{}, opts \\ []) do
    attrs = normalize_attrs(attrs)

    case ControlPlane.authorize_write_path(:node_admission) do
      :ok -> admit_node_with_policy_gate(node_id, attrs, opts)
      {:error, _reason} = error -> error
    end
  end

  defp admit_node_with_policy_gate(node_id, attrs, opts) do
    DispatchCapacity.with_policy_mutation_gate(node_id, fn ->
      AuditWriter.transaction(fn -> admit_node_locked(node_id, attrs, opts) end)
    end)
    |> unwrap_transaction_result()
  end

  defp admit_node_locked(node_id, attrs, opts) do
    with {:ok, authority} <- DispatchCapacity.lock_authority(),
         :ok <- ensure_pre_cutover_authority(authority),
         {:ok, node} <- BeamPeerGrants.lock_initial_admission_node(node_id, opts),
         :ok <- ensure_node_admittable(node, attrs),
         {:ok, capacity_policy} <- resolve_admission_capacity_policy(attrs, opts),
         opts <- put_actor_opts(opts, capacity_policy),
         {:ok, candidate} <- get_or_create_candidate_for_node(node),
         {:ok, {node, grants}} <- BeamPeerGrants.issue_initial_for_admission(node, opts),
         {:ok, admitted_node} <- update_node_state(node, :admitted),
         {:ok, admitted_candidate} <- update_candidate_category(candidate, :admitted),
         {:ok, audit_log} <-
           insert_admission_audit_log(
             "node_admission.admitted",
             admitted_candidate,
             admission_audit_payload(admitted_candidate, attrs),
             opts
           ),
         {:ok, decision} <-
           insert_admission_decision(
             admitted_candidate,
             :admitted,
             nil,
             audit_log,
             attrs,
             opts
           ),
         {:ok, policy} <-
           DispatchCapacity.approve_admission_policy(%{
             node_id: admitted_node.id,
             admission_decision_id: decision.id,
             controller_dispatch_ceiling: capacity_policy.ceiling,
             approved_by_actor_type: capacity_policy.actor_type,
             approved_by_actor_id: capacity_policy.actor_id,
             approved_at: utc_now(),
             approval_reason: capacity_policy.reason
           }) do
      {:ok,
       %{
         node: admitted_node,
         decision: decision,
         audit_log: audit_log,
         grants: grants,
         policy: policy
       }}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc """
  Ensures a registered Node is visible in pending admission review.

  Enrollment callers use this after the allocated Node reaches `:registered`.
  """
  @spec ensure_pending_admission_candidate(Node.t()) ::
          {:ok, AdmissionCandidate.t()} | {:error, term()}
  def ensure_pending_admission_candidate(%Node{state: :registered} = node) do
    get_or_create_candidate_for_node(node)
  end

  def ensure_pending_admission_candidate(%Node{}), do: {:error, :node_not_registered}

  @doc """
  Returns shared action-preview blocker codes for node admission.
  """
  @spec admission_blocker_codes(Node.t(), map() | keyword()) :: [atom()]
  def admission_blocker_codes(%Node{} = node, attrs \\ %{}) do
    attrs = normalize_attrs(attrs)

    case latest_admission_decision_for_node(node.id) do
      %AdmissionDecision{decision: :rejected} ->
        [:node_not_pending_admission]

      _decision ->
        do_admission_blocker_codes(node, attrs)
    end
  end

  @doc """
  Resolves the capacity policy shown by admission previews and persisted on success.
  """
  @spec admission_capacity_policy(map() | keyword()) ::
          {:ok,
           %{
             controller_dispatch_ceiling: non_neg_integer(),
             policy_state: :approved_explicit,
             warning_codes: [atom()]
           }}
          | {:error, :capacity_policy_reason_required | :invalid_controller_dispatch_ceiling}
  def admission_capacity_policy(attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, _reason} <- required_capacity_policy_reason(attrs),
         {:ok, ceiling} <- admission_capacity_ceiling(attrs) do
      {:ok,
       %{
         controller_dispatch_ceiling: ceiling,
         policy_state: :approved_explicit,
         warning_codes: [:controller_dispatch_ceiling_not_yet_enforcing]
       }}
    end
  end

  @doc """
  Returns the latest admission decision for a candidate.
  """
  @spec latest_admission_decision_for_candidate(Ecto.UUID.t()) :: AdmissionDecision.t() | nil
  def latest_admission_decision_for_candidate(candidate_id) do
    case normalize_uuid(candidate_id, :candidate_not_found) do
      {:ok, candidate_id} ->
        AdmissionDecision
        |> where([decision], decision.candidate_id == ^candidate_id)
        |> order_by([decision], desc: decision.decided_at, desc: decision.inserted_at)
        |> limit(1)
        |> Repo.one()

      {:error, :candidate_not_found} ->
        nil
    end
  end

  @doc """
  Returns the latest admission decisions keyed by candidate ID.
  """
  @spec latest_admission_decisions_for_candidates([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => AdmissionDecision.t()
        }
  def latest_admission_decisions_for_candidates(candidate_ids) do
    candidate_ids
    |> normalize_uuid_list()
    |> latest_admission_decisions_by(:candidate_id)
  end

  @doc """
  Returns the latest admission decisions keyed by node ID.
  """
  @spec latest_admission_decisions_for_nodes([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => AdmissionDecision.t()
        }
  def latest_admission_decisions_for_nodes(node_ids) do
    node_ids
    |> normalize_uuid_list()
    |> latest_admission_decisions_by(:node_id)
  end

  defp latest_admission_decisions_by([], _key), do: %{}

  defp latest_admission_decisions_by(ids, key) do
    AdmissionDecision
    |> where([decision], field(decision, ^key) in ^ids)
    |> order_by([decision], desc: decision.decided_at, desc: decision.inserted_at)
    |> Repo.all()
    |> Enum.reduce(%{}, fn decision, decisions ->
      Map.put_new(decisions, Map.get(decision, key), decision)
    end)
  end

  defp handle_observation_result(target, observed_at, result, status_response, opts) do
    case result do
      {:ok, node} ->
        refresh_observed_queue_capacities(target, node, status_response, opts)
        {:ok, node}

      {:noop, :identity_conflict} ->
        clear_existing_target_queue_capacity_sources(target, observed_at)
        :noop

      {:noop, _reason} ->
        :noop
    end
  end

  defp handle_authenticated_observation_result(
         target,
         result,
         status_response,
         trusted_node_id,
         opts
       ) do
    case result do
      {:ok, node} ->
        refresh_observed_queue_capacities(target, node, status_response, opts)
        observe_worker_crashes(trusted_node_id, status_response, opts)
        {:ok, node}

      {:noop, :out_of_order} ->
        :noop

      {:noop, _reason} ->
        clear_dispatch_capacity_sources(trusted_node_id, opts)
        :noop
    end
  end

  defp observe_worker_crashes(node_id, status_response, opts) do
    observer = Keyword.get(opts, :worker_crash_observer, Orchard.Metrics.WorkerCrashDeduplicator)
    observer.observe(node_id, Map.get(status_response, :worker_crash_counters, []))
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Records a transport-like failure for a target and persists node health.

  Classifies the given `reason` and, if it matches a transport failure pattern,
  marks the target unreachable. Non-transport reasons are ignored.
  Successful transport-failure marks clear all queue capacity sources owned by
  the failed node after the health transaction commits, so stale observations
  cannot wake queued requests.

  Transport failure reasons:
  - `{:connect_failed, _}` - gRPC channel could not be established
  - `:node_unavailable` / `:beam_node_unavailable` - node not reachable
  - `:node_timeout` / `:beam_node_timeout` - probe or RPC timed out
  - `:authenticated_transport_failed` - authenticated gRPC transport failed
  - `:beam_peer_grant_authorization_unavailable` - BEAM peer grant/connect failed

  Non-transport seam rejections (`:authenticated_observation_rejected`,
  `:beam_peer_observation_rejected`) are ignored and do not demote.

  Returns:
  - `{:ok, %Node{}}` when health was updated
  - `:noop` for non-transport reasons, unknown targets, or repo unavailable
  """
  @spec record_transport_failure(keyword() | Target.t(), term(), DateTime.t()) ::
          {:ok, Node.t()} | :noop
  def record_transport_failure(target, reason, observed_at) do
    if transport_failure_reason?(reason) do
      case mark_target_unreachable_without_queue_cleanup(target, observed_at) do
        {:ok, %Node{} = node} = result ->
          clear_dispatch_capacity_sources(node.id)
          result

        :noop ->
          :noop
      end
    else
      :noop
    end
  rescue
    _ -> :noop
  end

  @doc """
  Atomically records one actually-run transport failure against Node health and
  the durable circuit-breaker ledger.

  Unlike `record_transport_failure/3`, this seam requires the caller's stable,
  durable failure identity and canonical Node identity. It is reserved for
  actually-run attempt failures whose stable failure class is breaker-eligible.
  Activation, discovery, and compatibility probes must continue to use
  `record_transport_failure/3`, which remains health-only.

  The target must resolve to the same Node as `failure.node_id`. A mismatch
  fails before either health or breaker state is mutated. Re-delivery of the
  same failure is idempotent: the breaker reports `:duplicate`, and the Node
  transport watermark prevents a second health write.
  """
  @spec record_dispatch_transport_failure(keyword() | Target.t(), term(), map()) ::
          {:ok, %{node: Node.t(), breaker: Orchard.CircuitBreakers.Decision.t()}}
          | {:error, atom()}
  def record_dispatch_transport_failure(target, reason, failure) do
    cond do
      not repo_available?() ->
        {:error, :node_inventory_unavailable}

      not transport_failure_reason?(reason) ->
        {:error, :transport_failure_reason_not_eligible}

      true ->
        with {:ok, failure} <- normalize_dispatch_transport_failure(failure),
             {:ok, target_lookup} <- target_lookup(target) do
          record_dispatch_transport_failure_transaction(target_lookup, failure)
        else
          :error -> {:error, :transport_failure_target_invalid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Demotes `:active` Nodes whose last heartbeat is older than the unreachable threshold.

  Leader-gated. Uses the same graded health path as transport failure recording so
  idle Node loss is detected even when no probe failure is observed in the current
  cycle. Bounds detection at approximately `unreachable_threshold + sweep_interval`.

  `:admitted` Nodes are excluded: a stalled admitted heartbeat usually means the
  controller-side observation seam is rejecting a reachable Node, not Node loss.
  Nodes already recorded `:unhealthy` keep that health until an observation clears it.
  """
  @spec sweep_stale_node_heartbeats(DateTime.t()) :: {:ok, non_neg_integer()} | :noop
  def sweep_stale_node_heartbeats(observed_at \\ DateTime.utc_now()) do
    with true <- repo_available?(),
         :ok <- ControlPlane.authorize_write_path(:node_lifecycle),
         true <- is_struct(observed_at, DateTime) do
      freshness_cutoff =
        DateTime.add(
          observed_at,
          -Orchard.Inference.node_freshness_threshold_ms(),
          :millisecond
        )

      stale_source_node_ids = stale_queue_capacity_source_node_ids(freshness_cutoff)
      unreachable_cutoff = DateTime.add(observed_at, -unreachable_threshold_ms(), :millisecond)

      demoted_node_ids =
        unreachable_cutoff
        |> stale_heartbeat_node_ids()
        |> Enum.filter(&demote_stale_heartbeat_node(&1, observed_at))

      stale_source_node_ids
      |> Enum.concat(demoted_node_ids)
      |> Enum.uniq()
      |> Enum.each(&clear_dispatch_capacity_sources/1)

      {:ok, length(demoted_node_ids)}
    else
      _ -> :noop
    end
  rescue
    _ -> :noop
  end

  defp stale_queue_capacity_source_node_ids(cutoff) do
    Node
    |> where([n], n.state == :active)
    |> where([n], not is_nil(n.last_heartbeat_at))
    |> where([n], n.last_heartbeat_at < ^cutoff)
    |> select([n], n.id)
    |> Repo.all()
  end

  defp stale_heartbeat_node_ids(cutoff) do
    Node
    |> where([n], n.state == :active)
    |> where([n], not is_nil(n.last_heartbeat_at))
    |> where([n], n.last_heartbeat_at < ^cutoff)
    |> where([n], n.health not in [:unreachable, :unhealthy])
    |> select([n], n.id)
    |> Repo.all()
  end

  defp demote_stale_heartbeat_node(node_id, observed_at) do
    case execute_mark_unreachable({:node_id, node_id}, observed_at, :stale_sweep) do
      {:ok, %Node{}} ->
        true

      :noop ->
        false
    end
  end

  @doc """
  Clears queue capacity sources owned by an existing target without changing health.

  Use this for fresh identity rejections where the target was reachable enough
  to report status, but its observation must not remain an admission authority.
  Cleanup is still freshness-gated against the target's last heartbeat.
  """
  @spec clear_target_queue_capacity_sources(keyword() | Target.t(), DateTime.t()) :: :ok
  def clear_target_queue_capacity_sources(target, observed_at) do
    if repo_available?() do
      clear_existing_target_queue_capacity_sources(target, observed_at)
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Marks a node as unreachable by target address.

  Only updates health on an existing node. Does not insert new rows
  on failure-only observations. Preserves `state` and `last_heartbeat_at`.
  When the resulting node is not queue-capacity eligible, stale node-owned
  queue capacity sources are cleared after the health transaction commits.

  Returns:
  - `{:ok, %Node{}}` on successful mark
  - `:noop` when target is unknown, stale, malformed, or repo unavailable
  """
  @spec mark_target_unreachable(keyword() | Target.t(), DateTime.t()) :: {:ok, Node.t()} | :noop
  def mark_target_unreachable(target, observed_at) do
    case mark_target_unreachable_without_queue_cleanup(target, observed_at) do
      {:ok, %Node{} = node} = result ->
        clear_ineligible_node_queue_capacity_sources(node)
        result

      :noop ->
        :noop
    end
  rescue
    _ -> :noop
  end

  defp mark_target_unreachable_without_queue_cleanup(target, observed_at) do
    with true <- repo_available?(),
         {:ok, target_lookup} <- target_lookup(target) do
      execute_mark_unreachable(target_lookup, observed_at, :transport_failure)
    else
      _ -> :noop
    end
  end

  # -- Observation Normalization --

  defp normalize_candidate_observation(%Target{} = target, %Observation{} = observation) do
    target = Target.normalize(target)

    {:ok,
     %{
       observation
       | endpoint_id: observation.endpoint_id || target.id,
         target: target
     }}
  end

  defp normalize_candidate_observation(%Target{} = target, status_response)
       when is_map(status_response) do
    {:ok,
     target
     |> Target.normalize()
     |> GrpcCompatibilityMapper.observation_from_status(status_response)}
  rescue
    _error in ArgumentError -> :error
  end

  defp normalize_candidate_observation(_target, _status_response), do: :error

  defp normalize_observation(target, status_response, observed_at) do
    endpoint_transport = target_transport(target)
    target_address = target_address(target)
    metadata = extract_metadata(status_response)

    with {:metadata, %{} = meta} <- {:metadata, metadata},
         {:uuid, {:ok, node_id}} <- {:uuid, Ecto.UUID.cast(map_get(meta, :node_id))},
         {:display_name, display_name} when display_name != nil <-
           {:display_name, resolve_display_name(meta)},
         {:port, port} when is_integer(port) and port in 1..65_535 <-
           {:port, resolve_port(meta, target_address)} do
      hostname = map_get(meta, :hostname)
      listen_host = map_get(meta, :listen_host)

      {:ok,
       %{
         id: node_id,
         display_name: display_name,
         hostname: non_empty_or(hostname, target_host(target_address)),
         advertise_addr: non_empty_or(listen_host, target_host(target_address)),
         rpc_port: port,
         connect_host: connect_host(target_address),
         connect_port: connect_port(target_address),
         endpoint_transport: endpoint_transport,
         beam_address: beam_target_address(target),
         health: derive_health(extract_runtime_health(status_response)),
         agent_version: non_empty_or(map_get(meta, :agent_version), nil),
         capabilities: build_capabilities(meta, status_response),
         tool_readiness: build_tool_readiness(status_response),
         aggregate_capacity_evidence: aggregate_capacity_evidence(status_response),
         last_heartbeat_at: observed_at
       }}
    else
      _ -> :error
    end
  end

  defp extract_metadata(%{node_metadata: nil}), do: nil
  defp extract_metadata(%{node_metadata: meta}), do: meta
  defp extract_metadata(%{"node_metadata" => nil}), do: nil
  defp extract_metadata(%{"node_metadata" => meta}), do: meta

  defp extract_metadata(%Observation{metadata: metadata}) when is_map(metadata),
    do: observation_metadata(metadata)

  defp extract_metadata(_), do: nil

  defp extract_runtime_health(%{runtime_health: health}), do: health
  defp extract_runtime_health(%{"runtime_health" => health}), do: health
  defp extract_runtime_health(%Observation{health: health}) when is_map(health), do: health
  defp extract_runtime_health(_), do: nil

  defp resolve_display_name(meta) do
    display_name = map_get(meta, :display_name)
    hostname = map_get(meta, :hostname)

    cond do
      non_empty?(display_name) -> display_name
      non_empty?(hostname) -> hostname
      true -> nil
    end
  end

  defp resolve_port(meta, target) do
    port = map_get(meta, :listen_port)

    if is_integer(port) and port in 1..65_535 do
      port
    else
      target_port(target)
    end
  end

  defp derive_health(nil), do: :healthy
  defp derive_health(health) when not is_map(health), do: :healthy

  defp derive_health(health) do
    ready = map_get(health, :ready)
    code = map_get(health, :health_code) || ""
    message = map_get(health, :health_message) || ""

    cond do
      ready == false -> :unhealthy
      non_empty?(code) or non_empty?(message) -> :degraded
      true -> :healthy
    end
  end

  defp build_capabilities(meta, status_response) do
    backend = map_get(meta, :worker_backend) || ""

    hosted_tools =
      status_response
      |> extract_hosted_tool_capabilities()
      |> ToolCapability.normalize_all()
      |> ToolCapability.persist_all()

    %{}
    |> maybe_put_worker_backend(backend)
    |> Map.put(
      "supports_prompt_token_ids",
      map_get(status_response, :supports_prompt_token_ids) || false
    )
    |> Map.put("hosted_tools", hosted_tools)
  end

  defp build_tool_readiness(status_response) do
    capability_refs =
      status_response
      |> extract_hosted_tool_capabilities()
      |> ToolCapability.normalize_all()
      |> ToolCapability.refs()

    status_response
    |> extract_hosted_tool_readiness()
    |> ToolReadiness.normalize_all(capability_refs)
    |> ToolReadiness.persist_all()
  end

  defp refresh_observed_queue_capacities(target, %Node{} = node, status_response, opts) do
    queue_manager = Keyword.get(opts, :queue_manager, Orchard.Inference.queue_manager())
    placement_source = {:node, node.id, :placement}
    cold_source = {:node, node.id, :cold}

    refresh = %{
      clear_sources: node_queue_capacity_sources(node.id),
      node_source: {:node, node.id},
      placement_source: placement_source,
      cold_source: cold_source,
      node_id: node.id,
      node_active: observed_node_active(status_response),
      node_max: observed_node_max(status_response),
      placements: placement_observations(status_response),
      reserve_unassigned_node_grants?: Keyword.get(opts, :reserve_unassigned_node_grants?, true),
      reserve_unassigned_source_grants?:
        Keyword.get(opts, :reserve_unassigned_source_grants?, true)
    }

    if queue_capacity_refresh_target?(target, node) and
         queue_capacity_eligible_node?(node) and
         queue_capacity_eligible_observation?(status_response) do
      case observation_capacity_input(node, status_response, opts) do
        {:ok, input} ->
          refresh_or_clear_dispatch_capacity_sources(
            node,
            input,
            refresh,
            queue_manager,
            opts
          )

        {:error, _reason} ->
          queue_manager.clear_capacity_sources(refresh.clear_sources, promote?: true)
      end
    else
      queue_manager.clear_capacity_sources(refresh.clear_sources, promote?: true)
    end
  rescue
    error ->
      Logger.debug("Queue capacity refresh from node observation failed: #{inspect(error)}")
      clear_dispatch_capacity_sources(node.id, opts)
  catch
    :exit, reason ->
      Logger.debug("Queue capacity refresh from node observation exited: #{inspect(reason)}")
      clear_dispatch_capacity_sources(node.id, opts)
  end

  defp refresh_or_clear_dispatch_capacity_sources(node, input, refresh, queue_manager, opts) do
    authority =
      Keyword.get(opts, :dispatch_capacity_authority, DispatchCapacity.AllocationAuthority)

    refresh_dispatch_capacity_sources(node, input, refresh,
      authority: authority,
      queue_manager: queue_manager
    )
  rescue
    error ->
      Logger.debug("Dispatch-capacity source refresh failed: #{inspect(error)}")
      queue_manager.clear_capacity_sources(refresh.clear_sources, promote?: true)
  catch
    :exit, reason ->
      Logger.debug("Dispatch-capacity source refresh exited: #{inspect(reason)}")
      queue_manager.clear_capacity_sources(refresh.clear_sources, promote?: true)
  end

  defp observation_capacity_input(node, status_response, opts) do
    case Keyword.fetch(opts, :dispatch_capacity_input) do
      {:ok, %Orchard.DispatchCapacity.Evaluator.Input{} = input} ->
        {:ok, input}

      {:ok, _invalid} ->
        {:error, :dispatch_capacity_facts_unavailable}

      :error ->
        Authorization.input_for_observation(node, status_response,
          minimum_evidence_observed_at: node.last_heartbeat_at
        )
    end
  end

  defp queue_capacity_refresh_target?(%Target{transport: :beam} = target, %Node{id: node_id}) do
    case target_lookup(target) do
      {:ok, target_lookup} ->
        match?(%Node{id: ^node_id}, lookup_node_by_target_lookup(target_lookup))

      :error ->
        false
    end
  end

  defp queue_capacity_refresh_target?(_target, _node), do: true

  defp clear_ineligible_node_queue_capacity_sources(%Node{} = node) do
    unless queue_capacity_eligible_node?(node) do
      clear_dispatch_capacity_sources(node.id)
    end
  end

  defp clear_existing_target_queue_capacity_sources(target, observed_at) do
    case target_lookup(target) do
      {:ok, target_lookup} ->
        case lookup_node_by_target_lookup(target_lookup) do
          %Node{} = node -> clear_fresh_target_queue_capacity_sources(node, observed_at)
          nil -> :ok
        end

      :error ->
        :ok
    end
  rescue
    error ->
      Logger.debug("Queue capacity source clear for target failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("Queue capacity source clear for target exited: #{inspect(reason)}")
      :ok
  end

  defp clear_fresh_target_queue_capacity_sources(%Node{} = node, observed_at) do
    if stale_target_observation?(node, observed_at) do
      :ok
    else
      clear_dispatch_capacity_sources(node.id)
    end
  end

  defp stale_target_observation?(
         %Node{last_heartbeat_at: %DateTime{} = last_heartbeat_at},
         %DateTime{} = observed_at
       ) do
    DateTime.compare(last_heartbeat_at, observed_at) != :lt
  end

  defp stale_target_observation?(_node, _observed_at), do: false

  defp queue_capacity_eligible_node?(%Node{state: :active, health: health})
       when health in [:healthy, :degraded],
       do: true

  defp queue_capacity_eligible_node?(%Node{}), do: false

  defp queue_capacity_eligible_observation?(%Observation{availability: availability}),
    do: availability in [:available, :degraded]

  defp queue_capacity_eligible_observation?(_status_response), do: true

  defp node_queue_capacity_sources(node_id),
    do: [{:node, node_id}, {:node, node_id, :placement}, {:node, node_id, :cold}]

  defp extract_runtime_model_placements(%{runtime_model_placements: placements})
       when is_list(placements),
       do: placements

  defp extract_runtime_model_placements(_status_response), do: []

  defp placement_observations(%Observation{placements: placements}) do
    placements
    |> Enum.reduce(%{}, &put_runtime_endpoint_placement_observation/2)
    |> Enum.map(fn {{model_id, version}, status} -> {model_id, version, status} end)
  end

  defp placement_observations(status_response) do
    runtime_observations =
      status_response
      |> extract_runtime_model_placements()
      |> Enum.reduce(%{}, &put_placement_observation/2)

    status_response
    |> put_active_loaded_model_observations(runtime_observations)
    |> Enum.map(fn {{model_id, version}, status} -> {model_id, version, status} end)
  end

  defp put_active_loaded_model_observations(status_response, observations) do
    if non_negative_integer(map_get(status_response, :active_request_count), 0) > 0 do
      status_response
      |> extract_loaded_models()
      |> Enum.reduce(observations, &put_loaded_model_observation/2)
    else
      observations
    end
  end

  defp put_runtime_endpoint_placement_observation(%Placement{} = placement, observations) do
    case runtime_endpoint_placement_ref(placement) do
      {:ok, model_id, version} ->
        status = runtime_endpoint_placement_status(placement)
        Map.update(observations, {model_id, version}, status, fn _existing -> :ambiguous end)

      :error ->
        observations
    end
  end

  defp put_runtime_endpoint_placement_observation(_placement, observations), do: observations

  defp runtime_endpoint_placement_ref(%Placement{
         model_ref: %ModelRef{model_id: model_id, version: version}
       })
       when is_binary(model_id) and model_id != "" and is_binary(version) and version != "",
       do: {:ok, model_id, version}

  defp runtime_endpoint_placement_ref(_placement), do: :error

  defp runtime_endpoint_placement_status(%Placement{
         state: state,
         capacity: %PlacementCapacity{
           status: :known,
           active_request_count: active,
           max_concurrency: max
         }
       })
       when state in [:loaded, "loaded", :PLACEMENT_STATE_LOADED] do
    %{active_request_count: active, max_concurrency: max}
  end

  defp runtime_endpoint_placement_status(%Placement{}), do: :unavailable

  defp extract_loaded_models(%{loaded_models: models}) when is_list(models), do: models
  defp extract_loaded_models(%{"loaded_models" => models}) when is_list(models), do: models
  defp extract_loaded_models(_status_response), do: []

  defp put_loaded_model_observation(model, observations) when is_map(model) do
    case loaded_model_ref(model) do
      {:ok, model_id, version} -> Map.put_new(observations, {model_id, version}, :unavailable)
      :error -> observations
    end
  end

  defp put_loaded_model_observation(_model, observations), do: observations

  defp loaded_model_ref(model) do
    model_ref = map_get(model, :model_ref)

    cond do
      non_empty?(map_get(model, :model_id)) and non_empty?(map_get(model, :version)) ->
        {:ok, map_get(model, :model_id), map_get(model, :version)}

      is_map(model_ref) ->
        placement_model_ref(%{model_ref: model_ref})

      true ->
        :error
    end
  end

  defp put_placement_observation(placement, observations) when is_map(placement) do
    case placement_model_ref(placement) do
      {:ok, model_id, version} ->
        status = placement_observation_status(placement)
        Map.update(observations, {model_id, version}, status, fn _existing -> :ambiguous end)

      :error ->
        observations
    end
  end

  defp put_placement_observation(_placement, observations), do: observations

  defp placement_observation_status(placement) do
    if loaded_placement?(placement) and placement_max_concurrency(placement) > 0 do
      %{
        active_request_count: non_negative_integer(map_get(placement, :active_request_count), 0),
        max_concurrency: placement_max_concurrency(placement)
      }
    else
      :unavailable
    end
  end

  defp loaded_placement?(placement) do
    case map_get(placement, :placement_state) do
      nil -> true
      state -> state in [:PLACEMENT_STATE_LOADED, "PLACEMENT_STATE_LOADED", 7]
    end
  end

  defp placement_model_ref(placement) do
    case map_get(placement, :model_ref) do
      model_ref when is_map(model_ref) ->
        model_id = map_get(model_ref, :model_id)
        version = map_get(model_ref, :version)

        if non_empty?(model_id) and non_empty?(version) do
          {:ok, model_id, version}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp placement_max_concurrency(placement) do
    placement
    |> map_get(:max_concurrency)
    |> case do
      capacity when is_integer(capacity) and capacity > 0 -> capacity
      _other -> 0
    end
  end

  defp observed_node_active(%Observation{aggregate_active_request_count: active}),
    do: non_negative_integer(active, 0)

  defp observed_node_active(status_response),
    do: non_negative_integer(map_get(status_response, :active_request_count), 0)

  defp observed_node_max(%Observation{aggregate_max_concurrency: max}),
    do: positive_integer(max, 1)

  defp observed_node_max(status_response),
    do: positive_integer(map_get(status_response, :max_concurrency), 1)

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp extract_hosted_tool_capabilities(%{hosted_tool_capabilities: entries})
       when is_list(entries),
       do: entries

  defp extract_hosted_tool_capabilities(_status_response), do: []

  defp extract_hosted_tool_readiness(%{hosted_tool_readiness: entries}) when is_list(entries),
    do: entries

  defp extract_hosted_tool_readiness(_status_response), do: []

  defp maybe_put_worker_backend(capabilities, backend) do
    if non_empty?(backend) do
      Map.put(capabilities, "worker_backend", backend)
    else
      capabilities
    end
  end

  # -- Transactional Observe --

  defp execute_observe(observation) do
    Repo.transaction(fn ->
      conflicting = load_conflicting_nodes(observation)
      existing = classify_conflicting_nodes(conflicting, observation)

      with :ok <- ensure_no_identity_conflict(existing, observation),
           :ok <- ensure_fresh_observation(existing, observation) do
        upsert_observation(existing, observation)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :candidate_persisted} -> {:noop, :candidate_persisted}
      {:ok, node} -> {:ok, node}
      {:error, :identity_conflict} -> {:noop, :identity_conflict}
      {:error, :stale} -> {:noop, :stale}
    end
  rescue
    # Concurrent first-observation race: two transactions see no existing
    # rows, both attempt insert, one hits a uniqueness constraint.
    # Treat as a benign conflict - the other process won the insert.
    error in Ecto.ConstraintError ->
      Logger.debug("Node observation lost concurrent insert race: #{inspect(error.constraint)}")
      {:noop, :constraint_conflict}
  end

  defp execute_candidate_only_observe(observation) do
    Repo.transaction(fn ->
      conflicting = load_conflicting_nodes(observation)
      existing = classify_conflicting_nodes(conflicting, observation)

      case ensure_no_identity_conflict(existing, observation) do
        :ok ->
          # Candidate-only path never mutates Node rows, even when a provisioned
          # or registered placeholder already owns the claimed identity.
          upsert_observed_admission_candidate(observation)
          :candidate_persisted

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, :candidate_persisted} -> {:ok, :candidate_persisted}
      {:error, :identity_conflict} -> {:noop, :identity_conflict}
    end
  rescue
    error in Ecto.ConstraintError ->
      Logger.debug(
        "Candidate-only observation lost concurrent insert race: #{inspect(error.constraint)}"
      )

      {:noop, :constraint_conflict}
  end

  defp execute_authenticated_observe(
         %Target{transport: :beam} = target,
         observation,
         peer_identity,
         status_response,
         opts
       ) do
    Repo.transaction(fn ->
      with %BeamPeerGrants.Grant{} = grant <-
             lock_authenticated_beam_grant(target, peer_identity),
           :ok <- run_lock_observer(opts, :grant),
           %Node{} = node <- lock_authenticated_node(peer_identity.node_id),
           :ok <- run_lock_observer(opts, :node),
           %Enrollment{} = enrollment <- lock_authenticated_enrollment(peer_identity),
           :ok <- run_lock_observer(opts, :enrollment),
           %ControllerInstance{} = controller <-
             lock_authenticated_controller(grant.controller_id),
           :ok <- run_lock_observer(opts, :controller),
           {:ok, _authorization} <- BeamPeerGrants.authorize_target(target, opts),
           :ok <- ensure_authenticated_enrollment(enrollment, peer_identity),
           :ok <- ensure_authenticated_node(node, observation, peer_identity),
           :ok <- ensure_authenticated_beam_target(target, node, enrollment, grant, controller),
           true <- accept_authenticated_observation_health?(node, observation),
           true <- fresh_authenticated_observation?(observation.last_heartbeat_at),
           :ok <- BeamPeerGrants.ensure_active_grant_current(grant.id, opts) do
        update_fresh_authenticated_beam_observation(
          node,
          target,
          observation,
          status_response,
          grant.id,
          opts
        )
      else
        _reason -> Repo.rollback(:authenticated_observation_rejected)
      end
    end)
    |> authenticated_observe_result()
  rescue
    error in Ecto.ConstraintError ->
      Logger.debug("Authenticated node observation conflicted: #{inspect(error.constraint)}")
      {:noop, :constraint_conflict}
  end

  defp execute_authenticated_observe(
         target,
         observation,
         peer_identity,
         status_response,
         opts
       ) do
    Repo.transaction(fn ->
      with %Enrollment{} = enrollment <- lock_authenticated_enrollment(peer_identity),
           %Node{} = node <- lock_authenticated_node(peer_identity.node_id),
           :ok <- ensure_authenticated_enrollment(enrollment, peer_identity),
           :ok <- ensure_authenticated_node(node, observation, peer_identity),
           :ok <- ensure_authenticated_target(target, node, enrollment),
           true <- accept_authenticated_observation_health?(node, observation),
           true <- fresh_authenticated_observation?(observation.last_heartbeat_at) do
        update_fresh_authenticated_observation(
          node,
          target,
          observation,
          status_response,
          opts
        )
      else
        _reason -> Repo.rollback(:authenticated_observation_rejected)
      end
    end)
    |> authenticated_observe_result()
  rescue
    error in Ecto.ConstraintError ->
      Logger.debug("Authenticated node observation conflicted: #{inspect(error.constraint)}")
      {:noop, :constraint_conflict}
  end

  defp update_fresh_authenticated_beam_observation(
         node,
         target,
         observation,
         status_response,
         grant_id,
         opts
       ) do
    case ensure_fresh_observation(%{existing_by_id: node}, observation) do
      :ok ->
        update_authenticated_beam_observation(
          node,
          target,
          observation,
          status_response,
          grant_id,
          opts
        )

      {:error, :stale} ->
        Repo.rollback(:out_of_order)
    end
  end

  defp update_fresh_authenticated_observation(
         node,
         target,
         observation,
         status_response,
         opts
       ) do
    case ensure_fresh_observation(%{existing_by_id: node}, observation) do
      :ok ->
        update_authenticated_observation(node, target, observation, status_response, opts)

      {:error, :stale} ->
        Repo.rollback(:out_of_order)
    end
  end

  defp authenticated_observe_result({:ok, node}), do: {:ok, node}
  defp authenticated_observe_result({:error, reason}), do: {:noop, reason}

  defp load_conflicting_nodes(observation) do
    Node
    |> where(^conflicting_node_filter(observation))
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp conflicting_node_filter(observation) do
    base_filter =
      dynamic(
        [n],
        n.id == ^observation.id or
          n.display_name == ^observation.display_name
      )

    base_filter =
      if routable_advertise_addr?(observation.advertise_addr) do
        dynamic(
          [n],
          ^base_filter or
            (n.advertise_addr == ^observation.advertise_addr and
               n.rpc_port == ^observation.rpc_port)
        )
      else
        base_filter
      end

    if valid_connect_target?(observation.connect_host, observation.connect_port) do
      dynamic(
        [n],
        ^base_filter or
          (n.connect_host == ^observation.connect_host and
             n.connect_port == ^observation.connect_port)
      )
    else
      base_filter
    end
  end

  defp classify_conflicting_nodes(conflicting, observation) do
    %{
      existing_by_id: Enum.find(conflicting, &(&1.id == observation.id)),
      existing_by_name: Enum.find(conflicting, &(&1.display_name == observation.display_name)),
      existing_by_target: Enum.find(conflicting, &target_match?(&1, observation))
    }
  end

  defp ensure_no_identity_conflict(%{existing_by_target: %Node{id: id}}, observation)
       when id != observation.id do
    Logger.warning(
      "Node identity conflict: advertised target #{observation.advertise_addr}:#{observation.rpc_port} " <>
        "connect target #{format_connect_target(observation)} " <>
        "claimed by #{observation.id} but registered to #{id}"
    )

    {:error, :identity_conflict}
  end

  defp ensure_no_identity_conflict(%{existing_by_name: %Node{id: id}}, observation)
       when id != observation.id do
    Logger.warning(
      "Node identity conflict: display_name #{inspect(observation.display_name)} " <>
        "claimed by #{observation.id} but registered to #{id}"
    )

    {:error, :identity_conflict}
  end

  defp ensure_no_identity_conflict(_existing, _observation), do: :ok

  defp ensure_fresh_observation(%{existing_by_id: %Node{} = existing}, observation) do
    if timestamp_at_or_after?(existing.last_heartbeat_at, observation.last_heartbeat_at) or
         timestamp_at_or_after?(
           existing.last_transport_failure_at,
           observation.last_heartbeat_at
         ) do
      {:error, :stale}
    else
      :ok
    end
  end

  defp ensure_fresh_observation(_existing, _observation), do: :ok

  defp upsert_observation(%{existing_by_id: %Node{} = existing}, observation) do
    attrs =
      observation
      |> Map.delete(:id)
      |> Map.delete(:last_heartbeat_at)
      |> Map.delete(:endpoint_transport)
      |> Map.delete(:beam_address)
      |> Map.put(:state, existing.state)
      |> preserve_beam_connection_inventory(existing, observation)

    existing
    |> Node.changeset(attrs)
    |> Repo.update!()
  end

  defp upsert_observation(_existing, observation) do
    upsert_observed_admission_candidate(observation)
    :candidate_persisted
  end

  defp update_authenticated_observation(
         %Node{} = node,
         target,
         observation,
         status_response,
         opts
       ) do
    node
    |> authenticated_observation_changeset(observation)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        persist_authenticated_capacity_evidence(
          updated,
          target,
          observation,
          status_response,
          opts
        )

      {:error, _changeset} ->
        Repo.rollback(:authenticated_observation_rejected)
    end
  end

  defp update_authenticated_beam_observation(
         %Node{} = node,
         target,
         observation,
         status_response,
         grant_id,
         opts
       ) do
    changeset = authenticated_observation_changeset(node, observation)

    if changeset.valid? do
      updates = Map.put(changeset.changes, :updated_at, DateTime.utc_now())
      current_grant = current_active_grant_query(grant_id, opts)

      query =
        Node
        |> where([candidate], candidate.id == ^node.id)
        |> where([candidate], exists(subquery(current_grant)))

      case Repo.update_all(query, set: Map.to_list(updates)) do
        {1, _rows} ->
          Node
          |> Repo.get!(node.id)
          |> persist_authenticated_capacity_evidence(
            target,
            observation,
            status_response,
            opts
          )

        _other ->
          Repo.rollback(:authenticated_observation_rejected)
      end
    else
      Repo.rollback(:authenticated_observation_rejected)
    end
  end

  defp authenticated_observation_changeset(node, observation) do
    observation = preserve_beam_connection_inventory(node, observation)

    Node.changeset(
      node,
      observation
      |> Map.delete(:id)
      |> Map.put(:state, authenticated_observed_state(node))
    )
  end

  defp persist_authenticated_capacity_evidence(
         node,
         target,
         observation,
         status_response,
         opts
       ) do
    attrs =
      observation.aggregate_capacity_evidence
      |> Map.put(:observed_at, observation.last_heartbeat_at)

    case DispatchCapacity.record_capacity_evidence(node.id, attrs) do
      {:ok, _evidence} ->
        persist_authenticated_heartbeat(node, target, status_response, observation, opts)

      {:error, _changeset} ->
        Repo.rollback(:authenticated_observation_rejected)
    end
  end

  defp persist_authenticated_heartbeat(node, target, status_response, observation, opts) do
    heartbeat_context = Keyword.get(opts, :heartbeat_context, Orchard.NodeHeartbeats)

    case heartbeat_context.append(node, target, status_response, observation.last_heartbeat_at) do
      {:ok, _heartbeat} -> node
      {:error, _reason} -> Repo.rollback(:authenticated_observation_rejected)
    end
  end

  defp aggregate_capacity_evidence(%Observation{aggregate_capacity_evidence: evidence}),
    do: evidence

  defp aggregate_capacity_evidence(status_response) do
    Observation.new(%{
      aggregate_active_request_count: map_get(status_response, :active_request_count),
      aggregate_max_concurrency: map_get(status_response, :max_concurrency)
    }).aggregate_capacity_evidence
  end

  defp authenticated_observed_state(%Node{state: :admitted}), do: :active
  defp authenticated_observed_state(%Node{state: state}), do: state

  defp current_active_grant_query(grant_id, opts) do
    BeamPeerGrants.Grant
    |> where([grant], grant.id == ^grant_id)
    |> where([grant], grant.state == :active)
    |> current_grant_window(opts)
    |> select([grant], 1)
  end

  defp current_grant_window(query, opts) do
    case Keyword.get(opts, :test_database_now) do
      database_now when is_function(database_now, 0) ->
        now = database_now.()

        query
        |> where([grant], grant.not_before_at <= ^now)
        |> where([grant], grant.expires_at > ^now)

      nil ->
        query
        |> where([grant], fragment("? <= clock_timestamp()", grant.not_before_at))
        |> where([grant], fragment("? > clock_timestamp()", grant.expires_at))
    end
  end

  defp preserve_beam_connection_inventory(attrs, node, %{endpoint_transport: :beam}) do
    attrs
    |> Map.put(:connect_host, node.connect_host)
    |> Map.put(:connect_port, node.connect_port)
  end

  defp preserve_beam_connection_inventory(attrs, _node, _observation), do: attrs

  defp preserve_beam_connection_inventory(node, %{endpoint_transport: :beam} = observation) do
    Map.merge(observation, %{
      connect_host: node.connect_host,
      connect_port: node.connect_port
    })
  end

  defp preserve_beam_connection_inventory(_node, observation), do: observation

  defp upsert_observed_admission_candidate(observation) do
    attrs = observed_candidate_attrs(observation)

    case lock_open_observed_candidate(observation) do
      %AdmissionCandidate{} = candidate ->
        if fresh_candidate_observation?(candidate, observation) do
          attrs = Map.put(attrs, :admission_category, candidate.admission_category)

          candidate
          |> AdmissionCandidate.changeset(attrs)
          |> Repo.update!()
        else
          candidate
        end

      nil ->
        %AdmissionCandidate{}
        |> AdmissionCandidate.changeset(attrs)
        |> Repo.insert!(
          on_conflict: observed_candidate_conflict_update(),
          conflict_target:
            {:unsafe_fragment,
             """
             (source, endpoint_transport, endpoint_target, ((observed_identity->>'claimed_node_id')))
             WHERE source = 'runtime_endpoint_observation'
               AND admission_category IN ('pending_observed', 'rejected')
               AND endpoint_transport IS NOT NULL
               AND endpoint_target IS NOT NULL
               AND observed_identity ? 'claimed_node_id'
             """}
        )
    end
  end

  defp fresh_candidate_observation?(%AdmissionCandidate{last_observed_at: nil}, _observation),
    do: true

  defp fresh_candidate_observation?(
         %AdmissionCandidate{last_observed_at: last_observed_at},
         observation
       ) do
    DateTime.compare(last_observed_at, observation.last_heartbeat_at) == :lt
  end

  defp observed_candidate_conflict_update do
    from(candidate in AdmissionCandidate,
      where:
        is_nil(candidate.last_observed_at) or
          candidate.last_observed_at < fragment("EXCLUDED.last_observed_at"),
      update: [
        set: [
          observed_identity: fragment("EXCLUDED.observed_identity"),
          target_ref: fragment("EXCLUDED.target_ref"),
          endpoint_transport: fragment("EXCLUDED.endpoint_transport"),
          endpoint_target: fragment("EXCLUDED.endpoint_target"),
          inventory: fragment("EXCLUDED.inventory"),
          compatibility_evidence: fragment("EXCLUDED.compatibility_evidence"),
          last_observed_at: fragment("EXCLUDED.last_observed_at"),
          updated_at: fragment("EXCLUDED.updated_at")
        ]
      ]
    )
  end

  defp lock_open_observed_candidate(observation) do
    claimed_node_id = observation.id
    endpoint_target = endpoint_target(observation)

    case lock_open_observed_candidate_by_endpoint(observation, claimed_node_id, endpoint_target) do
      %AdmissionCandidate{} = candidate ->
        candidate

      nil ->
        # Pre-#192 BEAM candidates may still use advertise_addr:rpc_port keys.
        # Reconcile those open rows onto the configured service@host identity.
        lock_legacy_beam_observed_candidate(observation, claimed_node_id)
    end
  end

  defp lock_open_observed_candidate_by_endpoint(observation, claimed_node_id, endpoint_target) do
    AdmissionCandidate
    |> where([candidate], candidate.source == :runtime_endpoint_observation)
    |> where([candidate], candidate.admission_category in [:pending_observed, :rejected])
    |> where([candidate], candidate.endpoint_transport == ^observation.endpoint_transport)
    |> where([candidate], candidate.endpoint_target == ^endpoint_target)
    |> where(
      [candidate],
      fragment("?->>'claimed_node_id' = ?", candidate.observed_identity, ^claimed_node_id)
    )
    |> order_by([candidate], desc: candidate.updated_at)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_legacy_beam_observed_candidate(
         %{endpoint_transport: :beam} = observation,
         claimed_node_id
       ) do
    endpoint_target = endpoint_target(observation)

    AdmissionCandidate
    |> where([candidate], candidate.source == :runtime_endpoint_observation)
    |> where([candidate], candidate.admission_category in [:pending_observed, :rejected])
    |> where([candidate], candidate.endpoint_transport == :beam)
    |> where([candidate], candidate.endpoint_target != ^endpoint_target)
    |> where(
      [candidate],
      fragment("?->>'claimed_node_id' = ?", candidate.observed_identity, ^claimed_node_id)
    )
    |> order_by([candidate], desc: candidate.updated_at)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_legacy_beam_observed_candidate(_observation, _claimed_node_id), do: nil

  defp observed_candidate_attrs(observation) do
    %{
      source: :runtime_endpoint_observation,
      admission_category: :pending_observed,
      observed_identity: observed_identity_snapshot(observation),
      target_ref: endpoint_target(observation),
      endpoint_transport: observation.endpoint_transport,
      endpoint_target: endpoint_target(observation),
      inventory: inventory_snapshot(observation),
      compatibility_evidence: compatibility_snapshot(observation),
      last_observed_at: observation.last_heartbeat_at
    }
  end

  defp endpoint_target(%{endpoint_transport: :beam, beam_address: address})
       when is_binary(address) and address != "",
       do: address

  defp endpoint_target(observation) do
    case {observation.connect_host, observation.connect_port} do
      {host, port} when is_binary(host) and is_integer(port) -> "#{host}:#{port}"
      _other -> "#{observation.advertise_addr}:#{observation.rpc_port}"
    end
  end

  # -- Admission Decisions --

  defp do_reject_admission(lock_target, attrs, opts) do
    attrs = normalize_attrs(attrs)

    AuditWriter.transaction(fn ->
      with {:ok, target} <- lock_target.(),
           {:ok, reason} <- required_reason(attrs),
           {:ok, candidate} <- reject_admission_target(target),
           {:ok, audit_log} <-
             insert_admission_audit_log(
               "node_admission.rejected",
               candidate,
               admission_audit_payload(candidate, %{"reason" => reason}),
               opts
             ),
           {:ok, decision} <-
             insert_admission_decision(candidate, :rejected, reason, audit_log, %{}, opts) do
        {:ok, %{candidate: candidate, decision: decision, audit_log: audit_log}}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp do_clear_admission_rejection(lock_candidate, attrs, opts) do
    attrs = normalize_attrs(attrs)

    AuditWriter.transaction(fn ->
      with {:ok, candidate} <- lock_candidate.(),
           {:ok, restored} <- restore_candidate_pending_category(candidate),
           {:ok, audit_log} <-
             insert_admission_audit_log(
               "node_admission.rejection_cleared",
               restored,
               admission_audit_payload(restored, attrs),
               opts
             ),
           {:ok, decision} <-
             insert_admission_decision(restored, :rejection_cleared, nil, audit_log, attrs, opts) do
        {:ok, %{candidate: restored, decision: decision, audit_log: audit_log}}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
  end

  defp lock_admission_target(id) do
    case lock_candidate(id) do
      %AdmissionCandidate{} = candidate ->
        {:ok, {:candidate, candidate}}

      nil ->
        case lock_node(id) do
          {:ok, %Node{} = node} -> {:ok, {:node, node}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp lock_candidate_by_id(candidate_id) do
    with {:ok, candidate_id} <- normalize_uuid(candidate_id, :candidate_not_found) do
      candidate_id
      |> lock_candidate()
      |> case do
        %AdmissionCandidate{} = candidate -> {:ok, candidate}
        nil -> {:error, :candidate_not_found}
      end
    end
  end

  defp lock_candidate_target(candidate_id) do
    with {:ok, candidate} <- lock_candidate_by_id(candidate_id) do
      {:ok, {:candidate, candidate}}
    end
  end

  defp reject_admission_target({:candidate, %AdmissionCandidate{} = candidate}) do
    if candidate.admission_category in [
         :pending_observed,
         :pending_provisioned,
         :pending_registered
       ] do
      update_candidate_category(candidate, :rejected)
    else
      {:error, :admission_not_pending}
    end
  end

  defp reject_admission_target({:node, %Node{state: state} = node})
       when state in [:provisioned, :registered] do
    with {:ok, candidate} <- get_or_create_candidate_for_node(node) do
      reject_admission_target({:candidate, candidate})
    end
  end

  defp reject_admission_target({:node, %Node{}}), do: {:error, :admission_not_pending}

  defp lock_rejected_candidate(id) do
    case lock_candidate(id) do
      %AdmissionCandidate{admission_category: :rejected} = candidate ->
        {:ok, candidate}

      %AdmissionCandidate{} ->
        {:error, :admission_not_rejected}

      nil ->
        lock_rejected_candidate_for_node(id)
    end
  end

  defp lock_rejected_candidate_by_id(candidate_id) do
    with {:ok, candidate} <- lock_candidate_by_id(candidate_id) do
      case candidate do
        %AdmissionCandidate{admission_category: :rejected} = candidate ->
          {:ok, candidate}

        %AdmissionCandidate{} ->
          {:error, :admission_not_rejected}
      end
    end
  end

  defp lock_rejected_candidate_for_node(node_id) do
    AdmissionCandidate
    |> where([candidate], candidate.node_id == ^node_id)
    |> where([candidate], candidate.admission_category == :rejected)
    |> order_by([candidate], desc: candidate.updated_at)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %AdmissionCandidate{} = candidate -> {:ok, candidate}
      nil -> {:error, :admission_not_rejected}
    end
  end

  defp restore_candidate_pending_category(%AdmissionCandidate{} = candidate) do
    update_candidate_category(candidate, pending_category_for_source(candidate.source))
  end

  defp pending_category_for_source(:runtime_endpoint_observation), do: :pending_observed
  defp pending_category_for_source(:provisioned_placeholder), do: :pending_provisioned
  defp pending_category_for_source(:registered_node), do: :pending_registered

  defp ensure_node_admittable(%Node{state: :registered} = node, attrs) do
    case latest_admission_decision_for_node(node.id) do
      %AdmissionDecision{decision: :rejected} -> {:error, :admission_rejected}
      _other -> ensure_admission_inputs_present(node, attrs)
    end
  end

  defp ensure_node_admittable(%Node{state: :provisioned}, _attrs),
    do: {:error, :node_not_registered}

  defp ensure_node_admittable(%Node{}, _attrs), do: {:error, :node_not_pending_admission}

  defp ensure_pre_cutover_authority(%{enforcement_phase: :pre_cutover}), do: :ok

  defp ensure_pre_cutover_authority(_authority),
    do: {:error, :dispatch_capacity_phase_unsupported}

  defp resolve_admission_capacity_policy(attrs, opts) do
    with {:ok, reason} <- required_capacity_policy_reason(attrs),
         {:ok, ceiling} <- admission_capacity_ceiling(attrs),
         {:ok, actor} <- resolve_admission_actor(opts) do
      {:ok,
       %{
         reason: reason,
         ceiling: ceiling,
         actor_type: actor.actor_type,
         actor_id: actor.actor_id
       }}
    end
  end

  defp resolve_admission_actor(opts) do
    case audit_actor_id(opts) do
      actor_id when is_binary(actor_id) and actor_id != "" ->
        {:ok, %{actor_type: audit_actor_type(opts), actor_id: actor_id}}

      _absent ->
        local_controller_actor(opts)
    end
  end

  defp local_controller_actor(opts) do
    case ControllerInstances.local_principal(opts) do
      {:ok, principal} -> {:ok, %{actor_type: "operator", actor_id: principal}}
      {:error, _reason} -> {:error, :admission_actor_identity_unavailable}
    end
  end

  defp put_actor_opts(opts, %{actor_type: actor_type, actor_id: actor_id}) do
    Keyword.merge(opts, actor_type: actor_type, actor_id: actor_id)
  end

  defp required_capacity_policy_reason(attrs) do
    case attrs |> Map.get("capacity_policy_reason") |> AdmissionDecision.normalize_reason() do
      nil -> {:error, :capacity_policy_reason_required}
      reason -> {:ok, reason}
    end
  end

  defp admission_capacity_ceiling(attrs) do
    case Map.fetch(attrs, "controller_dispatch_ceiling") do
      :error -> {:ok, 1}
      {:ok, ceiling} when is_integer(ceiling) and ceiling >= 0 -> {:ok, ceiling}
      {:ok, _invalid} -> {:error, :invalid_controller_dispatch_ceiling}
    end
  end

  defp do_admission_blocker_codes(%Node{state: :provisioned}, _attrs),
    do: [:node_not_registered]

  defp do_admission_blocker_codes(%Node{state: :registered} = node, attrs) do
    []
    |> maybe_add_blocker(:inventory_missing, not registered_inventory_present?(node))
    |> maybe_add_blocker(
      :trust_not_established,
      blank_admission_input?(attrs, ["trust_evidence_ref", "trust_ref"])
    )
    |> maybe_add_blocker(:pool_required, blank_admission_input?(attrs, ["pool_id", "pool"]))
    |> maybe_add_blocker(
      :policy_required,
      blank_admission_input?(attrs, ["routing_policy_id", "policy_ref", "policy_inputs"])
    )
    |> maybe_add_blocker(
      :invalid_controller_dispatch_ceiling,
      match?({:error, :invalid_controller_dispatch_ceiling}, admission_capacity_ceiling(attrs))
    )
  end

  defp do_admission_blocker_codes(%Node{}, _attrs), do: [:node_not_pending_admission]

  defp maybe_add_blocker(blockers, blocker, true), do: blockers ++ [blocker]
  defp maybe_add_blocker(blockers, _blocker, false), do: blockers

  defp ensure_admission_inputs_present(%Node{} = node, attrs) do
    cond do
      not registered_inventory_present?(node) ->
        {:error, :inventory_missing}

      blank_admission_input?(attrs, ["trust_evidence_ref", "trust_ref"]) ->
        {:error, :trust_not_established}

      blank_admission_input?(attrs, ["pool_id", "pool"]) ->
        {:error, :pool_required}

      blank_admission_input?(attrs, ["routing_policy_id", "policy_ref", "policy_inputs"]) ->
        {:error, :policy_required}

      true ->
        :ok
    end
  end

  defp registered_inventory_present?(%Node{} = node) do
    non_empty?(node.hostname) and non_empty?(node.display_name) and
      node_has_routable_target?(node)
  end

  defp node_has_routable_target?(%Node{} = node) do
    (routable_advertise_addr?(node.advertise_addr) and is_integer(node.rpc_port)) or
      routable_connect_target?(node.connect_host, node.connect_port)
  end

  defp routable_connect_target?(host, port),
    do: routable_advertise_addr?(host) and is_integer(port)

  defp blank_admission_input?(attrs, keys) do
    keys
    |> Enum.map(&Map.get(attrs, &1))
    |> Enum.all?(&blank_admission_value?/1)
  end

  defp blank_admission_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_admission_value?(value) when is_map(value), do: map_size(value) == 0
  defp blank_admission_value?(value) when is_list(value), do: value == []
  defp blank_admission_value?(nil), do: true
  defp blank_admission_value?(_value), do: false

  @doc """
  Returns the latest admission decision for a node.
  """
  @spec latest_admission_decision_for_node(Ecto.UUID.t()) :: AdmissionDecision.t() | nil
  def latest_admission_decision_for_node(node_id) do
    case normalize_uuid(node_id, :node_not_found) do
      {:ok, node_id} -> do_latest_admission_decision_for_node(node_id)
      {:error, :node_not_found} -> nil
    end
  end

  defp do_latest_admission_decision_for_node(node_id) do
    AdmissionDecision
    |> where([decision], decision.node_id == ^node_id)
    |> order_by([decision], desc: decision.decided_at, desc: decision.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp get_or_create_candidate_for_node(%Node{} = node) do
    case lock_candidate_for_node(node.id) do
      %AdmissionCandidate{} = candidate ->
        {:ok, candidate}

      nil ->
        %AdmissionCandidate{}
        |> AdmissionCandidate.changeset(candidate_attrs_for_node(node))
        |> Repo.insert()
    end
  end

  defp lock_candidate_for_node(node_id) do
    AdmissionCandidate
    |> where([candidate], candidate.node_id == ^node_id)
    |> order_by([candidate], desc: candidate.updated_at)
    |> limit(1)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_candidate(id) do
    AdmissionCandidate
    |> where([candidate], candidate.id == ^id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  @doc "Locks one Node row for transaction-scoped capacity and lifecycle mutation."
  @spec lock_node(Ecto.UUID.t()) :: {:ok, Node.t()} | {:error, :node_not_found}
  def lock_node(node_id) do
    with {:ok, node_id} <- normalize_uuid(node_id, :node_not_found) do
      Node
      |> where([node], node.id == ^node_id)
      |> lock("FOR UPDATE")
      |> Repo.one()
      |> case do
        %Node{} = node -> {:ok, node}
        nil -> {:error, :node_not_found}
      end
    end
  end

  defp update_node_state(%Node{} = node, state) do
    node
    |> Ecto.Changeset.change(state: state)
    |> Repo.update()
  end

  defp update_candidate_category(%AdmissionCandidate{} = candidate, category) do
    candidate
    |> Ecto.Changeset.change(admission_category: category)
    |> Repo.update()
  end

  defp candidate_attrs_for_node(%Node{} = node) do
    source = candidate_source_for_node(node)

    %{
      node_id: node.id,
      source: source,
      admission_category: pending_category_for_source(source),
      observed_identity: node_identity_snapshot(node),
      target_ref: node_target_ref(node),
      endpoint_transport: :grpc,
      endpoint_target: node_target_ref(node),
      inventory: inventory_snapshot(node),
      compatibility_evidence: compatibility_snapshot(node),
      last_observed_at: node.last_heartbeat_at
    }
  end

  defp observed_identity_snapshot(observation) do
    sanitize_snapshot(%{
      "claimed_node_id" => observation.id,
      "display_name" => observation.display_name,
      "hostname" => observation.hostname,
      "agent_version" => observation.agent_version
    })
  end

  defp node_identity_snapshot(%Node{} = node) do
    sanitize_snapshot(%{
      "node_id" => node.id,
      "display_name" => node.display_name,
      "hostname" => node.hostname,
      "agent_version" => node.agent_version
    })
  end

  defp inventory_snapshot(source) do
    sanitize_snapshot(%{
      "advertise_addr" => source.advertise_addr,
      "rpc_port" => source.rpc_port,
      "connect_host" => source.connect_host,
      "connect_port" => source.connect_port,
      "capabilities" => source.capabilities
    })
  end

  defp compatibility_snapshot(source) do
    sanitize_snapshot(%{
      "health" => Atom.to_string(source.health),
      "tool_readiness" => source.tool_readiness
    })
  end

  defp candidate_source_for_node(%Node{state: :registered}), do: :registered_node
  defp candidate_source_for_node(%Node{}), do: :provisioned_placeholder

  defp node_target_ref(%Node{connect_host: host, connect_port: port})
       when is_binary(host) and is_integer(port),
       do: "#{host}:#{port}"

  defp node_target_ref(%Node{advertise_addr: host, rpc_port: port}), do: "#{host}:#{port}"

  defp insert_admission_audit_log(action, %AdmissionCandidate{} = candidate, payload, opts) do
    Governance.insert_cluster_audit_log(%{
      actor_type: audit_actor_type(opts),
      actor_id: audit_actor_id(opts),
      action: action,
      target_type: "node_admission_candidate",
      target_id: candidate.id,
      occurred_at: utc_now(),
      payload: payload
    })
  end

  defp insert_admission_decision(
         %AdmissionCandidate{} = candidate,
         decision,
         reason,
         %AuditLog{} = audit_log,
         metadata,
         opts
       ) do
    %AdmissionDecision{}
    |> AdmissionDecision.changeset(%{
      candidate_id: candidate.id,
      node_id: candidate.node_id,
      decision: decision,
      actor_type: audit_actor_type(opts),
      actor_id: audit_actor_id(opts),
      reason: reason,
      observed_identity: candidate.observed_identity || %{},
      target_ref: candidate.target_ref,
      audit_log_id: audit_log.id,
      metadata: sanitize_snapshot(metadata),
      decided_at: utc_now()
    })
    |> Repo.insert()
  end

  defp admission_audit_payload(%AdmissionCandidate{} = candidate, extra) do
    %{
      "candidate_id" => candidate.id,
      "node_id" => candidate.node_id,
      "source" => Atom.to_string(candidate.source),
      "admission_category" => Atom.to_string(candidate.admission_category),
      "observed_identity" => candidate.observed_identity || %{},
      "target_ref" => candidate.target_ref
    }
    |> Map.merge(sanitize_snapshot(extra))
  end

  defp required_reason(attrs) do
    case attrs |> Map.get("reason") |> AdmissionDecision.normalize_reason() do
      nil -> {:error, :reason_required}
      reason -> {:ok, reason}
    end
  end

  defp audit_actor_type(opts), do: opts |> Keyword.get(:actor_type, "operator") |> to_string()
  defp audit_actor_id(opts), do: Keyword.get(opts, :actor_id)

  defp utc_now, do: SchemaSupport.utc_now()

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_transaction_result({:ok, value}), do: value
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp maybe_filter_candidate_category(query, nil), do: query

  defp maybe_filter_candidate_category(query, categories) when is_list(categories) do
    where(query, [candidate], candidate.admission_category in ^categories)
  end

  defp maybe_filter_candidate_category(query, category) do
    where(query, [candidate], candidate.admission_category == ^category)
  end

  defp normalize_attrs(attrs) do
    attrs
    |> SchemaSupport.normalize_attrs()
    |> Map.drop(@reserved_actor_provenance_keys)
  end

  defp normalize_uuid(value, error) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, error}
    end
  end

  defp normalize_uuid_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case Ecto.UUID.cast(value) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp sanitize_snapshot(value), do: sanitize_snapshot(value, 0)

  defp sanitize_snapshot(value, depth) when depth >= @snapshot_max_depth do
    cond do
      is_map(value) -> %{"truncated" => true}
      is_list(value) -> ["truncated"]
      is_binary(value) -> bound_string(value)
      true -> value
    end
  end

  defp sanitize_snapshot(value, depth) when is_map(value) do
    entries = Enum.to_list(value)

    if length(entries) > @snapshot_entry_limit do
      entries
      |> Enum.take(@snapshot_entry_limit - 1)
      |> Map.new(&sanitize_snapshot_map_entry(&1, depth))
      |> Map.put(@snapshot_truncation_key, snapshot_truncation_marker(:map, length(entries)))
    else
      Map.new(entries, &sanitize_snapshot_map_entry(&1, depth))
    end
  end

  defp sanitize_snapshot(value, depth) when is_list(value) do
    if length(value) > @snapshot_entry_limit do
      retained =
        value
        |> Enum.take(@snapshot_entry_limit - 1)
        |> Enum.map(&sanitize_snapshot(&1, depth + 1))

      retained ++ [snapshot_truncation_marker(:list, length(value))]
    else
      Enum.map(value, &sanitize_snapshot(&1, depth + 1))
    end
  end

  defp sanitize_snapshot(value, _depth) when is_binary(value), do: bound_string(value)
  defp sanitize_snapshot(value, _depth), do: value

  defp sanitize_snapshot_map_entry({key, entry}, depth) do
    {to_string(key), sanitize_snapshot(entry, depth + 1)}
  end

  defp snapshot_truncation_marker(kind, original_count) do
    %{
      "truncated" => true,
      "reason" => "entry_limit",
      "kind" => Atom.to_string(kind),
      "entry_limit" => @snapshot_entry_limit,
      "original_count" => original_count
    }
  end

  defp bound_string(value) when byte_size(value) > @snapshot_string_limit_bytes do
    value
    |> String.slice(0, @snapshot_string_limit_bytes)
    |> trim_to_byte_size(@snapshot_string_limit_bytes)
  end

  defp bound_string(value), do: value

  defp trim_to_byte_size(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp trim_to_byte_size(value, max_bytes) do
    value
    |> String.slice(0..-2//1)
    |> trim_to_byte_size(max_bytes)
  end

  defp target_match?(node, observation) do
    advertised_target_match?(node, observation) or connect_target_match?(node, observation)
  end

  # -- Mark Unreachable --

  defp execute_mark_unreachable(target_lookup, observed_at, demotion_source) do
    Repo.transaction(fn ->
      case fetch_node_for_transport_update(target_lookup) do
        nil ->
          Repo.rollback(:noop)

        %Node{} = node ->
          update_transport_failure_health(node, observed_at, demotion_source)
      end
    end)
    |> case do
      {:ok, node} -> {:ok, node}
      {:error, :noop} -> :noop
    end
  end

  defp record_dispatch_transport_failure_transaction(target_lookup, failure) do
    normalize_dispatch_database_failure(fn ->
      AuditWriter.transaction(fn ->
        validate_dispatch_transport_identity(target_lookup, failure.node_id)
        record_dispatch_transport_breaker(target_lookup, failure)
      end)
      |> case do
        {:ok, {node, breaker, true}} ->
          clear_dispatch_capacity_sources(node.id)
          {:ok, %{node: node, breaker: breaker}}

        {:ok, {node, breaker, false}} ->
          {:ok, %{node: node, breaker: breaker}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp normalize_dispatch_database_failure(fun) do
    fun.()
  rescue
    _exception in @dispatch_database_errors ->
      {:error, :circuit_breaker_unavailable}
  catch
    :exit, reason ->
      if dispatch_database_exit?(reason),
        do: {:error, :circuit_breaker_unavailable},
        else: exit(reason)
  end

  defp dispatch_database_exit?(reason) when is_struct(reason),
    do: reason.__struct__ in @dispatch_database_errors

  defp dispatch_database_exit?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&dispatch_database_exit?/1)

  defp dispatch_database_exit?(reason) when is_list(reason),
    do: Enum.any?(reason, &dispatch_database_exit?/1)

  defp dispatch_database_exit?(_reason), do: false

  defp validate_dispatch_transport_identity(target_lookup, expected_node_id) do
    case lookup_node_by_target_lookup(target_lookup) do
      nil ->
        Repo.rollback(:transport_failure_target_unknown)

      %Node{id: node_id} when node_id != expected_node_id ->
        Repo.rollback(:transport_failure_target_mismatch)

      %Node{} ->
        :ok
    end
  end

  defp refetch_dispatch_transport_node(target_lookup, node_id) do
    case fetch_node_for_transport_update({:node_id, node_id}) do
      nil ->
        Repo.rollback(:transport_failure_target_unknown)

      %Node{} = node ->
        validate_dispatch_transport_target(node, target_lookup)
    end
  end

  defp validate_dispatch_transport_target(node, target_lookup) do
    if dispatch_transport_target_match?(node, target_lookup),
      do: node,
      else: Repo.rollback(:transport_failure_target_mismatch)
  end

  defp dispatch_transport_target_match?(%Node{id: node_id}, {:node_id, node_id}), do: true

  defp dispatch_transport_target_match?(node, {:connect_target, host, port}) do
    (node.connect_host == host and node.connect_port == port) or
      (is_nil(node.connect_host) and is_nil(node.connect_port) and
         node.advertise_addr == host and node.rpc_port == port)
  end

  defp record_dispatch_transport_breaker(target_lookup, failure) do
    case Orchard.CircuitBreakers.record_failure(failure) do
      {:ok, :not_eligible} ->
        Repo.rollback(:transport_failure_class_not_breaker_eligible)

      {:ok, breaker} ->
        node = refetch_dispatch_transport_node(target_lookup, failure.node_id)
        {node, health_changed?} = apply_dispatch_transport_health(node, failure.occurred_at)
        {node, breaker, health_changed?}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp apply_dispatch_transport_health(node, occurred_at) do
    case resolve_transport_failure_health(node, occurred_at) do
      :noop ->
        {node, false}

      health ->
        node =
          node
          |> Ecto.Changeset.change(demotion_changes(health, occurred_at, :transport_failure))
          |> Repo.update!()

        {node, true}
    end
  end

  defp fetch_node_for_transport_update({:connect_target, host, port}) do
    fetch_node_by_connect_target(host, port) ||
      fetch_legacy_node_by_advertise_target(host, port)
  end

  defp fetch_node_for_transport_update({:node_id, node_id}) do
    Node
    |> where([n], n.id == ^node_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp update_transport_failure_health(%Node{} = node, observed_at, demotion_source) do
    case resolve_transport_failure_health(node, observed_at) do
      :noop ->
        Repo.rollback(:noop)

      health ->
        node
        |> Ecto.Changeset.change(demotion_changes(health, observed_at, demotion_source))
        |> Repo.update!()
    end
  end

  defp demotion_changes(health, observed_at, :transport_failure),
    do: %{health: health, last_transport_failure_at: observed_at}

  defp demotion_changes(health, _observed_at, :stale_sweep), do: %{health: health}

  defp resolve_transport_failure_health(%Node{} = node, %DateTime{} = observed_at) do
    cond do
      timestamp_at_or_after?(node.last_transport_failure_at, observed_at) ->
        :noop

      timestamp_at_or_after?(node.last_heartbeat_at, observed_at) ->
        :noop

      is_nil(node.last_heartbeat_at) ->
        :unreachable

      node.health == :unhealthy ->
        :unhealthy

      DateTime.compare(
        node.last_heartbeat_at,
        DateTime.add(observed_at, -unreachable_threshold_ms(), :millisecond)
      ) == :lt ->
        :unreachable

      true ->
        :degraded
    end
  end

  defp resolve_transport_failure_health(_node, _observed_at), do: :noop

  defp timestamp_at_or_after?(%DateTime{} = timestamp, %DateTime{} = boundary) do
    DateTime.compare(timestamp, boundary) in [:eq, :gt]
  end

  defp timestamp_at_or_after?(_timestamp, _boundary), do: false

  # -- Helpers --

  defp trusted_runtime_endpoint_target({%Node{} = node, %Enrollment{} = enrollment}) do
    with {:ok, address} <- trusted_connection_address(node),
         {:ok, certificate} <- enrollment_certificate_binding(enrollment) do
      [
        Target.grpc_compat(
          Keyword.merge(address,
            node_id: node.id,
            metadata:
              Map.merge(certificate, %{
                authorization: runtime_target_authorization(node.state),
                enrollment_id: enrollment.id,
                source: :trusted_node_inventory
              })
          )
        )
      ]
    else
      _other -> []
    end
  end

  defp trusted_beam_runtime_endpoint_target(
         {%Node{} = node, %Enrollment{} = enrollment, %Orchard.BeamPeerGrants.Grant{} = grant}
       ) do
    with true <- is_binary(node.canonical_beam_name) and node.canonical_beam_name != "",
         true <- grant.node_beam_name == node.canonical_beam_name,
         true <- grant.node_id == node.id,
         {:ok, certificate} <- enrollment_certificate_binding(enrollment),
         true <- grant.node_certificate_identifier == certificate.certificate_identifier,
         true <-
           grant.node_certificate_fingerprint_sha256 == certificate.certificate_fingerprint do
      [
        Target.beam(node.id,
          address: node.canonical_beam_name,
          metadata:
            Map.merge(certificate, %{
              authorization: runtime_target_authorization(node.state),
              beam_authorization_root_id: grant.beam_authorization_root_id,
              controller_beam_name: grant.controller_beam_name,
              controller_certificate_fingerprint_sha256:
                grant.controller_certificate_fingerprint_sha256,
              controller_certificate_identifier: grant.controller_certificate_identifier,
              controller_id: grant.controller_id,
              enrollment_id: enrollment.id,
              generation: grant.generation,
              grant_id: grant.id,
              source: :trusted_node_inventory
            })
        )
      ]
    else
      _other -> []
    end
  end

  defp runtime_target_authorization(:admitted), do: :activation_probe
  defp runtime_target_authorization(:active), do: :inference_dispatch

  defp trusted_connection_address(%Node{connect_host: host, connect_port: port})
       when is_binary(host) and host != "" and is_integer(port) and port in 1..65_535,
       do: {:ok, [host: host, port: port]}

  defp trusted_connection_address(%Node{advertise_addr: host, rpc_port: port})
       when is_binary(host) and host not in ["", "0.0.0.0", "::"] and is_integer(port) and
              port in 1..65_535,
       do: {:ok, [host: host, port: port]}

  defp trusted_connection_address(_node), do: :error

  defp enrollment_certificate_binding(%Enrollment{} = enrollment) do
    result = enrollment.certificate_result
    certificate_pem = map_get(result, :node_certificate_pem)
    stored_serial = map_get(result, :certificate_serial)
    stored_node_uri = map_get(result, :node_uri_san)
    runtime_trust_spki = map_get(result, :runtime_trust_spki_sha256)

    expected_node_uri =
      "urn:orchard:cluster:#{enrollment.cluster_id}:node:#{enrollment.node_id}"

    with true <- non_empty?(enrollment.certificate_identifier),
         true <- is_binary(certificate_pem),
         {:ok, certificate} <- CertificateIdentity.from_pem(certificate_pem),
         true <- certificate.serial == stored_serial,
         true <- certificate.uri_sans == [expected_node_uri],
         true <- stored_node_uri == expected_node_uri,
         true <- non_empty?(runtime_trust_spki) do
      {:ok,
       %{
         certificate_identifier: enrollment.certificate_identifier,
         certificate_serial: certificate.serial,
         certificate_fingerprint: certificate.fingerprint,
         node_uri_san: expected_node_uri,
         runtime_trust_spki_sha256: runtime_trust_spki
       }}
    else
      _other -> {:error, :invalid_enrollment_certificate_binding}
    end
  end

  defp authenticated_peer_binding(%AuthenticatedPeer{} = peer) do
    %{
      certificate_identifier: peer.certificate_identifier,
      certificate_serial: peer.certificate_serial,
      certificate_fingerprint: peer.certificate_fingerprint,
      node_uri_san: peer.node_uri_san,
      runtime_trust_spki_sha256: peer.runtime_trust_spki_sha256
    }
  end

  defp normalize_authenticated_peer_identity(%AuthenticatedPeer{scheme: :mtls} = peer) do
    identifiers = [peer.node_id, peer.enrollment_id]

    valid =
      Enum.all?(identifiers, &match?({:ok, _uuid}, Ecto.UUID.cast(&1))) and
        Enum.all?(
          [
            peer.node_uri_san,
            peer.certificate_identifier,
            peer.certificate_serial,
            peer.certificate_fingerprint,
            peer.runtime_trust_spki_sha256
          ],
          &non_empty?/1
        )

    if valid, do: {:ok, peer}, else: :error
  end

  defp normalize_authenticated_peer_identity(_peer_identity), do: :error

  defp lock_authenticated_enrollment(peer) do
    Enrollment
    |> where([enrollment], enrollment.id == ^peer.enrollment_id)
    |> where([enrollment], enrollment.node_id == ^peer.node_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_authenticated_node(node_id) do
    Node
    |> where([node], node.id == ^node_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_authenticated_beam_grant(target, peer) do
    grant_id = metadata_value(target.metadata, :grant_id)

    BeamPeerGrants.Grant
    |> where([grant], grant.id == ^grant_id)
    |> where([grant], grant.node_id == ^peer.node_id)
    |> where([grant], grant.state == :active)
    |> where([grant], fragment("? <= clock_timestamp()", grant.not_before_at))
    |> where([grant], fragment("? > clock_timestamp()", grant.expires_at))
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp lock_authenticated_controller(controller_id) do
    ControllerInstance
    |> where([controller], controller.id == ^controller_id)
    |> where([controller], controller.status == :operational)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp ensure_authenticated_enrollment(
         %Enrollment{node_id: node_id, state: :consumed, certificate_issuance_outcome: :issued} =
           enrollment,
         %AuthenticatedPeer{node_id: node_id} = peer
       ) do
    with {:ok, binding} <- enrollment_certificate_binding(enrollment),
         true <- authenticated_peer_binding(peer) == binding do
      :ok
    else
      _other -> :error
    end
  end

  defp ensure_authenticated_enrollment(_enrollment, _peer_identity), do: :error

  defp ensure_authenticated_node(
         %Node{id: node_id, state: state},
         %{id: node_id},
         %AuthenticatedPeer{node_id: node_id}
       )
       when state in [:admitted, :active],
       do: :ok

  defp ensure_authenticated_node(_node, _observation, _peer_identity), do: :error

  defp ensure_authenticated_beam_target(target, node, enrollment, grant, controller) do
    case trusted_beam_runtime_endpoint_target({node, enrollment, grant}) do
      [expected] ->
        if controller.id == grant.controller_id and
             target_identity(expected) == target_identity(target) do
          :ok
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp ensure_authenticated_target(%Target{} = target, node, enrollment) do
    case authenticated_expected_targets(target, node, enrollment) do
      [expected] ->
        if target_identity(expected) == target_identity(target), do: :ok, else: :error

      _other ->
        :error
    end
  end

  defp ensure_authenticated_target(_target, _node, _enrollment), do: :error

  defp authenticated_expected_targets(%Target{}, node, enrollment) do
    trusted_runtime_endpoint_target({node, enrollment})
  end

  defp target_identity(%Target{} = target) do
    metadata = target.metadata

    {
      target.id,
      target.transport,
      target.node_id,
      target.address,
      metadata_value(metadata, :source),
      metadata_value(metadata, :enrollment_id),
      metadata_value(metadata, :certificate_identifier),
      metadata_value(metadata, :certificate_serial),
      metadata_value(metadata, :certificate_fingerprint),
      metadata_value(metadata, :node_uri_san),
      metadata_value(metadata, :runtime_trust_spki_sha256),
      metadata_value(metadata, :grant_id),
      metadata_value(metadata, :generation),
      metadata_value(metadata, :controller_id),
      metadata_value(metadata, :controller_beam_name),
      metadata_value(metadata, :controller_certificate_identifier),
      metadata_value(metadata, :controller_certificate_fingerprint_sha256),
      metadata_value(metadata, :beam_authorization_root_id)
    }
  end

  # Require a boolean ready flag so empty/garbage health maps cannot derive to
  # a false healthy observation through the authenticated seam.
  defp authenticated_status_health_present?(status_response) do
    case extract_runtime_health(status_response) do
      %{} = health -> is_boolean(map_get(health, :ready))
      _other -> false
    end
  end

  # Already-:active Nodes may record degraded/unhealthy observations.
  # :admitted → :active promotion remains healthy-gated.
  defp accept_authenticated_observation_health?(%Node{state: :active}, %{health: health})
       when health in [:healthy, :degraded, :unhealthy],
       do: true

  defp accept_authenticated_observation_health?(%Node{state: :admitted}, %{health: :healthy}),
    do: true

  defp accept_authenticated_observation_health?(_node, _observation), do: false

  defp fresh_authenticated_observation?(%DateTime{} = observed_at) do
    now = DateTime.utc_now()

    cutoff =
      DateTime.add(now, -Orchard.Inference.node_freshness_threshold_ms(), :millisecond)

    future_limit = DateTime.add(now, @authenticated_observation_future_skew_ms, :millisecond)

    DateTime.compare(observed_at, cutoff) in [:eq, :gt] and
      DateTime.compare(observed_at, future_limit) in [:lt, :eq]
  end

  defp fresh_authenticated_observation?(_observed_at), do: false

  defp repo_available? do
    pid = Process.whereis(Orchard.Repo)
    is_pid(pid) and Process.alive?(pid)
  end

  defp target_lookup(%Target{transport: :beam} = target) do
    case target_node_id_lookup(target) do
      {:ok, _lookup} = result -> result
      :error -> target_metadata_lookup(target.metadata)
    end
  end

  defp target_lookup(target), do: connection_target_lookup(target)

  defp target_node_id_lookup(%Target{node_id: node_id}) when is_binary(node_id) do
    case Ecto.UUID.cast(node_id) do
      {:ok, node_id} -> {:ok, {:node_id, node_id}}
      :error -> :error
    end
  end

  defp target_node_id_lookup(_target), do: :error

  defp target_metadata_lookup(%{} = metadata) do
    host =
      metadata_value(metadata, :connect_host) ||
        metadata_value(metadata, :host) ||
        metadata_value(metadata, :listen_host)

    port =
      metadata_value(metadata, :connect_port) ||
        metadata_value(metadata, :port) ||
        metadata_value(metadata, :listen_port)

    connection_target_lookup(host: host, port: port)
  end

  defp target_metadata_lookup(_metadata), do: :error

  defp connection_target_lookup(target) do
    target = target_address(target)
    host = Keyword.get(target, :host)
    port = Keyword.get(target, :port)

    if is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 do
      {:ok, {:connect_target, host, port}}
    else
      :error
    end
  end

  defp target_host(target), do: target |> target_address() |> Keyword.get(:host, "")
  defp target_port(target), do: target |> target_address() |> Keyword.get(:port)

  defp connect_host(target) do
    target = target_address(target)

    case Keyword.get(target, :host) do
      host when is_binary(host) and host != "" -> host
      _other -> nil
    end
  end

  defp connect_port(target) do
    target = target_address(target)

    case Keyword.get(target, :port) do
      port when is_integer(port) and port in 1..65_535 -> port
      _other -> nil
    end
  end

  defp beam_target_address(%Target{transport: :beam, address: address}) when is_atom(address),
    do: Atom.to_string(address)

  defp beam_target_address(%Target{transport: :beam, address: address})
       when is_binary(address) and address != "",
       do: address

  defp beam_target_address(_target), do: nil

  defp map_get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp map_get(_map, key) when is_atom(key), do: nil

  defp lookup_node_by_target_lookup({:connect_target, host, port}) do
    lookup_node_by_connect_target(host, port) ||
      lookup_legacy_node_by_advertise_target(host, port)
  end

  defp lookup_node_by_target_lookup({:node_id, node_id}) do
    Repo.get(Node, node_id)
  end

  defp lookup_node_by_connect_target(host, port) do
    connect_target_query(host, port)
    |> Repo.one()
  end

  defp lookup_legacy_node_by_advertise_target(host, port) do
    legacy_advertise_target_query(host, port)
    |> Repo.one()
  end

  defp fetch_node_by_connect_target(host, port) do
    connect_target_query(host, port)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp fetch_legacy_node_by_advertise_target(host, port) do
    legacy_advertise_target_query(host, port)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp connect_target_query(host, port) do
    Node
    |> where([n], n.connect_host == ^host and n.connect_port == ^port)
  end

  defp legacy_advertise_target_query(host, port) do
    Node
    |> where(
      [n],
      is_nil(n.connect_host) and is_nil(n.connect_port) and n.advertise_addr == ^host and
        n.rpc_port == ^port
    )
  end

  defp advertised_target_match?(node, observation) do
    routable_advertise_addr?(observation.advertise_addr) and
      node.advertise_addr == observation.advertise_addr and
      node.rpc_port == observation.rpc_port
  end

  defp connect_target_match?(node, observation) do
    valid_connect_target?(node.connect_host, node.connect_port) and
      node.connect_host == observation.connect_host and
      node.connect_port == observation.connect_port
  end

  defp non_empty?(value), do: is_binary(value) and value != ""
  defp non_empty_or(value, fallback), do: if(non_empty?(value), do: value, else: fallback)

  defp observation_metadata(metadata) do
    %{
      node_id: metadata_value(metadata, :node_id),
      display_name: metadata_value(metadata, :display_name),
      hostname: metadata_value(metadata, :hostname),
      agent_version: metadata_value(metadata, :agent_version),
      listen_host: metadata_value(metadata, :listen_host),
      listen_port: metadata_value(metadata, :listen_port),
      worker_backend: metadata_value(metadata, :worker_backend)
    }
  end

  defp metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp run_lock_observer(opts, lock_name) do
    case Keyword.get(opts, :test_lock_observer) do
      observer when is_function(observer, 1) -> observer.(lock_name)
      _other -> :ok
    end
  end

  defp target_transport(%Target{transport: :grpc_compat}), do: :grpc
  defp target_transport(%Target{transport: :beam}), do: :beam
  defp target_transport(_target), do: :grpc

  defp target_address(%Target{transport: :grpc_compat, address: address}), do: address
  defp target_address(%Target{transport: :beam}), do: []
  defp target_address(target) when is_list(target), do: target
  defp target_address(_target), do: []

  defp valid_connect_target?(host, port), do: non_empty?(host) and is_integer(port)

  defp routable_advertise_addr?(addr), do: non_empty?(addr) and addr not in ["0.0.0.0", "::"]

  defp format_connect_target(%{connect_host: host, connect_port: port})
       when is_binary(host) and is_integer(port),
       do: "#{host}:#{port}"

  defp format_connect_target(_observation), do: "unknown"

  defp zero_fill(counts, values) do
    Map.new(values, fn v -> {v, Map.get(counts, v, 0)} end)
  end

  defp empty_summary do
    %{
      total: 0,
      by_state: zero_fill(%{}, Node.states()),
      by_health: zero_fill(%{}, Node.health_values())
    }
  end

  # -- Transport Failure Classification --

  defp transport_failure_reason?({:connect_failed, _reason}), do: true
  defp transport_failure_reason?(:node_unavailable), do: true
  defp transport_failure_reason?(:node_timeout), do: true
  defp transport_failure_reason?(:beam_node_unavailable), do: true
  defp transport_failure_reason?(:beam_node_timeout), do: true
  defp transport_failure_reason?(:authenticated_transport_failed), do: true
  defp transport_failure_reason?(:beam_peer_grant_authorization_unavailable), do: true
  defp transport_failure_reason?(_reason), do: false

  defp normalize_dispatch_transport_failure(failure) when is_map(failure) do
    with {:ok, failure_id} <- Ecto.UUID.cast(map_get(failure, :failure_id)),
         {:ok, node_id} <- Ecto.UUID.cast(map_get(failure, :node_id)),
         failure_class when is_binary(failure_class) or is_atom(failure_class) <-
           map_get(failure, :failure_class),
         %DateTime{} = occurred_at <- map_get(failure, :occurred_at) do
      {:ok,
       failure
       |> Map.put(:failure_id, failure_id)
       |> Map.put(:node_id, node_id)
       |> Map.put(:failure_class, failure_class)
       |> Map.put(:occurred_at, occurred_at)}
    else
      _invalid -> {:error, :transport_failure_identity_invalid}
    end
  end

  defp normalize_dispatch_transport_failure(_failure),
    do: {:error, :transport_failure_identity_invalid}
end
