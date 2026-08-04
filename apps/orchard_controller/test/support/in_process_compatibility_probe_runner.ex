defmodule Orchard.TestSupport.InProcessCompatibilityProbeRunner do
  @moduledoc false

  @behaviour Orchard.Scheduler.MultiNode.CompatibilityProbeRunner

  @impl true
  def run(targets, probe, _opts) do
    Enum.map(targets, fn target -> {:ok, probe.(target)} end)
  end
end
