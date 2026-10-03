defmodule Orchard.Node.HostInventory.CommandTest do
  # SPEC.md §4.1 and §4.9: inventory probes run only allowlisted absolute
  # executables under a verified GNU guardian, with a cleared environment and
  # bounded output. Anything else yields absent or error evidence.
  use ExUnit.Case, async: true

  alias Orchard.Node.HostInventory.Command
  alias Orchard.TestSupport.GnuTimeoutGuardian

  @moduletag :tmp_dir

  test "only absolute regular executable files resolve", %{tmp_dir: dir} do
    tool = script!(dir, "tool", "echo ok")
    plain = Path.join(dir, "plain")
    File.write!(plain, "data")

    assert Command.resolve(["relative-tool", tool]) == {:ok, tool}
    assert Command.resolve(["sh"]) == {:error, :missing_tool}
    assert Command.resolve([Path.join(dir, "absent"), dir, plain]) == {:error, :missing_tool}
  end

  test "the guardian must identify as GNU coreutils timeout", %{tmp_dir: dir} do
    gnu = script!(dir, "gnu-timeout", "echo 'timeout (GNU coreutils) 9.4'")
    uutils = script!(dir, "uutils-timeout", "echo 'timeout (uutils coreutils) 0.2.2'")

    assert Command.guardian([gnu]) == {:ok, gnu}
    assert Command.guardian([uutils]) == {:error, :guardian_unavailable}
    assert Command.guardian([Path.join(dir, "absent")]) == {:error, :guardian_unavailable}
  end

  test "a guardian that disappears after verification makes the probe unavailable", %{
    tmp_dir: dir
  } do
    tool = script!(dir, "tool", "echo ok")

    assert Command.run(Path.join(dir, "vanished-timeout"), tool, []) ==
             {:error, :guardian_unavailable}
  end

  test "an executable file that cannot be started is not a guardian", %{tmp_dir: dir} do
    corrupt = Path.join(dir, "corrupt")
    File.write!(corrupt, <<0x7F, "ELF", 0, 1, 2, 3>>)
    File.chmod!(corrupt, 0o755)

    assert Command.guardian([corrupt]) == {:error, :guardian_unavailable}
  end

  test "guarded probe setup fails actionably without a verified GNU guardian", %{tmp_dir: dir} do
    uutils = script!(dir, "uutils-timeout", "echo 'timeout (uutils coreutils) 0.2.2'")

    for candidate <- [nil, uutils, Path.join(dir, "absent")] do
      error =
        assert_raise ExUnit.AssertionError, fn ->
          GnuTimeoutGuardian.verified!(candidate)
        end

      assert error.message =~ "GNU coreutils `timeout` is required"
      assert error.message =~ "/usr/bin/timeout"
      assert error.message =~ "brew install coreutils"
      assert error.message =~ "bin/gtimeout"
      assert error.message =~ "opt/coreutils/libexec/gnubin/timeout"
    end
  end

  describe "guardian discovery" do
    # Homebrew coreutils always installs g-prefixed tools plus a gnubin
    # directory; the unprefixed `timeout` alias is optional.
    # https://github.com/kapitan-ai/orchard/pull/466#discussion_r4153089052

    test "a Homebrew install with only the g-prefixed gtimeout is discovered", %{tmp_dir: dir} do
      for prefix <- ["opt/homebrew", "usr/local"] do
        root = Path.join(dir, String.replace(prefix, "/", "-"))
        gtimeout = gnu_timeout!(root, Path.join(prefix, "bin/gtimeout"))

        assert GnuTimeoutGuardian.discover(root) == gtimeout
      end
    end

    test "a coreutils gnubin timeout symlinked to the Cellar gtimeout is discovered", %{
      tmp_dir: dir
    } do
      for prefix <- ["opt/homebrew", "usr/local"] do
        root = Path.join(dir, String.replace(prefix, "/", "-"))
        cellar = gnu_timeout!(root, Path.join(prefix, "Cellar/coreutils/9.12/bin/gtimeout"))
        gnubin = Path.join([root, prefix, "opt/coreutils/libexec/gnubin/timeout"])
        File.mkdir_p!(Path.dirname(gnubin))
        File.ln_s!(cellar, gnubin)

        assert GnuTimeoutGuardian.discover(root) == gnubin
      end
    end

    test "a non-GNU earlier candidate is skipped for a later GNU candidate", %{tmp_dir: dir} do
      uutils = Path.join(dir, "usr/bin/timeout")
      File.mkdir_p!(Path.dirname(uutils))
      script!(Path.dirname(uutils), "timeout", "echo 'timeout (uutils coreutils) 0.2.2'")
      gtimeout = gnu_timeout!(dir, "opt/homebrew/bin/gtimeout")

      assert GnuTimeoutGuardian.discover(dir) == gtimeout
    end

    # Each candidate gets the bounded guardian check, so an earlier candidate
    # that cannot run or never answers `--version` cannot stall discovery.
    @tag timeout: 15_000
    test "unusable earlier candidates are skipped for a later GNU candidate", %{tmp_dir: dir} do
      not_executable = Path.join(dir, "usr/bin/timeout")
      File.mkdir_p!(Path.dirname(not_executable))
      File.write!(not_executable, "#!/bin/sh\necho 'timeout (GNU coreutils) 9.12'\n")

      corrupt = Path.join(dir, "opt/homebrew/bin/timeout")
      File.mkdir_p!(Path.dirname(corrupt))
      File.write!(corrupt, <<0x7F, "ELF", 0, 1, 2, 3>>)
      File.chmod!(corrupt, 0o755)

      silent = Path.join(dir, "usr/local/bin/timeout")
      File.mkdir_p!(Path.dirname(silent))
      script!(Path.dirname(silent), "timeout", "exec /bin/cat >/dev/null")

      gtimeout = gnu_timeout!(dir, "opt/homebrew/bin/gtimeout")

      assert GnuTimeoutGuardian.discover(dir) == gtimeout
    end

    test "no candidate is discovered when no GNU timeout is installed", %{tmp_dir: dir} do
      assert GnuTimeoutGuardian.discover(dir) == nil
    end
  end

  describe "guarded probes" do
    @describetag :gnu_timeout

    setup do
      guardian =
        :orchard_node_agent
        |> Application.fetch_env!(:test_gnu_timeout)
        |> GnuTimeoutGuardian.verified!()

      %{guardian: guardian}
    end

    test "a TERM-ignoring hung probe and its child end at the guardian deadline", %{
      tmp_dir: dir,
      guardian: guardian
    } do
      {tool, pid_file} = hung_probe!(dir)

      assert {:error, :command_timeout} =
               Command.run(guardian, tool, [], timeout_ms: 1_500, kill_after_ms: 300)

      assert probe_pids_gone?(pid_file)
    end

    test "a dead caller leaves the probe to end at its own guardian deadline", %{
      tmp_dir: dir,
      guardian: guardian
    } do
      {tool, pid_file} = hung_probe!(dir)

      caller =
        spawn(fn -> Command.run(guardian, tool, [], timeout_ms: 1_500, kill_after_ms: 300) end)

      assert wait_until(fn -> File.exists?(pid_file) end)
      Process.exit(caller, :kill)

      assert probe_pids_gone?(pid_file, 150)
    end

    test "output beyond the byte limit is output_too_large and the probe ends by its deadline", %{
      tmp_dir: dir,
      guardian: guardian
    } do
      pid_file = Path.join(dir, "flood.pids")

      tool =
        script!(dir, "flood", "echo $$ > #{pid_file}\nwhile :; do echo 0123456789abcdef; done")

      assert {:error, :output_too_large} =
               Command.run(guardian, tool, [],
                 max_output_bytes: 1_024,
                 timeout_ms: 1_000,
                 kill_after_ms: 300
               )

      assert probe_pids_gone?(pid_file, 150)
    end

    test "a failing probe is command_failed without its output", %{
      tmp_dir: dir,
      guardian: guardian
    } do
      tool = script!(dir, "fail", "echo secret-diagnostic\nexit 3")

      assert Command.run(guardian, tool, []) == {:error, :command_failed}
    end

    test "a probe sees only the C locale and a fixed PATH", %{tmp_dir: dir, guardian: guardian} do
      sentinel = "ORCHARD_INVENTORY_TEST_SENTINEL_#{System.unique_integer([:positive])}"
      System.put_env(sentinel, "must-not-leak")
      on_exit(fn -> System.delete_env(sentinel) end)
      tool = script!(dir, "print-env", "exec /usr/bin/env")

      assert {:ok, output} = Command.run(guardian, tool, [])

      lines = String.split(output, "\n", trim: true)
      assert "LC_ALL=C" in lines
      assert "PATH=/usr/bin:/bin" in lines
      refute output =~ sentinel
    end
  end

  # The probe records its own pid and its sleeping child's pid, ignores TERM,
  # and never exits on its own.
  defp hung_probe!(dir) do
    pid_file = Path.join(dir, "probe.pids")

    tool =
      script!(dir, "hung", """
      trap '' TERM
      /bin/sleep 30 &
      echo "$$ $!" > #{pid_file}
      wait
      while :; do /bin/sleep 1; done
      """)

    {tool, pid_file}
  end

  defp probe_pids_gone?(pid_file, attempts \\ 50) do
    pids = pid_file |> File.read!() |> String.split()

    cond do
      Enum.all?(pids, &(not os_process_alive?(&1))) -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && probe_pids_gone?(pid_file, attempts - 1)
    end
  end

  defp wait_until(fun, attempts \\ 150) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && wait_until(fun, attempts - 1)
    end
  end

  defp os_process_alive?(pid) do
    match?({_output, 0}, System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true))
  end

  defp gnu_timeout!(root, relative_path) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    script!(Path.dirname(path), Path.basename(path), "echo 'timeout (GNU coreutils) 9.12'")
  end

  defp script!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end
end
