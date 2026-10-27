defmodule Orchard.Node.WorkerRecoveryCustodyTest do
  @moduledoc """
  SPEC §12.2.2 prior-epoch ownership resolution.

  A checkpoint written in a previous Node Agent lifetime is the only custody
  evidence that survives ModelManager or Node Agent state loss, so the recorded
  runtime incarnation must still be provable without a host reboot.
  """

  use ExUnit.Case, async: false

  alias Orchard.Node.CustodyTestHelpers
  alias Orchard.Node.RuntimeProcessReaper
  alias Orchard.Node.WorkerProcessLifecycle
  alias Orchard.Node.WorkerRecoveryCustody

  @key {"custody/test", "v1"}
  @short_timeout_ms 200

  setup do
    assert {:ok, _apps} = Application.ensure_all_started(:orchard_node_agent)
    :ok
  end

  test "SPEC §12.2.2 recorded runtime custody resolves prior ownership after that process exits" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    owner = retained_custody_owner!(os_pid, "prior-runtime-incarnation")
    custody = WorkerRecoveryCustody.record_runtime_custody(nil, owner)

    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, custody) == :unresolved

    # The orphan an operator kills through host controls, with no reaper lease and
    # no host boot change, must still resolve from the recorded checkpoint alone.
    CustodyTestHelpers.stop_child(port, os_pid)

    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, custody) == :resolved
  end

  # SPEC.md §12.2.2: a reused PID alone is not proof, but a live PID whose launch
  # identity differs from the recorded one belongs to another process, so the
  # recorded incarnation is gone and prior ownership resolves without a reboot.
  test "SPEC §12.2.2 a PID reused by another process resolves prior ownership" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    owner = retained_custody_owner!(os_pid, "reused-pid")
    custody = WorkerRecoveryCustody.record_runtime_custody(nil, owner)

    # This BEAM started before the recorded runtime, so its PID stands in for the
    # recorded PID after the OS hands it to an unrelated, still-running process.
    reused_pid = System.pid()
    [boot, process] = String.split(custody, "/")
    [recorded_pid, digest] = String.split(process, ".")
    assert recorded_pid == Integer.to_string(os_pid)

    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(
             @key,
             "#{boot}/#{reused_pid}.#{digest}"
           ) == :resolved

    # Without a recorded identity a live PID cannot be told apart, so custody
    # written before identities were recorded stays fail-closed.
    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, "#{boot}/#{reused_pid}") ==
             :unresolved

    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, custody) == :unresolved
  end

  test "SPEC §12.2.2 a recorded launch identity survives a write that cannot confirm it" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()
    root = Path.join(System.tmp_dir!(), "custody-#{System.unique_integer([:positive])}")
    fake_bin = Path.join(root, "fake-bin")
    File.mkdir_p!(fake_bin)
    File.write!(Path.join(fake_bin, "ps"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(fake_bin, "ps"), 0o755)
    previous_path = System.fetch_env!("PATH")

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      CustodyTestHelpers.stop_child(port, os_pid)
      File.rm_rf!(root)
    end)

    owner = retained_custody_owner!(os_pid, "unconfirmed-identity")
    recorded = WorkerRecoveryCustody.record_runtime_custody(nil, owner)
    assert recorded =~ ~r/\/#{os_pid}\.[0-9a-f]{32}\z/

    System.put_env("PATH", fake_bin <> ":" <> previous_path)
    assert WorkerRecoveryCustody.record_runtime_custody(nil, owner) =~ ~r/\/#{os_pid}\z/
    assert WorkerRecoveryCustody.record_runtime_custody(recorded, owner) == recorded
  end

  # SPEC.md §12.2.2 compares launch identities across Node Agent lifetimes, so the
  # snapshot must not follow the reader's timezone or locale.
  test "SPEC §12.2.2 a launch identity does not depend on the reader's TZ or locale" do
    os_pid = String.to_integer(System.pid())
    previous = for name <- ~w(TZ LC_ALL LANG), into: %{}, do: {name, System.get_env(name)}

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env(%{"TZ" => "UTC0", "LC_ALL" => "C", "LANG" => "C"})
    assert {:ok, process} = WorkerProcessLifecycle.process_identity(os_pid)
    assert {:ok, launch} = WorkerProcessLifecycle.launch_identity(os_pid)

    System.put_env(%{"TZ" => "JST-9", "LC_ALL" => "de_DE.UTF-8", "LANG" => "de_DE.UTF-8"})
    assert {:ok, ^process} = WorkerProcessLifecycle.process_identity(os_pid)
    assert {:ok, ^launch} = WorkerProcessLifecycle.launch_identity(os_pid)
  end

  test "SPEC §12.2.2 proven exit is recorded so a later epoch resolves without re-probing" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()
    owner = retained_custody_owner!(os_pid, "proven-exit")

    CustodyTestHelpers.stop_child(port, os_pid)
    assert WorkerRecoveryCustody.resolve_current(owner) == :resolved

    custody = WorkerRecoveryCustody.record_runtime_custody(nil, owner)
    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, custody) == :resolved
  end

  test "SPEC §12.2.2 a recorded runtime incarnation is never downgraded to boot evidence" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()

    on_exit(fn -> CustodyTestHelpers.stop_child(port, os_pid) end)

    owner = retained_custody_owner!(os_pid, "no-downgrade")
    recorded = WorkerRecoveryCustody.record_runtime_custody(nil, owner)

    refute recorded == WorkerRecoveryCustody.boot_identity()

    for unknown_owner <- [nil, self()] do
      assert WorkerRecoveryCustody.record_runtime_custody(recorded, unknown_owner) == recorded
    end

    CustodyTestHelpers.stop_child(port, os_pid)
    proven = WorkerRecoveryCustody.record_runtime_custody(recorded, owner)

    assert WorkerRecoveryCustody.record_runtime_custody(proven, nil) == proven
    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, proven) == :resolved
  end

  test "SPEC §12.2.2 custody without a recorded runtime incarnation stays unresolved" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(owner, :kill) end)

    assert WorkerRecoveryCustody.record_runtime_custody(nil, owner) ==
             WorkerRecoveryCustody.boot_identity()

    for custody <- [nil, "not-a-boot-identity", WorkerRecoveryCustody.boot_identity()] do
      assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, custody) == :unresolved
    end
  end

  defp retained_custody_owner!(os_pid, model_ref) do
    {:ok, os_identity} = WorkerProcessLifecycle.process_identity(os_pid)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    assert {:ok, ref} =
             RuntimeProcessReaper.watch(owner, os_pid, %{
               shutdown_timeout_ms: @short_timeout_ms,
               model_ref: model_ref,
               os_identity: os_identity,
               phase: :loaded
             })

    RuntimeProcessReaper.release(ref)

    assert CustodyTestHelpers.wait_until(
             fn -> RuntimeProcessReaper.owner_custody(owner) != :unknown end,
             1_000
           )

    owner
  end

  # SPEC.md §12.2: the host boot id cannot change during this OS process, and
  # resolve_prior_worker_ownership/2 consults it on every 1 Hz cleanup re-probe,
  # so it must be resolved once rather than forked per tick.
  test "SPEC §12.2 host boot identity is resolved once per OS process" do
    :persistent_term.erase({WorkerRecoveryCustody, :boot_identity})

    first = WorkerRecoveryCustody.boot_identity()

    assert is_binary(first)
    assert :persistent_term.get({WorkerRecoveryCustody, :boot_identity}) == first
    assert WorkerRecoveryCustody.boot_identity() == first
  end
end
