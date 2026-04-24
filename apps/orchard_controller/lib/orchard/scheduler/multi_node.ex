defmodule Orchard.Scheduler.MultiNode do
  @moduledoc """
  Multi-node scheduler that probes configured runtime targets and
  selects the best candidate for dispatch.

  Ranking order (descending priority):
  1. Node has the requested model already loaded
  2. Lower `active_request_count`
  3. Healthier node (`:healthy` over `:degraded`)
  4. Live prefix-cache fingerprint match when explicitly enabled
  5. Cache-affinity match when explicitly enabled
  6. Memory headroom positive signal when explicitly enabled
  7. Lexicographically smaller `node_id` (deterministic tie-break)

  Falls back to `SingleNode.default_schedule/1` when:
  - Only 0 or 1 targets are configured
  - All probes fail
  - No schedulable nodes remain after filtering
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Dispatch.GrpcNodeRuntimeClient
  alias Orchard.Inference
  alias Orchard.Inference.CacheAffinity
  alias Orchard.Nodes
  alias Orchard.Runtime.{MemoryBudget, PrefixCacheStatus}
  alias Orchard.Scheduler.SingleNode

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
  - `:status_client` — module implementing `connect/1`, `status/2`, `disconnect/1`
    (default: `GrpcNodeRuntimeClient`)
  - `:status_timeout_ms` — timeout for each status probe (default: #{@default_status_timeout_ms})
  - `:observed_at` — timestamp for observations (default: `DateTime.utc_now()`)
  """
  def schedule(%CanonicalRequest{} = request, opts) when is_list(opts) do
    targets = Inference.runtime_client_targets()

    if length(targets) <= 1 do
      fallback_schedule(request, targets)
    else
      schedule_multi(request, targets, opts)
    end
  end

  # -- Internal --

  defp schedule_multi(request, targets, opts) do
    client = Keyword.get(opts, :status_client, GrpcNodeRuntimeClient)
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

    if candidates == [] do
      fallback_schedule(request, targets)
    else
      cache_affinity_config = Inference.cache_affinity_config()

      {affinity_candidates, affinity_context} =
        CacheAffinity.prepare(request, candidates, cache_affinity_config)

      live_fingerprint_match_enabled? =
        CacheAffinity.live_fingerprint_match_enabled?(cache_affinity_config)

      memory_admission_enabled? = Inference.memory_admission_enabled?()

      annotated_candidates =
        affinity_candidates
        |> annotate_prefix_cache_fingerprint_matches(
          affinity_context,
          live_fingerprint_match_enabled?
        )
        |> annotate_memory_admission(memory_admission_enabled?)

      ranked =
        rank_candidates(annotated_candidates,
          live_fingerprint_match?: live_fingerprint_match_enabled?,
          memory_admission?: memory_admission_enabled?
        )

      selected = hd(ranked)

      schedule =
        %{
          strategy: :multi_node,
          request_id: request.public_id,
          runtime_client_target: selected.target,
          request_timeout_ms: Inference.request_timeout_ms(),
          model_load_timeout_ms: Inference.model_load_timeout_ms(),
          node_id: selected.node_id,
          candidate_count: length(ranked),
          selected_tier: if(selected.loaded_model?, do: "loaded", else: "cold")
        }
        |> maybe_put_prefix_cache_status(Map.get(selected, :prefix_cache_status))
        |> maybe_put_prefix_cache_fingerprint_match(
          selected,
          live_fingerprint_match_enabled?
        )
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
              # Persist observation best-effort
              Nodes.observe_status(target, response, observed_at)

              # Extract node_id from metadata — skip if missing/invalid
              case extract_valid_node_id(response) do
                nil ->
                  nil

                node_id ->
                  %{
                    node_id: node_id,
                    target: target,
                    loaded_model?: model_loaded?(response, request),
                    active_request_count: response.active_request_count || 0
                  }
                  |> maybe_put_prefix_cache_status(
                    prefix_cache_status_for(response, request.model_ref)
                  )
                  |> maybe_put_memory_budget(memory_budget_for(response, request.model_ref))
              end

            {:error, reason} ->
              # Persist transport-like probe failures best-effort
              Nodes.record_transport_failure(target, reason, observed_at)
              nil
          end
        after
          client.disconnect(channel)
        end

      {:error, reason} ->
        # Persist transport-like connect failures best-effort
        Nodes.record_transport_failure(target, reason, observed_at)
        nil
    end
  end

  defp extract_valid_node_id(%{node_metadata: %{node_id: node_id}}) when is_binary(node_id) do
    case Ecto.UUID.cast(node_id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp extract_valid_node_id(_), do: nil

  defp model_loaded?(%{loaded_models: models}, %CanonicalRequest{model_ref: model_ref})
       when is_list(models) do
    Enum.any?(models, fn m ->
      to_string(Map.get(m, :model_id, "")) == model_ref.model_id and
        to_string(Map.get(m, :version, "")) == model_ref.version
    end)
  end

  defp model_loaded?(_, _), do: false

  defp prefix_cache_status_for(response, %CanonicalRequest.ModelRef{} = model_ref) do
    response
    |> Map.get(:runtime_prefix_cache_statuses, [])
    |> find_prefix_cache_status(model_ref)
    |> PrefixCacheStatus.normalize_for_scheduler()
  end

  defp find_prefix_cache_status(statuses, model_ref) when is_list(statuses) do
    Enum.find(statuses, &prefix_cache_model_ref_matches?(&1, model_ref))
  end

  defp find_prefix_cache_status(_statuses, _model_ref), do: nil

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

  defp memory_budget_for(response, %CanonicalRequest.ModelRef{} = model_ref) do
    response
    |> Map.get(:runtime_memory_budgets, [])
    |> find_memory_budget(model_ref)
  end

  defp find_memory_budget(budgets, model_ref) when is_list(budgets) do
    Enum.find(budgets, &memory_budget_model_ref_matches?(&1, model_ref))
  end

  defp find_memory_budget(_budgets, _model_ref), do: nil

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
    rank_candidates(candidates, live_fingerprint_match?: false)
  end

  @doc """
  Sorts candidates and optionally inserts live fingerprint and memory tie-breakers.
  """
  def rank_candidates(candidates, opts) do
    live_fingerprint_match? = Keyword.get(opts, :live_fingerprint_match?, false)
    memory_admission? = Keyword.get(opts, :memory_admission?, false)

    Enum.sort_by(candidates, &rank_tuple(&1, live_fingerprint_match?, memory_admission?))
  end

  defp rank_tuple(candidate, true, true) do
    base_rank(candidate) ++
      [
        not Map.get(candidate, :prefix_cache_fingerprint_match?, false),
        not Map.get(candidate, :cache_affinity_match?, false),
        not Map.get(candidate, :memory_headroom_ok?, false),
        candidate.node_id
      ]
  end

  defp rank_tuple(candidate, true, false) do
    base_rank(candidate) ++
      [
        not Map.get(candidate, :prefix_cache_fingerprint_match?, false),
        not Map.get(candidate, :cache_affinity_match?, false),
        candidate.node_id
      ]
  end

  defp rank_tuple(candidate, false, true) do
    base_rank(candidate) ++
      [
        not Map.get(candidate, :cache_affinity_match?, false),
        not Map.get(candidate, :memory_headroom_ok?, false),
        candidate.node_id
      ]
  end

  defp rank_tuple(candidate, false, false) do
    base_rank(candidate) ++
      [
        not Map.get(candidate, :cache_affinity_match?, false),
        candidate.node_id
      ]
  end

  defp base_rank(candidate) do
    [
      not candidate.loaded_model?,
      candidate.active_request_count,
      health_rank(candidate.node.health)
    ]
  end

  defp health_rank(:healthy), do: 0
  defp health_rank(:degraded), do: 1
  defp health_rank(_), do: 2

  # -- Helpers --

  # When there is exactly one unique target, pass it explicitly to
  # SingleNode.default_schedule/2 so the fallback uses the actual target
  # from the plural config, not the separate singular runtime_client_target.
  # When targets is empty or has multiple entries, use the implicit singular
  # fallback (no single deterministic target to pass).
  defp fallback_schedule(request, [single_target]) do
    SingleNode.default_schedule(request, single_target)
  end

  defp fallback_schedule(request, _targets) do
    SingleNode.default_schedule(request)
  end
end
