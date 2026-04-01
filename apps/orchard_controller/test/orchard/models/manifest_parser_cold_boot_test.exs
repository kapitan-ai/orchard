defmodule Orchard.Models.ManifestParserColdBootTest do
  use ExUnit.Case, async: false

  @fixture_bundle Path.expand("../../fixtures/bundles/test-model-bundle", __DIR__)
  @app_root Path.expand("../../..", __DIR__)
  @runner Path.join(@app_root, "test/support/manifest_parser_cold_boot_runner.exs")

  test "parse_from_bundle succeeds in a fresh VM before Orchard.ModelManifest is loaded" do
    mix = System.find_executable("mix") || flunk("mix executable not found")

    {output, status} =
      System.cmd(
        mix,
        ["run", "--no-start", "--no-compile", @runner, @fixture_bundle],
        cd: @app_root,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, "cold-boot runner failed (status #{status}):\n#{output}"
    assert output =~ "preloaded_before_parse=false"
    assert output =~ "parse_status=ok"
    assert output =~ "model_id=test-org/tiny-llm"
    assert output =~ "version=mlx-q4-v1"
    assert output =~ "COLD_BOOT_PARSE_OK"
  end
end
