defmodule Orchard.Runtime.PrefixCacheScoreTest do
  use ExUnit.Case, async: true

  alias Orchard.Runtime.PrefixCacheScore

  @status_message_expectations %{
    "ok" => "",
    "disabled" => "prefix cache scoring disabled",
    "unavailable" => "prefix cache scoring unavailable",
    "model_not_loaded" => "model not loaded",
    "timeout" => "prefix cache scoring timed out",
    "invalid_request" => "invalid prefix cache scoring request",
    "unsupported_version" => "prefix cache scoring unsupported version",
    "error" => "prefix cache scoring error"
  }

  @score_tiers ~w(resident_fingerprint recent_fingerprint_only no_match unknown)

  test "normalize_for_scheduler enforces status and tier allowlists" do
    normalized =
      PrefixCacheScore.normalize_for_scheduler(%{
        status_code: "surprise",
        status_message: "hello",
        resident_fingerprint_match: true,
        score_tier: "bad",
        session_started_unix_ms: -1
      })

    assert normalized.status_code == "error"
    assert normalized.score_tier == "unknown"
    assert normalized.resident_fingerprint_match == false
    assert normalized.session_started_unix_ms == 0
    assert normalized.status_message == "prefix cache scoring error"
  end

  test "normalize_for_scheduler canonicalizes all documented score statuses" do
    Enum.each(@status_message_expectations, fn {status_code, status_message} ->
      normalized =
        PrefixCacheScore.normalize_for_scheduler(%{
          status_code: status_code,
          status_message: "must-not-cross-controller-boundary",
          resident_fingerprint_match: true,
          score_tier: "resident_fingerprint",
          session_started_unix_ms: 42
        })

      assert normalized.status_code == status_code
      assert normalized.status_message == status_message
    end)
  end

  test "normalize_for_scheduler keeps all documented score tiers" do
    Enum.each(@score_tiers, fn score_tier ->
      normalized =
        PrefixCacheScore.normalize_for_scheduler(%{
          status_code: "ok",
          score_tier: score_tier,
          resident_fingerprint_match: score_tier == "resident_fingerprint"
        })

      assert normalized.score_tier == score_tier
    end)
  end

  test "normalize_for_scheduler coerces contradictory ok diagnostics to safe shape" do
    assert PrefixCacheScore.normalize_for_scheduler(%{
             status_code: "ok",
             score_tier: "no_match",
             resident_fingerprint_match: true
           }) == %{
             status_code: "ok",
             status_message: "",
             resident_fingerprint_match: false,
             score_tier: "unknown",
             session_started_unix_ms: 0
           }

    assert PrefixCacheScore.normalize_for_scheduler(%{
             status_code: "ok",
             score_tier: "resident_fingerprint",
             resident_fingerprint_match: false
           }) == %{
             status_code: "ok",
             status_message: "",
             resident_fingerprint_match: false,
             score_tier: "unknown",
             session_started_unix_ms: 0
           }
  end

  test "selected_fields returns empty map when score telemetry is missing" do
    assert PrefixCacheScore.selected_fields(nil) == %{}
  end

  test "selected_fields emits full whitelist for ok status" do
    fields =
      PrefixCacheScore.selected_fields(%{
        status_code: "ok",
        status_message: "matched hmac-sha256:#{String.duplicate("a", 64)}",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint",
        session_started_unix_ms: 1
      })

    assert Map.keys(fields) |> Enum.sort() == Enum.sort(PrefixCacheScore.selected_field_keys())
    assert fields.selected_prefix_cache_score_source == "score_prefix_cache_rpc"
    assert fields.selected_prefix_cache_score_status_message == ""
  end

  test "selected_fields emits bounded non-ok diagnostics only" do
    fields =
      PrefixCacheScore.selected_fields(%{
        status_code: "timeout",
        status_message: "Traceback req_123 /tmp/orchard token_ids: [1,2,3]",
        resident_fingerprint_match: true,
        score_tier: "resident_fingerprint",
        session_started_unix_ms: 42
      })

    assert fields.selected_prefix_cache_score_status_code == "timeout"
    assert fields.selected_prefix_cache_score_tier == "unknown"
    assert fields.selected_prefix_cache_score_source == "score_prefix_cache_rpc"
    assert fields.selected_prefix_cache_score_status_message == "prefix cache scoring timed out"
    refute Map.has_key?(fields, :selected_prefix_cache_score_resident_fingerprint_match)
    refute Map.has_key?(fields, :selected_prefix_cache_score_session_started_unix_ms)
  end
end
