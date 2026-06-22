defmodule Orchard.Nodes do
  @moduledoc """
  Persistence context for node inventory.

  Provides observational node discovery (no join ceremony) — nodes are
  automatically registered when a successful `GetStatus` response includes
  valid `RuntimeNodeMetadata`.
  """

  import Ecto.Query

  require Logger

  alias Orchard.Nodes.Node
  alias Orchard.Nodes.ToolCapability
  alias Orchard.Nodes.ToolReadiness
  alias Orchard.Repo

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
  Looks up a node by its connection target.

  Accepts a target keyword list matching the scheduler/dispatch shape:
  `[host: "127.0.0.1", port: 50071]`.

  Returns `nil` when no match, target is malformed, or repo is unavailable.
  """
  @spec lookup_by_target(keyword()) :: Node.t() | nil
  def lookup_by_target(target) do
    with true <- repo_available?(),
         {:ok, host, port} <- validate_target(target) do
      lookup_node_by_target(host, port)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # -- Observational Write APIs --

  @doc """
  Observes a successful status response and persists the node.

  Normalizes metadata from a `StatusResponse` (or compatible map),
  resolves conflicts (identity, display_name, staleness), and inserts
  or updates the node row.

  New nodes are inserted with `state: :active`. Updates preserve the
  existing `state` (admin-managed).

  Returns:
  - `{:ok, %Node{}}` on insert or update
  - `:noop` when metadata is missing/invalid, repo unavailable,
    observation is stale, or an identity conflict is detected
  """
  @spec observe_status(keyword(), map() | struct(), DateTime.t()) ::
          {:ok, Node.t()} | :noop
  def observe_status(target, status_response, observed_at) do
    with true <- repo_available?(),
         {:ok, observation} <- normalize_observation(target, status_response, observed_at) do
      case execute_observe(observation) do
        {:ok, node} ->
          refresh_observed_queue_capacities(node, status_response)
          {:ok, node}

        :noop ->
          :noop
      end
    else
      _ -> :noop
    end
  rescue
    _ -> :noop
  end

  @doc """
  Records a transport-like failure for a target and persists health degradation.

  Classifies the given `reason` and, if it matches a transport failure pattern,
  delegates to `mark_target_unreachable/2`. Non-transport reasons are ignored.

  Transport failure reasons:
  - `{:connect_failed, _}` — gRPC channel could not be established
  - `:node_unavailable` — node not reachable
  - `:node_timeout` — probe or RPC timed out

  Returns:
  - `{:ok, %Node{}}` when health was updated
  - `:noop` for non-transport reasons, unknown targets, or repo unavailable
  """
  @spec record_transport_failure(keyword(), term(), DateTime.t()) :: {:ok, Node.t()} | :noop
  def record_transport_failure(target, reason, observed_at) do
    if transport_failure_reason?(reason) do
      mark_target_unreachable(target, observed_at)
    else
      :noop
    end
  end

  @doc """
  Marks a node as unreachable by target address.

  Only updates health on an existing node. Does not insert new rows
  on failure-only observations. Preserves `state` and `last_heartbeat_at`.

  Returns:
  - `{:ok, %Node{}}` on successful mark
  - `:noop` when target is unknown, stale, malformed, or repo unavailable
  """
  @spec mark_target_unreachable(keyword(), DateTime.t()) :: {:ok, Node.t()} | :noop
  def mark_target_unreachable(target, observed_at) do
    with true <- repo_available?(),
         {:ok, host, port} <- validate_target(target) do
      execute_mark_unreachable(host, port, observed_at)
    else
      _ -> :noop
    end
  rescue
    _ -> :noop
  end

  # -- Observation Normalization --

  defp normalize_observation(target, status_response, observed_at) do
    metadata = extract_metadata(status_response)

    with {:metadata, %{} = meta} <- {:metadata, metadata},
         {:uuid, {:ok, node_id}} <- {:uuid, Ecto.UUID.cast(meta.node_id)},
         {:display_name, display_name} when display_name != nil <-
           {:display_name, resolve_display_name(meta)},
         {:port, port} when is_integer(port) and port in 1..65_535 <-
           {:port, resolve_port(meta, target)} do
      {:ok,
       %{
         id: node_id,
         display_name: display_name,
         hostname: non_empty_or(meta.hostname, target_host(target)),
         advertise_addr: non_empty_or(meta.listen_host, target_host(target)),
         rpc_port: port,
         connect_host: connect_host(target),
         connect_port: connect_port(target),
         health: derive_health(extract_runtime_health(status_response)),
         agent_version: non_empty_or(meta.agent_version, nil),
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
  defp extract_metadata(_), do: nil

  defp extract_runtime_health(%{runtime_health: health}), do: health
  defp extract_runtime_health(_), do: nil

  defp resolve_display_name(meta) do
    cond do
      non_empty?(meta.display_name) -> meta.display_name
      non_empty?(meta.hostname) -> meta.hostname
      true -> nil
    end
  end

  defp resolve_port(meta, target) do
    port = meta.listen_port

    if is_integer(port) and port in 1..65_535 do
      port
    else
      target_port(target)
    end
  end

  defp derive_health(nil), do: :healthy

  defp derive_health(health) do
    ready = Map.get(health, :ready, true)
    code = Map.get(health, :health_code, "")
    message = Map.get(health, :health_message, "")

    cond do
      ready == false -> :unhealthy
      non_empty?(code) or non_empty?(message) -> :degraded
      true -> :healthy
    end
  end

  defp build_capabilities(meta, status_response) do
    backend = Map.get(meta, :worker_backend, "")

    hosted_tools =
      status_response
      |> extract_hosted_tool_capabilities()
      |> ToolCapability.normalize_all()
      |> ToolCapability.persist_all()

    %{}
    |> maybe_put_worker_backend(backend)
    |> Map.put(
      "supports_prompt_token_ids",
      Map.get(status_response, :supports_prompt_token_ids, false)
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

  defp refresh_observed_queue_capacities(%Node{} = node, status_response) do
    queue_manager = Orchard.Inference.queue_manager()
    placement_source = {:node, node.id, :placement}
    cold_source = {:node, node.id, :cold}
    legacy_source = {:node, node.id}

    previous_source_keys =
      MapSet.new(queue_manager.active_capacity_source_lanes(placement_source))

    queue_manager.clear_capacity_source(legacy_source)
    queue_manager.clear_capacity_source(placement_source)
    queue_manager.clear_capacity_source(cold_source)

    if queue_capacity_eligible_node?(node) do
      placements = extract_runtime_model_placements(status_response)

      placement_keys =
        placements
        |> MapSet.new(&placement_queue_key/1)
        |> MapSet.union(previous_source_keys)

      Enum.each(
        placements,
        &refresh_loaded_placement_capacity(placement_source, status_response, &1)
      )

      refresh_cold_queue_capacities(queue_manager, cold_source, status_response, placement_keys)
    end
  rescue
    error ->
      Logger.debug("Queue capacity refresh from node observation failed: #{inspect(error)}")
      :ok
  end

  defp queue_capacity_eligible_node?(%Node{state: :active, health: health})
       when health in [:healthy, :degraded],
       do: true

  defp queue_capacity_eligible_node?(%Node{}), do: false

  defp refresh_cold_queue_capacities(queue_manager, source, status_response, placement_keys) do
    capacity = cold_node_queue_capacity(status_response)

    queue_manager.queued_model_lanes()
    |> Enum.reject(&(&1 in placement_keys))
    |> Enum.each(fn {model_id, version} ->
      queue_manager.refresh_capacity(model_id, version, capacity, source: source)
    end)
  end

  defp extract_runtime_model_placements(%{runtime_model_placements: placements})
       when is_list(placements),
       do: placements

  defp extract_runtime_model_placements(_status_response), do: []

  defp refresh_loaded_placement_capacity(source, status_response, placement)
       when is_map(placement) do
    case placement_model_ref(placement) do
      {:ok, model_id, version} ->
        capacity =
          if loaded_placement?(placement) do
            effective_placement_capacity(status_response, placement)
          else
            0
          end

        Orchard.Inference.queue_manager().refresh_capacity(model_id, version, capacity,
          source: source
        )

      :error ->
        :ok
    end
  end

  defp refresh_loaded_placement_capacity(_source, _status_response, _placement), do: :ok

  defp placement_queue_key(placement) do
    case placement_model_ref(placement) do
      {:ok, model_id, version} -> {model_id, version}
      :error -> nil
    end
  end

  defp cold_node_queue_capacity(status_response) do
    if node_capacity_available?(status_response), do: 1, else: 0
  end

  defp node_capacity_available?(status_response) do
    node_active = non_negative_integer(map_get(status_response, :active_request_count), 0)
    node_max = positive_integer(map_get(status_response, :max_concurrency), 1)

    node_active < node_max
  end

  defp loaded_placement?(placement) do
    placement
    |> map_get(:placement_state)
    |> then(&(&1 in [:PLACEMENT_STATE_LOADED, "PLACEMENT_STATE_LOADED", 7]))
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

  defp effective_placement_capacity(status_response, placement) do
    placement_active = non_negative_integer(map_get(placement, :active_request_count), 0)
    placement_max = placement_max_concurrency(placement)

    node_active = non_negative_integer(map_get(status_response, :active_request_count), 0)
    node_max = positive_integer(map_get(status_response, :max_concurrency), 1)
    remaining_node_capacity = max(node_max - node_active, 0)

    min(placement_max, placement_active + remaining_node_capacity)
  end

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
      {:ok, node} -> {:ok, node}
      {:error, :identity_conflict} -> :noop
      {:error, :stale} -> :noop
    end
  rescue
    # Concurrent first-observation race: two transactions see no existing
    # rows, both attempt insert, one hits a uniqueness constraint.
    # Treat as a benign conflict — the other process won the insert.
    error in Ecto.ConstraintError ->
      Logger.debug("Node observation lost concurrent insert race: #{inspect(error.constraint)}")
      :noop
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
      |> Map.put(:state, existing.state)
    )
    |> Repo.update!()
  end

  defp upsert_observation(_existing, observation) do
    %Node{}
    |> Node.changeset(Map.put(observation, :state, :active))
    |> Repo.insert!()
  end

  defp target_match?(node, observation) do
    advertised_target_match?(node, observation) or connect_target_match?(node, observation)
  end

  # -- Mark Unreachable --

  defp execute_mark_unreachable(host, port, observed_at) do
    Repo.transaction(fn ->
      case fetch_node_for_transport_update(host, port) do
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

  defp fetch_node_for_transport_update(host, port) do
    fetch_node_by_connect_target(host, port) ||
      fetch_legacy_node_by_advertise_target(host, port)
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

  defp validate_target(target) do
    host = Keyword.get(target, :host)
    port = Keyword.get(target, :port)

    if is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 do
      {:ok, host, port}
    else
      :error
    end
  end

  defp target_host(target), do: Keyword.get(target, :host, "")
  defp target_port(target), do: Keyword.get(target, :port)

  defp connect_host(target) do
    case Keyword.get(target, :host) do
      host when is_binary(host) and host != "" -> host
      _other -> nil
    end
  end

  defp connect_port(target) do
    case Keyword.get(target, :port) do
      port when is_integer(port) and port in 1..65_535 -> port
      _other -> nil
    end
  end

  defp map_get(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp lookup_node_by_target(host, port) do
    lookup_node_by_connect_target(host, port) ||
      lookup_legacy_node_by_advertise_target(host, port)
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
