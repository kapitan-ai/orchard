defmodule Orchard.Inference.ChatResponseSerializer do
  @moduledoc """
  Builds non-stream chat completion payloads and replay persistence attrs.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.EventUsage
  alias Orchard.Inference.ToolCallAccumulator
  alias Orchard.InferenceEvent

  @spec completion_payload(CanonicalRequest.t(), [InferenceEvent.t()]) :: map()
  @spec completion_payload(CanonicalRequest.t(), [InferenceEvent.t()], integer() | nil) :: map()
  def completion_payload(%CanonicalRequest{} = canonical, events, created_at_override \\ nil)
      when is_list(events) do
    content = collect_content(events)
    tool_calls = collected_tool_calls(events)

    %{
      id: canonical.public_id,
      object: "chat.completion",
      created: created_at(events, created_at_override),
      model: format_model_display(canonical),
      choices: [
        %{
          index: 0,
          message: message_payload(content, tool_calls),
          finish_reason: finish_reason(events)
        }
      ],
      usage: usage_map(EventUsage.find(events))
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
    content = collect_content(events)

    %{
      response_payload: completion_payload(canonical, events, created_at_override),
      response_preview: preview_content(content, tool_call_preview(events))
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
  defp map_proto_finish_reason(:finish_reason_tool_calls), do: "tool_calls"
  defp map_proto_finish_reason(_other), do: "stop"

  defp message_payload(content, tool_calls) do
    %{role: "assistant", content: content_payload(content, tool_calls)}
    |> maybe_put_tool_calls(tool_calls)
  end

  defp content_payload("", tool_calls) when tool_calls != [], do: nil
  defp content_payload(content, _tool_calls), do: content

  defp maybe_put_tool_calls(message, []), do: message
  defp maybe_put_tool_calls(message, tool_calls), do: Map.put(message, :tool_calls, tool_calls)

  defp preview_content("", tool_preview) when tool_preview != "", do: tool_preview
  defp preview_content(content, _tool_preview), do: content

  defp collected_tool_calls(events) do
    events
    |> tool_call_accumulator!()
    |> ToolCallAccumulator.chat_tool_calls()
  end

  defp tool_call_preview(events) do
    events
    |> tool_call_accumulator!()
    |> ToolCallAccumulator.preview()
  end

  defp tool_call_accumulator!(events) do
    case ToolCallAccumulator.from_events(events) do
      {:ok, accumulator} -> accumulator
      {:error, reason} -> raise ArgumentError, "invalid tool call events: #{inspect(reason)}"
    end
  end
end
