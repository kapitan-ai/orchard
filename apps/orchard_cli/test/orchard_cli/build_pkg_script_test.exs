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

  test "package build ships managed postgres guard but excludes launchd service" do
    script = File.read!(@script_path)

    assert script =~ "WRAPPER_SCRIPTS=("
    assert script =~ "PLIST_FILES=("
    assert script =~ "operator-safe guard"
    assert script =~ "com.orchard.postgres.plist is excluded"

    wrapper_section = section_between(script, "WRAPPER_SCRIPTS=(", ")\nfor script")
    plist_section = section_between(script, "PLIST_FILES=(", ")\nfor plist")

    assert wrapper_section =~ "orchard-managed-postgres"
    refute plist_section =~ "com.orchard.postgres.plist"
  end

  defp index_of(haystack, needle) do
    case :binary.match(haystack, needle) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end

  defp section_between(haystack, start_marker, end_marker) do
    start_index = index_of(haystack, start_marker)
    assert is_integer(start_index)

    section_start = start_index + byte_size(start_marker)
    rest = binary_part(haystack, section_start, byte_size(haystack) - section_start)
    end_index = index_of(rest, end_marker)
    assert is_integer(end_index)

    binary_part(rest, 0, end_index)
  end
end
