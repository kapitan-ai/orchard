defmodule Orchard.Scheduler.SingleNode do
  @moduledoc """
  Injectable single-node scheduler and fallback for source-dev runtime targets.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Dispatch.GrpcNodeRuntimeClient
  alias Orchard.Inference

  @callback schedule(CanonicalRequest.t()) :: {:ok, map()} | {:error, term()}

  @default_status_timeout_ms 2_000

  def schedule(%CanonicalRequest{} = request) do
    case Inference.configured_scheduler_impl() do
      nil -> default_schedule(request)
      __MODULE__ -> default_schedule(request)
      module -> module.schedule(request)
    end
  end

  def target, do: Orchard.Inference.runtime_client_target()

  @doc """
  Build a single-node schedule map directly, without delegation.

  Public so that `MultiNode` can call this as a recursion-safe fallback
  when cluster scheduling is unavailable.

  The 1-arity version uses the configured singular `runtime_client_target`.
  The 2-arity version accepts an explicit target, used by `MultiNode` to
  preserve the actual plural target during fallback.
  """
  def default_schedule(%CanonicalRequest{} = request) do
    default_schedule(request, target())
  end

  def default_schedule(%CanonicalRequest{} = request, target) do
    default_schedule(request, target, [])
  end

  def default_schedule(%CanonicalRequest{} = request, target, opts) when is_list(opts) do
    node_id = resolve_node_id(target)

    schedule = %{
      strategy: :single_node,
      request_id: request.public_id,
      runtime_client_target: target,
      request_timeout_ms: Orchard.Inference.request_timeout_ms(),
      model_load_timeout_ms: Orchard.Inference.model_load_timeout_ms(),
      node_id: node_id
    }

    maybe_put_queue_lane_capacity(schedule, request, target, opts)
  end

  defp resolve_node_id(target) do
    case Orchard.Nodes.lookup_by_target(target) do
      %{id: id} -> id
      nil -> nil
    end
  rescue
    _ -> nil
  end

  defp maybe_put_queue_lane_capacity(schedule, request, target, opts) do
    if Keyword.get(opts, :probe_status?, true) do
      client = Keyword.get(opts, :status_client, GrpcNodeRuntimeClient)
      timeout = Keyword.get(opts, :status_timeout_ms, @default_status_timeout_ms)

      case client.connect(target) do
        {:ok, channel} ->
          try do
            case client.status(channel, timeout: timeout) do
              {:ok, response} -> capacity_schedule(schedule, request, response)
              {:error, _reason} -> {:ok, schedule}
            end
          after
            client.disconnect(channel)
          end

        {:error, _reason} ->
          {:ok, schedule}
      end
    else
      {:ok, schedule}
    end
  rescue
    _error -> {:ok, schedule}
  catch
    :exit, _reason -> {:ok, schedule}
  end

  defp capacity_schedule(schedule, request, response) do
    case runtime_model_placement_for(response, request.model_ref) do
      nil ->
        {:ok, schedule}

      placement ->
        placement_capacity_schedule(schedule, placement)
    end
  end

  defp placement_capacity_schedule(schedule, placement) do
    if loaded_placement_state?(placement_state(placement)) do
      active_request_count =
        non_negative_integer(placement_value(placement, :active_request_count), 0)

      max_concurrency = positive_integer(placement_value(placement, :max_concurrency), 1)

      cond do
        active_request_count < max_concurrency ->
          {:ok, Map.put(schedule, :queue_lane_capacity, max_concurrency)}

        max_concurrency > 1 ->
          {:error, :model_busy}

        true ->
          {:ok, schedule}
      end
    else
      {:ok, schedule}
    end
  end

  defp runtime_model_placement_for(response, %CanonicalRequest.ModelRef{} = model_ref) do
    response
    |> response_list(:runtime_model_placements)
    |> Enum.find(&runtime_model_placement_matches?(&1, model_ref))
  end

  defp response_list(response, key) do
    case Map.get(response, key) || Map.get(response, to_string(key)) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  defp runtime_model_placement_matches?(placement, model_ref) when is_map(placement) do
    case placement_value(placement, :model_ref) do
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

  defp runtime_model_placement_matches?(_placement, _model_ref), do: false

  defp placement_state(placement), do: placement_value(placement, :placement_state)

  defp placement_value(placement, key) do
    Map.get(placement, key, Map.get(placement, to_string(key)))
  end

  defp loaded_placement_state?(state)
       when state in [:PLACEMENT_STATE_LOADED, "PLACEMENT_STATE_LOADED", 7],
       do: true

  defp loaded_placement_state?(_state), do: false

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp non_negative_integer(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value, default), do: default
end
