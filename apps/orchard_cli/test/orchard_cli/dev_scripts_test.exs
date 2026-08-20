defmodule OrchardCLI.DevScriptsTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../../..", __DIR__)

  test "dev-controller uses controller app shell and avoids node-agent startup path" do
    controller = File.read!(Path.join(@repo_root, "bin/dev-controller"))
    dev = File.read!(Path.join(@repo_root, "bin/dev"))
    node_agent = File.read!(Path.join(@repo_root, "bin/dev-node-agent"))

    assert controller =~ "cd \"$REPO_ROOT/apps/orchard_controller\""

    assert controller =~
             ~s(exec iex ${ORCHARD_BEAM_IEX_ARGS[@]+"${ORCHARD_BEAM_IEX_ARGS[@]}"} -S mix phx.server)

    assert controller =~ "exec iex -S mix phx.server"
    refute controller =~ "apps/orchard_node_agent"
    refute controller =~ "mix run --no-halt"

    assert node_agent =~ "cd \"$REPO_ROOT/apps/orchard_node_agent\""

    assert node_agent =~
             ~s(exec iex ${ORCHARD_BEAM_IEX_ARGS[@]+"${ORCHARD_BEAM_IEX_ARGS[@]}"} -S mix run --no-halt)

    assert node_agent =~ "exec iex -S mix run --no-halt"

    assert dev =~ "exec iex -S mix phx.server"
    refute dev =~ "cd \"$REPO_ROOT/apps/orchard_controller\""
    refute dev =~ "cd \"$REPO_ROOT/apps/orchard_node_agent\""
  end

  test "dev-controller does not kill MLX workers, while dev and dev-node-agent use owned cleanup" do
    controller = File.read!(Path.join(@repo_root, "bin/dev-controller"))
    dev = File.read!(Path.join(@repo_root, "bin/dev"))
    node_agent = File.read!(Path.join(@repo_root, "bin/dev-node-agent"))

    refute controller =~ "pgrep -f orchard-worker-mlx"
    refute controller =~ "xargs kill"

    assert dev =~ "source-dev-worker-cleanup.sh"
    assert node_agent =~ "source-dev-worker-cleanup.sh"

    assert dev =~ "orchard_source_dev_cleanup_workers"
    assert node_agent =~ "orchard_source_dev_cleanup_workers"

    refute dev =~ "orphans=$(pgrep -f orchard-worker-mlx)"
    refute node_agent =~ "orphans=$(pgrep -f orchard-worker-mlx)"
  end

  test "source-dev BEAM bootstrap shell contract stays wired into Mix tests" do
    script = Path.join(@repo_root, "scripts/test-source-dev-beam-bootstrap.sh")

    assert {output, 0} =
             System.cmd("bash", [script],
               cd: @repo_root,
               stderr_to_stdout: true
             )

    assert output =~ "source-dev BEAM bootstrap tests passed"
  end

  test "source-dev worker cleanup kills only owned checkout workers" do
    script = Path.join(@repo_root, "scripts/test-source-dev-worker-cleanup.sh")

    assert {output, 0} =
             System.cmd("bash", [script],
               cd: @repo_root,
               stderr_to_stdout: true
             )

    assert output =~ "source-dev worker cleanup tests passed"
  end
end
