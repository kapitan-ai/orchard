defmodule Orchard.Governance.PortalPasswordVerifierTest do
  use ExUnit.Case, async: false

  alias Orchard.Governance.PortalPasswordVerifier

  setup do
    previous = Application.get_env(:orchard_controller, :portal, [])

    Application.put_env(:orchard_controller, :portal,
      verifier_workers: 1,
      verifier_queue: 0,
      verifier_timeout_ms: 5_000
    )

    on_exit(fn ->
      Application.put_env(:orchard_controller, :portal, previous)
    end)

    pid = start_supervised!(PortalPasswordVerifier)
    %{pid: pid}
  end

  test "queue overflow returns throttled without running the job" do
    parent = self()

    task =
      Task.async(fn ->
        PortalPasswordVerifier.run(fn ->
          send(parent, {:started, self()})

          receive do
            :release -> :ran
          end
        end)
      end)

    assert_receive {:started, worker}, 1_000

    assert PortalPasswordVerifier.run(fn -> send(parent, :should_not_run) end) ==
             {:error, :throttled}

    refute_receive :should_not_run, 50

    send(worker, :release)
    assert Task.await(task) == :ran
  end
end
