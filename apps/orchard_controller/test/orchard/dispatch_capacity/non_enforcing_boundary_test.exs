defmodule Orchard.DispatchCapacity.NonEnforcingBoundaryTest do
  use ExUnit.Case, async: true

  @consumer_modules [
    Orchard.Scheduler.MultiNode,
    Orchard.Scheduler.SingleNode,
    Orchard.Nodes,
    Orchard.Inference.QueueManager,
    Orchard.Dispatch.RequestDispatcher
  ]

  test "foundation tracer keeps all five production consumers off the evaluator" do
    Enum.each(@consumer_modules, fn module ->
      source = module.module_info(:compile) |> Keyword.fetch!(:source) |> File.read!()

      refute source =~ "DispatchCapacity.Evaluator",
             "#{inspect(module)} must not consume the counterfactual evaluator"

      refute source =~ "Evaluator.evaluate",
             "#{inspect(module)} must retain its existing authorization behavior"

      refute source =~ "DispatchCapacity.Diagnostics",
             "#{inspect(module)} must not consume the diagnostics assembler"

      refute source =~ "CapacitySnapshot",
             "#{inspect(module)} must not consume a precomputed diagnostic result"
    end)
  end
end
