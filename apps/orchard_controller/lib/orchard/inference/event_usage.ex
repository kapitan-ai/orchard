defmodule Orchard.Inference.EventUsage do
  @moduledoc false

  alias Orchard.InferenceEvent

  @spec find([InferenceEvent.t()]) :: InferenceEvent.Usage.t() | nil
  def find(events) when is_list(events) do
    usage_event = Enum.find(events, &(InferenceEvent.kind(&1) == :usage))
    completed_event = Enum.find(events, &(InferenceEvent.kind(&1) == :completed))

    cond do
      usage_event != nil -> usage_event.event.usage
      completed_event != nil && completed_event.event.usage != nil -> completed_event.event.usage
      true -> nil
    end
  end
end
