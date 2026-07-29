defmodule OrchardCLI.Commands.StopTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.Commands.Stop

  # ── Helpers ──────────────────────────────────────────────────────────

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

  defp base_runtime(overrides \\ %{}) do
    Map.merge(
      %{
        uid: fn -> 0 end,
        services: test_services(),
        read_install_role: fn -> {:ok, "all"} end,
        file_regular?: fn _path -> true end,
        cmd: fn _prog, _args, _opts -> {"\n", 0} end
      },
      overrides
    )
  end

  # Services are loaded (launchctl list returns 0)
  defp loaded_cmd(parent) do
    fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> _label]} -> {"{\n\t\"pid\" : 123;\n}\n", 0}
        {"launchctl", ["bootout" | _]} -> {"\n", 0}
        _ -> {"\n", 0}
      end
    end
  end

  # Services are not loaded
  defp not_loaded_cmd(parent) do
    fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> _label]} -> {"Could not find service\n", 113}
        _ -> {"\n", 0}
      end
    end
  end

  # ── Usage / Help ─────────────────────────────────────────────────────

  test "help returns usage" do
    assert {:ok, msg} = Stop.run(["help"], base_runtime())
    assert msg =~ "orchardctl stop"
  end

  test "--help returns usage" do
    assert {:ok, msg} = Stop.run(["--help"], base_runtime())
    assert msg =~ "orchardctl stop"
  end

  test "extra args returns error" do
    assert {:error, msg, 1} = Stop.run(["extra"], base_runtime())
    assert msg =~ "orchardctl stop"
  end

  # ── Root Check ───────────────────────────────────────────────────────

  test "non-root returns root-required error" do
    runtime = base_runtime(%{uid: fn -> 501 end})
    assert {:error, msg, 1} = Stop.run([], runtime)
    assert msg =~ "root privileges required"
    assert msg =~ "sudo orchardctl stop"
  end

  # ── Packaged Context Detection ───────────────────────────────────────

  test "no plists and no loaded services returns packaged-install error" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role: fn -> {:error, :enoent} end,
        file_regular?: fn _path -> false end,
        cmd: not_loaded_cmd(parent)
      })

    assert {:error, msg, 1} = Stop.run([], runtime)
    assert msg =~ "packaged install not found"
    assert msg =~ "install role"
  end

  test "plists exist but services not loaded shows already stopped" do
    parent = self()

    runtime =
      base_runtime(%{
        file_regular?: fn _path -> true end,
        cmd: not_loaded_cmd(parent)
      })

    assert {:ok, msg} = Stop.run([], runtime)
    assert msg =~ "already stopped"
  end

  # ── Successful Stop ──────────────────────────────────────────────────

  test "controller role stops controller only" do
    parent = self()

    runtime =
      base_runtime(%{read_install_role: fn -> {:ok, "controller"} end, cmd: loaded_cmd(parent)})

    assert {:ok, msg} = Stop.run([], runtime)
    assert msg =~ "Stopped Orchard services."
    assert msg =~ "Role: controller"

    cmds = collect_cmds()
    bootout_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootout" | _], args) end)
    assert [{_, ["bootout", target]}] = bootout_calls
    assert target =~ "controller"
  end

  test "node-agent role stops node-agent only" do
    parent = self()

    runtime =
      base_runtime(%{read_install_role: fn -> {:ok, "node-agent"} end, cmd: loaded_cmd(parent)})

    assert {:ok, msg} = Stop.run([], runtime)
    assert msg =~ "Stopped Orchard services."
    assert msg =~ "Role: node-agent"

    cmds = collect_cmds()
    bootout_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootout" | _], args) end)
    assert [{_, ["bootout", target]}] = bootout_calls
    assert target =~ "node-agent"
  end

  test "node-agent role does not stop postgres when postgres is loaded" do
    parent = self()

    runtime =
      base_runtime(%{
        read_install_role: fn -> {:ok, "node-agent"} end,
        file_regular?: fn path ->
          String.ends_with?(path, "com.orchard.postgres.plist") or
            String.ends_with?(path, "com.orchard.node-agent.plist")
        end,
        cmd: loaded_cmd(parent)
      })
      |> Map.delete(:services)

    assert {:ok, msg} = Stop.run([], runtime)
    assert msg =~ "Stopped Orchard services."

    cmds = collect_cmds()
    bootout_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootout" | _], args) end)
    assert [{_, ["bootout", target]}] = bootout_calls
    assert target =~ "node-agent"
    refute target =~ "postgres"
  end

  test "stops services in reverse order: controller then node-agent" do
    parent = self()
    runtime = base_runtime(%{cmd: loaded_cmd(parent)})

    assert {:ok, msg} = Stop.run([], runtime)
    assert msg =~ "Stopped Orchard services."

    cmds = collect_cmds()
    bootout_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootout" | _], args) end)
    assert length(bootout_calls) == 2

    [{_, ["bootout", ctrl_target]}, {_, ["bootout", na_target]}] = bootout_calls
    assert ctrl_target =~ "controller"
    assert na_target =~ "node-agent"
  end

  test "partial running: only loaded service gets booted out" do
    parent = self()
    ctrl_label = "com.orchard.controller"
    na_label = "com.orchard.node-agent"

    cmd_fn = fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> ^ctrl_label]} -> {"{\n\t\"pid\" : 123;\n}\n", 0}
        {"launchctl", ["print", "system/" <> ^na_label]} -> {"Could not find service\n", 113}
        {"launchctl", ["bootout" | _]} -> {"\n", 0}
        _ -> {"\n", 0}
      end
    end

    runtime = base_runtime(%{cmd: cmd_fn})
    assert {:ok, msg} = Stop.run([], runtime)
    assert msg =~ "some services were already stopped"

    cmds = collect_cmds()
    bootout_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootout" | _], args) end)
    assert length(bootout_calls) == 1
  end

  test "ignores stale managed postgres when stopping" do
    parent = self()
    postgres_label = "com.orchard.postgres"
    ctrl_label = "com.orchard.controller"
    na_label = "com.orchard.node-agent"

    cmd_fn = fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> ^postgres_label]} -> {"{\n\t\"pid\" : 111;\n}\n", 0}
        {"launchctl", ["print", "system/" <> ^ctrl_label]} -> {"{\n\t\"pid\" : 123;\n}\n", 0}
        {"launchctl", ["print", "system/" <> ^na_label]} -> {"{\n\t\"pid\" : 124;\n}\n", 0}
        {"launchctl", ["bootout" | _]} -> {"\n", 0}
        _ -> {"\n", 0}
      end
    end

    runtime =
      base_runtime(%{
        services: nil,
        file_regular?: fn path ->
          String.ends_with?(path, "com.orchard.postgres.plist") or
            String.ends_with?(path, "com.orchard.node-agent.plist") or
            String.ends_with?(path, "com.orchard.controller.plist")
        end,
        cmd: cmd_fn
      })

    assert {:ok, msg} = Stop.run([], runtime)
    assert msg =~ "Stopped Orchard services."

    cmds = collect_cmds()
    bootout_calls = Enum.filter(cmds, fn {_, args} -> match?(["bootout" | _], args) end)

    assert [
             {_, ["bootout", controller_target]},
             {_, ["bootout", node_agent_target]}
           ] = bootout_calls

    assert controller_target =~ "controller"
    assert node_agent_target =~ "node-agent"

    refute Enum.any?(cmds, fn {_prog, args} ->
             args == ["print", "system/com.orchard.postgres"]
           end)
  end

  # ── Bootout Failure ──────────────────────────────────────────────────

  test "bootout failure returns error" do
    parent = self()

    # Service is loaded, bootout fails, recheck still loaded
    cmd_fn = fn prog, args, _opts ->
      send(parent, {:cmd, prog, args})

      case {prog, args} do
        {"launchctl", ["print", "system/" <> _label]} -> {"{\n\t\"pid\" : 123;\n}\n", 0}
        {"launchctl", ["bootout" | _]} -> {"Operation not permitted\n", 1}
        _ -> {"\n", 0}
      end
    end

    runtime = base_runtime(%{cmd: cmd_fn})
    assert {:error, msg, 1} = Stop.run([], runtime)
    assert msg =~ "failed to stop"
    assert msg =~ "launchctl exit 1: Operation not permitted"
  end

  # ── Helper ───────────────────────────────────────────────────────────

  defp collect_cmds do
    collect_cmds([])
  end

  defp collect_cmds(acc) do
    receive do
      {:cmd, prog, args} -> collect_cmds([{prog, args} | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end
