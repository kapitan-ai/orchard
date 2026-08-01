defmodule Orchard.TestSupport.TerminalCardinality do
  @moduledoc false

  alias Orchard.InferenceEvent

  @spec classify([InferenceEvent.t()]) :: :zero | :exactly_one | :multiple
  def classify(events) when is_list(events) do
    case Enum.count(events, &InferenceEvent.terminal?/1) do
      0 -> :zero
      1 -> :exactly_one
      _multiple -> :multiple
    end
  end
end
