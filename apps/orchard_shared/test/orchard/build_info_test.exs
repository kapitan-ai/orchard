defmodule Orchard.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Orchard.BuildInfo

  @build_info_source Path.expand("../../lib/orchard/build_info.ex", __DIR__)

  test "git_sha returns a non-empty string" do
    sha = BuildInfo.git_sha()
    assert is_binary(sha)
    assert sha != ""
  end

  test "effective provenance changes recompile without rebuilding unrelated modules" do
    fixture = create_fixture!()
    counter = Path.join(fixture, "compile-counter")
    first_sha = git!(fixture, ["rev-parse", "HEAD"])

    git!(fixture, ["commit", "--allow-empty", "-m", "second build identity"])
    second_sha = git!(fixture, ["rev-parse", "HEAD"])
    refute second_sha == first_sha
    git!(fixture, ["checkout", "--quiet", "--detach", first_sha])

    compile!(fixture, counter, first_sha)
    assert baked_sha!(fixture, counter, first_sha) == first_sha
    assert File.read!(counter) == "compiled\n"
    assert File.dir?(Path.join(fixture, "_build/dev"))

    compile!(fixture, counter, second_sha)
    assert baked_sha!(fixture, counter, second_sha) == second_sha
    assert File.read!(counter) == "compiled\n"

    compile!(fixture, counter, nil)
    assert baked_sha!(fixture, counter, nil) == String.slice(first_sha, 0, 7)
    assert File.read!(counter) == "compiled\n"

    git!(fixture, ["checkout", "--quiet", "--detach", second_sha])
    compile!(fixture, counter, nil)
    assert baked_sha!(fixture, counter, nil) == String.slice(second_sha, 0, 7)
    assert File.read!(counter) == "compiled\n"
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

  defp compile!(fixture, counter, sha) do
    mix!(fixture, counter, sha, ["compile"])
  end

  defp baked_sha!(fixture, counter, sha) do
    fixture
    |> mix!(counter, sha, [
      "run",
      "--no-start",
      "--no-compile",
      "-e",
      "IO.write(Orchard.BuildInfo.git_sha())"
    ])
    |> String.trim()
  end

  defp mix!(fixture, counter, sha, args) do
    {output, status} =
      System.cmd("mix", args,
        cd: fixture,
        env: [
          {"MIX_ENV", "dev"},
          {"ORCHARD_BUILD_SHA", sha},
          {"ORCHARD_COMPILE_COUNTER", counter}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    output
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
