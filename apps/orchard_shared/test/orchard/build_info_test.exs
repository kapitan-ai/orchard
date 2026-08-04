defmodule Orchard.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Orchard.BuildInfo

  @build_info_source Path.expand("../../lib/orchard/build_info.ex", __DIR__)

  test "git_sha returns a non-empty string" do
    sha = BuildInfo.git_sha()
    assert is_binary(sha)
    assert sha != ""
  end

  # SPEC.md §13.1: Build Provenance uses the full source commit, with no
  # abbreviated form retained for source builds.
  test "git_sha is a full 40-character commit or 'unknown'" do
    sha = BuildInfo.git_sha()
    assert sha == "unknown" or sha =~ ~r/^[0-9a-f]{40}$/
  end

  # SPEC.md §13.1: an explicit Build Provenance override is either a full lowercase
  # source commit or a compile-time error; it never degrades to "unknown".
  test "explicit build SHA accepts only a lowercase 40-character commit" do
    fixture = create_fixture!()
    counter = Path.join(fixture, "compile-counter")
    valid_sha = "abcdef0123456789abcdef0123456789abcdef01"

    for invalid <- [
          "",
          "   ",
          " #{valid_sha}",
          "#{valid_sha}\n",
          "abcdef0",
          String.upcase(valid_sha),
          String.replace(valid_sha, "a", "g")
        ] do
      output = compile_failure!(fixture, counter, sha: invalid)
      assert output =~ "ORCHARD_BUILD_SHA must be a 40-character lowercase Git commit"
    end

    compile!(fixture, counter, sha: valid_sha)
    assert baked_info!(fixture, counter, sha: valid_sha).git_sha == valid_sha
  end

  test "absent provenance resolves to unknown only when Git metadata is unavailable" do
    fixture = create_fixture!()
    counter = Path.join(fixture, "compile-counter")

    File.rm_rf!(Path.join(fixture, ".git"))
    compile!(fixture, counter)
    assert baked_info!(fixture, counter).git_sha == "unknown"

    {_output, _status} = mix(fixture, counter, [], ["clean"])
    git!(fixture, ["init", "--quiet"])
    git!(fixture, ["add", "."])
    git!(fixture, ["commit", "-m", "restored repository"])

    path_without_git = toolchain_path_without_git!(fixture)
    compile!(fixture, counter, path: path_without_git)
    assert baked_info!(fixture, counter, path: path_without_git).git_sha == "unknown"
  end

  test "invalid Git-derived provenance fails compilation" do
    fixture = create_fixture!()
    counter = Path.join(fixture, "compile-counter")
    fake_bin = Path.join(fixture, "fake-bin")
    File.mkdir_p!(fake_bin)

    fake_git = Path.join(fake_bin, "git")
    path = fake_bin <> ":" <> System.fetch_env!("PATH")

    for invalid <- [
          "",
          "   ",
          "abcdef0",
          "gbcdef0123456789abcdef0123456789abcdef01",
          "ABCDEF0123456789ABCDEF0123456789ABCDEF01"
        ] do
      File.write!(fake_git, "#!/bin/sh\nprintf '%s\\n' '#{invalid}'\n")
      File.chmod!(fake_git, 0o755)

      output = compile_failure!(fixture, counter, path: path)
      assert output =~ "Git-derived build provenance must be a 40-character lowercase Git commit"
    end
  end

  test "effective provenance changes recompile without rebuilding unrelated modules" do
    fixture = create_fixture!()
    counter = Path.join(fixture, "compile-counter")
    first_sha = git!(fixture, ["rev-parse", "HEAD"])

    git!(fixture, ["commit", "--allow-empty", "-m", "second build identity"])
    second_sha = git!(fixture, ["rev-parse", "HEAD"])
    refute second_sha == first_sha
    git!(fixture, ["checkout", "--quiet", "--detach", first_sha])

    compile!(fixture, counter, sha: first_sha)
    assert baked_info!(fixture, counter, sha: first_sha).git_sha == first_sha
    assert File.read!(counter) == "compiled\n"
    assert File.dir?(Path.join(fixture, "_build/dev"))

    compile!(fixture, counter, sha: second_sha)
    assert baked_info!(fixture, counter, sha: second_sha).git_sha == second_sha
    assert File.read!(counter) == "compiled\n"

    compile!(fixture, counter)
    assert baked_info!(fixture, counter).git_sha == first_sha
    assert File.read!(counter) == "compiled\n"

    git!(fixture, ["checkout", "--quiet", "--detach", second_sha])
    compile!(fixture, counter)
    assert baked_info!(fixture, counter).git_sha == second_sha
    assert File.read!(counter) == "compiled\n"
  end

  test "Git availability and effective channel changes recompile only build metadata" do
    fixture = create_fixture!()
    counter = Path.join(fixture, "compile-counter")
    sha = git!(fixture, ["rev-parse", "HEAD"])

    compile!(fixture, counter, sha: sha, channel: " internal ")

    assert baked_info!(fixture, counter, sha: sha, channel: "internal").build_channel ==
             "internal"

    assert File.read!(counter) == "compiled\n"

    unchanged_output = compile!(fixture, counter, sha: sha, channel: "internal")
    refute unchanged_output =~ "Compiling"
    assert File.read!(counter) == "compiled\n"

    changed_channel_output = compile!(fixture, counter, sha: sha, channel: "pilot")
    assert changed_channel_output =~ "Compiling 1 file"
    assert baked_info!(fixture, counter, sha: sha, channel: "pilot").build_channel == "pilot"
    assert File.read!(counter) == "compiled\n"

    available_git_output = compile!(fixture, counter)
    assert available_git_output =~ "Compiling 1 file"
    assert baked_info!(fixture, counter).git_sha == sha
    assert baked_info!(fixture, counter).build_channel == "dev"

    defaulted_channel_output = compile!(fixture, counter, channel: "   ")
    refute defaulted_channel_output =~ "Compiling"

    path_without_git = toolchain_path_without_git!(fixture)
    unavailable_git_output = compile!(fixture, counter, path: path_without_git)
    assert unavailable_git_output =~ "Compiling 1 file"
    assert baked_info!(fixture, counter, path: path_without_git).git_sha == "unknown"
    assert File.read!(counter) == "compiled\n"
  end

  test "build_date is the current UTC ISO date" do
    date = BuildInfo.build_date()
    assert date == Date.utc_today() |> Date.to_iso8601()
  end

  test "build_channel returns a non-empty trimmed string" do
    channel = BuildInfo.build_channel()

    assert is_binary(channel)
    assert channel != ""
    assert channel == String.trim(channel)
  end

  defp create_fixture! do
    fixture =
      Path.join(
        System.tmp_dir!(),
        "orchard-build-info-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(Path.join(fixture, "lib/orchard"))
    File.cp!(@build_info_source, Path.join(fixture, "lib/orchard/build_info.ex"))

    File.write!(Path.join(fixture, "mix.exs"), """
    defmodule BuildInfoFixture.MixProject do
      use Mix.Project

      def project, do: [app: :build_info_fixture, version: "0.1.0", elixir: "~> 1.18"]
    end
    """)

    File.write!(Path.join(fixture, "lib/unrelated.ex"), """
    defmodule BuildInfoFixture.Unrelated do
      File.write!(System.fetch_env!("ORCHARD_COMPILE_COUNTER"), "compiled\\n", [:append])
    end
    """)

    git!(fixture, ["init", "--quiet"])
    git!(fixture, ["add", "."])
    git!(fixture, ["commit", "-m", "fixture"])

    on_exit(fn -> File.rm_rf!(fixture) end)
    fixture
  end

  defp compile!(fixture, counter, opts \\ []) do
    {output, status} = mix(fixture, counter, opts, ["compile"])
    assert status == 0, output
    output
  end

  defp compile_failure!(fixture, counter, opts) do
    {_output, _status} = mix(fixture, counter, [], ["clean"])
    {output, status} = mix(fixture, counter, opts, ["compile"])
    refute status == 0, "#{inspect(opts)} unexpectedly compiled:\n#{output}"
    output
  end

  defp baked_info!(fixture, counter, opts \\ []) do
    {output, status} =
      mix(fixture, counter, opts, [
        "run",
        "--no-start",
        "--no-compile",
        "-e",
        "IO.write(Enum.join([Orchard.BuildInfo.git_sha(), Orchard.BuildInfo.build_date(), Orchard.BuildInfo.build_channel()], \"|\"))"
      ])

    assert status == 0, output
    [git_sha, build_date, build_channel] = output |> String.trim() |> String.split("|")
    %{git_sha: git_sha, build_date: build_date, build_channel: build_channel}
  end

  defp mix(fixture, counter, opts, args) do
    env_args =
      [
        "-u",
        "ORCHARD_BUILD_SHA",
        "-u",
        "ORCHARD_BUILD_CHANNEL",
        "MIX_ENV=dev",
        "ORCHARD_COMPILE_COUNTER=#{counter}"
      ]
      |> maybe_assign("ORCHARD_BUILD_SHA", opts, :sha)
      |> maybe_assign("ORCHARD_BUILD_CHANNEL", opts, :channel)
      |> maybe_assign("PATH", opts, :path)

    System.cmd("/usr/bin/env", env_args ++ [System.find_executable("mix") | args],
      cd: fixture,
      stderr_to_stdout: true
    )
  end

  defp maybe_assign(args, name, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> args ++ ["#{name}=#{value}"]
      :error -> args
    end
  end

  defp toolchain_path_without_git!(fixture) do
    bin = Path.join(fixture, "toolchain-without-git")
    File.mkdir_p!(bin)

    for command <- ~w(mix elixir erl dirname basename readlink cut sed mkdir) do
      File.ln_s!(System.find_executable(command), Path.join(bin, command))
    end

    bin
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
end
