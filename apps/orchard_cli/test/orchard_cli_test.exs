defmodule OrchardCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints usage when invoked without arguments" do
    output = capture_io(fn -> OrchardCLI.main([]) end)

    assert output =~ "orchardctl (M0 scaffold)"
    assert output =~ "cluster, nodes, models, requests, support, upgrade"
  end

  test "dispatches each placeholder command module" do
    commands = ["cluster", "nodes", "models", "requests", "support", "upgrade"]

    for command <- commands do
      output = capture_io(fn -> OrchardCLI.main([command]) end)
      assert output =~ "not implemented yet"
    end
  end

  test "cli application supervisor is running" do
    assert is_pid(Process.whereis(OrchardCLI.Supervisor))
  end
end
