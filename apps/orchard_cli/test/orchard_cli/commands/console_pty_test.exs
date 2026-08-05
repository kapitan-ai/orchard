defmodule OrchardCLI.Commands.ConsolePTYTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  @harness_source Path.expand("../../support/console_pty_harness.c", __DIR__)

  setup_all do
    if :os.type() == {:unix, :darwin} do
      root =
        Path.join(
          System.tmp_dir!(),
          "orchard-console-pty-harness-#{System.unique_integer([:positive])}"
        )

      harness = Path.join(root, "console-pty-harness")
      File.mkdir_p!(root)

      {output, status} =
        System.cmd(
          "xcrun",
          ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", @harness_source, "-o", harness],
          stderr_to_stdout: true
        )

      assert status == 0, "could not compile Console PTY harness: #{output}"

      on_exit(fn -> File.rm_rf(root) end)
      {:ok, harness: harness}
    else
      {:ok, harness: nil}
    end
  end

  test "fast pasted username and password stay secret through the real PTY", %{harness: harness} do
    with_macos_harness(harness, "pasted-success", "enable", fn support_root, marker ->
      assert File.exists?(Path.join([support_root, "config", "console.env"]))
      assert File.exists?(marker)
    end)
  end

  test "credential entry can pause longer than the guard protocol timeout", %{harness: harness} do
    with_macos_harness(harness, "delayed-success", "enable", fn support_root, marker ->
      assert File.exists?(Path.join([support_root, "config", "console.env"]))
      assert File.exists?(marker)
    end)
  end

  test "owner exit restores the terminal and reaps the guard reader", %{harness: harness} do
    with_macos_harness(harness, "owner-exit", "enable", &assert_aborted/2)
  end

  test "EOF restores the exact state without persistence or restart", %{harness: harness} do
    with_macos_harness(harness, "eof", "enable", &assert_aborted/2)
  end

  test "callback exceptions restore the exact state without side effects", %{harness: harness} do
    with_macos_harness(harness, "exception", "exception", &assert_aborted/2)
  end

  test "failed no-echo setup renders no prompt and never enters the callback", %{harness: harness} do
    with_macos_harness(harness, "setup-failure", "setup-failure", &assert_aborted/2)
  end

  test "interruption restores on owner exit without premature guard restoration", %{
    harness: harness
  } do
    with_macos_harness(harness, "interruption", "enable", &assert_aborted/2)
  end

  defp with_macos_harness(nil, _scenario, _action, _assertions) do
    IO.puts("Console PTY regression is macOS-only")
  end

  defp with_macos_harness(harness, scenario, action, assertions) do
    support_root = temp_support_root()
    side_effect_marker = Path.join(support_root, "launchctl-invoked")
    File.mkdir_p!(support_root)

    on_exit(fn -> File.rm_rf(support_root) end)

    {output, status} =
      System.cmd(
        harness,
        [scenario, "--" | source_child_command(action, support_root, side_effect_marker)],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output == "console PTY ok: #{scenario}\n"
    assertions.(support_root, side_effect_marker)
  end

  defp assert_aborted(support_root, side_effect_marker) do
    refute File.exists?(Path.join([support_root, "config", "console.env"]))
    refute File.exists?(side_effect_marker)
  end

  defp source_child_command(action, support_root, side_effect_marker) do
    code_paths =
      Path.wildcard(Path.expand("../../../../../_build/test/lib/*/ebin", __DIR__))
      |> Enum.flat_map(&["-pa", &1])

    [System.find_executable("elixir") | code_paths] ++
      [
        "-e",
        "OrchardCLI.ConsolePTYProcess.main(System.argv())",
        "--",
        action,
        support_root,
        side_effect_marker
      ]
  end

  defp temp_support_root do
    Path.join(
      System.tmp_dir!(),
      "orchard-console-pty-test-#{System.unique_integer([:positive])}"
    )
  end
end
