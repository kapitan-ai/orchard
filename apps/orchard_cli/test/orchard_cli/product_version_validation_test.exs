defmodule OrchardCLI.ProductVersionValidationTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)
  @mix_project_files [
    "mix.exs",
    "apps/orchard_cli/mix.exs",
    "apps/orchard_controller/mix.exs",
    "apps/orchard_node_agent/mix.exs",
    "apps/orchard_shared/mix.exs"
  ]

  test "canonical source preserves the current Product Version bytes" do
    assert File.read!(Path.join(@repo_root, "VERSION")) == "0.5.0-dev\n"
  end

  test "public validation accepts the development version without creating release state" do
    status_before = git_status()

    assert {output, 0} =
             System.cmd("make", ["validate-product-version"],
               cd: @repo_root,
               stderr_to_stdout: true
             )

    assert output =~
             "Product Version validation passed: 0.5.0-dev; 5 Mix project surfaces agree"

    assert git_status() == status_before
  end

  test "public validation rejects malformed canonical bytes without rewriting them" do
    malformed_versions = [
      "0.5.0-dev",
      "0.5.0-dev\n\n",
      " 0.5.0-dev\n",
      "0.5.0-dev \n",
      "0.5.0-dev # current\n",
      "0.5.0-dev+build.1\n",
      "1.0.0-dev\n",
      "not-semver\n",
      "0.5.0-dév\n"
    ]

    Enum.each(malformed_versions, fn malformed_version ->
      fixture_root = fixture_root!()
      version_path = Path.join(fixture_root, "VERSION")
      File.write!(version_path, malformed_version)

      assert {output, status} = run_validation(fixture_root)
      assert status != 0

      assert output =~
               "Product Version validation failed: VERSION must contain exactly one " <>
                 "ASCII SemVer line followed by one terminal newline"

      assert File.read!(version_path) == malformed_version
    end)
  end

  test "all first-party Mix consumers derive from the canonical authority" do
    fixture_root = fixture_root!()
    File.write!(Path.join(fixture_root, "VERSION"), "0.5.1-dev\n")

    assert {output, 0} =
             System.cmd("make", ["validate-product-version"],
               cd: fixture_root,
               stderr_to_stdout: true
             )

    assert output =~
             "Product Version validation passed: 0.5.1-dev; 5 Mix project surfaces agree"
  end

  test "public validation rejects intentional drift in every first-party Mix surface" do
    Enum.each(@mix_project_files, fn relative_path ->
      fixture_root = fixture_root!()
      project_path = Path.join(fixture_root, relative_path)

      drifted_project =
        project_path
        |> File.read!()
        |> String.replace(
          "version: Orchard.ProductVersion.read!()",
          "version: \"0.5.1-dev\"",
          global: false
        )

      File.write!(project_path, drifted_project)

      assert {output, status} = run_validation(fixture_root)
      assert status != 0
      assert output =~ "#{relative_path} reports \"0.5.1-dev\""
      assert output =~ "VERSION is \"0.5.0-dev\""
      assert File.read!(project_path) == drifted_project
    end)
  end

  defp git_status do
    {status, 0} = System.cmd("git", ["status", "--short"], cd: @repo_root)
    status
  end

  defp run_validation(fixture_root) do
    System.cmd("make", ["validate-product-version"],
      cd: fixture_root,
      stderr_to_stdout: true
    )
  end

  defp fixture_root! do
    fixture_root =
      Path.join(
        System.tmp_dir!(),
        "orchard-product-version-#{System.unique_integer([:positive, :monotonic])}"
      )

    on_exit(fn -> File.rm_rf!(fixture_root) end)

    Enum.each(fixture_files(), fn relative_path ->
      source = Path.join(@repo_root, relative_path)
      destination = Path.join(fixture_root, relative_path)
      File.mkdir_p!(Path.dirname(destination))
      File.cp!(source, destination)
    end)

    fixture_root
  end

  defp fixture_files do
    [
      "Makefile",
      "VERSION",
      "config/product_version.exs",
      "scripts/validate-product-version.exs"
    ] ++ @mix_project_files
  end
end
