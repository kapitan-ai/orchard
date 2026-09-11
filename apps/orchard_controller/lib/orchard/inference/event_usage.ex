defmodule Orchard.Inference.EventUsage do
  @moduledoc false

  alias Orchard.InferenceEvent

  @spec find([InferenceEvent.t()]) :: InferenceEvent.Usage.t() | nil
  def find(events) when is_list(events) do
    # SPEC 7.5.3a: Worker usage counters are cumulative, so the newest
    # usage-bearing event supersedes every earlier one. A terminal `Completed`
    # then wins with the exact total, while a cancelled or Controller-synthesized
    # terminal leaves the last `UsageUpdate` standing as the lower bound.
    Enum.reduce(events, nil, fn
      %InferenceEvent{event: %{usage: usage}}, _latest_usage when usage != nil -> usage
      _event, latest_usage -> latest_usage
    end)
  end
end
