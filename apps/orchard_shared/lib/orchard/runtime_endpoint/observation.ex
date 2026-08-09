defmodule Orchard.RuntimeEndpoint.Observation do
  @moduledoc """
  Transport-independent Runtime Endpoint status observation.
  """

  alias Orchard.RuntimeEndpoint.{ModelRef, Placement, PlacementCapacity, Target}

  defstruct endpoint_id: nil,
            target: nil,
            observed_at: nil,
            availability: :unknown,
            worker_state: :unknown,
            aggregate_active_request_count: 0,
            aggregate_max_concurrency: nil,
            aggregate_capacity_evidence: %{
              runtime_concurrency_limit: nil,
              active_request_count: nil,
              validity: :missing
            },
            metadata: %{},
            health: %{},
            placements: [],
            hosted_tool_capabilities: [],
            hosted_tool_readiness: [],
            runtime_memory_budgets: [],
            runtime_prefix_cache_statuses: [],
            worker_crash_counters: [],
            supports_prompt_token_ids: false

  @type availability :: :unknown | :available | :unavailable | :degraded | atom()
  @type t :: %__MODULE__{
          endpoint_id: String.t() | nil,
          target: Target.t() | nil,
          observed_at: term(),
          availability: availability(),
          worker_state: term(),
          aggregate_active_request_count: non_neg_integer(),
          aggregate_max_concurrency: pos_integer() | nil,
          aggregate_capacity_evidence: %{
            runtime_concurrency_limit: pos_integer() | nil,
            active_request_count: non_neg_integer() | nil,
            validity: :valid | :missing | :invalid
          },
          metadata: map(),
          health: map(),
          placements: [Placement.t()],
          hosted_tool_capabilities: [term()],
          hosted_tool_readiness: [term()],
          runtime_memory_budgets: [term()],
          runtime_prefix_cache_statuses: [term()],
          worker_crash_counters: [term()],
          supports_prompt_token_ids: boolean()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    %__MODULE__{
      endpoint_id: value(attrs, :endpoint_id),
      target: value(attrs, :target),
      observed_at: value(attrs, :observed_at),
      availability: value(attrs, :availability) || :unknown,
      worker_state: value(attrs, :worker_state) || :unknown,
      aggregate_active_request_count: aggregate_active_request_count(attrs),
      aggregate_max_concurrency: aggregate_max_concurrency(attrs),
      aggregate_capacity_evidence: aggregate_capacity_evidence(attrs),
      metadata: map_value(attrs, :metadata),
      health: map_value(attrs, :health),
      placements: Enum.map(list_value(attrs, :placements), &normalize_placement/1),
      hosted_tool_capabilities: list_value(attrs, :hosted_tool_capabilities),
      hosted_tool_readiness: list_value(attrs, :hosted_tool_readiness),
      runtime_memory_budgets: list_value(attrs, :runtime_memory_budgets),
      runtime_prefix_cache_statuses: list_value(attrs, :runtime_prefix_cache_statuses),
      worker_crash_counters: list_value(attrs, :worker_crash_counters),
      supports_prompt_token_ids: value(attrs, :supports_prompt_token_ids) == true
    }
  end

  @spec node_id(t()) :: String.t() | nil
  def node_id(%__MODULE__{target: %Target{node_id: node_id}})
      when is_binary(node_id) and node_id != "",
      do: node_id

  def node_id(%__MODULE__{metadata: metadata}) when is_map(metadata) do
    value(metadata, :node_id)
  end

  @spec loaded_placement(t(), ModelRef.t() | map()) :: Placement.t() | nil
  def loaded_placement(%__MODULE__{placements: placements}, model_ref) do
    Enum.find(placements, fn placement ->
      Placement.loaded?(placement) and ModelRef.equal?(placement.model_ref, model_ref)
    end)
  end

  @spec placement_capacity_for(t(), ModelRef.t() | map()) :: PlacementCapacity.t()
  def placement_capacity_for(%__MODULE__{placements: placements}, model_ref) do
    matching =
      Enum.filter(placements, fn placement ->
        ModelRef.equal?(placement.model_ref, model_ref)
      end)

    case matching do
      [%Placement{capacity: %PlacementCapacity{} = capacity}] ->
        capacity

      [] ->
        PlacementCapacity.unknown(model_ref, :not_observed)

      _duplicates ->
        PlacementCapacity.new(%{
          model_ref: model_ref,
          active_request_count: :duplicate,
          max_concurrency: :duplicate,
          source: :duplicate_observation
        })
    end
  end

  defp normalize_placement(%Placement{} = placement), do: placement
  defp normalize_placement(%{} = attrs), do: Placement.new(attrs)

  defp aggregate_active_request_count(attrs) do
    case value(attrs, :aggregate_active_request_count) do
      count when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  end

  defp aggregate_max_concurrency(attrs) do
    case aggregate_max_concurrency_value(attrs) do
      count when is_integer(count) and count > 0 -> count
      _ -> nil
    end
  end

  defp aggregate_max_concurrency_value(attrs) do
    case value(attrs, :aggregate_max_concurrency) do
      nil -> value(attrs, :max_concurrency)
      value -> value
    end
  end

  defp aggregate_capacity_evidence(attrs) do
    active = value(attrs, :aggregate_active_request_count)
    limit = aggregate_max_concurrency_value(attrs)

    %{
      active_request_count: non_negative_or_nil(active),
      runtime_concurrency_limit: positive_or_nil(limit),
      validity: aggregate_capacity_validity(active, limit)
    }
  end

  defp aggregate_capacity_validity(active, limit) do
    cond do
      malformed?(active, &non_negative_or_nil/1) -> :invalid
      malformed?(limit, &positive_or_nil/1) -> :invalid
      is_nil(active) or is_nil(limit) -> :missing
      true -> :valid
    end
  end

  defp malformed?(nil, _normalizer), do: false
  defp malformed?(value, normalizer), do: is_nil(normalizer.(value))

  defp non_negative_or_nil(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_or_nil(_value), do: nil

  defp positive_or_nil(value) when is_integer(value) and value > 0, do: value
  defp positive_or_nil(_value), do: nil

  defp map_value(attrs, key) do
    case value(attrs, key) do
      %{} = map -> map
      nil -> %{}
      other -> %{raw_value: other}
    end
  end

  defp list_value(attrs, key) do
    case value(attrs, key) do
      list when is_list(list) -> list
      nil -> []
      other -> [other]
    end
  end

  defp value(%{} = attrs, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.fetch!(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.fetch!(attrs, string_key)
      true -> nil
    end
  end
end
