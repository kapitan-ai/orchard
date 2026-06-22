defmodule OrchardCLI.BuildPkgScriptTest do
  use ExUnit.Case, async: true

  @script_path Path.expand("../../../../scripts/build-pkg.sh", __DIR__)

  test "build channel allowlist is explicit and rejects deprecated guard" do
    script = File.read!(@script_path)

    assert script =~ "internal|trial|pilot|release"
    assert script =~ "Invalid ORCHARD_BUILD_CHANNEL"
    assert script =~ "ORCHARD_BUILD_CHANNEL=dev"

    refute script =~ "require ORCHARD_BUILD_CHANNEL to be a non-dev channel"
  end

  test "build channel validation runs before mix commands" do
    script = File.read!(@script_path)

    allowlist_index = index_of(script, "case \"$ORCHARD_BUILD_CHANNEL\" in")
    mix_run_index = index_of(script, "mix run --no-start")
    mix_deps_index = index_of(script, "mix deps.get")
    mix_release_index = index_of(script, "mix release orchard_controller")

    assert is_integer(allowlist_index)
    assert is_integer(mix_run_index)
    assert is_integer(mix_deps_index)
    assert is_integer(mix_release_index)

    assert allowlist_index < mix_run_index
    assert allowlist_index < mix_deps_index
    assert allowlist_index < mix_release_index
  end

  test "build channel defaults only when environment variable is unset" do
    script = File.read!(@script_path)

    assert script =~ "${ORCHARD_BUILD_CHANNEL+x}"
    assert script =~ "to be non-empty"
    assert script =~ "default channel: trial"
  end

  test "package build bootstraps pinned asset dependencies before deploy" do
    script = File.read!(@script_path)

    mix_deps_index = index_of(script, "mix deps.get")
    assets_setup_index = index_of(script, "MIX_ENV=prod mix assets.setup")
    assets_deploy_index = index_of(script, "MIX_ENV=prod mix assets.deploy")

    assert is_integer(mix_deps_index)
    assert is_integer(assets_setup_index)
    assert is_integer(assets_deploy_index)

    assert mix_deps_index < assets_setup_index
    assert assets_setup_index < assets_deploy_index
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end
end
