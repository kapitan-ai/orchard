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

  @spec terminal([InferenceEvent.t()]) :: map()
  def terminal(events) do
    Enum.reduce_while(
      events,
      %{output_tokens: 0, output_usage_status: "lower_bound"},
      fn
        %InferenceEvent{event: %InferenceEvent.Completed{usage: usage}}, acc ->
          {:halt, accumulate(usage, acc, "exact")}

        %InferenceEvent{event: %InferenceEvent.Failed{}}, acc ->
          {:halt, acc}

        %InferenceEvent{event: %InferenceEvent.UsageUpdate{usage: usage}}, acc ->
          {:cont, accumulate(usage, acc, "lower_bound")}

        _event, acc ->
          {:cont, acc}
      end
    )
  end

  defp accumulate(
         %InferenceEvent.Usage{input_tokens: input, output_tokens: output, total_tokens: total},
         acc,
         status
       )
       when is_integer(input) and input >= 0 and input <= 2_147_483_647 and
              is_integer(output) and output >= 0 and output <= 2_147_483_647 and
              total == input + output and output >= acc.output_tokens do
    if input >= Map.get(acc, :input_tokens, 0) do
      %{input_tokens: input, output_tokens: output, output_usage_status: status}
    else
      acc
    end
  end

  defp accumulate(_usage, acc, _status), do: acc
end
