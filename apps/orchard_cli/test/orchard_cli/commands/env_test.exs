defmodule OrchardCLI.Commands.EnvTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Env

  @moduletag :env

  defp test_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        hostname: fn -> {:ok, ~c"testhost"} end,
        current_user: fn -> {:ok, "orchard_test_user"} end,
        find_executable: fn
          "psql" -> "/usr/bin/psql"
          "createdb" -> "/usr/bin/createdb"
          _ -> nil
        end,
        cmd: fn
          command, ["-U", "orchard_test_user", "orchard_controller"], _opts ->
            if Path.basename(command) == "createdb" do
              {:ok, ""}
            else
              {:error, 1, "unsupported command"}
            end

          _command, _args, _opts ->
            {:error, 1, "unsupported command"}
        end,
        strong_rand_bytes: fn 32 ->
          <<
            0x00,
            0x11,
            0x22,
            0x33,
            0x44,
            0x55,
            0x66,
            0x77,
            0x88,
            0x99,
            0xAA,
            0xBB,
            0xCC,
            0xDD,
            0xEE,
            0xFF,
            0x10,
            0x20,
            0x30,
            0x40,
            0x50,
            0x60,
            0x70,
            0x80,
            0x90,
            0xA0,
            0xB0,
            0xC0,
            0xD0,
            0xE0,
            0xF0,
            0x01
          >>
        end
      },
      overrides
    )
  end

  defp expected_secret_key_base do
    "00112233445566778899aabbccddeeff102030405060708090a0b0c0d0e0f001"
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
      assert summary =~ "SECRET_KEY_BASE generated"
      assert summary =~ "DATABASE_URL generated for local PostgreSQL"

      # Verify files exist
      controller_env = Path.join([support_root, "config", "controller.env"])
      node_agent_env = Path.join([support_root, "config", "node-agent.env"])
      assert File.regular?(controller_env)
      assert File.regular?(node_agent_env)

      # Verify content is properly quoted (support root has spaces)
      controller_content = File.read!(controller_env)

      assert controller_content =~
               "DATABASE_URL=\"ecto://orchard_test_user@localhost:5432/orchard_controller\""

      assert controller_content =~ "SECRET_KEY_BASE=\"#{expected_secret_key_base()}\""
      refute controller_content =~ ~r/^# DATABASE_URL=/m
      refute controller_content =~ ~r/^# SECRET_KEY_BASE=/m
      assert controller_content =~ "ORCHARD_TRANSPORT_MODE=\"plain_http_localhost\""
      assert controller_content =~ "ORCHARD_TRUSTED_PROXIES=\"127.0.0.1/32,::1/128\""
      assert controller_content =~ "ORCHARD_TLS_CERTFILE=\"/path/to/server.crt\""
      assert controller_content =~ "ORCHARD_RUNTIME_CLIENT_TARGETS"
      assert controller_content =~ "ORCHARD_PUBLIC_HOST=\"replace-with-lan-or-tailscale-host\""
      assert controller_content =~ "ORCHARD_TOKENIZER_EXECUTABLE="
      assert controller_content =~ "Application Support"

      assert controller_content =~
               ~r/ORCHARD_TOKENIZER_EXECUTABLE="[^"]*Application Support[^"]*"/

      refute controller_content =~ "ORCHARD_NODE_AGENT_LISTEN_HOST"
      refute File.exists?(Path.join([support_root, "public", "endpoint.json"]))

      node_agent_content = File.read!(node_agent_env)
      assert node_agent_content =~ "ORCHARD_NODE_AGENT_LISTEN_HOST"
      assert node_agent_content =~ "ORCHARD_NODE_AGENT_LISTEN_PORT=\"50061\""
      assert node_agent_content =~ "ORCHARD_WORKER_EXECUTABLE="
      assert node_agent_content =~ "ORCHARD_NODE_DISPLAY_NAME="
      assert node_agent_content =~ "Pending M3 join flow"
      assert node_agent_content =~ "ORCHARD_JOIN_BOOTSTRAP_TOKEN"
      assert node_agent_content =~ ~r/ORCHARD_WORKER_EXECUTABLE="[^"]*Application Support[^"]*"/
      refute node_agent_content =~ "ORCHARD_RUNTIME_CLIENT_TARGETS"

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
      controller_env = Path.join(config_dir, "controller.env")
      assert File.regular?(controller_env)
      refute File.exists?(Path.join(config_dir, "node-agent.env"))

      content = File.read!(controller_env)
      assert content =~ "ORCHARD_RUNTIME_CLIENT_TARGETS"
      assert content =~ "ORCHARD_PUBLIC_HOST=\"replace-with-lan-or-tailscale-host\""
      refute content =~ "ORCHARD_NODE_AGENT_LISTEN_HOST"
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

      content =
        Path.join([support_root, "config", "node-agent.env"])
        |> File.read!()

      assert content =~ "ORCHARD_NODE_AGENT_LISTEN_HOST"
      assert content =~ "ORCHARD_NODE_AGENT_LISTEN_PORT=\"50061\""
      assert content =~ "Pending M3 join flow"
      refute content =~ "ORCHARD_RUNTIME_CLIENT_TARGETS"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init writes commented database URL when postgres is not detected" do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("orchard_env_no_pg_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      runtime =
        test_runtime(%{
          find_executable: fn _ -> nil end,
          detect_postgresql: fn -> :error end
        })

      assert {:ok, summary} = Env.run(["init", "--support-root", support_root], runtime)

      controller_content =
        Path.join([support_root, "config", "controller.env"])
        |> File.read!()

      assert controller_content =~
               "# DATABASE_URL=\"ecto://USER@localhost:5432/orchard_controller\""

      assert controller_content =~ "SECRET_KEY_BASE=\"#{expected_secret_key_base()}\""
      assert summary =~ "PostgreSQL executable not detected"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init treats createdb already exists as non-fatal" do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("orchard_env_exists_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      runtime =
        test_runtime(%{
          cmd: fn
            command, ["-U", "orchard_test_user", "orchard_controller"], _opts ->
              if Path.basename(command) == "createdb" do
                {:error, 1, "database \"orchard_controller\" already exists"}
              else
                {:error, 1, "unsupported command"}
              end

            _command, _args, _opts ->
              {:error, 1, "unsupported command"}
          end
        })

      assert {:ok, summary} = Env.run(["init", "--support-root", support_root], runtime)
      assert summary =~ "Database orchard_controller already exists"
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init treats createdb failure as non-fatal" do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("orchard_env_createdb_fail_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      runtime =
        test_runtime(%{
          cmd: fn
            command, ["-U", "orchard_test_user", "orchard_controller"], _opts ->
              if Path.basename(command) == "createdb" do
                {:error, 2, "permission denied"}
              else
                {:error, 1, "unsupported command"}
              end

            _command, _args, _opts ->
              {:error, 1, "unsupported command"}
          end
        })

      assert {:ok, summary} = Env.run(["init", "--support-root", support_root], runtime)
      assert summary =~ "Database auto-create failed"

      controller_content =
        Path.join([support_root, "config", "controller.env"])
        |> File.read!()

      assert controller_content =~
               "DATABASE_URL=\"ecto://orchard_test_user@localhost:5432/orchard_controller\""
    after
      File.rm_rf!(tmp_dir)
    end
  end

  test "init skips existing files without --force" do
    tmp_dir =
      System.tmp_dir!() |> Path.join("orchard_env_skip_#{System.unique_integer([:positive])}")

    try do
      support_root = setup_support_root(tmp_dir)

      parent = self()

      runtime =
        test_runtime(%{
          cmd: fn
            command, ["-U", "orchard_test_user", "orchard_controller"], _opts ->
              if Path.basename(command) == "createdb" do
                send(parent, :createdb_called)
                {:ok, ""}
              else
                {:error, 1, "unsupported command"}
              end

            _command, _args, _opts ->
              {:error, 1, "unsupported command"}
          end
        })

      {:ok, _} = Env.run(["init", "--support-root", support_root], runtime)
      assert_received :createdb_called

      assert {:ok, summary} = Env.run(["init", "--support-root", support_root], runtime)
      refute_received :createdb_called

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

  test "shell_quote leaves hash literal so sourced values round-trip" do
    assert Env.shell_quote("a#{"#"}b") == ~s("a#b")
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
