defmodule OrchardCLI.LifecycleSystemTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.LifecycleSystem

  test "parses one exact launchd PID and rejects duplicate PID state" do
    assert 4242 = LifecycleSystem.job_pid("state = running\n\tpid = 4242\n")
    assert :missing = LifecycleSystem.job_pid("state = waiting\n")
    assert :ambiguous = LifecycleSystem.job_pid("pid = 4242\npid = 4343\n")
  end
end
