defmodule OrchardCLI.Commands.LifecycleSupportTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.LifecycleSupport

  defp test_services do
    [
      %{
        id: :node_agent,
        label: "com.orchard.node-agent",
        plist_path: "/tmp/test-node-agent.plist",
        display_name: "Node Agent"
      },
      %{
        id: :controller,
        label: "com.orchard.controller",
        plist_path: "/tmp/test-controller.plist",
        display_name: "Controller"
      }
    ]
  end

  defp base_runtime(overrides) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        services: test_services(),
        cmd: fn _program, _args, _opts -> {"", 0} end
      },
      overrides
    )
  end

  test "start enables a persistently disabled service before bootstrap" do
    parent = self()
    service = hd(test_services())

    runtime =
      base_runtime(%{
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})

          case args do
            ["print", "system/com.orchard.node-agent"] -> {"Could not find service", 113}
            ["enable", "system/com.orchard.node-agent"] -> {"", 0}
            ["bootstrap", "system", "/tmp/test-node-agent.plist"] -> {"", 0}
          end
        end
      })

    assert {:loaded, ^service} = LifecycleSupport.ensure_started(service, runtime)

    assert [
             {"launchctl", ["print", "system/com.orchard.node-agent"], _print_opts},
             {"launchctl", ["enable", "system/com.orchard.node-agent"], _enable_opts},
             {"launchctl", ["bootstrap", "system", "/tmp/test-node-agent.plist"], _bootstrap_opts}
           ] = collect_cmds()
  end

  test "restart_loaded requires root" do
    runtime = base_runtime(%{uid: fn -> 501 end})

    assert {:error, message, 1} = LifecycleSupport.restart_loaded(:all, :controller, runtime)
    assert message =~ "root privileges required"
    assert message =~ "Run the calling orchardctl command with sudo"
    refute message =~ "sudo orchardctl restart"
  end

  test "loaded controller uses launchctl kickstart through runtime" do
    parent = self()

    runtime =
      base_runtime(%{
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})

          case args do
            ["print", "system/com.orchard.controller"] -> {"{ pid = 123 }", 0}
            ["kickstart", "-k", "system/com.orchard.controller"] -> {"", 0}
            unexpected -> flunk("unexpected launchctl args: #{inspect(unexpected)}")
          end
        end
      })

    assert {:restarted, %{id: :controller, label: "com.orchard.controller"}} =
             LifecycleSupport.restart_loaded(:all, :controller, runtime)

    assert [
             {"launchctl", ["print", "system/com.orchard.controller"], print_opts},
             {"launchctl", ["kickstart", "-k", "system/com.orchard.controller"], kickstart_opts}
           ] = collect_cmds()

    assert print_opts[:stderr_to_stdout] == true
    assert kickstart_opts[:stderr_to_stdout] == true
  end

  test "not-loaded controller returns structured no-op" do
    parent = self()

    runtime =
      base_runtime(%{
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})

          case args do
            ["print", "system/com.orchard.controller"] -> {"Could not find service", 113}
            ["kickstart" | _] -> flunk("not-loaded service must not be kickstarted")
          end
        end
      })

    assert {:not_loaded, %{id: :controller, label: "com.orchard.controller"}} =
             LifecycleSupport.restart_loaded(:all, :controller, runtime)

    assert [{"launchctl", ["print", "system/com.orchard.controller"], _opts}] = collect_cmds()
  end

  test "kickstart failure returns structured no-op when service unloads during restart" do
    parent = self()
    print_count = :counters.new(1, [])

    runtime =
      base_runtime(%{
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})

          case args do
            ["print", "system/com.orchard.controller"] ->
              :counters.add(print_count, 1, 1)

              case :counters.get(print_count, 1) do
                1 -> {"{ pid = 123 }", 0}
                _ -> {"Could not find service", 113}
              end

            ["kickstart", "-k", "system/com.orchard.controller"] ->
              {"No such process", 113}
          end
        end
      })

    assert {:not_loaded, %{id: :controller, label: "com.orchard.controller"}} =
             LifecycleSupport.restart_loaded(:all, :controller, runtime)

    assert [
             {"launchctl", ["print", "system/com.orchard.controller"], _print_opts},
             {"launchctl", ["kickstart", "-k", "system/com.orchard.controller"], _kickstart_opts},
             {"launchctl", ["print", "system/com.orchard.controller"], _recheck_opts}
           ] = collect_cmds()
  end

  test "kickstart failure returns error when service remains loaded" do
    parent = self()

    runtime =
      base_runtime(%{
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})

          case args do
            ["print", "system/com.orchard.controller"] -> {"{ pid = 123 }", 0}
            ["kickstart", "-k", "system/com.orchard.controller"] -> {"permission denied", 1}
          end
        end
      })

    assert {:error, message, 1} = LifecycleSupport.restart_loaded(:all, :controller, runtime)
    assert message =~ "failed to restart Controller"
    assert message =~ "permission denied"

    assert [
             {"launchctl", ["print", "system/com.orchard.controller"], _print_opts},
             {"launchctl", ["kickstart", "-k", "system/com.orchard.controller"], _kickstart_opts},
             {"launchctl", ["print", "system/com.orchard.controller"], _recheck_opts}
           ] = collect_cmds()
  end

  test "controller-only role rejects node-agent target" do
    runtime =
      base_runtime(%{
        cmd: fn _program, _args, _opts -> flunk("rejected target must not call launchctl") end
      })

    assert {:error, message, 1} =
             LifecycleSupport.restart_loaded(:controller, :node_agent, runtime)

    assert message =~ "node-agent service is not available for role controller"
  end

  test "role all targeting controller does not restart node-agent" do
    parent = self()

    runtime =
      base_runtime(%{
        cmd: fn program, args, opts ->
          send(parent, {:cmd, program, args, opts})

          case args do
            ["print", "system/com.orchard.controller"] -> {"{ pid = 123 }", 0}
            ["kickstart", "-k", "system/com.orchard.controller"] -> {"", 0}
            unexpected -> flunk("unexpected launchctl args: #{inspect(unexpected)}")
          end
        end
      })

    assert {:restarted, %{id: :controller}} =
             LifecycleSupport.restart_loaded(:all, :controller, runtime)

    cmds = collect_cmds()

    refute Enum.any?(cmds, fn {_program, args, _opts} ->
             Enum.any?(args, &String.contains?(&1, "node-agent"))
           end)
  end

  test "invalid target is rejected without launchctl" do
    runtime =
      base_runtime(%{
        cmd: fn _program, _args, _opts -> flunk("invalid target must not call launchctl") end
      })

    assert {:error, message, 1} = LifecycleSupport.restart_loaded(:all, :postgres, runtime)
    assert message =~ "invalid restart target"
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
