defmodule Orchard.Node.SourceStartupNativeTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)

  test "SPEC 4.9 candidate launchers refuse before source bootstrap" do
    {output, status} =
      System.cmd("bash", [Path.join(@repo_root, "scripts/test-source-node-startup.sh")],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  @tag timeout: 60_000
  test "SPEC 4.9 relocated roots retain real Linux kernel ownership across exec and parent death" do
    linux? = :os.type() == {:unix, :linux}
    command = if linux?, do: "timeout", else: "bash"
    script = Path.join(@repo_root, "scripts/test-linux-node-root-guardian.sh")
    arguments = if linux?, do: ["50", script], else: [script]

    {output, status} =
      System.cmd(command, arguments, stderr_to_stdout: true)

    if linux? and status == 77 and System.get_env("GITHUB_ACTIONS") != "true" do
      assert output =~ "SKIP: test root needs local ext/XFS"
    else
      assert_native_result(linux?, status, output)
    end
  end

  defp assert_native_result(linux?, status, output) do
    if linux? do
      assert status == 0, output
      assert output =~ "PASS: Linux relocated-root process fixtures"
    else
      assert status == 77, output
      assert output =~ "PASS: portable host-fact validator and non-Linux refusal checks"
      assert output =~ "SKIP: Linux kernel guardian tests require Linux"
    end
  end
end
