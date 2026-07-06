defmodule Orchard.Runtime.MemoryBudget do
  @moduledoc """
  Normalizes runtime memory-budget telemetry for scheduler ranking and
  scheduler-decision persistence.

  The Phase 4E contract treats memory-budget data as a positive-only,
  non-excluding ranking input. Only `status_code == "ok"` with
  `headroom_available == true` receives scheduler preference.
  """

  alias Orchard.Runtime.TextBounds

  @type admission_tier :: :headroom_ok | :headroom_unavailable | :headroom_unknown

  @type t :: %{
          optional(:model_ref) => String.t(),
          required(:mode) => String.t(),
          required(:budget_available) => boolean() | nil,
          required(:headroom_available) => boolean() | nil,
          required(:status_code) => String.t(),
          required(:status_message) => String.t() | nil,
          required(:source) => String.t() | nil,
          required(:target_working_set_bytes) => non_neg_integer() | nil,
          required(:resident_memory_bytes) => non_neg_integer() | nil,
          required(:estimated_headroom_bytes) => non_neg_integer() | nil,
          required(:kv_cache_bytes_per_token) => non_neg_integer() | nil,
          required(:prefill_workspace_bytes_per_token) => non_neg_integer() | nil,
          required(:recommended_context_tokens) => non_neg_integer() | nil,
          required(:admission_tier) => admission_tier()
        }

  @selected_memory_keys [
    :selected_memory_status_code,
    :selected_memory_budget_available,
    :selected_memory_headroom_available,
    :selected_memory_target_working_set_bytes,
    :selected_memory_resident_memory_bytes,
    :selected_memory_estimated_headroom_bytes,
    :selected_memory_kv_cache_bytes_per_token,
    :selected_memory_prefill_workspace_bytes_per_token
  ]

  @uint64_max 18_446_744_073_709_551_615
  @max_model_ref_length 160
  @max_mode_length 40
  @max_status_code_length 80
  @max_status_message_length 240
  @max_source_length 80

  @uint64_fields [
    :target_working_set_bytes,
    :resident_memory_bytes,
    :estimated_headroom_bytes,
    :kv_cache_bytes_per_token,
    :prefill_workspace_bytes_per_token,
    :recommended_context_tokens
  ]

  @doc """
  Returns the scheduler-decision keys owned by memory admission.
  """
  @spec selected_field_keys() :: [atom()]
  def selected_field_keys, do: @selected_memory_keys

  @doc """
  Normalizes a runtime memory-budget payload to approved fields only.
  """
  @spec normalize(term()) :: t() | nil
  def normalize(nil), do: nil

  def normalize(budget) when is_map(budget) do
    normalized = %{
      model_ref: normalize_model_ref(value(budget, :model_ref)),
      mode: TextBounds.bounded_string(value(budget, :mode), "unknown", @max_mode_length),
      budget_available: normalize_boolean(value(budget, :budget_available)),
      headroom_available: normalize_boolean(value(budget, :headroom_available)),
      status_code: normalize_status_code(value(budget, :status_code)),
      status_message:
        TextBounds.bounded_optional_string(
          value(budget, :status_message),
          @max_status_message_length
        ),
      source: TextBounds.bounded_optional_string(value(budget, :source), @max_source_length),
      target_working_set_bytes: normalize_uint64(value(budget, :target_working_set_bytes)),
      resident_memory_bytes: normalize_uint64(value(budget, :resident_memory_bytes)),
      estimated_headroom_bytes: normalize_uint64(value(budget, :estimated_headroom_bytes)),
      kv_cache_bytes_per_token: normalize_uint64(value(budget, :kv_cache_bytes_per_token)),
      prefill_workspace_bytes_per_token:
        normalize_uint64(value(budget, :prefill_workspace_bytes_per_token)),
      recommended_context_tokens: normalize_uint64(value(budget, :recommended_context_tokens))
    }

    normalized =
      if malformed_numeric_payload?(budget) do
        %{normalized | status_code: "invalid_status"}
      else
        normalized
      end

    Map.put(normalized, :admission_tier, admission_tier(normalized))
  end

  def normalize(_budget) do
    %{
      mode: "unknown",
      budget_available: nil,
      headroom_available: nil,
      status_code: "invalid_status",
      status_message: "memory-budget telemetry payload was malformed",
      source: nil,
      target_working_set_bytes: nil,
      resident_memory_bytes: nil,
      estimated_headroom_bytes: nil,
      kv_cache_bytes_per_token: nil,
      prefill_workspace_bytes_per_token: nil,
      recommended_context_tokens: nil,
      admission_tier: :headroom_unknown
    }
  end

  @doc """
  Normalizes memory-budget telemetry for scheduler-internal ranking.
  """
  @spec normalize_for_scheduler(term()) :: t() | %{required(:admission_tier) => admission_tier()}
  def normalize_for_scheduler(nil), do: %{admission_tier: :headroom_unknown}
  def normalize_for_scheduler(budget), do: normalize(budget)

  @doc """
  Returns flat, sanitized selected-candidate fields for `scheduler_decision`.
  """
  @spec selected_fields(term()) :: map()
  def selected_fields(budget) do
    case normalize(budget) do
      nil ->
        %{}

      %{status_code: "ok"} = normalized ->
        normalized
        |> ok_selected_fields()
        |> reject_nil_values()

      normalized ->
        %{
          selected_memory_status_code: normalized.status_code,
          selected_memory_budget_available: normalized.budget_available,
          selected_memory_headroom_available: normalized.headroom_available
        }
        |> reject_nil_values()
    end
  end

  defp ok_selected_fields(normalized) do
    %{
      selected_memory_status_code: normalized.status_code,
      selected_memory_budget_available: normalized.budget_available,
      selected_memory_headroom_available: normalized.headroom_available,
      selected_memory_target_working_set_bytes: normalized.target_working_set_bytes,
      selected_memory_resident_memory_bytes: normalized.resident_memory_bytes,
      selected_memory_estimated_headroom_bytes: normalized.estimated_headroom_bytes,
      selected_memory_kv_cache_bytes_per_token: normalized.kv_cache_bytes_per_token,
      selected_memory_prefill_workspace_bytes_per_token:
        normalized.prefill_workspace_bytes_per_token
    }
  end

  defp admission_tier(%{status_code: "ok", headroom_available: true}), do: :headroom_ok

  defp admission_tier(%{status_code: "resident_memory_unavailable"}),
    do: :headroom_unavailable

  defp admission_tier(%{status_code: "ok", budget_available: true, headroom_available: false}),
    do: :headroom_unavailable

  defp admission_tier(_normalized), do: :headroom_unknown

  defp malformed_numeric_payload?(budget) do
    Enum.any?(@uint64_fields, &malformed_uint64?(budget, &1))
  end

  defp malformed_uint64?(budget, field) do
    case fetch_value(budget, field) do
      {:ok, value} -> value != nil and normalize_uint64(value) == nil
      :error -> false
    end
  end

  defp normalize_model_ref(%{model_id: model_id, version: version})
       when is_binary(model_id) and model_id != "" and is_binary(version) and version != "" do
    String.slice("#{model_id}@#{version}", 0, @max_model_ref_length)
  end

  defp normalize_model_ref(%{"model_id" => model_id, "version" => version})
       when is_binary(model_id) and model_id != "" and is_binary(version) and version != "" do
    String.slice("#{model_id}@#{version}", 0, @max_model_ref_length)
  end

  defp normalize_model_ref(value) when is_binary(value) and value != "",
    do: String.slice(value, 0, @max_model_ref_length)

  defp normalize_model_ref(_value), do: nil

  defp normalize_boolean(value) when is_boolean(value), do: value
  defp normalize_boolean(_value), do: nil

  defp normalize_uint64(value) when is_integer(value) and value >= 0 and value <= @uint64_max,
    do: value

  defp normalize_uint64(_value), do: nil

  defp normalize_status_code(value) when is_binary(value) and value != "",
    do: String.slice(value, 0, @max_status_code_length)

  defp normalize_status_code(_value), do: "invalid_status"

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp value(map, key) do
    case fetch_value(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_value(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, string_key) -> {:ok, Map.get(map, string_key)}
      true -> :error
    end
  end
end
