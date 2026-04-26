defmodule OrchardCLI.DevScriptsTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  test "dev-controller uses controller app shell and avoids node-agent startup path" do
    controller = File.read!(Path.join(@repo_root, "bin/dev-controller"))
    dev = File.read!(Path.join(@repo_root, "bin/dev"))
    node_agent = File.read!(Path.join(@repo_root, "bin/dev-node-agent"))

    assert controller =~ "cd \"$REPO_ROOT/apps/orchard_controller\""
    assert controller =~ "exec iex -S mix phx.server"
    refute controller =~ "apps/orchard_node_agent"
    refute controller =~ "mix run --no-halt"

    assert node_agent =~ "cd \"$REPO_ROOT/apps/orchard_node_agent\""
    assert node_agent =~ "exec iex -S mix run --no-halt"

    assert dev =~ "exec iex -S mix phx.server"
    refute dev =~ "cd \"$REPO_ROOT/apps/orchard_controller\""
    refute dev =~ "cd \"$REPO_ROOT/apps/orchard_node_agent\""
  end

  test "dev-controller does not kill MLX workers, while dev and dev-node-agent do" do
    controller = File.read!(Path.join(@repo_root, "bin/dev-controller"))
    dev = File.read!(Path.join(@repo_root, "bin/dev"))
    node_agent = File.read!(Path.join(@repo_root, "bin/dev-node-agent"))

    refute controller =~ "pgrep -f orchard-worker-mlx"
    refute controller =~ "xargs kill"

    assert dev =~ "pgrep -f orchard-worker-mlx"
    assert node_agent =~ "pgrep -f orchard-worker-mlx"
  end
end
