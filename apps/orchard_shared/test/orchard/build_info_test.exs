defmodule Orchard.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Orchard.BuildInfo

  test "git_sha returns a non-empty string" do
    sha = BuildInfo.git_sha()
    assert is_binary(sha)
    assert sha != ""
  end

  test "git_sha is 7 characters or 'unknown'" do
    sha = BuildInfo.git_sha()
    assert sha == "unknown" or (String.length(sha) == 7 and sha =~ ~r/^[0-9a-f]+$/)
  end

  test "build_date returns a valid ISO date" do
    date = BuildInfo.build_date()
    assert is_binary(date)
    assert {:ok, _} = Date.from_iso8601(date)
  end

  test "build_channel returns a non-empty trimmed string" do
    channel = BuildInfo.build_channel()

    assert is_binary(channel)
    assert channel != ""
    assert channel == String.trim(channel)
  end
end
