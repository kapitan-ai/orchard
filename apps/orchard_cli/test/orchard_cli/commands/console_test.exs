defmodule OrchardCLI.Commands.ConsoleTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Console

  defp tmp_support_root do
    System.tmp_dir!()
    |> Path.join("orchard-console-test-#{System.unique_integer([:positive])}")
  end

  defp base_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        read_install_role: fn -> {:ok, "all"} end,
        tty?: fn -> true end,
        prompt: fn _prompt, _opts -> flunk("unexpected prompt") end,
        cmd: fn
          "launchctl", ["print", "system/com.orchard.controller"], _opts ->
            {"Could not find service", 113}

          _program, _args, _opts ->
            flunk("unexpected command invocation")
        end
      },
      overrides
    )
  end

  defp prompt_runtime(inputs, overrides) do
    parent = self()
    {:ok, agent} = Agent.start(fn -> inputs end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    base_runtime(
      Map.merge(
        %{
          prompt: fn prompt, opts ->
            send(parent, {:prompt, prompt, opts})

            Agent.get_and_update(agent, fn
              [next | rest] -> {{:ok, next}, rest}
              [] -> flunk("prompt requested more values than the test supplied")
            end)
          end
        },
        overrides
      )
    )
  end

  test "help and group usage describe console subcommands" do
    assert {:ok, message} = Console.run(["--help"], base_runtime())
    assert message =~ "orchardctl console <command>"
    assert message =~ "enable"
    assert message =~ "disable"
    assert message =~ "rotate"

    assert {:ok, message} = Console.run(["enable", "--help"], base_runtime())
    assert message =~ "orchardctl console enable"
    assert message =~ "interactive TTY"

    assert {:error, message, 1} = Console.run([], base_runtime())
    assert message =~ "orchardctl console <command>"

    assert {:error, message, 1} = Console.run(["bogus"], base_runtime())
    assert message =~ "enable|disable|rotate"
  end

  test "credential commands reject flags and argv credentials before prompting" do
    parent = self()

    runtime =
      base_runtime(%{
        prompt: fn _prompt, _opts ->
          send(parent, :prompted)
          {:ok, "should-not-be-read"}
        end
      })

    for args <- [
          ["enable", "operator"],
          ["enable", "--username", "operator"],
          ["enable", "--password", "secret"],
          ["enable", "--super-secret-token"],
          ["rotate", "operator"],
          ["rotate", "--password", "secret"],
          ["rotate", "--password=secret"]
        ] do
      assert {:error, message, 1} = Console.run(args, runtime)
      assert message =~ "orchardctl console"
      refute message =~ "operator"
      refute message =~ "secret"
      refute message =~ "super-secret-token"
    end

    refute_received :prompted
  end

  test "enable and rotate require root before TTY or prompts" do
    parent = self()

    runtime =
      base_runtime(%{
        uid: fn -> 501 end,
        tty?: fn ->
          send(parent, :tty_checked)
          true
        end,
        prompt: fn _prompt, _opts ->
          send(parent, :prompted)
          {:ok, "should-not-be-read"}
        end
      })

    for command <- ["enable", "rotate"] do
      assert {:error, message, 1} = Console.run([command], runtime)
      assert message =~ "root privileges required"
      assert message =~ "sudo orchardctl console #{command}"
    end

    refute_received :tty_checked
    refute_received :prompted
  end

  test "enable and rotate require an interactive TTY before prompts" do
    parent = self()

    runtime =
      base_runtime(%{
        tty?: fn -> false end,
        prompt: fn _prompt, _opts ->
          send(parent, :prompted)
          {:ok, "should-not-be-read"}
        end
      })

    for command <- ["enable", "rotate"] do
      assert {:error, message, 1} = Console.run([command], runtime)
      assert message =~ "interactive TTY required"
      assert message =~ "sudo orchardctl console #{command}"
    end

    refute_received :prompted
  end

  test "enable aborts before reading password when no-echo setup fails" do
    support_root = tmp_support_root()
    parent = self()

    runtime =
      prompt_runtime(["operator"], %{
        support_root: support_root,
        prompt: fn prompt, opts ->
          send(parent, {:prompt, prompt, opts})

          case prompt do
            "Console username: " ->
              {:ok, "operator"}

            "Console password: " ->
              {:error, "could not disable terminal echo; refusing to read secret input"}

            other ->
              flunk("unexpected prompt: #{inspect(other)}")
          end
        end
      })

    try do
      assert {:error, message, 1} = Console.run(["enable"], runtime)
      assert message =~ "could not disable terminal echo"
      refute File.exists?(Path.join([support_root, "config", "console.env"]))
      assert_received {:prompt, "Console username: ", _opts}
      assert_received {:prompt, "Console password: ", opts}
      assert Keyword.fetch!(opts, :echo) == false
      refute_received {:prompt, "Confirm console password: ", _opts}
    after
      File.rm_rf(support_root)
    end
  end

  test "enable writes only console keys with mode 0600 and start guidance without leaking credentials" do
    support_root = tmp_support_root()
    username = ~s(operator$admin)
    password = ~s(super-secret-console-password)

    runtime =
      prompt_runtime([username, password, password], %{
        support_root: support_root
      })

    try do
      assert {:ok, message} = Console.run(["enable"], runtime)

      assert_received {:prompt, "Console username: ", opts}
      assert Keyword.get(opts, :echo, true) == true
      assert_received {:prompt, "Console password: ", opts}
      assert Keyword.fetch!(opts, :echo) == false
      assert_received {:prompt, "Confirm console password: ", opts}
      assert Keyword.fetch!(opts, :echo) == false

      console_env = Path.join([support_root, "config", "console.env"])
      contents = File.read!(console_env)
      assert Bitwise.band(File.stat!(console_env).mode, 0o777) == 0o600
      assert contents =~ ~r/^ORCHARD_CONSOLE_ENABLED="true"$/m
      assert contents =~ ~r/^ORCHARD_CONSOLE_USERNAME=/m
      assert contents =~ ~r/^ORCHARD_CONSOLE_PASSWORD=/m
      assert length(String.split(String.trim(contents), "\n")) == 3

      assert message =~ "Console enabled."
      assert message =~ "Run: sudo orchardctl start"
      refute message =~ username
      refute message =~ password
    after
      File.rm_rf(support_root)
    end
  end

  test "rotate restarts only a loaded controller and does not leak credentials" do
    support_root = tmp_support_root()
    parent = self()
    username = "operator"
    password = "rotated-secret"

    runtime =
      prompt_runtime([username, password, password], %{
        support_root: support_root,
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})

          case args do
            ["print", "system/com.orchard.controller"] -> {"{ pid = 123 }", 0}
            ["kickstart", "-k", "system/com.orchard.controller"] -> {"", 0}
            unexpected -> flunk("unexpected launchctl args: #{inspect(unexpected)}")
          end
        end
      })

    try do
      assert {:ok, message} = Console.run(["rotate"], runtime)

      assert message =~ "Console credentials rotated."
      assert message =~ "Controller restarted."
      refute message =~ username
      refute message =~ password

      cmds = collect_cmds()

      assert [
               {"launchctl", ["print", "system/com.orchard.controller"], _print_opts},
               {"launchctl", ["kickstart", "-k", "system/com.orchard.controller"], _kick_opts}
             ] = cmds

      refute Enum.any?(cmds, fn {_program, args, _opts} ->
               Enum.any?(args, &String.contains?(&1, "node-agent"))
             end)
    after
      File.rm_rf(support_root)
    end
  end

  test "password confirmation mismatch leaves console env absent and does not leak either value" do
    support_root = tmp_support_root()
    username = "operator"
    password = "first-secret"
    confirmation = "second-secret"

    runtime = prompt_runtime([username, password, confirmation], %{support_root: support_root})

    try do
      assert {:error, message, 1} = Console.run(["enable"], runtime)
      assert message =~ "confirmation did not match"
      refute message =~ username
      refute message =~ password
      refute message =~ confirmation
      refute File.exists?(Path.join([support_root, "config", "console.env"]))
    after
      File.rm_rf(support_root)
    end
  end

  test "blank usernames and passwords are rejected before writing" do
    support_root = tmp_support_root()

    try do
      cases = [
        {"blank username", [" ", "password", "password"]},
        {"blank password", ["operator", "", ""]}
      ]

      for {_label, inputs} <- cases do
        runtime = prompt_runtime(inputs, %{support_root: support_root})

        assert {:error, message, 1} = Console.run(["enable"], runtime)
        assert message =~ "must not be blank"
        refute File.exists?(Path.join([support_root, "config", "console.env"]))
      end
    after
      File.rm_rf(support_root)
    end
  end

  test "control characters in username or password are rejected without writing or leaking values" do
    support_root = tmp_support_root()

    try do
      cases = [
        {"bad\nuser", "password", "password"},
        {"operator", "bad\0password", "bad\0password"},
        {"operator", <<"bad", 0x7F, "password">>, <<"bad", 0x7F, "password">>}
      ]

      for {username, password, confirmation} <- cases do
        runtime =
          prompt_runtime([username, password, confirmation], %{support_root: support_root})

        assert {:error, message, 1} = Console.run(["enable"], runtime)
        assert message =~ "control characters"
        refute message =~ username
        refute message =~ password
        refute File.exists?(Path.join([support_root, "config", "console.env"]))
      end
    after
      File.rm_rf(support_root)
    end
  end

  test "shell metacharacters round-trip through /bin/sh without execution" do
    support_root = tmp_support_root()
    marker_path = Path.join(support_root, "executed")
    username = ~s(operator # '$HOME' "quoted" `touch #{marker_path}` \\ end)
    password = ~s(secret # '$HOME' "quoted" `touch #{marker_path}` \\ end)

    runtime = prompt_runtime([username, password, password], %{support_root: support_root})

    try do
      assert {:ok, message} = Console.run(["enable"], runtime)
      refute message =~ username
      refute message =~ password

      console_env = Path.join([support_root, "config", "console.env"])

      script =
        "set -a; . \"$1\"; printf '%s\\n%s' \"$ORCHARD_CONSOLE_USERNAME\" \"$ORCHARD_CONSOLE_PASSWORD\""

      assert {output, 0} = System.cmd("/bin/sh", ["-c", script, "sh", console_env])
      assert output == username <> "\n" <> password
      refute File.exists?(marker_path)
    after
      File.rm_rf(support_root)
    end
  end

  test "disable writes only disabled flag with mode 0600 and removes credentials" do
    support_root = tmp_support_root()
    console_env = Path.join([support_root, "config", "console.env"])
    File.mkdir_p!(Path.dirname(console_env))

    File.write!(
      console_env,
      "ORCHARD_CONSOLE_ENABLED=\"true\"\nORCHARD_CONSOLE_USERNAME=\"operator\"\nORCHARD_CONSOLE_PASSWORD=\"old-secret\"\n"
    )

    runtime = base_runtime(%{support_root: support_root})

    try do
      assert {:ok, message} = Console.run(["disable"], runtime)

      contents = File.read!(console_env)
      assert contents == "ORCHARD_CONSOLE_ENABLED=\"false\"\n"
      assert Bitwise.band(File.stat!(console_env).mode, 0o777) == 0o600
      refute contents =~ "ORCHARD_CONSOLE_USERNAME"
      refute contents =~ "ORCHARD_CONSOLE_PASSWORD"
      assert message =~ "Console disabled."
      assert message =~ "Run: sudo orchardctl start"
      refute message =~ "operator"
      refute message =~ "old-secret"
    after
      File.rm_rf(support_root)
    end
  end

  test "node-agent role is not applicable and does not write console env" do
    support_root = tmp_support_root()

    runtime =
      base_runtime(%{
        support_root: support_root,
        read_install_role: fn -> {:ok, "node-agent"} end,
        uid: fn -> 501 end
      })

    try do
      assert {:ok, message} = Console.run(["disable"], runtime)
      assert message =~ "not applicable for node-agent role"
      refute File.exists?(Path.join([support_root, "config", "console.env"]))
    after
      File.rm_rf(support_root)
    end
  end

  defp collect_cmds do
    collect_cmds([])
  end

  defp collect_cmds(acc) do
    receive do
      {:cmd, program, args, opts} -> collect_cmds([{program, args, opts} | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
