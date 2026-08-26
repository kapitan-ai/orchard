defmodule OrchardCLI.LifecycleNativeTest do
  use ExUnit.Case, async: false

  @moduletag :macos

  alias OrchardCLI.LifecycleNative
  alias OrchardCLI.TestTemp

  test "SPEC 11.4 uses nonblocking crash-released flock without inheritance" do
    with_temp("lifecycle-lock", fn directory ->
      lock_path = Path.join(directory, ".app-lifecycle.lock")
      parent = self()

      holder =
        spawn(fn ->
          LifecycleNative.with_lock(lock_path, fn lock ->
            send(parent, {:locked, self(), lock, LifecycleNative.lock_valid(lock)})
            Process.sleep(:infinity)
          end)
        end)

      assert_receive {:locked, ^holder, lock, :ok}, 1_000
      assert is_map(lock.guard_identity)
      assert is_integer(lock.lock_device)
      assert is_integer(lock.lock_inode)
      assert {:error, :locked} = LifecycleNative.with_lock(lock_path, fn _lock -> :unexpected end)

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      assert :reacquired = LifecycleNative.with_lock(lock_path, fn _lock -> :reacquired end)
      assert File.stat!(lock_path).mode |> Bitwise.band(0o777) == 0o600
    end)
  end

  test "child commands do not inherit the lifecycle lock descriptor" do
    with_temp("lifecycle-cloexec", fn directory ->
      lock_path = Path.join(directory, ".app-lifecycle.lock")

      child =
        LifecycleNative.with_lock(lock_path, fn _lock ->
          Port.open({:spawn_executable, "/bin/sleep"}, [:exit_status, args: ["2"]])
        end)

      assert Port.info(child) != nil
      assert :reacquired = LifecycleNative.with_lock(lock_path, fn _lock -> :reacquired end)
      Port.close(child)
    end)
  end

  test "canonical flock interoperates with Orchard.app's Swift lock family" do
    with_temp("lifecycle-swift-flock", fn directory ->
      lock_path = Path.join(directory, ".app-lifecycle.lock")
      holder = compile_swift_holder(directory)

      swift_port = open_swift_holder(holder, lock_path)
      assert_receive {^swift_port, {:data, {:eol, "READY"}}}, 1_000
      assert {:error, :locked} = LifecycleNative.with_lock(lock_path, fn _lock -> :unexpected end)
      Port.command(swift_port, "RELEASE\n")
      assert_receive {^swift_port, {:exit_status, 0}}, 1_000

      assert :ok =
               LifecycleNative.with_lock(lock_path, fn _lock ->
                 contender = open_swift_holder(holder, lock_path)
                 assert_receive {^contender, {:exit_status, 75}}, 1_000
                 :ok
               end)
    end)
  end

  test "orphan census rejects spoofed release environment outside the trusted release root" do
    executable = System.find_executable("elixir")

    port =
      Port.open(
        {:spawn_executable, executable},
        [
          :binary,
          :exit_status,
          args: ["-e", "Process.sleep(:infinity)"],
          env: [
            {~c"RELEASE_NAME", ~c"orchard_node_agent"},
            {~c"RELEASE_ROOT",
             ~c"/Library/Application Support/Orchard/releases/orchard_node_agent"}
          ]
        ]
      )

    {:os_pid, child_pid} = Port.info(port, :os_pid)

    try do
      assert {:ok, identities} = LifecycleNative.process_snapshot()
      refute Enum.any?(identities, &(&1["pid"] == child_pid))
      refute Enum.any?(identities, &(&1["pid"] == String.to_integer(System.pid())))
    after
      System.cmd("/bin/kill", ["-KILL", Integer.to_string(child_pid)])
      if Port.info(port) != nil, do: Port.close(port)
    end
  end

  test "launchd PID census and exact-identity signal cover an unmarked Node Agent process" do
    with_temp("lifecycle-signal", fn directory ->
      source =
        :orchard_cli
        |> :code.priv_dir()
        |> List.to_string()
        |> Path.join("orchard-lifecycle-helper")

      executable = Path.join(directory, "beam.smp")
      File.cp!(source, executable)
      File.chmod!(executable, 0o700)

      port =
        Port.open(
          {:spawn_executable, executable},
          [
            :binary,
            :exit_status,
            :use_stdio,
            args: ["lock", Path.join(directory, "process.lock")]
          ]
        )

      {:os_pid, child_pid} = Port.info(port, :os_pid)

      try do
        assert {:ok, identities} = await_expected_snapshot(child_pid, 50)
        assert [identity] = Enum.filter(identities, &(&1["pid"] == child_pid))

        assert :ok =
                 LifecycleNative.with_lock(
                   Path.join(directory, ".app-lifecycle.lock"),
                   &LifecycleNative.signal_process(&1, identity)
                 )

        assert :exited = await_identity_exit(identity, 100)
      after
        if Port.info(port) != nil, do: Port.close(port)
      end
    end)
  end

  defp await_identity_exit(_identity, 0), do: :timeout

  defp await_identity_exit(identity, attempts) do
    case LifecycleNative.process_identity_state(identity) do
      :alive ->
        Process.sleep(50)
        await_identity_exit(identity, attempts - 1)

      state ->
        state
    end
  end

  defp await_expected_snapshot(_pid, 0), do: {:error, :timeout}

  defp await_expected_snapshot(pid, attempts) do
    case LifecycleNative.process_snapshot(pid) do
      {:ok, identities} = result ->
        if Enum.any?(identities, &(&1["pid"] == pid)) do
          result
        else
          Process.sleep(20)
          await_expected_snapshot(pid, attempts - 1)
        end

      {:error, _reason} ->
        Process.sleep(20)
        await_expected_snapshot(pid, attempts - 1)
    end
  end

  test "lock release handshake failure is returned instead of callback success" do
    with_temp("lifecycle-release-failure", fn directory ->
      lock_path = Path.join(directory, ".app-lifecycle.lock")

      assert {:error, reason} =
               LifecycleNative.with_lock(lock_path, fn lock ->
                 assert Port.command(lock.port, "INVALID\n")
                 Process.sleep(20)
                 :callback_success
               end)

      assert reason in [:lock_release_lost, {:lock_release_failed, 74}]
      assert :ok = LifecycleNative.with_lock(lock_path, fn _lock -> :ok end)
    end)
  end

  test "command custody terminates a child at the bounded deadline" do
    started = System.monotonic_time(:millisecond)
    {_output, code} = LifecycleNative.run_command("/bin/sleep", ["10"], 20)

    assert code == 124
    assert System.monotonic_time(:millisecond) - started < 1_000
  end

  defp compile_swift_holder(directory) do
    source = Path.expand("../support/flock_holder.swift", __DIR__)
    binary = Path.join(directory, "flock-holder")

    assert {_output, 0} =
             System.cmd("xcrun", ["swiftc", source, "-o", binary], stderr_to_stdout: true)

    binary
  end

  defp open_swift_holder(binary, lock_path) do
    Port.open(
      {:spawn_executable, binary},
      [:binary, :exit_status, :use_stdio, {:line, 1024}, args: [lock_path]]
    )
  end

  defp with_temp(prefix, callback) do
    owner = TestTemp.create_run!(prefix: prefix)

    try do
      callback.(TestTemp.root(owner))
    after
      TestTemp.cleanup!(owner)
    end
  end
end
