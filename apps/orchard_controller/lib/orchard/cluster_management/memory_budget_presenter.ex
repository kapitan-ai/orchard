defmodule Orchard.ClusterManagement.MemoryBudgetPresenter do
  @moduledoc """
  Builds operator-facing runtime memory-budget blocks for node surfaces.
  """

  alias Orchard.Models

  @type memory_budget_block :: %{
          runtime_memory_budgets: [map()],
          runtime_memory_budgets_truncated_count: non_neg_integer()
        }

  @spec for_node(map() | struct(), module()) :: memory_budget_block() | nil
  def for_node(node, runtime_impl \\ OrchardConsole.Runtime) do
    runtime_impl.cluster_snapshot()
    |> Enum.find(&runtime_snapshot_matches_node?(&1, node))
    |> memory_budget_from_snapshot()
  rescue
    _exception -> nil
  catch
    _kind, _reason -> nil
  end

  defp runtime_snapshot_matches_node?(snapshot, node) when is_map(snapshot) do
    metadata = map_value(snapshot, :node_metadata)

    metadata_value(metadata, :node_id) == node_value(node, :id) or
      metadata_value(metadata, :display_name) == node_value(node, :display_name) or
      metadata_value(metadata, :hostname) == node_value(node, :hostname)
  end

  defp runtime_snapshot_matches_node?(_snapshot, _node), do: false

  defp memory_budget_from_snapshot(nil), do: nil

  defp memory_budget_from_snapshot(snapshot) do
    budgets = map_value(snapshot, :runtime_memory_budgets)

    case budgets do
      [_ | _] ->
        %{
          runtime_memory_budgets: Enum.map(budgets, &memory_budget_row/1),
          runtime_memory_budgets_truncated_count:
            non_negative_integer(map_value(snapshot, :runtime_memory_budgets_truncated_count)) ||
              0
        }

      _ ->
        nil
    end
  end

  defp memory_budget_row(budget) when is_map(budget) do
    budget
    |> Map.new(fn {key, value} -> {normalize_budget_key(key), value} end)
    |> normalize_recommended_context_tokens()
    |> put_catalog_max_context_tokens()
  end

  defp memory_budget_row(_budget) do
    %{
      display_state: :invalid,
      model_ref: "unknown model",
      mode: "unknown",
      budget_available: nil,
      headroom_available: nil,
      status_code: "invalid_status",
      status_message: "memory budget telemetry payload was malformed",
      target_working_set_bytes: nil,
      resident_memory_bytes: nil,
      kv_cache_bytes_per_token: nil,
      prefill_workspace_bytes_per_token: nil,
      recommended_context_tokens: nil,
      max_context_tokens: nil
    }
  end

  defp normalize_budget_key(key) when is_atom(key), do: key

  defp normalize_budget_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_budget_key(key), do: key

  defp normalize_recommended_context_tokens(budget) do
    case budget[:recommended_context_tokens] do
      value when is_integer(value) and value > 0 -> budget
      _ -> Map.put(budget, :recommended_context_tokens, nil)
    end
  end

  defp put_catalog_max_context_tokens(%{model_ref: model_ref} = budget) do
    Map.put(budget, :max_context_tokens, catalog_max_context_tokens(model_ref))
  end

  defp put_catalog_max_context_tokens(budget), do: Map.put(budget, :max_context_tokens, nil)

  defp catalog_max_context_tokens(model_ref) when is_binary(model_ref) do
    with [model_id, version] <- String.split(model_ref, "@", parts: 2),
         %{max_context_tokens: max_context_tokens} <-
           Models.get_model_by_identity(model_id, version) do
      max_context_tokens
    else
      _ -> nil
    end
  rescue
    _exception -> nil
  end

  defp catalog_max_context_tokens(_model_ref), do: nil

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp metadata_value(metadata, key), do: map_value(metadata, key)
  defp node_value(node, key), do: map_value(node, key)

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil
end
