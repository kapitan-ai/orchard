defmodule Orchard.Runtime.PrefixCacheStatus do
  @moduledoc """
  Defensive normalization for observe-only runtime prefix-cache telemetry.

  Prefix-cache status is worker-authoritative diagnostic data. The controller
  whitelists and sanitizes fields before any UI display or scheduler-decision
  persistence; it is not a scheduling or admission input in this slice.
  """

  @type t :: %{
          optional(:model_ref) => String.t(),
          required(:implementation) => String.t(),
          required(:enabled) => boolean() | nil,
          required(:entry_count) => non_neg_integer() | nil,
          required(:total_bytes) => non_neg_integer() | nil,
          required(:hits) => non_neg_integer() | nil,
          required(:misses) => non_neg_integer() | nil,
          required(:failures) => non_neg_integer() | nil,
          required(:stores) => non_neg_integer() | nil,
          required(:evictions) => non_neg_integer() | nil,
          required(:configured_max_entries) => non_neg_integer() | nil,
          required(:configured_max_bytes) => non_neg_integer() | nil,
          required(:status_code) => String.t(),
          required(:status_message) => String.t() | nil,
          required(:session_started_unix_ms) => non_neg_integer() | nil,
          required(:prefix_cache_fingerprint_count) => non_neg_integer(),
          required(:prefix_cache_warmth_indicator) => boolean()
        }

  @selected_prefix_cache_keys [
    :selected_prefix_cache_status_code,
    :selected_prefix_cache_enabled,
    :selected_prefix_cache_implementation,
    :selected_prefix_cache_entry_count,
    :selected_prefix_cache_total_bytes,
    :selected_prefix_cache_hits,
    :selected_prefix_cache_misses,
    :selected_prefix_cache_stores,
    :selected_prefix_cache_evictions,
    :selected_prefix_cache_session_started_unix_ms,
    :selected_prefix_cache_fingerprint_count,
    :selected_prefix_cache_warmth_indicator,
    :selected_prefix_cache_fingerprint_match
  ]

  @status_codes ~w(ok disabled unavailable invalid_status error)
  @uint32_max 4_294_967_295
  @uint64_max 18_446_744_073_709_551_615
  @max_model_ref_length 160
  @max_implementation_length 40
  @max_status_code_length 80
  @max_status_message_length 240
  @max_prefix_cache_fingerprints 64
  @prefix_cache_fingerprint_pattern ~r/\Ahmac-sha256:[a-f0-9]{64}\z/

  @uint32_fields [:entry_count, :configured_max_entries]

  @uint64_fields [
    :total_bytes,
    :hits,
    :misses,
    :failures,
    :stores,
    :evictions,
    :configured_max_bytes,
    :session_started_unix_ms
  ]

  @doc """
  Returns the scheduler-decision keys owned by prefix-cache introspection.
  """
  @spec selected_field_keys() :: [atom()]
  def selected_field_keys, do: @selected_prefix_cache_keys

  @doc """
  Normalizes a worker-reported prefix-cache status to approved fields only.
  """
  @spec normalize(term()) :: t() | nil
  def normalize(nil), do: nil

  def normalize(status) when is_map(status) do
    normalized = %{
      model_ref: normalize_model_ref(value(status, :model_ref)),
      implementation:
        bounded_string(value(status, :implementation), "unknown", @max_implementation_length),
      enabled: normalize_boolean(value(status, :enabled)),
      entry_count: normalize_uint32(value(status, :entry_count)),
      total_bytes: normalize_uint64(value(status, :total_bytes)),
      hits: normalize_uint64(value(status, :hits)),
      misses: normalize_uint64(value(status, :misses)),
      failures: normalize_uint64(value(status, :failures)),
      stores: normalize_uint64(value(status, :stores)),
      evictions: normalize_uint64(value(status, :evictions)),
      configured_max_entries: normalize_uint32(value(status, :configured_max_entries)),
      configured_max_bytes: normalize_uint64(value(status, :configured_max_bytes)),
      status_code: normalize_status_code(value(status, :status_code)),
      status_message:
        bounded_optional_string(value(status, :status_message), @max_status_message_length),
      session_started_unix_ms: normalize_uint64(value(status, :session_started_unix_ms)),
      prefix_cache_fingerprint_count: prefix_cache_fingerprint_count(status),
      prefix_cache_warmth_indicator: prefix_cache_warmth_indicator?(status)
    }

    if malformed_numeric_payload?(status) do
      %{normalized | status_code: "invalid_status"}
    else
      normalized
    end
  end

  def normalize(_status) do
    %{
      implementation: "unknown",
      enabled: nil,
      entry_count: nil,
      total_bytes: nil,
      hits: nil,
      misses: nil,
      failures: nil,
      stores: nil,
      evictions: nil,
      configured_max_entries: nil,
      configured_max_bytes: nil,
      status_code: "invalid_status",
      status_message: "prefix-cache telemetry payload was malformed",
      session_started_unix_ms: nil,
      prefix_cache_fingerprint_count: 0,
      prefix_cache_warmth_indicator: false
    }
  end

  @doc """
  Normalizes prefix-cache status for scheduler-internal matching.

  This path retains only a validated, deduplicated, capped set of opaque HMAC
  fingerprints. Persistence and UI callers MUST use `normalize/1` or
  `selected_fields/2`, which expose derived fields only.
  """
  @spec normalize_for_scheduler(term()) :: map() | nil
  def normalize_for_scheduler(nil), do: nil

  def normalize_for_scheduler(status) when is_map(status) do
    status
    |> normalize()
    |> Map.put(:prefix_cache_fingerprints, normalize_prefix_cache_fingerprints(status))
  end

  def normalize_for_scheduler(status) do
    status
    |> normalize()
    |> Map.put(:prefix_cache_fingerprints, [])
  end

  @doc """
  Returns flat, sanitized selected-candidate fields for `scheduler_decision`.
  """
  @spec selected_fields(term(), keyword()) :: map()
  def selected_fields(status, opts \\ []) do
    case normalize(status) do
      nil ->
        %{}

      %{status_code: "ok"} = normalized ->
        normalized
        |> ok_selected_fields(Keyword.get(opts, :fingerprint_match))
        |> reject_nil_values()

      normalized ->
        %{
          selected_prefix_cache_status_code: normalized.status_code,
          selected_prefix_cache_enabled: normalized.enabled
        }
        |> reject_nil_values()
    end
  end

  defp ok_selected_fields(normalized, fingerprint_match?) do
    %{
      selected_prefix_cache_status_code: normalized.status_code,
      selected_prefix_cache_enabled: normalized.enabled,
      selected_prefix_cache_implementation: normalized.implementation,
      selected_prefix_cache_entry_count: normalized.entry_count,
      selected_prefix_cache_total_bytes: normalized.total_bytes,
      selected_prefix_cache_hits: normalized.hits,
      selected_prefix_cache_misses: normalized.misses,
      selected_prefix_cache_stores: normalized.stores,
      selected_prefix_cache_evictions: normalized.evictions,
      selected_prefix_cache_session_started_unix_ms: normalized.session_started_unix_ms,
      selected_prefix_cache_fingerprint_count: normalized.prefix_cache_fingerprint_count,
      selected_prefix_cache_warmth_indicator: normalized.prefix_cache_warmth_indicator,
      selected_prefix_cache_fingerprint_match: fingerprint_match?
    }
  end

  defp malformed_numeric_payload?(status) do
    Enum.any?(@uint32_fields, &malformed_uint32?(status, &1)) or
      Enum.any?(@uint64_fields, &malformed_uint64?(status, &1))
  end

  defp malformed_uint32?(status, field) do
    case fetch_value(status, field) do
      {:ok, value} -> value != nil and normalize_uint32(value) == nil
      :error -> false
    end
  end

  defp malformed_uint64?(status, field) do
    case fetch_value(status, field) do
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

  defp normalize_model_ref(%{model_id: model_id}) when is_binary(model_id) and model_id != "",
    do: String.slice(model_id, 0, @max_model_ref_length)

  defp normalize_model_ref(%{"model_id" => model_id}) when is_binary(model_id) and model_id != "",
    do: String.slice(model_id, 0, @max_model_ref_length)

  defp normalize_model_ref(value) when is_binary(value) and value != "",
    do: String.slice(value, 0, @max_model_ref_length)

  defp normalize_model_ref(_value), do: nil

  defp normalize_boolean(value) when is_boolean(value), do: value
  defp normalize_boolean(_value), do: nil

  defp normalize_uint32(value) when is_integer(value) and value in 0..@uint32_max, do: value
  defp normalize_uint32(_value), do: nil

  defp normalize_uint64(value) when is_integer(value) and value >= 0 and value <= @uint64_max,
    do: value

  defp normalize_uint64(_value), do: nil

  defp normalize_status_code(value) when is_binary(value) do
    status_code = String.slice(value, 0, @max_status_code_length)
    if status_code in @status_codes, do: status_code, else: "invalid_status"
  end

  defp normalize_status_code(_value), do: "invalid_status"

  defp prefix_cache_fingerprint_count(status) do
    status
    |> normalize_prefix_cache_fingerprints()
    |> length()
  end

  defp prefix_cache_warmth_indicator?(status), do: prefix_cache_fingerprint_count(status) > 0

  defp normalize_prefix_cache_fingerprints(status) when is_map(status) do
    status
    |> value(:prefix_cache_fingerprints)
    |> normalize_prefix_cache_fingerprint_list()
  end

  defp normalize_prefix_cache_fingerprint_list(fingerprints) when is_list(fingerprints) do
    {_seen, ordered, _count} =
      Enum.reduce_while(fingerprints, {MapSet.new(), [], 0}, fn fingerprint, {seen, acc, count} ->
        cond do
          count >= @max_prefix_cache_fingerprints ->
            {:halt, {seen, acc, count}}

          valid_prefix_cache_fingerprint?(fingerprint) and not MapSet.member?(seen, fingerprint) ->
            {:cont, {MapSet.put(seen, fingerprint), [fingerprint | acc], count + 1}}

          true ->
            {:cont, {seen, acc, count}}
        end
      end)

    Enum.reverse(ordered)
  end

  defp normalize_prefix_cache_fingerprint_list(_fingerprints), do: []

  defp valid_prefix_cache_fingerprint?(fingerprint) when is_binary(fingerprint) do
    Regex.match?(@prefix_cache_fingerprint_pattern, fingerprint)
  end

  defp valid_prefix_cache_fingerprint?(_fingerprint), do: false

  defp bounded_string(value, _fallback, limit) when is_binary(value) and value != "",
    do: String.slice(value, 0, limit)

  defp bounded_string(_value, fallback, _limit), do: fallback

  defp bounded_optional_string(value, limit) when is_binary(value) and value != "",
    do: String.slice(value, 0, limit)

  defp bounded_optional_string(_value, _limit), do: nil

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
