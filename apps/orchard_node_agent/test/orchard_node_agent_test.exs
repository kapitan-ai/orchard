defmodule OrchardNodeAgentTest do
  use ExUnit.Case, async: true

  test "node agent version is exposed" do
    assert Orchard.NodeAgent.version() == "0.1.0"
  end

  test "node supervisor is already part of the started application tree" do
    pid = Process.whereis(Orchard.Node.Supervisor)

    assert is_pid(pid)
    assert {:error, {:already_started, ^pid}} = Orchard.Node.Supervisor.start_link([])
  end

  test "node supervisor init returns a one_for_one strategy" do
    assert {:ok, {%{strategy: :one_for_one}, []}} = Orchard.Node.Supervisor.init([])
  end

  test "node agent application supervisor is running" do
    assert is_pid(Process.whereis(Orchard.NodeAgent.Supervisor))
  end
end
