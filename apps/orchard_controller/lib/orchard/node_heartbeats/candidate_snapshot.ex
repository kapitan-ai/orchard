defmodule Orchard.NodeHeartbeats.CandidateSnapshot do
  @moduledoc """
  Builds one immutable request-scoped production candidate snapshot from Postgres.

  Callers supply the effective normalized targets for the scheduling attempt and the
  certificate-backed active inventory resolved for that same attempt. The snapshot
  intersects those identities with current Node facts and the latest durable heartbeat.
  """

  import Ecto.Query

  alias Orchard.Nodes.{Node, NodeHeartbeat}
  alias Orchard.Runtime.{MemoryBudget, PrefixCacheStatus}
  alias Orchard.RuntimeEndpoint.{ModelRef, Placement, PlacementCapacity, Target}

  @candidate_source "monitor_snapshot"
  @eligible_health [:healthy, :degraded]
  @placement_limit 40

  defmodule Candidate do
    @moduledoc "Positive scheduler-candidate evidence from one durable observation."

    alias Orchard.Nodes.Node
    alias Orchard.Runtime.{MemoryBudget, PrefixCacheStatus}
    alias Orchard.RuntimeEndpoint.{Placement, Target}

    @enforce_keys [
      :target,
      :node,
      :heartbeat_id,
      :observed_at,
      :availability,
      :worker_state,
      :active_request_count,
      :max_concurrency,
      :aggregate_capacity_evidence,
      :placements,
      :runtime_memory_budgets,
      :runtime_prefix_cache_statuses,
      :supports_prompt_token_ids,
      :candidate_source
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            target: Target.t(),
            node: Node.t(),
            heartbeat_id: pos_integer(),
            observed_at: DateTime.t(),
            availability: :available | :degraded,
            worker_state: atom(),
            active_request_count: non_neg_integer(),
            max_concurrency: pos_integer(),
            aggregate_capacity_evidence: %{
              required(:runtime_concurrency_limit) => pos_integer(),
              required(:active_request_count) => non_neg_integer(),
              required(:validity) => :valid
            },
            placements: [Placement.t()],
            runtime_memory_budgets: [MemoryBudget.t()],
            runtime_prefix_cache_statuses: [PrefixCacheStatus.t()],
            supports_prompt_token_ids: boolean(),
            candidate_source: String.t()
          }
  end

  defmodule Rejection do
    @moduledoc "Deterministic diagnostic for one excluded lifecycle-managed target."

    alias Orchard.RuntimeEndpoint.Target

    @enforce_keys [:target, :node_id, :reason_codes, :diagnostics, :candidate_source]
    defstruct @enforce_keys ++ [observed_at: nil]

    @type t :: %__MODULE__{
            target: Target.t(),
            node_id: String.t() | nil,
            observed_at: DateTime.t() | nil,
            reason_codes: [String.t()],
            diagnostics: map(),
            candidate_source: String.t()
          }
  end

  @enforce_keys [:observed_at, :freshness_threshold_ms, :candidates, :rejections]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          observed_at: DateTime.t(),
          freshness_threshold_ms: pos_integer(),
          candidates: [Candidate.t()],
          rejections: [Rejection.t()]
        }

  @type error :: :candidate_snapshot_unavailable | :invalid_snapshot_boundary

  @doc """
  Reads one production candidate snapshot.

  The active inventory must be the successful result of
  `Orchard.Nodes.active_runtime_endpoint_targets/0`. `:observed_at` injects the
  request boundary for deterministic freshness checks. `:repo` is a test seam only.
  """
  @spec read([Target.t()], [Target.t()], keyword()) :: {:ok, t()} | {:error, error()}
  def read(effective_targets, active_targets, opts \\ [])
      when is_list(effective_targets) and is_list(active_targets) and is_list(opts) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    threshold_ms = configured_freshness_threshold_ms()
    repo = Keyword.get(opts, :repo, Orchard.Repo)

    case {observed_at, threshold_ms} do
      {%DateTime{}, threshold_ms} when is_integer(threshold_ms) and threshold_ms > 0 ->
        build_snapshot(
          normalize_targets(effective_targets),
          normalize_targets(active_targets),
          observed_at,
          threshold_ms,
          repo
        )

      _invalid ->
        {:error, :invalid_snapshot_boundary}
    end
  end

  defp build_snapshot(effective, active, observed_at, threshold_ms, repo) do
    {subjects, intersection_rejections} = intersect_targets(effective, active)

    case read_latest_rows(subjects, repo) do
      {:ok, rows_by_node_id} ->
        {candidates, row_rejections} =
          evaluate_subjects(subjects, rows_by_node_id, observed_at, threshold_ms)

        {:ok,
         %__MODULE__{
           observed_at: observed_at,
           freshness_threshold_ms: threshold_ms,
           candidates: candidates,
           rejections: sort_rejections(intersection_rejections ++ row_rejections)
         }}

      {:error, :candidate_snapshot_unavailable} = error ->
        error
    end
  end

  defp normalize_targets(targets) do
    targets
    |> Enum.flat_map(&normalize_target/1)
    |> Enum.sort_by(&identity_sort_key/1)
    |> Enum.uniq_by(&target_identity/1)
  end

  defp normalize_target(%Target{} = target) do
    [Target.normalize(target)]
  rescue
    _error in ArgumentError -> []
  end

  defp normalize_target(_target), do: []

  defp intersect_targets(effective, active) do
    effective_identities = Map.new(effective, &{target_identity(&1), &1})

    Enum.reduce(active, {[], []}, fn target, {subjects, rejections} ->
      identity = target_identity(target)

      cond do
        is_nil(target.node_id) ->
          {subjects, [identity_rejection(target, :active_target_node_id_missing) | rejections]}

        Map.has_key?(effective_identities, identity) ->
          {[target | subjects], rejections}

        identity_conflict?(target, effective) ->
          {subjects,
           [identity_rejection(target, :effective_target_identity_mismatch) | rejections]}

        true ->
          {subjects, rejections}
      end
    end)
    |> then(fn {subjects, rejections} ->
      {Enum.sort_by(subjects, &identity_sort_key/1), Enum.reverse(rejections)}
    end)
  end

  defp identity_conflict?(target, effective) do
    Enum.any?(effective, fn configured ->
      configured.id == target.id or
        (is_binary(configured.node_id) and configured.node_id == target.node_id)
    end)
  end

  defp identity_rejection(target, fact) do
    rejection(target, nil, "runtime_identity_mismatch", fact)
  end

  defp read_latest_rows([], _repo), do: {:ok, %{}}

  defp read_latest_rows(subjects, repo) do
    node_ids = subjects |> Enum.map(& &1.node_id) |> Enum.uniq() |> Enum.sort()
    query = latest_rows_query(node_ids)

    case repo.all(query) do
      rows when is_list(rows) -> validate_rows(rows, node_ids)
      _incomplete -> {:error, :candidate_snapshot_unavailable}
    end
  rescue
    _error in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Ecto.QueryError,
      Postgrex.Error
    ] ->
      {:error, :candidate_snapshot_unavailable}
  end

  defp latest_rows_query(node_ids) do
    latest_heartbeat =
      from(heartbeat in NodeHeartbeat,
        where: heartbeat.node_id == parent_as(:node).id,
        order_by: [desc: heartbeat.observed_at, desc: heartbeat.id],
        limit: 1
      )

    from(node in Node,
      as: :node,
      where: node.id in ^node_ids,
      left_lateral_join: heartbeat in subquery(latest_heartbeat),
      on: true,
      order_by: [asc: node.id],
      select: {node, heartbeat}
    )
  end

  defp validate_rows(rows, node_ids) do
    row_node_ids =
      Enum.flat_map(rows, fn
        {%Node{id: node_id}, _heartbeat} -> [node_id]
        _invalid -> []
      end)

    with true <- Enum.all?(rows, &valid_row?/1),
         true <- length(row_node_ids) == length(node_ids),
         true <- Enum.sort(row_node_ids) == node_ids do
      {:ok,
       Map.new(rows, fn {%Node{id: node_id} = node, heartbeat} ->
         {node_id, {node, heartbeat}}
       end)}
    else
      _incomplete -> {:error, :candidate_snapshot_unavailable}
    end
  end

  defp valid_row?({%Node{}, nil}), do: true
  defp valid_row?({%Node{}, %NodeHeartbeat{}}), do: true
  defp valid_row?(_row), do: false

  defp evaluate_subjects(subjects, rows_by_node_id, observed_at, threshold_ms) do
    Enum.reduce(subjects, {[], []}, fn target, {candidates, rejections} ->
      {node, heartbeat} = Map.fetch!(rows_by_node_id, target.node_id)

      case evaluate_target(target, node, heartbeat, observed_at, threshold_ms) do
        {:ok, candidate} -> {candidates ++ [candidate], rejections}
        {:error, rejection} -> {candidates, rejections ++ [rejection]}
      end
    end)
  end

  defp evaluate_target(target, node, heartbeat, observed_at, threshold_ms) do
    case node_eligibility_rejection(target, node, heartbeat, observed_at, threshold_ms) do
      nil -> evaluate_heartbeat(target, node, heartbeat, observed_at, threshold_ms)
      rejection -> {:error, rejection}
    end
  end

  defp node_eligibility_rejection(target, node, heartbeat, observed_at, threshold_ms) do
    cond do
      node.state != :active ->
        rejection(target, heartbeat, "node_not_active", :node_lifecycle_not_active)

      node.health == :unreachable ->
        rejection(target, heartbeat, "node_health_unreachable", :node_health_unreachable)

      node.health not in @eligible_health ->
        rejection(target, heartbeat, "node_health_unhealthy", :node_health_unhealthy)

      not fresh?(node.last_heartbeat_at, observed_at, threshold_ms) ->
        rejection(target, heartbeat, "node_observation_stale", :node_heartbeat_stale)

      true ->
        nil
    end
  end

  defp evaluate_heartbeat(target, _node, nil, _observed_at, _threshold_ms) do
    {:error,
     rejection(
       target,
       nil,
       "dispatch_capacity_facts_unavailable",
       :heartbeat_observation_missing
     )}
  end

  defp evaluate_heartbeat(target, node, heartbeat, observed_at, threshold_ms) do
    cond do
      not fresh?(heartbeat.observed_at, observed_at, threshold_ms) ->
        {:error,
         rejection(target, heartbeat, "node_observation_stale", :heartbeat_observation_stale)}

      DateTime.compare(node.last_heartbeat_at, heartbeat.observed_at) != :eq ->
        {:error,
         rejection(
           target,
           heartbeat,
           "node_observation_stale",
           :node_heartbeat_observation_incoherent
         )}

      transport_failure_after_heartbeat?(node, heartbeat) ->
        {:error, rejection(target, heartbeat, "transport_unreachable", :transport_failure_newer)}

      true ->
        candidate_from_payload(target, node, heartbeat)
    end
  end

  defp candidate_from_payload(target, node, heartbeat) do
    payload = heartbeat.payload

    with :ok <- valid_envelope(payload),
         :ok <- matching_payload_identity(target, heartbeat, payload),
         {:ok, availability} <- available_runtime(payload),
         {:ok, capacity} <- capacity_evidence(payload),
         {:ok, placements} <- normalize_placements(payload["placements"]) do
      {:ok,
       %Candidate{
         target: target,
         node: node,
         heartbeat_id: heartbeat.id,
         observed_at: heartbeat.observed_at,
         availability: availability,
         worker_state: worker_state(payload["worker_state"]),
         active_request_count: capacity.active_request_count,
         max_concurrency: capacity.runtime_concurrency_limit,
         aggregate_capacity_evidence: capacity,
         placements: placements,
         runtime_memory_budgets: normalize_memory_budgets(payload["runtime_memory_budgets"]),
         runtime_prefix_cache_statuses:
           normalize_prefix_cache_statuses(payload["runtime_prefix_cache_statuses"]),
         supports_prompt_token_ids: payload["supports_prompt_token_ids"] == true,
         candidate_source: @candidate_source
       }}
    else
      {:error, reason_code, fact} ->
        {:error, rejection(target, heartbeat, reason_code, fact)}
    end
  end

  defp valid_envelope(%{"schema_version" => 1, "validity" => "valid"}), do: :ok

  defp valid_envelope(%{"schema_version" => 1, "validity" => "invalid"} = payload) do
    {:error, "dispatch_capacity_facts_unavailable",
     {:invalid_heartbeat_payload, payload["invalid_reason"]}}
  end

  defp valid_envelope(_payload) do
    {:error, "dispatch_capacity_facts_unavailable", :malformed_heartbeat_payload}
  end

  defp matching_payload_identity(target, heartbeat, payload) do
    cond do
      heartbeat.node_id != target.node_id ->
        {:error, "runtime_identity_mismatch", :heartbeat_node_identity_mismatch}

      not present_string?(payload["endpoint_id"]) ->
        {:error, "dispatch_capacity_facts_unavailable", :malformed_heartbeat_payload}

      true ->
        compare_payload_target_identity(target, payload)
    end
  end

  defp compare_payload_target_identity(target, payload) do
    case payload_target_identity(payload["target"]) do
      {:ok, identity} ->
        if payload["endpoint_id"] == target.id and identity == target_identity(target) do
          :ok
        else
          {:error, "runtime_identity_mismatch", :heartbeat_target_identity_mismatch}
        end

      :error ->
        {:error, "dispatch_capacity_facts_unavailable", :malformed_heartbeat_payload}
    end
  end

  defp payload_target_identity(%{
         "id" => id,
         "transport" => transport,
         "address" => address,
         "node_id" => node_id
       }) do
    with {:ok, transport} <- payload_transport(transport),
         {:ok, address} <- payload_address(transport, address),
         {:ok, node_id} <- Ecto.UUID.cast(node_id) do
      {:ok, {id, transport, address, node_id}}
    else
      _invalid -> :error
    end
  end

  defp payload_target_identity(_target), do: :error

  defp payload_transport("beam"), do: {:ok, :beam}
  defp payload_transport("grpc_compat"), do: {:ok, :grpc_compat}
  defp payload_transport(_transport), do: :error

  defp payload_address(:beam, address) when is_binary(address), do: {:ok, address}

  defp payload_address(:grpc_compat, %{"host" => host, "port" => port})
       when is_binary(host) and is_integer(port),
       do: {:ok, {host, port}}

  defp payload_address(_transport, _address), do: :error

  defp available_runtime(%{"availability" => availability})
       when availability in ["available", "degraded"] do
    {:ok, String.to_existing_atom(availability)}
  end

  defp available_runtime(_payload), do: {:error, "runtime_not_ready", :runtime_status_unavailable}

  defp capacity_evidence(payload) do
    evidence = payload["aggregate_capacity_evidence"]
    active = payload["aggregate_active_request_count"]
    limit = payload["aggregate_max_concurrency"]

    case evidence do
      %{
        "active_request_count" => ^active,
        "runtime_concurrency_limit" => ^limit,
        "validity" => "valid"
      }
      when is_integer(active) and active >= 0 and is_integer(limit) and limit > 0 ->
        {:ok,
         %{
           active_request_count: active,
           runtime_concurrency_limit: limit,
           validity: :valid
         }}

      _missing_or_invalid ->
        {:error, "dispatch_capacity_facts_unavailable", :aggregate_capacity_facts_unavailable}
    end
  end

  defp normalize_placements(placements) when is_list(placements) do
    normalized = Enum.flat_map(placements, &normalize_placement/1)

    cond do
      duplicate_placement_model_refs?(normalized) ->
        {:error, "dispatch_capacity_facts_unavailable", :duplicate_placement_model_ref}

      length(placements) > @placement_limit ->
        {:error, "dispatch_capacity_facts_unavailable", :placement_entry_overflow}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_placements(_placements), do: {:ok, []}

  defp duplicate_placement_model_refs?(placements) do
    refs = Enum.map(placements, &placement_model_ref/1)
    length(refs) != length(Enum.uniq(refs))
  end

  defp placement_model_ref(%Placement{model_ref: model_ref}),
    do: {model_ref.model_id, model_ref.version}

  defp normalize_placement(%{"model_ref" => model_ref} = placement) do
    case ModelRef.new(model_ref) do
      {:ok, normalized_ref} ->
        capacity =
          placement
          |> Map.get("capacity")
          |> normalize_placement_capacity(normalized_ref)

        [
          %Placement{
            model_ref: normalized_ref,
            state: placement_state(placement["state"]),
            capacity: capacity,
            last_used_at: placement["last_used_at"],
            diagnostics: %{}
          }
        ]

      {:error, :invalid_model_ref} ->
        []
    end
  end

  defp normalize_placement(_placement), do: []

  defp normalize_placement_capacity(capacity, model_ref) when is_map(capacity) do
    capacity
    |> Map.put("model_ref", model_ref)
    |> PlacementCapacity.new()
  end

  defp normalize_placement_capacity(_capacity, model_ref) do
    PlacementCapacity.unknown(model_ref, :invalid_capacity)
  end

  defp normalize_memory_budgets(budgets) when is_list(budgets) do
    budgets
    |> Enum.map(&MemoryBudget.normalize/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_memory_budgets(_budgets), do: []

  defp normalize_prefix_cache_statuses(statuses) when is_list(statuses) do
    statuses
    |> Enum.map(&normalize_prefix_cache_status/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_prefix_cache_statuses(_statuses), do: []

  defp normalize_prefix_cache_status(nil), do: nil

  defp normalize_prefix_cache_status(status) when is_map(status) do
    status
    |> PrefixCacheStatus.normalize()
    |> Map.put(
      :prefix_cache_fingerprint_count,
      non_negative_integer(status["prefix_cache_fingerprint_count"], 0)
    )
    |> Map.put(
      :prefix_cache_warmth_indicator,
      status["prefix_cache_warmth_indicator"] == true
    )
  end

  defp normalize_prefix_cache_status(status), do: PrefixCacheStatus.normalize(status)

  defp present_string?(value), do: is_binary(value) and value != ""

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default

  defp worker_state("starting"), do: :starting
  defp worker_state("idle"), do: :idle
  defp worker_state("busy"), do: :busy
  defp worker_state("stopping"), do: :stopping
  defp worker_state("failed"), do: :failed
  defp worker_state("stopped"), do: :stopped
  defp worker_state(_state), do: :unknown

  defp placement_state("unavailable"), do: :unavailable
  defp placement_state("cached"), do: :cached
  defp placement_state("loaded"), do: :loaded
  defp placement_state("provider_available"), do: :provider_available
  defp placement_state("failed"), do: :failed
  defp placement_state("loading"), do: :loading
  defp placement_state(_state), do: :unknown

  defp configured_freshness_threshold_ms do
    :orchard_controller
    |> Application.fetch_env!(:inference)
    |> Keyword.get(:node_freshness_threshold_ms, 30_000)
  end

  defp fresh?(%DateTime{} = timestamp, observed_at, threshold_ms) do
    cutoff = DateTime.add(observed_at, -threshold_ms, :millisecond)

    DateTime.compare(timestamp, cutoff) in [:eq, :gt] and
      DateTime.compare(timestamp, observed_at) in [:lt, :eq]
  end

  defp fresh?(_timestamp, _observed_at, _threshold_ms), do: false

  defp transport_failure_after_heartbeat?(
         %Node{last_transport_failure_at: %DateTime{} = failed_at},
         %NodeHeartbeat{observed_at: %DateTime{} = heartbeat_at}
       ) do
    DateTime.compare(failed_at, heartbeat_at) == :gt
  end

  defp transport_failure_after_heartbeat?(_node, _heartbeat), do: false

  defp rejection(target, heartbeat, reason_code, fact) do
    %Rejection{
      target: target,
      node_id: target.node_id,
      observed_at: heartbeat_observed_at(heartbeat),
      reason_codes: [reason_code],
      diagnostics: %{
        candidate_source: @candidate_source,
        fact: diagnostic_fact(fact),
        heartbeat_id: heartbeat_id(heartbeat)
      },
      candidate_source: @candidate_source
    }
  end

  defp diagnostic_fact({fact, detail}), do: %{kind: Atom.to_string(fact), detail: detail}
  defp diagnostic_fact(fact) when is_atom(fact), do: Atom.to_string(fact)

  defp heartbeat_observed_at(%NodeHeartbeat{observed_at: observed_at}), do: observed_at
  defp heartbeat_observed_at(_heartbeat), do: nil

  defp heartbeat_id(%NodeHeartbeat{id: id}), do: id
  defp heartbeat_id(_heartbeat), do: nil

  defp sort_rejections(rejections) do
    Enum.sort_by(rejections, fn rejection ->
      {rejection.node_id || "", rejection.target.id, rejection.reason_codes}
    end)
  end

  defp target_identity(%Target{} = target) do
    {target.id, target.transport, target_address(target), target.node_id}
  end

  defp target_address(%Target{transport: :beam, address: address}) when is_atom(address),
    do: Atom.to_string(address)

  defp target_address(%Target{transport: :beam, address: address}), do: address

  defp target_address(%Target{transport: :grpc_compat, address: address})
       when is_list(address) or is_map(address) do
    address = Map.new(address)

    {Map.get(address, :host) || Map.get(address, "host"),
     Map.get(address, :port) || Map.get(address, "port")}
  end

  defp identity_sort_key(target) do
    target
    |> target_identity()
    |> inspect()
  end
end
