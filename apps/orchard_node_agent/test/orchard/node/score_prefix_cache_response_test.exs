defmodule Orchard.Node.ScorePrefixCacheResponseTest do
  use ExUnit.Case, async: true

  alias Orchard.Node.ScorePrefixCacheResponse

  test "normalize/1 prefers atom keys over string keys, preserving explicit false values" do
    response =
      ScorePrefixCacheResponse.normalize(%{
        :status_code => "ok",
        "status_code" => "error",
        :status_message => "atom message",
        "status_message" => "string message",
        :resident_fingerprint_match => false,
        "resident_fingerprint_match" => true,
        :score_tier => "no_match",
        "score_tier" => "resident_fingerprint",
        :session_started_unix_ms => 111,
        "session_started_unix_ms" => 222
      })

    assert response.status_code == "ok"
    assert response.status_message == "atom message"
    assert response.resident_fingerprint_match == false
    assert response.score_tier == "no_match"
    assert response.session_started_unix_ms == 111
  end
end
