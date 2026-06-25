defmodule Orchard.Scheduler.MultiNode do
  @moduledoc """
  Multi-node scheduler that probes configured runtime targets and
  selects the best candidate for dispatch.

  Ranking order (descending priority):
  1. Exclude candidates with exhausted node or placement capacity, or loaded-model
     candidates with active requests and unknown placement capacity
  2. Node has the requested model already loaded
  3. Lower active request count for the requested placement
  4. Healthier node (`:healthy` over `:degraded`)
  5. Live prefix-cache fingerprint match when explicitly enabled
  6. Cache-affinity match when explicitly enabled
  7. Prompt-token-ID capable worker preference when explicitly enabled and safe mode is not `:off`
  8. Memory headroom positive signal when explicitly enabled
  9. Gated Phase 4D tie-only `ScorePrefixCache` reselection, when explicitly enabled
  10. Lexicographically smaller `node_id` (deterministic tie-break)

  Falls back to the single-node scheduler when:
  - No targets are configured
  - All probes fail
  - No schedulable nodes remain after filtering

  Returns `{:error, :cluster_busy}` when live probes joined to persisted schedulable
  nodes, but every joined candidate has exhausted capacity or is an active
  loaded-model candidate with unknown placement capacity.

  Successful schedules include `:queue_lane_capacity`, derived from loaded
  candidates with live node and placement room plus eligible cold candidates
  with remaining aggregate node capacity.

  Transport-like probe and connect failures are recorded through node inventory
  so failed targets stop contributing stale queue capacity before queued work is
  promoted.
  Probe disconnect cleanup is best-effort and does not remove an otherwise valid
  candidate or change the scheduling outcome.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Inference
  alias Orchard.Inference.CacheAffinity
  alias Orchard.Nodes

  alias Orchard.RuntimeEndpoint.{
    GrpcCompatibilityMapper,
    ModelRef,
    Observation,
    Operation,
    PlacementCapacity,
    Target
  }

  alias Orchard.Runtime.{MemoryBudget, PrefixCacheScore, PrefixCacheStatus}
  alias Orchard.Scheduler.SingleNode

  require Logger

  @behaviour Orchard.Scheduler.SingleNode

  @default_status_timeout_ms 2_000

  # -- Public API --

  @doc """
  Schedule a request across configured cluster targets.

  Probes each target for live status, persists observations, filters
  for schedulable nodes, ranks candidates, and returns a dispatch-compatible
  schedule map.
  """
  @impl true
  def schedule(%CanonicalRequest{} = request) do
    schedule(request, [])
  end

  @doc """
  Schedule with injectable options for testing.

  Options:
  - `:status_client` - module implementing the Runtime Endpoint client callbacks
    (default: `Inference.runtime_endpoint_client/0`)
  - `:status_timeout_ms` - timeout for each status probe (default: #{@default_status_timeout_ms})
  - `:observed_at` - timestamp for observations (default: `DateTime.utc_now()`)
  """
  def schedule(%CanonicalRequest{} = request, opts) when is_list(opts) do
    targets = Inference.runtime_endpoint_targets()

    if targets == [] do
      fallback_schedule(request, targets, opts)
    else
      schedule_multi(request, targets, opts)
    end
  end

  # -- Internal --

  defp schedule_multi(request, targets, opts) do
    client = Keyword.get(opts, :status_client, Inference.runtime_endpoint_client())
    timeout = Keyword.get(opts, :status_timeout_ms, @default_status_timeout_ms)
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    # Probe each target sequentially and collect ephemeral ranking data.
    # Sequential probing is intentional for M3b scope (1-4 nodes):
    # - Avoids Task supervision and cancellation complexity
    # - Deterministic ordering, simpler failure handling
    # - Worst-case latency is cumulative (N × timeout_ms) but acceptable at this scale
    # Future: parallel probing via Task.async_stream or cached observations
    # within freshness window for larger clusters.
    probe_results =
      targets
      |> Enum.map(&probe_target(&1, client, timeout, observed_at, request))
      |> Enum.reject(&is_nil/1)

    # Join with persistent schedulable nodes
    schedulable_map =
      Nodes.schedulable_nodes()
      |> Map.new(&{&1.id, &1})

    candidates =
      probe_results
      |> Enum.filter(&Map.has_key?(schedulable_map, &1.node_id))
      |> Enum.map(&Map.put(&1, :node, schedulable_map[&1.node_id]))

    available_candidates = Enum.reject(candidates, &candidate_full?/1)

    cond do
      candidates == [] and probe_results == [] ->
        fallback_schedule(request, targets, Keyword.put(opts, :probe_status?, false))

      candidates == [] ->
        fallback_schedule(request, targets, opts)

      available_candidates == [] ->
        {:error, :cluster_busy}

      true ->
        cache_affinity_config = Inference.cache_affinity_config()

        {affinity_candidates, affinity_context} =
          CacheAffinity.prepare(request, available_candidates, cache_affinity_config)

        live_fingerprint_match_enabled? =
          CacheAffinity.live_fingerprint_match_enabled?(cache_affinity_config)

        prefix_cache_scoring_enabled? = Inference.prefix_cache_scoring_enabled?()
        memory_admission_enabled? = Inference.memory_admission_enabled?()

        prefer_capable_workers? =
          Inference.tokenizer_safe_mode_prefer_capable_workers?() and
            Inference.tokenizer_safe_mode() != :off

        annotated_candidates =
          affinity_candidates
          |> annotate_prefix_cache_fingerprint_matches(
            affinity_context,
            live_fingerprint_match_enabled?
          )
          |> annotate_capable_workers(prefer_capable_workers?)
          |> annotate_memory_admission(memory_admission_enabled?)

        ranking_opts = [
          live_fingerprint_match?: live_fingerprint_match_enabled?,
          prefer_capable_workers?: prefer_capable_workers?,
          memory_admission?: memory_admission_enabled?
        ]

        ranked = rank_candidates(annotated_candidates, ranking_opts)

        {selected, selected_score} =
          select_candidate_with_prefix_cache_score(
            request,
            ranked,
            client,
            cache_affinity_config,
            prefix_cache_scoring_enabled?,
            ranking_opts
          )

        schedule =
          %{
            strategy: :multi_node,
            request_id: request.public_id,
            runtime_endpoint_target: selected.target,
            request_timeout_ms: Inference.request_timeout_ms(),
            model_load_timeout_ms: Inference.model_load_timeout_ms(),
            node_id: selected.node_id,
            candidate_count: length(ranked),
            queue_lane_capacity: queue_lane_capacity(available_candidates),
            selected_tier: if(selected.loaded_model?, do: "loaded", else: "cold")
          }
          |> maybe_put_runtime_client_target(selected.target)
          |> maybe_put_prefix_cache_status(Map.get(selected, :prefix_cache_status))
          |> maybe_put_prefix_cache_fingerprint_match(
            selected,
            live_fingerprint_match_enabled?
          )
          |> maybe_put_prefix_cache_score(selected_score)
          |> maybe_put_memory_admission(selected, memory_admission_enabled?)

        {:ok,
         Map.merge(schedule, CacheAffinity.scheduler_metadata(affinity_context, ranked, selected))}
    end
  end

  defp probe_target(target, client, timeout, observed_at, request) do
    case client.connect(target) do
      {:ok, channel} ->
        try do
          case client.status(channel, timeout: timeout) do
            {:ok, response} ->
              observation = normalize_status_observation(target, response)

              Nodes.observe_status(observation_target(target), observation, observed_at,
                reserve_unassigned_node_grants?: true,
                reserve_unassigned_source_grants?: true
              )

              case extract_valid_node_id(observation) do
                nil ->
                  nil

                node_id ->
                  loaded_model? = model_loaded?(observation, request)

                  %{
                    node_id: node_id,
                    target: target,
                    availability: observation.availability,
                    loaded_model?: loaded_model?,
                    active_request_count: observation.aggregate_active_request_count,
                    max_concurrency: node_max_concurrency(observation),
                    supports_prompt_token_ids: observation.supports_prompt_token_ids
                  }
                  |> maybe_put_model_placement_capacity(
                    model_placement_capacity_for(observation, request.model_ref, loaded_model?)
                  )
                  |> maybe_put_prefix_cache_status(
                    prefix_cache_status_for(observation, request.model_ref)
                  )
                  |> maybe_put_memory_budget(memory_budget_for(observation, request.model_ref))
              end

            {:error, reason} ->
              # Persist transport-like probe failures best-effort
              Nodes.record_transport_failure(observation_target(target), reason, observed_at)
              nil
          end
        after
          disconnect_best_effort(client, channel)
        end

      {:error, reason} ->
        # Persist transport-like connect failures best-effort
        Nodes.record_transport_failure(observation_target(target), reason, observed_at)
        nil
    end
  end

  defp disconnect_best_effort(client, channel) do
    client.disconnect(channel)
    :ok
  rescue
    error ->
      Logger.warning("Runtime endpoint disconnect failed: #{exception_name(error)}")
      :ok
  catch
    :exit, _reason ->
      Logger.warning("Runtime endpoint disconnect exited")
      :ok

    _kind, _reason ->
      Logger.warning("Runtime endpoint disconnect threw")
      :ok
  end

  defp candidate_full?(candidate) do
    runtime_endpoint_unavailable?(candidate) or node_concurrency_full?(candidate) or
      placement_capacity_full?(candidate) or
      active_without_known_capacity?(candidate)
  end

  defp runtime_endpoint_unavailable?(%{availability: availability}),
    do: availability not in [:available, :degraded]

  defp runtime_endpoint_unavailable?(_candidate), do: false

  defp node_concurrency_full?(%{active_request_count: active, max_concurrency: max})
       when is_integer(active) and is_integer(max) and max > 0,
       do: active >= max

  defp node_concurrency_full?(_candidate), do: false

  defp placement_capacity_full?(%{
         model_placement_capacity: %PlacementCapacity{status: :known} = capacity
       }),
       do: PlacementCapacity.full?(capacity)

  defp placement_capacity_full?(%{
         model_placement_capacity: %{active_request_count: active, max_concurrency: max}
       })
       when is_integer(active) and is_integer(max) and max > 0,
       do: active >= max

  defp placement_capacity_full?(_candidate), do: false

  defp active_without_known_capacity?(%{
         model_placement_capacity: %PlacementCapacity{status: :known}
       }),
       do: false

  defp active_without_known_capacity?(%{
         model_placement_capacity: %{active_request_count: active, max_concurrency: max}
       })
       when is_integer(active) and active >= 0 and is_integer(max) and max > 0,
       do: false

  defp active_without_known_capacity?(%{loaded_model?: true, active_request_count: count})
       when is_integer(count) and count > 0,
       do: true

  defp active_without_known_capacity?(_candidate), do: false

  defp queue_lane_capacity(candidates) do
    loaded_capacity =
      candidates
      |> Enum.filter(& &1.loaded_model?)
      |> Enum.map(&effective_model_capacity_for_queue/1)
      |> Enum.sum()

    cold_capacity =
      candidates
      |> Enum.reject(& &1.loaded_model?)
      |> Enum.count(&node_has_available_capacity?/1)

    case loaded_capacity + cold_capacity do
      capacity when capacity > 0 -> capacity
      _capacity -> 1
    end
  end

  defp effective_model_capacity_for_queue(%{
         active_request_count: node_active,
         max_concurrency: node_max,
         model_placement_capacity: %PlacementCapacity{
           status: :known,
           active_request_count: model_active,
           max_concurrency: placement_max
         }
       })
       when is_integer(node_active) and is_integer(node_max) and is_integer(model_active) and
              is_integer(placement_max) do
    remaining_node_capacity = max(node_max - node_active, 0)
    min(placement_max, max(model_active, 0) + remaining_node_capacity)
  end

  defp effective_model_capacity_for_queue(%{
         model_placement_capacity: %PlacementCapacity{}
       }),
       do: 1

  defp effective_model_capacity_for_queue(%{
         active_request_count: node_active,
         max_concurrency: node_max,
         model_placement_capacity: %{
           active_request_count: model_active,
           max_concurrency: placement_max
         }
       })
       when is_integer(node_active) and is_integer(node_max) and is_integer(model_active) and
              is_integer(placement_max) do
    remaining_node_capacity = max(node_max - node_active, 0)
    min(placement_max, max(model_active, 0) + remaining_node_capacity)
  end

  defp effective_model_capacity_for_queue(%{
         model_placement_capacity: %{max_concurrency: placement_max}
       })
       when is_integer(placement_max) and placement_max > 0,
       do: placement_max

  defp effective_model_capacity_for_queue(%{loaded_model?: true, active_request_count: active})
       when is_integer(active) and active > 0,
       do: 0

  defp effective_model_capacity_for_queue(_candidate), do: 1

  defp node_has_available_capacity?(%{active_request_count: active, max_concurrency: max})
       when is_integer(active) and is_integer(max) and max > 0,
       do: active < max

  defp node_has_available_capacity?(_candidate), do: true

  defp node_max_concurrency(%Observation{aggregate_max_concurrency: value}) do
    case value do
      value when is_integer(value) and value > 0 -> value
      _other -> 1
    end
  end

  defp extract_valid_node_id(%Observation{} = observation) do
    observation
    |> Observation.node_id()
    |> extract_valid_node_id()
  end

  defp extract_valid_node_id(node_id) when is_binary(node_id) do
    case Ecto.UUID.cast(node_id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp extract_valid_node_id(_), do: nil

  defp exception_name(%{__struct__: module}) when is_atom(module), do: Atom.to_string(module)

  defp model_loaded?(%Observation{} = observation, %CanonicalRequest{model_ref: model_ref}) do
    Observation.loaded_placement(observation, runtime_model_ref(model_ref)) != nil
  end

  defp model_loaded?(_, _), do: false

  defp prefix_cache_status_for(
         %Observation{} = observation,
         %CanonicalRequest.ModelRef{} = model_ref
       ) do
    observation.runtime_prefix_cache_statuses
    |> find_prefix_cache_status(model_ref)
    |> PrefixCacheStatus.normalize_for_scheduler()
  end

  defp find_prefix_cache_status(statuses, model_ref) when is_list(statuses) do
    Enum.find(statuses, &prefix_cache_model_ref_matches?(&1, model_ref))
  end

  defp prefix_cache_model_ref_matches?(status, model_ref) when is_map(status) do
    case Map.get(status, :model_ref) || Map.get(status, "model_ref") do
      %{model_id: model_id, version: version}
      when is_binary(model_id) and is_binary(version) ->
        model_id == model_ref.model_id and version == model_ref.version

      %{"model_id" => model_id, "version" => version}
      when is_binary(model_id) and is_binary(version) ->
        model_id == model_ref.model_id and version == model_ref.version

      _other ->
        false
    end
  end

  defp prefix_cache_model_ref_matches?(_status, _model_ref), do: false

  defp memory_budget_for(%Observation{} = observation, %CanonicalRequest.ModelRef{} = model_ref) do
    observation.runtime_memory_budgets
    |> find_memory_budget(model_ref)
  end

  defp find_memory_budget(budgets, model_ref) when is_list(budgets) do
    Enum.find(budgets, &memory_budget_model_ref_matches?(&1, model_ref))
  end

  defp memory_budget_model_ref_matches?(budget, model_ref) when is_map(budget) do
    case Map.get(budget, :model_ref) || Map.get(budget, "model_ref") do
      %{model_id: model_id, version: version}
      when is_binary(model_id) and is_binary(version) ->
        model_id == model_ref.model_id and version == model_ref.version

      %{"model_id" => model_id, "version" => version}
      when is_binary(model_id) and is_binary(version) ->
        model_id == model_ref.model_id and version == model_ref.version

      _other ->
        false
    end
  end

  defp memory_budget_model_ref_matches?(_budget, _model_ref), do: false

  defp model_placement_capacity_for(_observation, _model_ref, false), do: nil

  defp model_placement_capacity_for(
         %Observation{} = observation,
         %CanonicalRequest.ModelRef{} = model_ref,
         true
       ) do
    Observation.placement_capacity_for(observation, runtime_model_ref(model_ref))
  end

  defp maybe_put_model_placement_capacity(map, nil), do: map

  defp maybe_put_model_placement_capacity(map, capacity),
    do: Map.put(map, :model_placement_capacity, capacity)

  defp maybe_put_prefix_cache_status(map, nil), do: map
  defp maybe_put_prefix_cache_status(map, status), do: Map.put(map, :prefix_cache_status, status)

  defp maybe_put_memory_budget(map, nil), do: map
  defp maybe_put_memory_budget(map, budget), do: Map.put(map, :memory_budget, budget)

  defp maybe_put_prefix_cache_fingerprint_match(map, _selected, false), do: map

  defp maybe_put_prefix_cache_fingerprint_match(map, selected, true) do
    Map.put(
      map,
      :prefix_cache_fingerprint_match?,
      Map.get(selected, :prefix_cache_fingerprint_match?, false)
    )
  end

  defp annotate_prefix_cache_fingerprint_matches(candidates, _affinity_context, false) do
    candidates
  end

  defp annotate_prefix_cache_fingerprint_matches(candidates, affinity_context, true) do
    affinity_key = Map.get(affinity_context, :affinity_key)

    Enum.map(candidates, fn candidate ->
      Map.put(
        candidate,
        :prefix_cache_fingerprint_match?,
        prefix_cache_fingerprint_match?(candidate, affinity_key)
      )
    end)
  end

  defp prefix_cache_fingerprint_match?(_candidate, affinity_key) when not is_binary(affinity_key),
    do: false

  defp prefix_cache_fingerprint_match?(candidate, affinity_key) do
    candidate
    |> Map.get(:prefix_cache_status, %{})
    |> Map.get(:prefix_cache_fingerprints, [])
    |> Enum.member?(affinity_key)
  end

  defp annotate_capable_workers(candidates, false), do: candidates

  defp annotate_capable_workers(candidates, true) do
    Enum.map(candidates, fn candidate ->
      Map.put(
        candidate,
        :capable_worker_preferred?,
        Map.get(candidate, :supports_prompt_token_ids, false) == true
      )
    end)
  end

  defp annotate_memory_admission(candidates, false), do: candidates

  defp annotate_memory_admission(candidates, true) do
    Enum.map(candidates, fn candidate ->
      normalized = MemoryBudget.normalize_for_scheduler(Map.get(candidate, :memory_budget))
      tier = Map.get(normalized, :admission_tier, :headroom_unknown)

      candidate
      |> Map.put(:memory_admission_tier, tier)
      |> Map.put(:memory_headroom_ok?, tier == :headroom_ok)
    end)
  end

  defp maybe_put_prefix_cache_score(map, nil), do: map

  defp maybe_put_prefix_cache_score(map, score), do: Map.put(map, :prefix_cache_score, score)

  defp select_candidate_with_prefix_cache_score(
         request,
         ranked,
         client,
         cache_affinity_config,
         prefix_cache_scoring_enabled?,
         ranking_opts
       ) do
    selected = hd(ranked)

    scoring_context =
      prefix_cache_scoring_context(
        request,
        cache_affinity_config,
        prefix_cache_scoring_enabled?,
        Keyword.get(ranking_opts, :live_fingerprint_match?, false)
      )

    selected_score = score_prefix_cache_candidate(request, selected, client, scoring_context)

    maybe_reselect_prefix_cache_candidate(
      request,
      ranked,
      client,
      scoring_context,
      selected_score,
      ranking_opts
    )
  end

  defp prefix_cache_scoring_context(
         _request,
         _cache_affinity_config,
         false,
         _live_fingerprint_match_enabled?
       ),
       do: nil

  defp prefix_cache_scoring_context(
         _request,
         _cache_affinity_config,
         _prefix_cache_scoring_enabled?,
         false
       ),
       do: nil

  defp prefix_cache_scoring_context(request, cache_affinity_config, true, true) do
    case CacheAffinity.derive_key(request, cache_affinity_config) do
      {:ok, fingerprint} ->
        %{fingerprint: fingerprint, timeout_ms: Inference.prefix_cache_scoring_timeout_ms()}

      :unavailable ->
        nil
    end
  end

  defp score_prefix_cache_candidate(_request, _candidate, _client, nil), do: nil

  defp score_prefix_cache_candidate(request, candidate, client, scoring_context) do
    timeout_ms = scoring_context.timeout_ms

    response =
      %Operation.PrefixCacheScoreRequest{
        request_id: request.public_id,
        controller_session_id: request.internal_id,
        model_ref: runtime_model_ref(request.model_ref),
        cache_affinity_fingerprint: scoring_context.fingerprint,
        deadline_unix_ms: System.system_time(:millisecond) + timeout_ms
      }
      |> score_prefix_cache_response(client, candidate.target, timeout_ms)

    PrefixCacheScore.normalize_for_scheduler(response)
  end

  defp maybe_reselect_prefix_cache_candidate(
         _request,
         ranked,
         _client,
         _scoring_context,
         nil,
         _ranking_opts
       ),
       do: {hd(ranked), nil}

  defp maybe_reselect_prefix_cache_candidate(
         request,
         ranked,
         client,
         scoring_context,
         selected_score,
         ranking_opts
       ) do
    if Inference.prefix_cache_scoring_ranking_active?() do
      maybe_reselect_tied_candidate(
        request,
        ranked,
        client,
        scoring_context,
        selected_score,
        ranking_opts
      )
    else
      {hd(ranked), selected_score}
    end
  end

  defp maybe_reselect_tied_candidate(
         request,
         ranked,
         client,
         scoring_context,
         selected_score,
         ranking_opts
       ) do
    case leading_tie_group(ranked, ranking_opts) do
      [incumbent, challenger] ->
        challenger_score =
          score_prefix_cache_candidate(request, challenger, client, scoring_context)

        if prefix_cache_score_promotes?(selected_score, challenger_score) do
          {challenger, challenger_score}
        else
          {incumbent, selected_score}
        end

      _no_two_candidate_tie ->
        {hd(ranked), selected_score}
    end
  end

  defp prefix_cache_score_promotes?(incumbent_score, challenger_score) do
    comparable_ok_non_resident_score?(incumbent_score) and
      authoritative_resident_score?(challenger_score)
  end

  defp comparable_ok_non_resident_score?(%{
         status_code: "ok",
         resident_fingerprint_match: false,
         score_tier: score_tier
       })
       when score_tier in ["no_match", "recent_fingerprint_only"],
       do: true

  defp comparable_ok_non_resident_score?(_score), do: false

  defp authoritative_resident_score?(%{
         status_code: "ok",
         resident_fingerprint_match: true,
         score_tier: "resident_fingerprint"
       }),
       do: true

  defp authoritative_resident_score?(_score), do: false

  defp score_prefix_cache_response(request, client, target, timeout_ms) do
    request_id = Map.get(request, :request_id)

    if is_atom(client) and Code.ensure_loaded?(client) and
         function_exported?(client, :score_prefix_cache, 3) do
      try do
        case client.score_prefix_cache(target, request, timeout: timeout_ms) do
          {:ok, response} -> response
          {:error, reason} -> score_prefix_cache_failure(reason, target, request_id)
          _unexpected -> score_prefix_cache_failure(:unexpected_response, target, request_id)
        end
      rescue
        _exception -> score_prefix_cache_failure(:rescued_exception, target, request_id)
      catch
        :exit, reason -> score_prefix_cache_failure({:exit, reason}, target, request_id)
      end
    else
      score_prefix_cache_failure(:unsupported_version, target, request_id)
    end
  end

  defp score_prefix_cache_failure(reason, target, request_id) do
    failure = score_prefix_cache_failure(reason)

    Logger.warning(
      "prefix cache score RPC fail-open: status_code=#{failure.status_code} " <>
        "reason=#{prefix_cache_score_failure_reason(reason)} " <>
        "target=#{prefix_cache_score_target(target)} request_id=#{request_id || "unknown"}"
    )

    failure
  end

  defp score_prefix_cache_failure(:unsupported_version), do: %{status_code: "unsupported_version"}
  defp score_prefix_cache_failure(:unimplemented), do: %{status_code: "unsupported_version"}

  defp score_prefix_cache_failure(%{status: status}) when status in [:unimplemented, 12],
    do: %{status_code: "unsupported_version"}

  defp score_prefix_cache_failure({:rpc_error, status, _message})
       when status in [:unimplemented, 12],
       do: %{status_code: "unsupported_version"}

  defp score_prefix_cache_failure({:exit, {:undef, _}}), do: %{status_code: "unsupported_version"}
  defp score_prefix_cache_failure(_reason), do: %{status_code: "error"}

  defp prefix_cache_score_failure_reason(:unsupported_version), do: "unsupported_version"
  defp prefix_cache_score_failure_reason(:unimplemented), do: "unimplemented"
  defp prefix_cache_score_failure_reason(:unexpected_response), do: "unexpected_response"
  defp prefix_cache_score_failure_reason(:rescued_exception), do: "rescued_exception"

  defp prefix_cache_score_failure_reason(%{status: status}) when status in [:unimplemented, 12],
    do: "unimplemented"

  defp prefix_cache_score_failure_reason({:rpc_error, status, _message})
       when status in [:unimplemented, 12],
       do: "unimplemented"

  defp prefix_cache_score_failure_reason({:exit, {:undef, _}}), do: "exit_undef"
  defp prefix_cache_score_failure_reason({:exit, _reason}), do: "exit"
  defp prefix_cache_score_failure_reason(_reason), do: "error"

  defp prefix_cache_score_target(target) when is_list(target) do
    "#{Keyword.get(target, :host, "unknown")}:#{Keyword.get(target, :port, "unknown")}"
  end

  defp prefix_cache_score_target(%Target{} = target),
    do: prefix_cache_score_target(target.address)

  defp prefix_cache_score_target(_target), do: "unknown"

  defp maybe_put_memory_admission(map, _selected, false), do: map

  defp maybe_put_memory_admission(map, selected, true) do
    Map.merge(map, %{
      memory_admission_enabled: true,
      memory_admission_tier:
        selected
        |> Map.get(:memory_admission_tier, :headroom_unknown)
        |> Atom.to_string(),
      memory_budget: Map.get(selected, :memory_budget)
    })
  end

  # -- Ranking --

  @doc """
  Sorts candidates using the scheduler's deterministic tie-break order.
  """
  def rank_candidates(candidates) do
    rank_candidates(candidates, [])
  end

  @doc """
  Sorts candidates and optionally inserts live fingerprint, capability, and memory tie-breakers.
  """
  def rank_candidates(candidates, opts) do
    ranking_opts = [
      live_fingerprint_match?: Keyword.get(opts, :live_fingerprint_match?, false),
      prefer_capable_workers?: Keyword.get(opts, :prefer_capable_workers?, false),
      memory_admission?: Keyword.get(opts, :memory_admission?, false)
    ]

    Enum.sort_by(candidates, &rank_tuple(&1, ranking_opts))
  end

  defp rank_tuple(candidate, ranking_opts) do
    base_rank(candidate) ++ optional_rank_terms(candidate, ranking_opts) ++ [candidate.node_id]
  end

  defp optional_rank_terms(candidate, ranking_opts) do
    [
      maybe_rank_term(
        Keyword.get(ranking_opts, :live_fingerprint_match?, false),
        not Map.get(candidate, :prefix_cache_fingerprint_match?, false)
      ),
      not Map.get(candidate, :cache_affinity_match?, false),
      maybe_rank_term(
        Keyword.get(ranking_opts, :prefer_capable_workers?, false),
        not Map.get(candidate, :capable_worker_preferred?, false)
      ),
      maybe_rank_term(
        Keyword.get(ranking_opts, :memory_admission?, false),
        not Map.get(candidate, :memory_headroom_ok?, false)
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_rank_term(true, term), do: term
  defp maybe_rank_term(false, _term), do: nil

  defp base_rank(candidate) do
    [
      not candidate.loaded_model?,
      active_request_rank(candidate),
      health_rank(candidate.node.health)
    ]
  end

  defp active_request_rank(%{
         model_placement_capacity: %PlacementCapacity{
           status: :known,
           active_request_count: active_request_count
         }
       })
       when is_integer(active_request_count) and active_request_count >= 0,
       do: active_request_count

  defp active_request_rank(%{active_request_count: active_request_count})
       when is_integer(active_request_count) and active_request_count >= 0,
       do: active_request_count

  defp active_request_rank(_candidate), do: 0

  defp health_rank(:healthy), do: 0
  defp health_rank(:degraded), do: 1
  defp health_rank(_), do: 2

  defp leading_tie_group([_first | _rest] = ranked, ranking_opts) do
    max_candidates = Inference.prefix_cache_scoring_max_ranking_candidates()

    ranked
    |> leading_rank_equivalent_candidates(ranking_opts)
    |> Enum.take(max_candidates)
  end

  defp leading_rank_equivalent_candidates([first | _rest] = ranked, ranking_opts) do
    leading_key = rank_equivalence_key(first, ranking_opts)

    tied =
      Enum.take_while(ranked, fn candidate ->
        rank_equivalence_key(candidate, ranking_opts) == leading_key
      end)

    if length(tied) > 1, do: tied, else: []
  end

  defp rank_equivalence_key(candidate, ranking_opts) do
    candidate
    |> rank_tuple(ranking_opts)
    |> Enum.drop(-1)
  end

  # -- Helpers --

  # When there is exactly one unique target, pass it explicitly to
  # SingleNode.default_schedule/2 so the fallback uses the actual target
  # from the plural config, not the separate singular runtime_client_target.
  # When targets is empty or has multiple entries, use the implicit singular
  # fallback (no single deterministic target to pass).
  defp fallback_schedule(request, [single_target], opts) do
    SingleNode.default_schedule(request, dispatch_target(single_target), opts)
  end

  defp fallback_schedule(request, _targets, opts) do
    SingleNode.default_schedule(request, SingleNode.target(), opts)
  end

  defp normalize_status_observation(_target, %Observation{} = observation), do: observation

  defp normalize_status_observation(target, %{} = status_response) do
    GrpcCompatibilityMapper.observation_from_status(target, status_response)
  end

  defp runtime_model_ref(%CanonicalRequest.ModelRef{} = model_ref) do
    ModelRef.new!(model_ref.model_id, model_ref.version)
  end

  defp maybe_put_runtime_client_target(schedule, %Target{
         transport: :grpc_compat,
         address: address
       }) do
    Map.put(schedule, :runtime_client_target, address)
  end

  defp maybe_put_runtime_client_target(schedule, _target), do: schedule

  defp dispatch_target(%Target{transport: :grpc_compat, address: address}), do: address
  defp dispatch_target(target), do: target

  defp observation_target(%Target{transport: :grpc_compat, address: address}), do: address
  defp observation_target(target), do: target
end
