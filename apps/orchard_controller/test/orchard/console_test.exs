defmodule OrchardConsoleTest do
  use ExUnit.Case, async: true

  # SPEC.md §13.1 keeps Build Provenance at the full source commit, but the console
  # sidebar is a fixed 16rem with `white-space: nowrap` and `overflow: hidden`. A full
  # 40-character commit is clipped mid-SHA there and renders as a plausible but wrong
  # shorter SHA, so the sidebar shows an abbreviation derived from the full value.
  # Authenticated `/ops/v1/health` `build_ref` and the Sentry `build_sha` tag carry the
  # full commit.
  describe "display_version/0" do
    test "abbreviates build provenance to seven characters" do
      version = OrchardConsole.display_version()

      case Regex.run(~r/\(([^)]*)\)\z/, version) do
        nil ->
          assert Orchard.BuildInfo.git_sha() == "unknown"

        [_match, provenance] ->
          full_sha = Orchard.BuildInfo.git_sha()
          assert full_sha =~ ~r/\A[0-9a-f]{40}\z/
          assert byte_size(provenance) == 7
          assert provenance == String.slice(full_sha, 0, 7)
      end
    end

    test "stays short enough for the fixed-width sidebar" do
      assert String.length(OrchardConsole.display_version()) <= 24
    end
  end
end
