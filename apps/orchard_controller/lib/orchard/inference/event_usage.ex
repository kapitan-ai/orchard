defmodule Orchard.Inference.EventUsage do
  @moduledoc false

  alias Orchard.InferenceEvent

  @spec find([InferenceEvent.t()]) :: InferenceEvent.Usage.t() | nil
  def find(events) when is_list(events) do
    Enum.reduce(events, nil, fn
      %InferenceEvent{event: %{usage: usage}}, _latest_usage when usage != nil -> usage
      _event, latest_usage -> latest_usage
    end)
  end
end
