defmodule OrchardCLI.LifecycleSystemTest do
  use ExUnit.Case, async: true

  alias OrchardCLI.LifecycleSystem

  @label "com.orchard.node-agent"

  test "parses actual launchctl print-disabled system booleans exactly" do
    assert :disabled =
             LifecycleSystem.disabled_state(
               ~s(disabled services = {\n\t"#{@label}" => true\n}\n),
               @label
             )

    assert :enabled =
             LifecycleSystem.disabled_state(
               ~s(disabled services = {\n\t"#{@label}" => false\n}\n),
               @label
             )

    assert :missing = LifecycleSystem.disabled_state(~s("other" => true\n), @label)
  end

  test "duplicate or malformed disablement evidence fails closed" do
    output = ~s("#{@label}" => true\n"#{@label}" => false\n)
    assert :ambiguous = LifecycleSystem.disabled_state(output, @label)
    assert :ambiguous = LifecycleSystem.disabled_state(~s("#{@label}" => disabled\n), @label)
  end

  test "parses one exact launchd PID and rejects duplicate PID state" do
    assert 4242 = LifecycleSystem.job_pid("state = running\n\tpid = 4242\n")
    assert :missing = LifecycleSystem.job_pid("state = waiting\n")
    assert :ambiguous = LifecycleSystem.job_pid("pid = 4242\npid = 4343\n")
  end
end
