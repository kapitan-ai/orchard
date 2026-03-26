defmodule OrchardCLI.Commands.EnvTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Env

  @moduletag :env

  defp test_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        hostname: fn -> {:ok, ~c"testhost"} end
      },
      overrides
    )
  end

  # Helper: create a support root with fake executables
  defp setup_support_root(tmp_dir) do
    support_root = Path.join(tmp_dir, "Application Support/Orchard")

    # Create tokenizer venv entrypoint
    tokenizer_venv = Path.join([support_root, "native", "orchard_tokenizer", ".venv", "bin"])
    File.mkdir_p!(tokenizer_venv)
    tokenizer_entry = Path.join(tokenizer_venv, "orchard-tokenizer")
    File.write!(tokenizer_entry, "#!/bin/sh\necho tokenizer")
    File.chmod!(tokenizer_entry, 0o755)

    # Create worker venv entrypoint
    worker_venv = Path.join([support_root, "native", "orchard_worker_mlx", ".venv", "bin"])
    File.mkdir_p!(worker_venv)
    worker_entry = Path.join(worker_venv, "orchard-worker-mlx")
    File.write!(worker_entry, "#!/bin/sh\necho worker")
    File.chmod!(worker_entry, 0o755)

    support_root
  end

  # ── Group Usage ─────────────────────────────────────────────────

  test "env without subcommand returns group usage" do
    assert {:error, message, 1} = Env.run([])
    assert message =~ "orchardctl env <command>"
    assert message =~ "init"
  end

  test "env help returns group usage with ok" do
    assert {:ok, message} = Env.run(["help"])
    assert message =~ "orchardctl env <command>"
  end

  test "env --help returns group usage with ok" do
    assert {:ok, message} = Env.run(["--help"])
    assert message =~ "orchardctl env <command>"
  end

  test "env unknown-command returns group usage" do
    assert {:error, message, 1} = Env.run(["unknown"])
    assert message =~ "orchardctl env <command>"
  end

  # ── Init Usage ──────────────────────────────────────────────────

  test "init --help returns init usage" do
    assert {:ok, message} = Env.run(["init", "--help"])
    assert message =~ "orchardctl env init"
    assert message =~ "--support-root"
    assert message =~ "--service"
    assert message =~ "--force"
  end

  test "init with unknown flag returns error" do
    assert {:error, message, 1} = Env.run(["init", "--bogus"])
    assert message =~ "unknown option"
  end

  test "init with positional args returns error" do
    assert {:error, message, 1} = Env.run(["init", "extra"])
    assert message =~ "unexpected argument"
  end

  test "init with invalid --service returns error" do
    assert {:error, message, 1} = Env.run(["init", "--service", "invalid"])
    assert message =~ "invalid --service value"
  end

  # ── Init Execution ───────────────────────────────────────────────

  test "init generates both env files in support root with spaces" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_test_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      assert {:ok, summary} =
               Env.run(
                 ["init", "--support-root", support_root],
                 test_runtime()
               )

      assert summary =~ "controller.env"
      assert summary =~ "node-agent.env"
      assert summary =~ "created"

      # Verify files exist
      controller_env = Path.join([support_root, "config", "controller.env"])
      node_agent_env = Path.join([support_root, "config", "node-agent.env"])
      assert File.regular?(controller_env)
      assert File.regular?(node_agent_env)

      # Verify content is properly quoted (support root has spaces)
      controller_content = File.read!(controller_env)
      assert controller_content =~ "ORCHARD_TOKENIZER_EXECUTABLE="
      assert controller_content =~ "Application Support"
      # The path with spaces must be inside double quotes
      assert controller_content =~
               ~r/ORCHARD_TOKENIZER_EXECUTABLE="[^"]*Application Support[^"]*"/

      node_agent_content = File.read!(node_agent_env)
      assert node_agent_content =~ "ORCHARD_WORKER_EXECUTABLE="
      assert node_agent_content =~ "ORCHARD_NODE_DISPLAY_NAME="
      assert node_agent_content =~ ~r/ORCHARD_WORKER_EXECUTABLE="[^"]*Application Support[^"]*"/

      # Verify file permissions (0600)
      {:ok, %{mode: mode}} = File.stat(controller_env)
      assert Bitwise.band(mode, 0o777) == 0o600

      {:ok, %{mode: mode}} = File.stat(node_agent_env)
      assert Bitwise.band(mode, 0o777) == 0o600
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init prefers .venv/bin entrypoint over wrapper" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_venv_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      # Also create the wrapper script path (should be less preferred)
      wrapper_dir = Path.join([support_root, "native", "orchard_tokenizer", "bin"])
      File.mkdir_p!(wrapper_dir)
      wrapper = Path.join(wrapper_dir, "orchard-tokenizer")
      File.write!(wrapper, "#!/bin/sh\necho wrapper")
      File.chmod!(wrapper, 0o755)

      {:ok, _} = Env.run(["init", "--support-root", support_root], test_runtime())

      controller_content =
        Path.join([support_root, "config", "controller.env"])
        |> File.read!()

      # Should use .venv path, not wrapper path
      assert controller_content =~ ".venv/bin/orchard-tokenizer"
      refute controller_content =~ ~r/native\/orchard_tokenizer\/bin\/orchard-tokenizer/
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init --service controller generates only controller.env" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_svc_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      assert {:ok, summary} =
               Env.run(
                 ["init", "--support-root", support_root, "--service", "controller"],
                 test_runtime()
               )

      assert summary =~ "controller.env"
      refute summary =~ "node-agent.env"

      config_dir = Path.join(support_root, "config")
      assert File.regular?(Path.join(config_dir, "controller.env"))
      refute File.exists?(Path.join(config_dir, "node-agent.env"))
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init --service node-agent generates only node-agent.env" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_na_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      assert {:ok, summary} =
               Env.run(
                 ["init", "--support-root", support_root, "--service", "node-agent"],
                 test_runtime()
               )

      refute summary =~ "controller.env"
      assert summary =~ "node-agent.env"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init skips existing files without --force" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_skip_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      # Create first
      {:ok, _} = Env.run(["init", "--support-root", support_root], test_runtime())

      # Run again without --force
      assert {:ok, summary} =
               Env.run(["init", "--support-root", support_root], test_runtime())

      assert summary =~ "skipped"
      assert summary =~ "already exists"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init --force overwrites existing files" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_force_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      # Create first
      {:ok, _} = Env.run(["init", "--support-root", support_root], test_runtime())

      # Overwrite
      assert {:ok, summary} =
               Env.run(
                 ["init", "--support-root", support_root, "--force"],
                 test_runtime()
               )

      assert summary =~ "overwritten"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init fails with actionable error when executables are missing" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_miss_#{System.unique_integer([:positive])}")

    try do
      # Empty support root — no native/ executables
      support_root = Path.join(tmp_dir, "Application Support/Orchard")
      File.mkdir_p!(support_root)

      assert {:error, message, 1} =
               Env.run(["init", "--support-root", support_root], test_runtime())

      assert message =~ "not found"
      assert message =~ "tokenizer"

      # No env files should be created
      config_dir = Path.join(support_root, "config")
      refute File.exists?(Path.join(config_dir, "controller.env"))
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init uses detected hostname in node-agent.env" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_host_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      runtime = test_runtime(%{hostname: fn -> {:ok, ~c"mawarduri"} end})

      {:ok, _} =
        Env.run(
          ["init", "--support-root", support_root, "--service", "node-agent"],
          runtime
        )

      content =
        Path.join([support_root, "config", "node-agent.env"])
        |> File.read!()

      assert content =~ "ORCHARD_NODE_DISPLAY_NAME=\"mawarduri\""
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init returns clean error when config dir is not writable" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_perm_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)
      config_dir = Path.join(support_root, "config")
      File.mkdir_p!(config_dir)
      # Make config dir read-only so writes fail
      File.chmod!(config_dir, 0o500)

      assert {:error, message, 1} =
               Env.run(
                 ["init", "--support-root", support_root, "--force"],
                 test_runtime()
               )

      assert message =~ "Error:"
      assert message =~ "sudo"
    after
      # Restore permissions for cleanup
      config_dir = Path.join([tmp_dir, "Application Support/Orchard", "config"])
      File.chmod(config_dir, 0o700)
      File.rm_rf!(tmp_dir)
    end
  end

  test "init rejects non-executable files as candidates" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_noexec_#{System.unique_integer([:positive])}")

    try do
      support_root = Path.join(tmp_dir, "Application Support/Orchard")

      # Create tokenizer file but NOT executable
      tokenizer_venv = Path.join([support_root, "native", "orchard_tokenizer", ".venv", "bin"])
      File.mkdir_p!(tokenizer_venv)
      tokenizer_entry = Path.join(tokenizer_venv, "orchard-tokenizer")
      File.write!(tokenizer_entry, "#!/bin/sh\necho tokenizer")
      File.chmod!(tokenizer_entry, 0o644)

      # Create worker file but NOT executable
      worker_venv = Path.join([support_root, "native", "orchard_worker_mlx", ".venv", "bin"])
      File.mkdir_p!(worker_venv)
      worker_entry = Path.join(worker_venv, "orchard-worker-mlx")
      File.write!(worker_entry, "#!/bin/sh\necho worker")
      File.chmod!(worker_entry, 0o644)

      assert {:error, message, 1} =
               Env.run(["init", "--support-root", support_root], test_runtime())

      assert message =~ "not found"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  # ── Shell Quoting ──────────────────────────────────────────────────

  test "shell_quote wraps in double quotes" do
    assert Env.shell_quote("simple") == ~s("simple")
  end

  test "shell_quote escapes backslashes" do
    assert Env.shell_quote("a\\b") == ~s("a\\\\b")
  end

  test "shell_quote escapes double quotes" do
    assert Env.shell_quote(~s(a"b)) == ~s("a\\\"b")
  end

  test "shell_quote escapes dollar signs" do
    assert Env.shell_quote("a$b") == ~s("a\\$b")
  end

  test "shell_quote escapes backticks" do
    assert Env.shell_quote("a`b") == ~s("a\\`b")
  end

  test "shell_quote escapes hash to prevent interpolation" do
    assert Env.shell_quote("a#{"#"}b") == ~s("a\\#b")
  end

  test "shell_quote handles path with spaces" do
    path = "/Library/Application Support/Orchard/native/tokenizer"
    quoted = Env.shell_quote(path)
    assert quoted == ~s("/Library/Application Support/Orchard/native/tokenizer")
  end

  test "shell_quote rejects newlines" do
    assert_raise ArgumentError, ~r/newline or NUL/, fn ->
      Env.shell_quote("a\nb")
    end
  end

  test "shell_quote rejects NUL bytes" do
    assert_raise ArgumentError, ~r/newline or NUL/, fn ->
      Env.shell_quote("a\0b")
    end
  end
end
