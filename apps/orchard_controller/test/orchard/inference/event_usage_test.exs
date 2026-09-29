defmodule Orchard.Inference.EventUsageTest do
  use ExUnit.Case, async: true

  alias Orchard.Inference.EventUsage
  alias Orchard.InferenceEvent

  test "SPEC.md §§3.7.1, 5.3 (#329): missing evidence is not exact zero" do
    for events <- [[], [InferenceEvent.failed("worker_down", "gone", true)]] do
      assert EventUsage.terminal(events) == %{
               output_tokens: 0,
               output_usage_status: "lower_bound"
             }
    end

    assert EventUsage.terminal([InferenceEvent.completed(:finish_reason_stop, usage(0))]) == %{
             input_tokens: 3,
             output_tokens: 0,
             output_usage_status: "exact"
           }
  end

  test "SPEC.md §§3.7.1, 5.3 (#329): invalid or regressing evidence cannot replace the validated bound" do
    for invalid <- [
          usage(-1),
          usage(2),
          %{usage(8) | input_tokens: 2, total_tokens: 10},
          %{usage(8) | total_tokens: 10},
          usage(2_147_483_648)
        ] do
      events = [
        InferenceEvent.usage_update(usage(5)),
        %InferenceEvent{event: %InferenceEvent.UsageUpdate{usage: invalid}},
        InferenceEvent.failed("worker_down", "gone", true),
        InferenceEvent.usage_update(usage(9))
      ]

      assert EventUsage.terminal(events) == %{
               input_tokens: 3,
               output_tokens: 5,
               output_usage_status: "lower_bound"
             }

      assert EventUsage.find(events) == nil
    end
  end

  defp usage(output),
    do: %InferenceEvent.Usage{input_tokens: 3, output_tokens: output, total_tokens: 3 + output}
end
