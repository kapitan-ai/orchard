defmodule OrchardCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias OrchardCLI.Commands.{ApiKeys, Models, Nodes, Tenants}

  # A no-op halt function for tests that just need to suppress halt
  defp no_halt(_code), do: :ok

  # A halt stub that sends the exit code to the test process
  defp halt_stub(parent) do
    fn code -> send(parent, {:halt_called, code}) end
  end

  test "prints usage when invoked without arguments" do
    output = capture_io(fn -> OrchardCLI.main([], &no_halt/1) end)

    assert output =~ "orchardctl (M0 scaffold)"

    assert output =~
             "status, start, stop, cluster, env, license, nodes, models, requests, support, tenants, api-keys, tls, upgrade"
  end

  test "dispatches each placeholder command module" do
    placeholder_commands = ["cluster", "requests", "support", "upgrade"]

    for command <- placeholder_commands do
      output = capture_io(fn -> OrchardCLI.main([command], &no_halt/1) end)
      assert output =~ "not implemented yet"
    end
  end

  test "placeholder commands do not trigger halt" do
    parent = self()

    for command <- ["cluster", "requests", "support", "upgrade"] do
      capture_io(fn -> OrchardCLI.main([command], halt_stub(parent)) end)
      refute_received {:halt_called, _}
    end
  end

  test "env command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["env"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl env"
    assert_received {:halt_called, 1}
  end

  test "nodes command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["nodes"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl nodes"
    assert_received {:halt_called, 1}
  end

  test "Nodes.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = Nodes.run([])
    assert message =~ "orchardctl nodes"
  end

  test "models command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["models"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl models"
    assert_received {:halt_called, 1}
  end

  test "tenants command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["tenants"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl tenants"
    assert_received {:halt_called, 1}
  end

  test "api-keys command without subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["api-keys"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl api-keys"
    assert_received {:halt_called, 1}
  end

  test "models import without path exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["models", "import"], halt_stub(parent))
      end)

    assert stderr =~ "missing bundle path"
    assert_received {:halt_called, 1}
  end

  test "Tenants.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = Tenants.run([])
    assert message =~ "orchardctl tenants"
  end

  test "ApiKeys.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = ApiKeys.run([])
    assert message =~ "orchardctl api-keys"
  end

  test "Models.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = Models.run([])
    assert message =~ "orchardctl models"
    assert message =~ "<import|list|delete>"
  end

  test "Models.run/1 returns error tuple for missing import path" do
    assert {:error, message, 1} = Models.run(["import"])
    assert message =~ "missing bundle path"
  end

  test "no-arg usage does not trigger halt" do
    parent = self()
    capture_io(fn -> OrchardCLI.main([], halt_stub(parent)) end)
    refute_received {:halt_called, _}
  end

  test "Models.run/1 returns ok tuple for import with too many args" do
    assert {:error, message, 1} = Models.run(["import", "a", "b"])
    assert message =~ "expected exactly one bundle path"
  end

  test "status --help dispatches through main without network activity" do
    output = capture_io(fn -> OrchardCLI.main(["status", "--help"], &no_halt/1) end)
    assert output =~ "orchardctl status"
    assert output =~ "health endpoint"
  end

  test "license help dispatches through main without network activity" do
    output = capture_io(fn -> OrchardCLI.main(["license", "help"], &no_halt/1) end)
    assert output =~ "orchardctl license"
    assert output =~ "activate <key>"
  end

  test "license with missing subcommand exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["license"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl license"
    assert_received {:halt_called, 1}
  end

  test "status with extra args exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["status", "extra"], halt_stub(parent))
      end)

    assert stderr =~ "orchardctl status"
    assert_received {:halt_called, 1}
  end

  test "start --help dispatches through main without side effects" do
    output = capture_io(fn -> OrchardCLI.main(["start", "--help"], &no_halt/1) end)
    assert output =~ "orchardctl start"
    assert output =~ "launchd"
  end

  test "stop --help dispatches through main without side effects" do
    output = capture_io(fn -> OrchardCLI.main(["stop", "--help"], &no_halt/1) end)
    assert output =~ "orchardctl stop"
    assert output =~ "launchd"
  end

  test "cli application supervisor is running" do
    assert is_pid(Process.whereis(OrchardCLI.Supervisor))
  end
end
