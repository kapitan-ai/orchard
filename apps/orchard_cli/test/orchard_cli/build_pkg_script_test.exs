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

  test "clean package preflight exports the exact full HEAD before Mix" do
    fixture = create_packaging_fixture!()
    head = git!(fixture, ["rev-parse", "HEAD"])

    {output, status} = run_packaging_fixture(fixture, advance_head: true)

    refute status == 0, output
    assert output =~ "Source HEAD changed during package construction"
    assert File.read!(Path.join(fixture, ".git/mix.log")) =~ "sha=#{head} args=run --no-start"
  end

  test "package cleanliness rejects tracked staged and untracked inputs before Mix" do
    for dirty_input <- [:tracked, :staged, :untracked] do
      fixture = create_packaging_fixture!()
      dirty_packaging_fixture!(fixture, dirty_input)

      {output, status} = run_packaging_fixture(fixture)

      refute status == 0, "#{dirty_input} input unexpectedly passed:\n#{output}"
      assert output =~ "Uncommitted or untracked build inputs detected"
      refute File.exists?(Path.join(fixture, ".git/mix.log"))
    end
  end

  test "only the known generated static gzip is excluded from source inputs" do
    fixture = create_packaging_fixture!()

    generated_gzip =
      Path.join(fixture, "apps/orchard_controller/priv/static/images/orchard-mark.svg.gz")

    File.mkdir_p!(Path.dirname(generated_gzip))
    File.write!(generated_gzip, "generated gzip\n")

    {output, status} = run_packaging_fixture(fixture)

    refute status == 0, output
    refute output =~ "Uncommitted or untracked build inputs detected"
    refute output =~ "Build inputs changed during package construction"
    assert File.exists?(Path.join(fixture, ".git/mix.log"))

    unexpected_fixture = create_packaging_fixture!()

    unexpected_gzip =
      Path.join(unexpected_fixture, "apps/orchard_controller/priv/static/images/operator.css.gz")

    File.mkdir_p!(Path.dirname(unexpected_gzip))
    File.write!(unexpected_gzip, "unexpected gzip\n")

    {unexpected_output, unexpected_status} = run_packaging_fixture(unexpected_fixture)

    refute unexpected_status == 0, unexpected_output
    assert unexpected_output =~ "Uncommitted or untracked build inputs detected"
    refute File.exists?(Path.join(unexpected_fixture, ".git/mix.log"))
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

  test "package runbook identifies all three abbreviated presentation surfaces" do
    readme = File.read!(@pkg_readme)

    assert readme =~ "Three surfaces present an abbreviated form"
    assert readme =~ "Sentry release names use a seven-character suffix"
    assert readme =~ "Console sidebar appends seven characters"
    assert readme =~ "PKG filename"
  end

  test "package runbook describes source exposure as deterrence only" do
    readme = File.read!(@pkg_readme)

    assert readme =~ "bytecode/deterrence"
    assert readme =~ "does not provide compiled source protection"
    assert readme =~ "duplicate native helper source trees are not staged"
    refute readme =~ "accepted source exposure risk"
  end

  defp create_packaging_fixture! do
    fixture =
      Path.join(
        System.tmp_dir!(),
        "orchard-package-preflight-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(fixture, "scripts"))
    File.cp!(@script_path, Path.join(fixture, "scripts/build-pkg.sh"))
    File.write!(Path.join(fixture, "mix.exs"), "# package preflight fixture\n")

    fake_bin = Path.join(fixture, "fake-bin")
    File.mkdir_p!(fake_bin)

    File.write!(Path.join(fake_bin, "mix"), """
    #!/bin/bash
    mkdir -p "$(dirname "$FAKE_MIX_LOG")"
    printf 'sha=%s args=%s\\n' "$ORCHARD_BUILD_SHA" "$*" >> "$FAKE_MIX_LOG"
    if [[ "${ORCHARD_FAKE_ADVANCE_HEAD:-0}" == "1" ]]; then
      printf '# changed during build\\n' >> mix.exs
      git add mix.exs
      git -c user.name='Orchard Test' -c user.email='orchard-test@invalid' commit -m 'advance during build' >/dev/null
    fi
    printf '0.5.0-dev\\n'
    """)

    File.chmod!(Path.join(fake_bin, "mix"), 0o755)
    git!(fixture, ["init", "--quiet"])
    git!(fixture, ["add", "."])
    git!(fixture, ["commit", "-m", "package fixture"])

    on_exit(fn -> File.rm_rf!(fixture) end)
    fixture
  end

  defp run_packaging_fixture(fixture, opts \\ []) do
    env = [
      {"FAKE_MIX_LOG", Path.join(fixture, ".git/mix.log")},
      {"ORCHARD_FAKE_ADVANCE_HEAD", if(Keyword.get(opts, :advance_head), do: "1", else: "0")},
      {"PATH", Path.join(fixture, "fake-bin") <> ":" <> System.fetch_env!("PATH")}
    ]

    System.cmd(
      "/bin/bash",
      [Path.join(fixture, "scripts/build-pkg.sh"), Path.join(fixture, "out")],
      cd: fixture,
      env: env,
      stderr_to_stdout: true
    )
  end

  defp dirty_packaging_fixture!(fixture, :tracked) do
    File.write!(Path.join(fixture, "mix.exs"), "# tracked change\n", [:append])
  end

  defp dirty_packaging_fixture!(fixture, :staged) do
    dirty_packaging_fixture!(fixture, :tracked)
    git!(fixture, ["add", "mix.exs"])
  end

  defp dirty_packaging_fixture!(fixture, :untracked) do
    File.mkdir_p!(Path.join(fixture, "packaging"))
    File.write!(Path.join(fixture, "packaging/new-input"), "untracked package input\n")
  end

  defp git!(fixture, args) do
    {output, status} =
      System.cmd(
        "git",
        ["-c", "user.name=Orchard Test", "-c", "user.email=orchard-test@invalid" | args],
        cd: fixture,
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.trim(output)
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
