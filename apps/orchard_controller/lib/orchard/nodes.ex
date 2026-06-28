defmodule Orchard.Nodes do
  @moduledoc """
  Persistence context for node inventory.

  Stores trusted node inventory and admission review state.

  First-observed Runtime Endpoint metadata is persisted as admission candidate
  evidence until a trusted node registration and explicit admission path exists.
  """

  import Ecto.Query

  require Logger

  alias Orchard.Governance
  alias Orchard.Governance.AuditLog
  alias Orchard.Nodes.{AdmissionCandidate, AdmissionDecision, Node}
  alias Orchard.Nodes.ToolCapability
  alias Orchard.Nodes.ToolReadiness
  alias Orchard.Repo
  alias Orchard.RuntimeEndpoint.{ModelRef, Observation, Placement, PlacementCapacity, Target}

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
  Looks up a node by its connection target.

  Accepts a target keyword list matching the scheduler/dispatch shape:
  `[host: "127.0.0.1", port: 50071]`, or a Runtime Endpoint target.
  BEAM Runtime Endpoint targets resolve by configured `node_id` first, then by
  target metadata containing a connect/listen host and port.

  Returns `nil` when no match, target is malformed, or repo is unavailable.
  """
  @spec lookup_by_target(keyword() | Target.t()) :: Node.t() | nil
  def lookup_by_target(target) do
    with true <- repo_available?(),
         {:ok, target_lookup} <- target_lookup(target) do
      lookup_node_by_target_lookup(target_lookup)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -- Observational Write APIs --

  @doc """
  Observes a successful Runtime Endpoint status observation.

  Normalizes metadata from a Runtime Endpoint Observation, `StatusResponse`,
  or compatible map before resolving conflicts (identity, display_name,
  staleness) and updating a trusted node row or admission candidate.

  First observations that do not match a trusted node create or update a
  Runtime Endpoint Admission Candidate and return `:noop`.
  Updates preserve admin-managed lifecycle except for `admitted -> active`
  after a fresh healthy observation.
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
  @spec observe_status(keyword(), map() | struct(), DateTime.t(), keyword()) ::
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
    attrs = normalize_attrs(attrs)

    Repo.transaction(fn ->
      with {:ok, target} <- lock_admission_target(candidate_or_node_id),
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
    attrs = normalize_attrs(attrs)

    Repo.transaction(fn ->
      with {:ok, candidate} <- lock_rejected_candidate(candidate_or_node_id),
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

  @doc """
  Admits a registered node without activating it.
  """
  @spec admit_node(Ecto.UUID.t(), map() | keyword(), keyword()) ::
          {:ok, %{node: Node.t(), decision: AdmissionDecision.t(), audit_log: AuditLog.t()}}
          | {:error, term()}
  def admit_node(node_id, attrs \\ %{}, opts \\ []) do
    attrs = normalize_attrs(attrs)

    Repo.transaction(fn ->
      with {:ok, node} <- lock_node(node_id),
           :ok <- ensure_node_admittable(node, attrs),
           {:ok, candidate} <- get_or_create_candidate_for_node(node),
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
             ) do
        {:ok, %{node: admitted_node, decision: decision, audit_log: audit_log}}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_transaction_result()
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

  @doc """
  Records a transport-like failure for a target and persists node health.

  Classifies the given `reason` and, if it matches a transport failure pattern,
  marks the target unreachable. Non-transport reasons are ignored.
  Successful transport-failure marks clear all queue capacity sources owned by
  the failed node after the health transaction commits, so stale observations
  cannot wake queued requests.

  Transport failure reasons:
  - `{:connect_failed, _}` - gRPC channel could not be established
  - `:node_unavailable` - node not reachable
  - `:node_timeout` - probe or RPC timed out

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
          clear_node_queue_capacity_sources(node)
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
      execute_mark_unreachable(target_lookup, observed_at)
    else
      _ -> :noop
    end
  end

  # -- Observation Normalization --

  defp normalize_observation(target, status_response, observed_at) do
    endpoint_transport = target_transport(target)
    target = target_address(target)
    metadata = extract_metadata(status_response)

    with {:metadata, %{} = meta} <- {:metadata, metadata},
         {:uuid, {:ok, node_id}} <- {:uuid, Ecto.UUID.cast(map_get(meta, :node_id))},
         {:display_name, display_name} when display_name != nil <-
           {:display_name, resolve_display_name(meta)},
         {:port, port} when is_integer(port) and port in 1..65_535 <-
           {:port, resolve_port(meta, target)} do
      hostname = map_get(meta, :hostname)
      listen_host = map_get(meta, :listen_host)

      {:ok,
       %{
         id: node_id,
         display_name: display_name,
         hostname: non_empty_or(hostname, target_host(target)),
         advertise_addr: non_empty_or(listen_host, target_host(target)),
         rpc_port: port,
         connect_host: connect_host(target),
         connect_port: connect_port(target),
         endpoint_transport: endpoint_transport,
         health: derive_health(extract_runtime_health(status_response)),
         agent_version: non_empty_or(map_get(meta, :agent_version), nil),
         capabilities: build_capabilities(meta, status_response),
         tool_readiness: build_tool_readiness(status_response),
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
    queue_manager = Orchard.Inference.queue_manager()
    placement_source = {:node, node.id, :placement}
    cold_source = {:node, node.id, :cold}

    if queue_capacity_refresh_target?(target, node) and
         queue_capacity_eligible_node?(node) and
         queue_capacity_eligible_observation?(status_response) do
      queue_manager.refresh_node_capacity_sources(%{
        clear_sources: node_queue_capacity_sources(node),
        node_source: {:node, node.id},
        placement_source: placement_source,
        cold_source: cold_source,
        node_id: node.id,
        node_active: observed_node_active(status_response),
        node_max: observed_node_max(status_response),
        placements: placement_observations(status_response),
        reserve_unassigned_node_grants?:
          Keyword.get(opts, :reserve_unassigned_node_grants?, true),
        reserve_unassigned_source_grants?:
          Keyword.get(opts, :reserve_unassigned_source_grants?, true)
      })
    else
      clear_node_queue_capacity_sources(node)
    end
  rescue
    error ->
      Logger.debug("Queue capacity refresh from node observation failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("Queue capacity refresh from node observation exited: #{inspect(reason)}")
      :ok
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

  defp clear_node_queue_capacity_sources(%Node{} = node, opts \\ []) do
    queue_manager = Orchard.Inference.queue_manager()

    queue_manager.clear_capacity_sources(
      node_queue_capacity_sources(node),
      promote?: Keyword.get(opts, :promote?, true)
    )
  rescue
    error ->
      Logger.debug("Queue capacity source clear for node failed: #{inspect(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.debug("Queue capacity source clear for node exited: #{inspect(reason)}")
      :ok
  end

  defp clear_ineligible_node_queue_capacity_sources(%Node{} = node) do
    unless queue_capacity_eligible_node?(node) do
      clear_node_queue_capacity_sources(node)
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
      clear_node_queue_capacity_sources(node)
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

  defp node_queue_capacity_sources(%Node{} = node),
    do: [{:node, node.id}, {:node, node.id, :placement}, {:node, node.id, :cold}]

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
    if existing.last_heartbeat_at != nil and
         DateTime.compare(existing.last_heartbeat_at, observation.last_heartbeat_at) != :lt do
      {:error, :stale}
    else
      :ok
    end
  end

  defp ensure_fresh_observation(_existing, _observation), do: :ok

  defp upsert_observation(%{existing_by_id: %Node{} = existing}, observation) do
    existing
    |> Node.changeset(
      observation
      |> Map.delete(:id)
      |> Map.put(:state, observed_state(existing, observation))
    )
    |> Repo.update!()
  end

  defp upsert_observation(_existing, observation) do
    upsert_observed_admission_candidate(observation)
    :candidate_persisted
  end

  defp observed_state(%Node{state: :admitted}, %{health: :healthy}), do: :active
  defp observed_state(%Node{} = existing, _observation), do: existing.state

  defp upsert_observed_admission_candidate(observation) do
    attrs = observed_candidate_attrs(observation)

    case lock_open_observed_candidate(observation) do
      %AdmissionCandidate{} = candidate ->
        attrs = Map.put(attrs, :admission_category, candidate.admission_category)

        candidate
        |> AdmissionCandidate.changeset(attrs)
        |> Repo.update!()

      nil ->
        %AdmissionCandidate{}
        |> AdmissionCandidate.changeset(attrs)
        |> Repo.insert!(
          on_conflict:
            {:replace,
             [
               :observed_identity,
               :target_ref,
               :endpoint_transport,
               :endpoint_target,
               :inventory,
               :compatibility_evidence,
               :last_observed_at,
               :updated_at
             ]},
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

  defp lock_open_observed_candidate(observation) do
    claimed_node_id = observation.id
    endpoint_target = endpoint_target(observation)

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

  defp endpoint_target(observation) do
    case {observation.connect_host, observation.connect_port} do
      {host, port} when is_binary(host) and is_integer(port) -> "#{host}:#{port}"
      _other -> "#{observation.advertise_addr}:#{observation.rpc_port}"
    end
  end

  # -- Admission Decisions --

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
      routable_advertise_addr?(node.advertise_addr) and is_integer(node.rpc_port)
  end

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

  defp latest_admission_decision_for_node(node_id) do
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

  defp lock_node(node_id) do
    Node
    |> where([node], node.id == ^node_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %Node{} = node -> {:ok, node}
      nil -> {:error, :node_not_found}
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

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp unwrap_transaction_result({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_transaction_result({:ok, value}), do: value
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp maybe_filter_candidate_category(query, nil), do: query

  defp maybe_filter_candidate_category(query, category) do
    where(query, [candidate], candidate.admission_category == ^category)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put_new(acc, Atom.to_string(key), value)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: normalize_attrs(Enum.into(attrs, %{}))
  defp normalize_attrs(_attrs), do: %{}

  defp sanitize_snapshot(value), do: sanitize_snapshot(value, 0)

  defp sanitize_snapshot(value, depth) when depth >= 4 do
    cond do
      is_map(value) -> %{"truncated" => true}
      is_list(value) -> ["truncated"]
      is_binary(value) -> bound_string(value)
      true -> value
    end
  end

  defp sanitize_snapshot(value, depth) when is_map(value) do
    value
    |> Enum.take(40)
    |> Map.new(fn {key, entry} -> {to_string(key), sanitize_snapshot(entry, depth + 1)} end)
  end

  defp sanitize_snapshot(value, depth) when is_list(value) do
    value
    |> Enum.take(40)
    |> Enum.map(&sanitize_snapshot(&1, depth + 1))
  end

  defp sanitize_snapshot(value, _depth) when is_binary(value), do: bound_string(value)
  defp sanitize_snapshot(value, _depth), do: value

  defp bound_string(value) when byte_size(value) > 512 do
    value
    |> String.slice(0, 512)
    |> trim_to_byte_size(512)
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

  defp execute_mark_unreachable(target_lookup, observed_at) do
    Repo.transaction(fn ->
      case fetch_node_for_transport_update(target_lookup) do
        nil ->
          Repo.rollback(:noop)

        %Node{} = node ->
          update_transport_failure_health(node, observed_at)
      end
    end)
    |> case do
      {:ok, node} -> {:ok, node}
      {:error, :noop} -> :noop
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

  defp update_transport_failure_health(%Node{} = node, observed_at) do
    case resolve_transport_failure_health(node, observed_at) do
      :noop ->
        Repo.rollback(:noop)

      health ->
        node
        |> Ecto.Changeset.change(health: health)
        |> Repo.update!()
    end
  end

  defp resolve_transport_failure_health(%Node{last_heartbeat_at: nil}, _observed_at),
    do: :unreachable

  defp resolve_transport_failure_health(
         %Node{health: health, last_heartbeat_at: last_hb},
         observed_at
       )
       when is_struct(observed_at, DateTime) do
    cond do
      DateTime.compare(last_hb, observed_at) != :lt ->
        :noop

      health == :unhealthy ->
        :unhealthy

      DateTime.compare(
        last_hb,
        DateTime.add(observed_at, -unreachable_threshold_ms(), :millisecond)
      ) ==
          :lt ->
        :unreachable

      true ->
        :degraded
    end
  end

  # -- Helpers --

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

  defp target_transport(%Target{transport: :grpc_compat}), do: :grpc
  defp target_transport(%Target{transport: :beam}), do: :beam
  defp target_transport(_target), do: :grpc

  defp target_address(%Target{transport: :grpc_compat, address: address}), do: address
  defp target_address(%Target{transport: :beam}), do: []
  defp target_address(target), do: target

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
  defp transport_failure_reason?(_reason), do: false
end
