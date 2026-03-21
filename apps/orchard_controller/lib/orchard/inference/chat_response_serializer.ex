defmodule Orchard.Inference.ChatResponseSerializer do
  @moduledoc """
  Builds non-stream chat completion payloads and replay persistence attrs.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.InferenceEvent

  @spec completion_payload(CanonicalRequest.t(), [InferenceEvent.t()]) :: map()
  @spec completion_payload(CanonicalRequest.t(), [InferenceEvent.t()], integer() | nil) :: map()
  def completion_payload(%CanonicalRequest{} = canonical, events, created_at_override \\ nil)
      when is_list(events) do
    %{
      id: canonical.public_id,
      object: "chat.completion",
      created: created_at(events, created_at_override),
      model: format_model_display(canonical),
      choices: [
        %{
          index: 0,
          message: %{role: "assistant", content: collect_content(events)},
          finish_reason: finish_reason(events)
        }
      ],
      usage: usage_map(find_usage(events))
    }
  end

  @spec success_persistence_attrs(CanonicalRequest.t(), [InferenceEvent.t()]) :: map()
  @spec success_persistence_attrs(CanonicalRequest.t(), [InferenceEvent.t()], integer() | nil) ::
          map()
  def success_persistence_attrs(
        %CanonicalRequest{} = canonical,
        events,
        created_at_override \\ nil
      )
      when is_list(events) do
    %{
      response_payload: completion_payload(canonical, events, created_at_override),
      response_preview: collect_content(events)
    }
  end

  @spec usage_map(InferenceEvent.Usage.t() | nil) :: map()
  def usage_map(nil), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  def usage_map(%InferenceEvent.Usage{} = usage) do
    %{
      prompt_tokens: usage.input_tokens,
      completion_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens
    }
  end

  @spec finish_reason_from_event(InferenceEvent.t()) :: String.t()
  def finish_reason_from_event(event) do
    case InferenceEvent.kind(event) do
      :completed -> map_proto_finish_reason(event.event.finish_reason)
      :failed -> "error"
      _other -> "stop"
    end
  end

  defp finish_reason(events) do
    case Enum.find(events, &InferenceEvent.terminal?/1) do
      nil -> "stop"
      event -> finish_reason_from_event(event)
    end
  end

  defp collect_content(events) do
    events
    |> Enum.filter(&(InferenceEvent.kind(&1) == :output_text_delta))
    |> Enum.map_join("", & &1.event.delta)
  end

  defp find_usage(events) do
    usage_event = Enum.find(events, &(InferenceEvent.kind(&1) == :usage))
    completed_event = Enum.find(events, &(InferenceEvent.kind(&1) == :completed))

    cond do
      usage_event != nil -> usage_event.event.usage
      completed_event != nil && completed_event.event.usage != nil -> completed_event.event.usage
      true -> nil
    end
  end

  defp created_at(_events, created_at_override) when is_integer(created_at_override),
    do: created_at_override

  defp created_at(events, _created_at_override) do
    case Enum.find(events, &(InferenceEvent.kind(&1) == :accepted)) do
      %InferenceEvent{event: %InferenceEvent.Accepted{accepted_at_unix_ms: accepted_at_unix_ms}} ->
        div(accepted_at_unix_ms, 1_000)

      _other ->
        System.system_time(:second)
    end
  end

  defp format_model_display(canonical) do
    "#{canonical.model_ref.model_id}@#{canonical.model_ref.version}"
  end

  defp map_proto_finish_reason(:finish_reason_stop), do: "stop"
  defp map_proto_finish_reason(:finish_reason_length), do: "length"
  defp map_proto_finish_reason(_other), do: "stop"
end
