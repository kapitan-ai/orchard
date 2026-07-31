defmodule OrchardCLI.BuildPkgScriptTest do
  use ExUnit.Case, async: true

  @script_path Path.expand("../../../../scripts/build-pkg.sh", __DIR__)
  @pkg_readme Path.expand("../../../../packaging/pkg/README.md", __DIR__)
  @lifecycle_contract Path.expand("../../../../packaging/service-lifecycle.json", __DIR__)
  @app_builder Path.expand("../../../../scripts/build-app.sh", __DIR__)
  @pkg_postinstall Path.expand("../../../../packaging/pkg/scripts/postinstall", __DIR__)
  @repo_root Path.expand("../../../..", __DIR__)

  test "app and PKG packaging share lifecycle roles paths plists and wrappers" do
    contract = @lifecycle_contract |> File.read!() |> Jason.decode!()
    pkg_script = File.read!(@script_path)
    app_builder = File.read!(@app_builder)
    pkg_postinstall = File.read!(@pkg_postinstall)

    pkg_path_links =
      section_between(
        pkg_postinstall,
        "# 4. Symlink wrappers into PATH (/usr/local/bin)",
        "# 5. Install role-selected launchd plists"
      )

    assert Map.keys(contract["roles"]) |> Enum.sort() == ["all", "controller", "node-agent"]

    assert pkg_script =~
             ~s(PAYLOAD_ROOT_REL="#{String.trim_leading(contract["support_root"], "/")}")

    assert app_builder =~ "packaging/service-lifecycle.json"

    contract["roles"]
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.each(fn label ->
      assert pkg_script =~ ~s("#{label}.plist")
      assert File.regular?(Path.join(@repo_root, "packaging/launchd/#{label}.plist"))
    end)

    Enum.each(contract["command_links"], fn {command, installed_path} ->
      assert pkg_script =~ ~s("#{command}")
      assert File.regular?(Path.join(@repo_root, "packaging/pkg/bin/#{command}"))
      assert installed_path == "/usr/local/bin/#{command}"
      assert pkg_path_links =~ command
    end)

    refute Map.has_key?(contract["command_links"], "orchard-managed-postgres")
  end

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

  test "full build SHA is exported before every mix command" do
    script = File.read!(@script_path)

    resolve_index = index_of(script, "git rev-parse HEAD")
    validation_index = index_of(script, "^[0-9a-f]{40}$")
    export_index = index_of(script, "export ORCHARD_BUILD_SHA=\"$FULL_GIT_SHA\"")

    assert is_integer(resolve_index)
    assert is_integer(validation_index)
    assert is_integer(export_index)
    assert resolve_index < validation_index
    assert validation_index < export_index

    for mix_command <- [
          "mix run --no-start",
          "mix deps.get",
          "MIX_ENV=prod mix assets.setup",
          "MIX_ENV=prod mix assets.deploy",
          "mix release orchard_controller",
          "mix release orchard_node_agent",
          "mix release orchard_cli"
        ] do
      mix_index = index_of(script, mix_command)
      assert is_integer(mix_index)
      assert export_index < mix_index
    end

    refute script =~ "git rev-parse --short"
  end

  test "dirty marker is separate from the exported build SHA" do
    script = File.read!(@script_path)

    assert script =~ "SHORT_GIT_SHA=\"${FULL_GIT_SHA:0:7}\""
    assert script =~ "PKG_FILENAME_REF=\"${SHORT_GIT_SHA}-dirty\""
    assert script =~ "Build SHA: $ORCHARD_BUILD_SHA"
    assert script =~ "PKG filename ref: $PKG_FILENAME_REF"

    refute script =~ "ORCHARD_BUILD_SHA=\"${ORCHARD_BUILD_SHA}-dirty\""
    refute script =~ "FULL_GIT_SHA=\"${FULL_GIT_SHA}-dirty\""
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
    assert script =~ "share/bin/orchard-managed-postgres"
    assert script =~ "./Library/Application Support/Orchard/share/bin/orchard-managed-postgres"
    refute plist_section =~ "com.orchard.postgres.plist"
  end

  test "package build stages native venvs without duplicate helper source trees" do
    script = File.read!(@script_path)

    assert script =~ "copy_packaging_venv_only"
    assert script =~ "assert_no_staged_native_sources"
    assert script =~ ".venv/bin/orchard-tokenizer"
    assert script =~ ".venv/bin/orchard-worker-mlx"

    for path <- [
          "native/orchard_tokenizer/src",
          "native/orchard_tokenizer/tests",
          "native/orchard_worker_mlx/src",
          "native/orchard_worker_mlx/tests",
          "native/orchard_worker_mlx/proto"
        ] do
      assert script =~ path
    end

    refute script =~ "tar --exclude './.venv' -cf - ."
  end

  test "package uninstall runbook deletes shipped wrapper commands" do
    readme = File.read!(@pkg_readme)
    delete_section = section_between(readme, "delete: [", "]")

    for wrapper <- [
          "orchardctl",
          "orchard-controller",
          "orchard-node-agent",
          "orchard-managed-postgres"
        ] do
      assert delete_section =~ "/Library/Application Support/Orchard/bin/#{wrapper}"
    end
  end

  test "package runbook describes source exposure as deterrence only" do
    readme = File.read!(@pkg_readme)

    assert readme =~ "bytecode/deterrence"
    assert readme =~ "does not provide compiled source protection"
    assert readme =~ "duplicate native helper source trees are not staged"
    refute readme =~ "accepted source exposure risk"
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
