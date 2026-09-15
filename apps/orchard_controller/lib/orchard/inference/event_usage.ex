defmodule Orchard.Inference.EventUsage do
  @moduledoc false

  alias Orchard.InferenceEvent

  @spec find([InferenceEvent.t()]) :: InferenceEvent.Usage.t() | nil
  def find(events) when is_list(events) do
    Enum.find_value(events, fn
      %InferenceEvent{event: %InferenceEvent.Completed{usage: usage}} -> usage
      _event -> nil
    end)
  end
end
