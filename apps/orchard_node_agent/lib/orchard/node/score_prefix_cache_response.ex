defmodule Orchard.Node.ScorePrefixCacheResponse do
  @moduledoc """
  Canonical node-agent normalizer for ScorePrefixCache responses.
  """

  alias Orchard.Cluster.V1.ScorePrefixCacheResponse, as: ProtoResponse

  @status_codes ~w(ok disabled unavailable model_not_loaded timeout invalid_request error unsupported_version)
  @score_tiers ~w(resident_fingerprint recent_fingerprint_only no_match unknown)

  @spec normalize(ProtoResponse.t() | map() | term()) :: ProtoResponse.t()
  def normalize(%ProtoResponse{} = response) do
    build(
      response.status_code,
      response.status_message,
      response.resident_fingerprint_match == true,
      response.score_tier,
      response.session_started_unix_ms
    )
  end

  def normalize(response) when is_map(response) do
    build(
      field(response, :status_code),
      field(response, :status_message),
      field(response, :resident_fingerprint_match) == true,
      field(response, :score_tier),
      field(response, :session_started_unix_ms)
    )
  end

  def normalize(_response), do: response("error", "malformed score response")

  @spec response(String.t(), String.t()) :: ProtoResponse.t()
  def response(status_code, status_message) do
    build(status_code, status_message, false, "unknown", 0)
  end

  defp build(status_code, status_message, resident?, score_tier, session_started_unix_ms) do
    normalized_status = normalize_status_code(status_code)
    normalized_tier = normalize_score_tier(score_tier)
    {tier, resident?} = normalize_diagnostics(normalized_status, normalized_tier, resident?)

    %ProtoResponse{
      status_code: normalized_status,
      status_message: normalize_status_message(status_message),
      resident_fingerprint_match: resident?,
      score_tier: tier,
      session_started_unix_ms: normalize_session_started(session_started_unix_ms)
    }
  end

  defp normalize_diagnostics(status_code, _score_tier, _resident?) when status_code != "ok" do
    {"unknown", false}
  end

  defp normalize_diagnostics("ok", "resident_fingerprint", true) do
    {"resident_fingerprint", true}
  end

  defp normalize_diagnostics("ok", "resident_fingerprint", false) do
    {"unknown", false}
  end

  defp normalize_diagnostics("ok", _score_tier, true) do
    {"unknown", false}
  end

  defp normalize_diagnostics("ok", score_tier, false) do
    {score_tier, false}
  end

  defp normalize_status_code(status_code) when status_code in @status_codes, do: status_code
  defp normalize_status_code(_status_code), do: "error"

  defp normalize_status_message(status_message) when is_binary(status_message) do
    String.slice(status_message, 0, 240)
  end

  defp normalize_status_message(_status_message), do: ""

  defp normalize_score_tier(score_tier) when score_tier in @score_tiers, do: score_tier
  defp normalize_score_tier(_score_tier), do: "unknown"

  defp normalize_session_started(value) when is_integer(value) and value >= 0, do: value
  defp normalize_session_started(_value), do: 0

  defp field(map, key) do
    if Map.has_key?(map, key) do
      Map.get(map, key)
    else
      Map.get(map, Atom.to_string(key))
    end
  end
end
