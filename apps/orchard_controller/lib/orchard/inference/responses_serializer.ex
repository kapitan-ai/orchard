defmodule Orchard.Inference.ResponsesSerializer do
  @moduledoc """
  Builds bounded non-stream `/v1/responses` payloads and replay persistence attrs.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.InferenceEvent

  @spec response_payload(CanonicalRequest.t(), [InferenceEvent.t()], integer() | nil) :: map()
  def response_payload(%CanonicalRequest{} = canonical, events, created_at_override \\ nil)
      when is_list(events) do
    output_text = collect_output_text(events)

    %{
      id: canonical.public_id,
      object: "response",
      created_at: created_at(events, created_at_override),
      status: "completed",
      model: format_model_display(canonical),
      output: [
        %{
          type: "message",
          role: "assistant",
          content: [
            %{
              type: "output_text",
              text: output_text,
              annotations: []
            }
          ]
        }
      ],
      output_text: output_text,
      usage: usage_map(find_usage(events)),
      error: nil,
      metadata: canonical.metadata
    }
  end

  @spec success_persistence_attrs(CanonicalRequest.t(), [InferenceEvent.t()], integer() | nil) ::
          map()
  def success_persistence_attrs(
        %CanonicalRequest{} = canonical,
        events,
        created_at_override \\ nil
      )
      when is_list(events) do
    output_text = collect_output_text(events)

    %{
      response_payload: response_payload(canonical, events, created_at_override),
      response_preview: output_text
    }
  end

  @spec usage_map(InferenceEvent.Usage.t() | nil) :: map()
  def usage_map(nil), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  def usage_map(%InferenceEvent.Usage{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens
    }
  end

  defp collect_output_text(events) do
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
end
