defmodule OrchardCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  # A no-op halt function for tests that just need to suppress halt
  defp no_halt(_code), do: :ok

  # A halt stub that sends the exit code to the test process
  defp halt_stub(parent) do
    fn code -> send(parent, {:halt_called, code}) end
  end

  test "prints usage when invoked without arguments" do
    output = capture_io(fn -> OrchardCLI.main([], &no_halt/1) end)

    assert output =~ "orchardctl (M0 scaffold)"
    assert output =~ "cluster, nodes, models, requests, support, upgrade"
  end

  test "dispatches each placeholder command module" do
    placeholder_commands = ["cluster", "nodes", "requests", "support", "upgrade"]

    for command <- placeholder_commands do
      output = capture_io(fn -> OrchardCLI.main([command], &no_halt/1) end)
      assert output =~ "not implemented yet"
    end
  end

  test "placeholder commands do not trigger halt" do
    parent = self()

    for command <- ["cluster", "nodes", "requests", "support", "upgrade"] do
      capture_io(fn -> OrchardCLI.main([command], halt_stub(parent)) end)
      refute_received {:halt_called, _}
    end
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

  test "models import without path exits non-zero" do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        OrchardCLI.main(["models", "import"], halt_stub(parent))
      end)

    assert stderr =~ "missing bundle path"
    assert_received {:halt_called, 1}
  end

  test "Models.run/1 returns error tuple for missing subcommand" do
    assert {:error, message, 1} = OrchardCLI.Commands.Models.run([])
    assert message =~ "orchardctl models"
  end

  test "Models.run/1 returns error tuple for missing import path" do
    assert {:error, message, 1} = OrchardCLI.Commands.Models.run(["import"])
    assert message =~ "missing bundle path"
  end

  test "no-arg usage does not trigger halt" do
    parent = self()
    capture_io(fn -> OrchardCLI.main([], halt_stub(parent)) end)
    refute_received {:halt_called, _}
  end

  test "Models.run/1 returns ok tuple for import with too many args" do
    assert {:error, message, 1} = OrchardCLI.Commands.Models.run(["import", "a", "b"])
    assert message =~ "expected exactly one bundle path"
  end

  test "cli application supervisor is running" do
    assert is_pid(Process.whereis(OrchardCLI.Supervisor))
  end
end
