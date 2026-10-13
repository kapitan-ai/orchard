defmodule Orchard.Node.HostInventoryTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.HostInventoryObservation
  alias Orchard.Node.{HostInventory, LinuxHostInventory}

  defmodule Provider do
    def observe(opts) do
      if owner = opts[:owner], do: send(owner, {:provider_observed, self()})

      %HostInventoryObservation{
        schema_version: Keyword.fetch!(opts, :schema_version),
        observed_at_unix_ms: System.system_time(:millisecond),
        authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY
      }
    end
  end

  defmodule FailingProvider do
    def observe(_opts), do: raise("fixture failure")
  end

  defmodule BlockingProvider do
    def observe(opts) do
      owner = Keyword.fetch!(opts, :owner)
      send(owner, {:provider_blocked, self()})

      receive do
        :release ->
          %HostInventoryObservation{
            schema_version: 9,
            observed_at_unix_ms: System.system_time(:millisecond),
            authority: :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY
          }
      end
    end
  end

  defmodule CommandProvider do
    def observe(opts) do
      owner = Keyword.fetch!(opts, :owner)
      pid_path = Keyword.fetch!(opts, :pid_path)
      timeout_ms = Keyword.fetch!(opts, :timeout_ms)
      send(owner, {:command_provider_started, self()})
      script = ~s(echo $$ > "$1"; exec sleep 30)
      LinuxHostInventory.run_command("sh", ["-c", script, "sh", pid_path], timeout_ms)
    end
  end

  test "retains and refreshes typed observation-only snapshots" do
    pid =
      start_supervised!(
        {HostInventory,
         name: nil,
         provider: Provider,
         provider_opts: [schema_version: 7, owner: self()],
         refresh_ms: 60_000}
      )

    assert_receive {:provider_observed, _provider_pid}
    assert %HostInventoryObservation{schema_version: 7} = await_observation(pid)
    assert %HostInventoryObservation{schema_version: 7} = HostInventory.refresh(pid)
  end

  test "provider failure becomes typed error evidence and does not crash the owner" do
    pid =
      start_supervised!({HostInventory, name: nil, provider: FailingProvider, refresh_ms: 60_000})

    assert Process.alive?(pid)
    observation = await_observation(pid)
    assert observation.authority == :HOST_INVENTORY_AUTHORITY_OBSERVATION_ONLY
    assert observation.cpu.evidence.state == :HOST_EVIDENCE_STATE_ERROR
    assert observation.cpu.evidence.error_code == "provider_failed"
  end

  test "blocked collection never delays startup or cached status reads" do
    started_at = System.monotonic_time(:millisecond)

    pid =
      start_supervised!(
        {HostInventory,
         name: nil,
         provider: BlockingProvider,
         provider_opts: [owner: self()],
         refresh_ms: 60_000,
         collection_timeout_ms: 5_000}
      )

    assert System.monotonic_time(:millisecond) - started_at < 500
    assert_receive {:provider_blocked, provider_pid}

    read_at = System.monotonic_time(:millisecond)
    assert HostInventory.current(pid) == nil
    assert System.monotonic_time(:millisecond) - read_at < 100

    send(provider_pid, :release)
    assert %HostInventoryObservation{schema_version: 9} = await_observation(pid)
  end

  test "timed out collection is terminated and retained as bounded error evidence" do
    pid =
      start_supervised!(
        {HostInventory,
         name: nil,
         provider: BlockingProvider,
         provider_opts: [owner: self()],
         refresh_ms: 60_000,
         collection_timeout_ms: 20}
      )

    assert_receive {:provider_blocked, provider_pid}
    observation = await_observation(pid)
    refute Process.alive?(provider_pid)
    assert observation.cpu.evidence.error_code == "provider_timeout"
    assert observation.cpu.evidence.state == :HOST_EVIDENCE_STATE_ERROR
  end

  test "collector terminates when its inventory owner is killed" do
    child_spec =
      Supervisor.child_spec(
        {HostInventory,
         name: nil,
         provider: BlockingProvider,
         provider_opts: [owner: self()],
         refresh_ms: 60_000,
         collection_timeout_ms: 5_000},
        restart: :temporary
      )

    owner_pid = start_supervised!(child_spec)
    assert_receive {:provider_blocked, provider_pid}
    owner_ref = Process.monitor(owner_pid)
    provider_ref = Process.monitor(provider_pid)

    Process.exit(owner_pid, :kill)

    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}
    assert_receive {:DOWN, ^provider_ref, :process, ^provider_pid, :killed}
  end

  test "owner death leaves the OS probe under its independent command deadline" do
    pid_path = temp_pid_path()
    on_exit(fn -> File.rm(pid_path) end)

    child_spec =
      Supervisor.child_spec(
        {HostInventory,
         name: nil,
         provider: CommandProvider,
         provider_opts: [owner: self(), pid_path: pid_path, timeout_ms: 1_000],
         refresh_ms: 60_000,
         collection_timeout_ms: 5_000},
        restart: :temporary
      )

    owner_pid = start_supervised!(child_spec)
    assert_receive {:command_provider_started, _provider_pid}
    os_pid = await_os_pid(pid_path)

    Process.exit(owner_pid, :kill)

    assert await_process_exit(os_pid)
  end

  test "collection deadline leaves the OS probe under its shorter command deadline" do
    pid_path = temp_pid_path()
    on_exit(fn -> File.rm(pid_path) end)

    pid =
      start_supervised!(
        {HostInventory,
         name: nil,
         provider: CommandProvider,
         provider_opts: [owner: self(), pid_path: pid_path, timeout_ms: 1_000],
         refresh_ms: 60_000,
         collection_timeout_ms: 250}
      )

    assert_receive {:command_provider_started, _provider_pid}
    os_pid = await_os_pid(pid_path)
    observation = await_observation(pid)

    assert observation.cpu.evidence.error_code == "provider_timeout"
    assert await_process_exit(os_pid)
  end

  defp await_observation(pid, attempts \\ 100)

  defp await_observation(_pid, 0), do: flunk("inventory observation was not published")

  defp await_observation(pid, attempts) do
    case HostInventory.current(pid) do
      nil ->
        Process.sleep(5)
        await_observation(pid, attempts - 1)

      observation ->
        observation
    end
  end

  defp temp_pid_path do
    Path.join(System.tmp_dir!(), "orchard-kap80-owner-#{System.unique_integer([:positive])}")
  end

  defp await_os_pid(path, attempts \\ 200)

  defp await_os_pid(_path, 0), do: flunk("probe did not publish its operating-system PID")

  defp await_os_pid(path, attempts) do
    case File.read(path) do
      {:ok, value} ->
        String.trim(value)

      {:error, :enoent} ->
        Process.sleep(5)
        await_os_pid(path, attempts - 1)
    end
  end

  defp await_process_exit(os_pid, attempts \\ 500)

  defp await_process_exit(_os_pid, 0), do: false

  defp await_process_exit(os_pid, attempts) do
    if File.exists?("/proc/#{os_pid}") do
      Process.sleep(5)
      await_process_exit(os_pid, attempts - 1)
    else
      true
    end
  end
end
