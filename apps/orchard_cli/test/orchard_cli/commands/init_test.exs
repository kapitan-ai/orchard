defmodule OrchardCLI.Commands.InitTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Init

  defp base_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        read_install_role_request: fn -> {:error, :enoent} end,
        read_install_role: fn -> {:ok, "all"} end,
        command_runner: successful_runner(self())
      },
      overrides
    )
  end

  defp successful_runner(parent) do
    fn command, args, _runtime ->
      send(parent, {:command, command, args})

      case {command, args} do
        {:env, ["init", "--service", _service]} ->
          {:ok, "Environment files: ok"}

        {:migrate, []} ->
          {:ok, "Database migrations completed."}

        {:transport, ["enable-local-https", "--host", _host, "--port", _port]} ->
          {:ok, "Direct HTTPS transport enabled."}

        {:console, ["enable"]} ->
          {:ok, "Console enabled."}

        {:start, []} ->
          {:ok, "Loaded Orchard services into launchd."}

        {:status, []} ->
          {:ok, "Orchard status: ready"}
      end
    end
  end

  defp collect_commands do
    collect_commands([])
  end

  defp collect_commands(acc) do
    receive do
      {:command, command, args} -> collect_commands(acc ++ [{command, args}])
    after
      0 -> acc
    end
  end

  test "help returns guided init usage without accepting secret flags" do
    assert {:ok, message} = Init.run(["--help"], base_runtime())
    assert message =~ "sudo orchardctl init --host HOST"
    assert message =~ "--console"
    assert message =~ "--skip-start"
    refute message =~ "license"
  end

  test "controller-bearing role runs env, migrate, transport, optional console, start, and status" do
    runtime = base_runtime(%{read_install_role: fn -> {:ok, "all"} end})

    assert {:ok, message} =
             Init.run(["--host", "mawarduri", "--port", "9443", "--console"], runtime)

    assert message =~ "Role: all"
    assert message =~ "Step 1: sudo orchardctl env init --service all"
    assert message =~ "Step 6: orchardctl status"
    assert message =~ "First-run initialization complete."

    assert collect_commands() == [
             {:env, ["init", "--service", "all"]},
             {:migrate, []},
             {:transport, ["enable-local-https", "--host", "mawarduri", "--port", "9443"]},
             {:console, ["enable"]},
             {:start, []},
             {:status, []}
           ]
  end

  test "controller-bearing role requires host before running any step" do
    runtime = base_runtime(%{read_install_role: fn -> {:ok, "controller"} end})

    assert {:error, message, 1} = Init.run([], runtime)
    assert message =~ "--host is required"
    assert message =~ "sudo orchardctl init --host HOST"
    assert collect_commands() == []
  end

  test "requires root before running setup" do
    parent = self()

    runtime =
      base_runtime(%{
        uid: fn -> 501 end,
        command_runner: fn command, args, _runtime ->
          send(parent, {:command, command, args})
          {:ok, "unexpected command"}
        end
      })

    assert {:error, message, 1} = Init.run(["--host", "mawarduri"], runtime)
    assert message =~ "root privileges required"
    assert message =~ "sudo orchardctl init --host mawarduri --port 8443"
    assert collect_commands() == []
  end

  test "overwrites stale composed command runtime role with resolved first-run role" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role_request: fn -> {:ok, "controller"} end,
        command_runtime: %{install_role: :node_agent},
        command_runner: fn command, args, command_runtime ->
          send(parent, {:command, command, args, Map.fetch!(command_runtime, :install_role)})

          case command do
            :env -> {:ok, "Environment files: ok"}
            :migrate -> {:ok, "Database migrations completed."}
            :transport -> {:ok, "Direct HTTPS transport enabled."}
            :start -> {:ok, "Loaded Orchard services into launchd."}
            :status -> {:ok, "Orchard status: ready"}
          end
        end
      })

    assert {:ok, _message} = Init.run(["--host", "controller.lan"], runtime)
    assert_receive {:command, :env, ["init", "--service", "controller"], :controller}
  end

  test "passes resolved request role to composed command runtime" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role_request: fn -> {:ok, "controller"} end,
        command_runner: fn command, args, command_runtime ->
          send(parent, {:command, command, args, Map.fetch!(command_runtime, :install_role)})

          case command do
            :env -> {:ok, "Environment files: ok"}
            :migrate -> {:ok, "Database migrations completed."}
            :transport -> {:ok, "Direct HTTPS transport enabled."}
            :start -> {:ok, "Loaded Orchard services into launchd."}
            :status -> {:ok, "Orchard status: ready"}
          end
        end
      })

    assert {:ok, _message} = Init.run(["--host", "controller.lan"], runtime)

    assert_receive {:command, :env, ["init", "--service", "controller"], :controller}
    assert_receive {:command, :migrate, [], :controller}

    assert_receive {:command, :transport,
                    ["enable-local-https", "--host", "controller.lan", "--port", "8443"],
                    :controller}
  end

  test "invalid host and port are rejected without echoing raw values" do
    secret = "secret-like-value"

    assert {:error, message, 1} = Init.run(["--host", "bad host #{secret}"], base_runtime())
    assert message =~ "invalid --host"
    refute message =~ secret
    assert collect_commands() == []

    assert {:error, message, 1} =
             Init.run(["--host", "mawarduri", "--port", secret], base_runtime())

    assert message =~ "invalid --port"
    refute message =~ secret
    assert collect_commands() == []
  end

  test "node-agent role rejects controller-only console setup" do
    runtime = base_runtime(%{read_install_role: fn -> {:ok, "node-agent"} end})

    assert {:error, message, 1} = Init.run(["--console"], runtime)
    assert message =~ "--console is only applicable for controller-bearing roles"
    assert message =~ "Role: node-agent"
    assert collect_commands() == []
  end

  test "node-agent role runs env init and start only without requiring host" do
    runtime = base_runtime(%{read_install_role: fn -> {:ok, "node-agent"} end})

    assert {:ok, message} = Init.run([], runtime)

    assert message =~ "Role: node-agent"
    assert message =~ "Node-agent first-run initialization complete."
    refute message =~ "migrate"
    refute message =~ "transport enable-local-https"
    refute message =~ "console enable"

    assert collect_commands() == [
             {:env, ["init", "--service", "node-agent"]},
             {:start, []}
           ]
  end

  test "install-role.request takes precedence over persisted marker for first-run role" do
    runtime =
      base_runtime(%{
        read_install_role_request: fn -> {:ok, "node-agent"} end,
        read_install_role: fn -> {:ok, "controller"} end
      })

    assert {:ok, message} = Init.run([], runtime)
    assert message =~ "Role: node-agent"

    assert collect_commands() == [
             {:env, ["init", "--service", "node-agent"]},
             {:start, []}
           ]
  end

  test "missing role request and marker default to all for first-run" do
    runtime =
      base_runtime(%{
        read_install_role_request: fn -> {:error, :enoent} end,
        read_install_role: fn -> {:error, :enoent} end
      })

    assert {:error, message, 1} = Init.run([], runtime)
    assert message =~ "--host is required"
    assert message =~ "Role: all"
    assert collect_commands() == []
  end

  test "missing role request and marker ignore stale plist inference for postinstall parity" do
    runtime =
      base_runtime(%{
        read_install_role_request: fn -> {:error, :enoent} end,
        read_install_role: fn -> {:error, :enoent} end,
        file_regular?: fn path -> String.ends_with?(path, "com.orchard.node-agent.plist") end
      })

    assert {:error, message, 1} = Init.run([], runtime)
    assert message =~ "--host is required"
    assert message =~ "Role: all"
    assert collect_commands() == []
  end

  test "skip-start prints exact start and status guidance without starting services" do
    runtime = base_runtime(%{read_install_role: fn -> {:ok, "controller"} end})

    assert {:ok, message} = Init.run(["--host", "controller.lan", "--skip-start"], runtime)

    assert message =~ "Start skipped by --skip-start."
    assert message =~ "Run: sudo orchardctl start"
    assert message =~ "Then run: orchardctl status"

    assert collect_commands() == [
             {:env, ["init", "--service", "controller"]},
             {:migrate, []},
             {:transport, ["enable-local-https", "--host", "controller.lan", "--port", "8443"]}
           ]
  end

  test "accepts bare ok from composed commands" do
    parent = self()

    runtime =
      base_runtime(%{
        command_runner: fn command, args, _runtime ->
          send(parent, {:command, command, args})

          case command do
            :env -> :ok
            :migrate -> :ok
            :transport -> :ok
            :start -> :ok
            :status -> :ok
          end
        end
      })

    assert {:ok, message} = Init.run(["--host", "mawarduri"], runtime)
    assert message =~ "First-run initialization complete."
    assert message =~ "Step 1: sudo orchardctl env init --service all\nOK"
  end

  test "subcommand failure stops immediately with failing subcommand and resume guidance" do
    parent = self()

    runtime =
      base_runtime(%{
        command_runner: fn command, args, _runtime ->
          send(parent, {:command, command, args})

          case command do
            :env -> {:ok, "Environment files: ok"}
            :migrate -> {:error, "Error: migration_failed", 1}
            other -> flunk("unexpected command after migrate failure: #{inspect(other)}")
          end
        end
      })

    assert {:error, message, 1} = Init.run(["--host", "mawarduri"], runtime)

    assert message =~ "First-run initialization stopped at: sudo orchardctl migrate"
    assert message =~ "Resume this step: sudo orchardctl migrate"
    assert message =~ "Then rerun: sudo orchardctl init --host mawarduri --port 8443"
    assert message =~ "Error: migration_failed"

    assert collect_commands() == [
             {:env, ["init", "--service", "all"]},
             {:migrate, []}
           ]
  end

  test "failure after console step does not ask for console credentials again on rerun" do
    parent = self()

    runtime =
      base_runtime(%{
        command_runner: fn command, args, _runtime ->
          send(parent, {:command, command, args})

          case command do
            :env -> {:ok, "Environment files: ok"}
            :migrate -> {:ok, "Database migrations completed."}
            :transport -> {:ok, "Direct HTTPS transport enabled."}
            :console -> {:ok, "Console enabled."}
            :start -> {:error, "Error: service_start_failed", 1}
          end
        end
      })

    assert {:error, message, 1} = Init.run(["--host", "mawarduri", "--console"], runtime)

    assert message =~ "Step 4: sudo orchardctl console enable"
    assert message =~ "First-run initialization stopped at: sudo orchardctl start"
    assert message =~ "Then rerun: sudo orchardctl init --host mawarduri --port 8443"
    refute message =~ "Then rerun: sudo orchardctl init --host mawarduri --port 8443 --console"
  end

  test "secret-looking positional and unknown flag values are rejected without echoing them" do
    secret = "super-secret-console-password"

    for args <- [[secret], ["--password", secret], ["--console-password=#{secret}"]] do
      assert {:error, message, 1} = Init.run(args, base_runtime())
      assert message =~ "orchardctl init"
      refute message =~ secret
      refute message =~ "password"
      assert collect_commands() == []
    end
  end
end
