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
    custody = WorkerRecoveryCustody.runtime_custody(owner)

    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, custody) == :unresolved

    # The orphan an operator kills through host controls, with no reaper lease and
    # no host boot change, must still resolve from the recorded checkpoint alone.
    CustodyTestHelpers.stop_child(port, os_pid)

    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, custody) == :resolved
  end

  test "SPEC §12.2.2 proven exit is recorded so a later epoch resolves without re-probing" do
    {port, os_pid} = CustodyTestHelpers.start_control_child!()
    owner = retained_custody_owner!(os_pid, "proven-exit")

    CustodyTestHelpers.stop_child(port, os_pid)
    assert WorkerRecoveryCustody.resolve_current(owner) == :resolved

    custody = WorkerRecoveryCustody.runtime_custody(owner)
    assert WorkerRecoveryCustody.resolve_prior_worker_ownership(@key, custody) == :resolved
  end

  test "SPEC §12.2.2 custody without a recorded runtime incarnation stays unresolved" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(owner, :kill) end)

    assert WorkerRecoveryCustody.runtime_custody(owner) == WorkerRecoveryCustody.boot_identity()

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
end
