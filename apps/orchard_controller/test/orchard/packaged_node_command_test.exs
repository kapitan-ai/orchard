defmodule Orchard.PackagedNodeCommandTest do
  use ExUnit.Case, async: true

  alias Orchard.PackagedNodeCommand

  test "SPEC 11.9 keeps help outside the packaged Repo runner" do
    runner = fn _fun, _opts -> flunk("help must not invoke the Repo runner") end

    assert {:ok, usage} = PackagedNodeCommand.run(["admit", "--help"], runner)
    assert usage =~ "orchardctl nodes admit"
  end

  test "SPEC 11.9 invokes the packaged Repo runner once with output mode" do
    parent = self()

    runner = fn _fun, opts ->
      send(parent, {:runner, opts})
      {:ok, ~s({"object":"cluster_management.node_status_list"})}
    end

    assert {:ok, output} = PackagedNodeCommand.run(["list", "--json"], runner)
    assert_receive {:runner, [json: true]}
    refute_receive {:runner, _opts}
    assert Jason.decode!(output)["object"] == "cluster_management.node_status_list"
  end

  test "packaged compatibility handler does not execute host-local namespaces" do
    runner = fn _fun, _opts -> flunk("denied commands must not invoke the Repo runner") end

    for args <- [["enrollment", "create"], ["trust", "init"]] do
      assert {:error, usage, 1} = PackagedNodeCommand.run(args, runner)
      assert usage =~ "Usage: orchardctl nodes <command>"
    end
  end
end
