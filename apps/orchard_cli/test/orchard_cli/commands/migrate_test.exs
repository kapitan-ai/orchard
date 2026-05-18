defmodule OrchardCLI.Commands.MigrateTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Migrate

  @wrapper_path "/Library/Application Support/Orchard/bin/orchard-controller"

  defp base_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        read_install_role: fn -> {:ok, "all"} end,
        cmd: fn _program, _args, _opts -> {"", 0} end
      },
      overrides
    )
  end

  test "help returns usage" do
    assert {:ok, message} = Migrate.run(["--help"], base_runtime())
    assert message =~ "orchardctl migrate"
    assert message =~ "Orchard.Release.migrate()"
  end

  test "rejects extra args" do
    assert {:error, message, 1} = Migrate.run(["now"], base_runtime())
    assert message =~ "Usage: sudo orchardctl migrate"
  end

  test "requires root for all/controller roles before reading packaged DB env" do
    runtime = base_runtime(%{uid: fn -> 501 end})

    assert {:error, message, 1} = Migrate.run([], runtime)
    assert message =~ "root privileges required"
    assert message =~ "sudo orchardctl migrate"
  end

  test "node-agent role exits successfully with not-applicable message" do
    runtime =
      base_runtime(%{
        read_install_role: fn -> {:ok, "node-agent"} end,
        cmd: fn _program, _args, _opts -> flunk("node-agent role must not invoke wrapper") end
      })

    assert {:ok, message} = Migrate.run([], runtime)
    assert message =~ "not applicable for node-agent role"
    assert message =~ "Run: orchardctl status"
  end

  test "non-root node-agent role exits successfully without invoking wrapper" do
    runtime =
      base_runtime(%{
        uid: fn -> 501 end,
        read_install_role: fn -> {:ok, "node-agent"} end,
        cmd: fn _program, _args, _opts -> flunk("node-agent role must not invoke wrapper") end
      })

    assert {:ok, message} = Migrate.run([], runtime)
    assert message =~ "not applicable for node-agent role"
    refute message =~ "root privileges required"
  end

  test "all role invokes packaged controller wrapper release eval" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role: fn -> {:ok, "all"} end,
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})
          {"migrated ok\n", 0}
        end
      })

    assert {:ok, message} = Migrate.run([], runtime)
    assert message =~ "Database migrations completed."
    assert message =~ "Role: all"
    assert message =~ "Next: configure controller transport before starting services."
    assert message =~ "Configure direct HTTPS or reverse-proxy TLS"
    assert message =~ "sudo orchardctl start"
    refute message =~ "orchardctl transport"
    refute message =~ "migrated ok"

    assert_received {:cmd, @wrapper_path, ["eval", "Orchard.Release.migrate()"], opts}
    assert opts[:stderr_to_stdout] == true
  end

  test "controller role invokes packaged controller wrapper release eval" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role: fn -> {:ok, "controller"} end,
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})
          {"", 0}
        end
      })

    assert {:ok, message} = Migrate.run([], runtime)
    assert message =~ "Role: controller"
    assert_received {:cmd, @wrapper_path, ["eval", "Orchard.Release.migrate()"], _opts}
  end

  test "wrapper non-zero exit maps to deterministic migration_failed without leaking output" do
    secret = "ecto://orchard:super-secret@example.invalid/orchard_controller"

    runtime =
      base_runtime(%{
        cmd: fn _program, _args, _opts ->
          {"database failed for DATABASE_URL=#{secret}\nstacktrace line", 1}
        end
      })

    assert {:error, message, 1} = Migrate.run([], runtime)
    assert message =~ "migration_failed"
    assert message =~ "wrapper exit 1"
    assert message =~ "Logs: /Library/Application Support/Orchard/logs/"
    refute message =~ secret
    refute message =~ "super-secret"
    refute message =~ "stacktrace"
  end

  test "missing wrapper maps to wrapper_invocation_failed without raw exception text" do
    runtime =
      base_runtime(%{
        cmd: fn _program, _args, _opts -> {"enoent: #{@wrapper_path}", 127} end
      })

    assert {:error, message, 1} = Migrate.run([], runtime)
    assert message =~ "wrapper_invocation_failed"
    assert message =~ "wrapper exit 127"
    refute message =~ @wrapper_path
    refute message =~ "enoent"
  end

  test "database connection failures map to db_unreachable without leaking stderr" do
    runtime =
      base_runtime(%{
        cmd: fn _program, _args, _opts ->
          {"Postgrex.Protocol connection refused for DATABASE_URL=ecto://secret", 1}
        end
      })

    assert {:error, message, 1} = Migrate.run([], runtime)
    assert message =~ "db_unreachable"
    refute message =~ "DATABASE_URL"
    refute message =~ "ecto://secret"
  end
end
