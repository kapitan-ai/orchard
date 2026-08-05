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
          [
            "clang",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            @harness_source,
            "-o",
            harness
          ],
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

  test "direct SecretTTY use fails closed without restoration custody", %{harness: harness} do
    with_macos_harness(harness, "unwrapped", "enable", &assert_aborted/2)
  end

  @tag secret_tty_case: :invalid_username_paste
  test "invalid username paste cannot reach the resumed parent shell", %{harness: harness} do
    with_macos_harness(harness, "invalid-username-paste", "enable", &assert_aborted/2)
  end

  test "backpressured invalid paste cannot cross the restore handoff", %{harness: harness} do
    with_macos_harness(
      harness,
      "invalid-username-backpressure",
      "enable",
      &assert_aborted/2
    )
  end

  test "paced invalid paste cannot outlive the restore handoff", %{harness: harness} do
    with_macos_harness(harness, "invalid-username-paced", "enable", &assert_aborted/2)
  end

  test "credential entry can pause longer than the guard protocol timeout", %{harness: harness} do
    with_macos_harness(harness, "delayed-success", "enable", fn support_root, marker ->
      assert File.exists?(Path.join([support_root, "config", "console.env"]))
      assert File.exists?(marker)
    end)
  end

  test "configured erase removes a complete UTF-8 character", %{harness: harness} do
    with_macos_harness(harness, "utf8-erase", "enable", fn support_root, marker ->
      assert File.exists?(Path.join([support_root, "config", "console.env"]))
      assert File.exists?(marker)
    end)
  end

  test "owner exit restores the terminal and reaps the guard reader", %{harness: harness} do
    with_macos_harness(harness, "owner-exit", "enable", &assert_aborted/2)
  end

  test "owner death cannot release a paced paste to the shell", %{harness: harness} do
    with_macos_harness(harness, "owner-exit-paced", "enable", &assert_aborted/2)
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

  test "post-protect setup failure restores before callback entry", %{harness: harness} do
    with_macos_harness(harness, "post-protect", "post-protect", &assert_aborted/2)
  end

  test "stalled watchdog handshake is killed and reaped without hanging", %{harness: harness} do
    with_macos_harness(
      harness,
      "watchdog-handshake",
      "watchdog-handshake",
      &assert_aborted/2
    )
  end

  test "watchdog stall after custody registration cannot strand active custody", %{
    harness: harness
  } do
    with_macos_harness(
      harness,
      "watchdog-custody-handshake",
      "watchdog-custody-handshake",
      &assert_aborted/2
    )
  end

  test "protected setup waits for paced input quiescence before returning", %{harness: harness} do
    with_macos_harness(
      harness,
      "watchdog-protected-handshake",
      "watchdog-protected-handshake",
      &assert_aborted/2
    )
  end

  test "emergency restorer survives parent death during protected handshake teardown", %{
    harness: harness
  } do
    with_macos_harness(
      harness,
      "restorer-parent-kill",
      "restorer-parent-kill",
      &assert_aborted/2
    )
  end

  test "emergency restorer stops the watchdog before restoring on early parent death", %{
    harness: harness
  } do
    with_macos_harness(
      harness,
      "restorer-pre-teardown-kill",
      "restorer-pre-teardown-kill",
      &assert_aborted/2
    )
  end

  test "emergency restorer retries unknown watchdog identity before restoration", %{
    harness: harness
  } do
    with_macos_harness(
      harness,
      "restorer-identity-retry",
      "restorer-identity-retry",
      &assert_aborted/2
    )
  end

  test "emergency signal setup failure falls back without deadlocking custody", %{
    harness: harness
  } do
    with_macos_harness(
      harness,
      "restorer-signal-setup",
      "restorer-signal-setup",
      &assert_aborted/2
    )
  end

  test "PTY harness waits for a complete fragmented process-exit record", %{harness: harness} do
    with_macos_harness(
      harness,
      "fragmented-record-self-test",
      "restorer-signal-setup",
      &assert_aborted/2
    )
  end

  test "helper death after custody publication cannot strand the foreground shell", %{
    harness: harness
  } do
    with_macos_harness(
      harness,
      "marker-pre-ready-kill",
      "marker-pre-ready-kill",
      &assert_aborted/2
    )
  end

  for signal <- ~w(int hup term kill) do
    @tag secret_tty_case: :helper_signal
    test "helper death under SIG#{String.upcase(signal)} restores without hanging", %{
      harness: harness
    } do
      signal = unquote(signal)
      scenario = "signal-#{signal}"
      with_macos_harness(harness, scenario, scenario, &assert_aborted/2)
    end
  end

  for point <- ~w(idle read) do
    @tag secret_tty_case: :watchdog_death
    test "watchdog death while #{point} falls back to exact restoration", %{harness: harness} do
      point = unquote(point)
      scenario = "watchdog-#{point}"
      with_macos_harness(harness, scenario, scenario, &assert_aborted/2)
    end
  end

  @tag secret_tty_case: :port_owner_death
  test "Port-owner death restores while the BEAM VM remains alive", %{harness: harness} do
    with_macos_harness(harness, "port-owner-exit", "port-owner-exit", &assert_aborted/2)
  end

  @tag secret_tty_case: :foreground_interrupt
  test "foreground Ctrl-C restores before the command exits", %{
    harness: harness
  } do
    with_macos_harness(harness, "interruption", "enable", &assert_aborted/2)
  end

  @tag secret_tty_case: :foreground_quit
  test "foreground Ctrl-backslash restores before the command exits", %{harness: harness} do
    with_macos_harness(harness, "quit", "enable", &assert_aborted/2)
  end

  @tag secret_tty_case: :foreground_stop
  test "foreground Ctrl-Z restores before stopping and aborts after resume", %{harness: harness} do
    with_macos_harness(harness, "stop", "enable", &assert_aborted/2)
  end

  test "backpressured paste cannot cross the Ctrl-Z restore handoff", %{harness: harness} do
    with_macos_harness(harness, "stop-backpressure", "enable", &assert_aborted/2)
  end

  test "paced paste cannot outlive the Ctrl-Z restore handoff", %{harness: harness} do
    with_macos_harness(harness, "stop-paced", "enable", &assert_aborted/2)
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
