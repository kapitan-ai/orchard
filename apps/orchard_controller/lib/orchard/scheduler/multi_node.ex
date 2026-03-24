defmodule Orchard.Scheduler.MultiNode do
  @moduledoc """
  Multi-node scheduler that probes configured runtime targets and
  selects the best candidate for dispatch.

  Ranking order (descending priority):
  1. Node has the requested model already loaded
  2. Lower `active_request_count`
  3. Healthier node (`:healthy` over `:degraded`)
  4. Lexicographically smaller `node_id` (deterministic tie-break)

  Falls back to `SingleNode.default_schedule/1` when:
  - Only 0 or 1 targets are configured
  - All probes fail
  - No schedulable nodes remain after filtering
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Dispatch.GrpcNodeRuntimeClient
  alias Orchard.Inference
  alias Orchard.Nodes
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
      SingleNode.default_schedule(request)
    else
      schedule_multi(request, dedup_targets(targets), opts)
    end
  end

  # -- Internal --

  defp schedule_multi(request, targets, opts) do
    client = Keyword.get(opts, :status_client, GrpcNodeRuntimeClient)
    timeout = Keyword.get(opts, :status_timeout_ms, @default_status_timeout_ms)
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    # Probe each target and collect ephemeral ranking data
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
      SingleNode.default_schedule(request)
    else
      ranked = rank_candidates(candidates)
      selected = hd(ranked)

      {:ok,
       %{
         strategy: :multi_node,
         request_id: request.public_id,
         runtime_client_target: selected.target,
         request_timeout_ms: Inference.request_timeout_ms(),
         model_load_timeout_ms: Inference.model_load_timeout_ms(),
         node_id: selected.node_id,
         candidate_count: length(ranked),
         selected_tier: if(selected.loaded_model?, do: "loaded", else: "cold")
       }}
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
              end

            {:error, _} ->
              nil
          end
        after
          client.disconnect(channel)
        end

      {:error, _} ->
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

  # -- Ranking --

  @doc false
  def rank_candidates(candidates) do
    Enum.sort_by(candidates, fn c ->
      {
        # 1. Loaded model first (false < true, so negate)
        not c.loaded_model?,
        # 2. Lower active_request_count
        c.active_request_count,
        # 3. Healthier first (:healthy = 0, :degraded = 1)
        health_rank(c.node.health),
        # 4. Lexicographic node_id tie-break
        c.node_id
      }
    end)
  end

  defp health_rank(:healthy), do: 0
  defp health_rank(:degraded), do: 1
  defp health_rank(_), do: 2

  # -- Helpers --

  defp dedup_targets(targets) do
    targets
    |> Enum.uniq_by(fn t -> {Keyword.get(t, :host), Keyword.get(t, :port)} end)
  end
end
