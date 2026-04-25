defmodule Orchard.Runtime.PrefixCacheScore do
  @moduledoc """
  Defensive normalization for selected-candidate prefix-cache score telemetry.
  """

  @selected_prefix_cache_score_keys [
    :selected_prefix_cache_score_status_code,
    :selected_prefix_cache_score_status_message,
    :selected_prefix_cache_score_resident_fingerprint_match,
    :selected_prefix_cache_score_tier,
    :selected_prefix_cache_score_session_started_unix_ms,
    :selected_prefix_cache_score_source
  ]

  @status_codes ~w(ok disabled unavailable model_not_loaded timeout invalid_request error unsupported_version)
  @tiers ~w(resident_fingerprint recent_fingerprint_only no_match unknown)

  @spec selected_field_keys() :: [atom()]
  def selected_field_keys, do: @selected_prefix_cache_score_keys

  @spec normalize_for_scheduler(term()) :: map()
  def normalize_for_scheduler(score) when is_map(score) do
    status_code = normalize_status_code(value(score, :status_code))

    {score_tier, resident_fingerprint_match} =
      normalize_score_diagnostics(
        status_code,
        normalize_tier(value(score, :score_tier)),
        value(score, :resident_fingerprint_match) == true
      )

    %{
      status_code: status_code,
      status_message: normalize_status_message(status_code),
      resident_fingerprint_match: resident_fingerprint_match,
      score_tier: score_tier,
      session_started_unix_ms: normalize_session_started(value(score, :session_started_unix_ms))
    }
  end

  def normalize_for_scheduler(_score) do
    %{
      status_code: "error",
      status_message: default_status_message("error"),
      resident_fingerprint_match: false,
      score_tier: "unknown",
      session_started_unix_ms: 0
    }
  end

  @spec selected_fields(term()) :: map()
  def selected_fields(nil), do: %{}

  def selected_fields(score) do
    normalized = normalize_for_scheduler(score)

    base_fields = %{
      selected_prefix_cache_score_status_code: normalized.status_code,
      selected_prefix_cache_score_status_message: normalized.status_message,
      selected_prefix_cache_score_tier: normalized.score_tier,
      selected_prefix_cache_score_source: "score_prefix_cache_rpc"
    }

    case normalized.status_code do
      "ok" ->
        Map.merge(base_fields, %{
          selected_prefix_cache_score_resident_fingerprint_match:
            normalized.resident_fingerprint_match,
          selected_prefix_cache_score_session_started_unix_ms: normalized.session_started_unix_ms
        })

      _non_ok ->
        base_fields
    end
  end

  defp normalize_status_code(status_code) when status_code in @status_codes, do: status_code
  defp normalize_status_code(_status_code), do: "error"

  defp normalize_status_message("ok"), do: ""
  defp normalize_status_message(status_code), do: default_status_message(status_code)

  defp default_status_message("ok"), do: ""
  defp default_status_message("disabled"), do: "prefix cache scoring disabled"
  defp default_status_message("unavailable"), do: "prefix cache scoring unavailable"
  defp default_status_message("model_not_loaded"), do: "model not loaded"
  defp default_status_message("timeout"), do: "prefix cache scoring timed out"
  defp default_status_message("invalid_request"), do: "invalid prefix cache scoring request"

  defp default_status_message("unsupported_version"),
    do: "prefix cache scoring unsupported version"

  defp default_status_message("error"), do: "prefix cache scoring error"
  defp default_status_message(_status_code), do: "prefix cache scoring error"

  defp normalize_tier(tier) when tier in @tiers, do: tier
  defp normalize_tier(_tier), do: "unknown"

  defp normalize_score_diagnostics(status_code, _score_tier, _resident_fingerprint_match)
       when status_code != "ok",
       do: {"unknown", false}

  defp normalize_score_diagnostics("ok", "resident_fingerprint", true),
    do: {"resident_fingerprint", true}

  defp normalize_score_diagnostics("ok", "resident_fingerprint", false),
    do: {"unknown", false}

  defp normalize_score_diagnostics("ok", score_tier, false),
    do: {score_tier, false}

  defp normalize_score_diagnostics("ok", _score_tier, true), do: {"unknown", false}

  defp normalize_session_started(value) when is_integer(value) and value >= 0, do: value
  defp normalize_session_started(_value), do: 0

  defp value(map, key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end
end
