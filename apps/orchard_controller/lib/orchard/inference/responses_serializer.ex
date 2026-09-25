defmodule Orchard.Inference.ResponsesSerializer do
  @moduledoc """
  Builds bounded `/v1/responses` payloads for sync and streaming modes.

  Sync helpers (`response_payload/3`, `success_persistence_attrs/3`) remain
  unchanged. Streaming helpers build typed SSE event payloads aligned with
  the OpenAI Responses streaming contract.
  """

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.EventUsage
  alias Orchard.Inference.ToolCallAccumulator
  alias Orchard.InferenceEvent

  @spec response_payload(CanonicalRequest.t(), [InferenceEvent.t()], integer() | nil) :: map()
  def response_payload(%CanonicalRequest{} = canonical, events, created_at_override \\ nil)
      when is_list(events) do
    output_text = collect_output_text(events)
    function_call_items = response_function_call_items(events, :completed)

    %{
      id: canonical.public_id,
      object: "response",
      created_at: created_at(events, created_at_override),
      status: "completed",
      model: format_model_display(canonical),
      output: output_items(canonical.public_id, output_text, function_call_items, "completed"),
      output_text: output_text,
      usage: usage_map(EventUsage.find(events)),
      error: nil,
      metadata: canonical.metadata
    }
  end

  @spec success_persistence_attrs(CanonicalRequest.t(), [InferenceEvent.t()], integer() | nil) ::
          map() | {:error, :invalid_tool_call}
  def success_persistence_attrs(
        %CanonicalRequest{} = canonical,
        events,
        created_at_override \\ nil
      )
      when is_list(events) do
    output_text = collect_output_text(events)

    {response_preview, response_preview_source} =
      persistence_preview(output_text, tool_call_preview(events))

    payload = response_payload(canonical, events, created_at_override)
    calls = Enum.filter(payload.output, &(&1.type == "function_call"))

    if valid_function_calls?(calls, canonical) do
      %{
        response_payload: payload,
        response_preview: response_preview,
        response_preview_source: response_preview_source
      }
    else
      {:error, :invalid_tool_call}
    end
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

  # -- Streaming event builders -----------------------------------------------

  @doc """
  Builds the `response.created` event payload emitted immediately after SSE start.
  """
  @spec created_event(CanonicalRequest.t(), integer()) :: map()
  def created_event(%CanonicalRequest{} = canonical, created_at) do
    %{
      type: "response.created",
      sequence_number: 0,
      response: base_response(canonical, "in_progress", "", nil, nil, created_at, [])
    }
  end

  @doc """
  Builds a `response.output_text.delta` event payload for a single text delta.
  """
  @spec output_text_delta_event(String.t(), String.t()) :: map()
  def output_text_delta_event(public_id, delta) do
    %{
      type: "response.output_text.delta",
      response_id: public_id,
      item_id: "msg_" <> public_id,
      logprobs: [],
      output_index: 0,
      content_index: 0,
      delta: delta
    }
  end

  @doc """
  Builds the `response.output_text.done` event payload emitted exactly once
  before the terminal event.
  """
  @spec output_text_done_event(String.t(), String.t()) :: map()
  def output_text_done_event(public_id, text) do
    %{
      type: "response.output_text.done",
      response_id: public_id,
      item_id: "msg_" <> public_id,
      logprobs: [],
      output_index: 0,
      content_index: 0,
      text: text
    }
  end

  @doc "Checks completed calls before publishing executable Responses output."
  @spec valid_function_calls?([map()], CanonicalRequest.t()) :: boolean()
  def valid_function_calls?(items, canonical) do
    names = Enum.map(canonical.tooling.tools, &get_in(&1, ["function", "name"]))
    choice = canonical.tooling.tool_choice

    Enum.all?(items, fn item ->
      is_binary(item.id) and item.id != "" and is_binary(item.name) and
        item.name in names and valid_call_arguments?(item.arguments) and
        choice_allows_call?(choice, item.name)
    end) and (not (choice == "required" or is_map(choice)) or items != [])
  end

  defp valid_call_arguments?(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, value} when is_map(value) -> true
      _ -> false
    end
  end

  defp valid_call_arguments?(_arguments), do: false
  defp choice_allows_call?("none", _name), do: false
  defp choice_allows_call?(%{"function" => %{"name" => selected}}, name), do: selected == name
  defp choice_allows_call?(_choice, _name), do: true

  @doc "Builds the buffered lifecycle for validated function calls."
  @spec function_call_events([map()], non_neg_integer()) :: [map()]
  def function_call_events(items, output_offset) do
    items
    |> Enum.with_index(output_offset)
    |> Enum.flat_map(fn {item, index} ->
      correlation = %{item_id: item.id, output_index: index}

      [
        %{
          type: "response.output_item.added",
          output_index: index,
          item: %{item | arguments: "", status: "in_progress"}
        },
        Map.merge(correlation, %{
          type: "response.function_call_arguments.delta",
          delta: item.arguments
        }),
        Map.merge(correlation, %{
          type: "response.function_call_arguments.done",
          arguments: item.arguments
        }),
        %{type: "response.output_item.done", output_index: index, item: item}
      ]
    end)
  end

  @doc "Builds the message item envelope correlated with text deltas and terminal output."
  @spec message_event(String.t(), String.t(), :added | :done) :: map()
  def message_event(public_id, text, phase) do
    status = if phase == :added, do: "in_progress", else: "completed"
    item = message_item(public_id, text, status)
    item = if phase == :added, do: %{item | content: [], status: status}, else: item
    %{type: "response.output_item.#{phase}", output_index: 0, item: item}
  end

  @doc """
  Builds the `response.completed` terminal event payload.
  """
  @spec completed_event(
          CanonicalRequest.t(),
          String.t(),
          InferenceEvent.Usage.t() | nil,
          integer(),
          [map()]
        ) ::
          map()
  def completed_event(
        %CanonicalRequest{} = canonical,
        output_text,
        usage,
        created_at,
        function_call_items \\ []
      ) do
    %{
      type: "response.completed",
      response:
        base_response(
          canonical,
          "completed",
          output_text,
          usage,
          nil,
          created_at,
          function_call_items
        )
    }
  end

  @doc """
  Builds the `response.failed` terminal event payload.
  """
  @spec failed_event(
          CanonicalRequest.t(),
          String.t(),
          InferenceEvent.Usage.t() | nil,
          map(),
          integer(),
          [map()],
          String.t()
        ) :: map()
  def failed_event(
        %CanonicalRequest{} = canonical,
        output_text,
        usage,
        error_map,
        created_at,
        function_call_items \\ [],
        status \\ "failed"
      ) do
    %{
      type: "response.failed",
      response:
        base_response(
          canonical,
          status,
          output_text,
          usage,
          error_map,
          created_at,
          function_call_items
        )
    }
  end

  defp base_response(
         canonical,
         status,
         output_text,
         usage,
         error,
         created_at,
         function_call_items
       ) do
    %{
      id: canonical.public_id,
      object: "response",
      created_at: created_at,
      status: status,
      model: format_model_display(canonical),
      output: output_items(canonical.public_id, output_text, function_call_items, status),
      output_text: output_text,
      usage: usage_map(usage),
      error: error,
      metadata: canonical.metadata
    }
  end

  # -- Private helpers --------------------------------------------------------

  defp collect_output_text(events) do
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

  defp output_items(public_id, output_text, function_call_items, status) do
    text_items =
      if output_text != "" do
        [message_item(public_id, output_text, status)]
      else
        []
      end

    text_items ++ function_call_items
  end

  defp message_item(public_id, text, status) do
    %{
      id: "msg_" <> public_id,
      type: "message",
      role: "assistant",
      status: if(status == "completed", do: "completed", else: "incomplete"),
      content: [%{type: "output_text", text: text, annotations: []}]
    }
  end

  defp response_function_call_items(events, status) do
    events
    |> tool_call_accumulator!()
    |> ToolCallAccumulator.responses_output_items(status)
  end

  defp tool_call_preview(events) do
    events
    |> tool_call_accumulator!()
    |> ToolCallAccumulator.preview()
  end

  defp persistence_preview("", tool_preview) when tool_preview != "",
    do: {tool_preview, :tool_call}

  defp persistence_preview(content, _tool_preview), do: {content, :assistant_text}

  defp tool_call_accumulator!(events) do
    case ToolCallAccumulator.from_events(events) do
      {:ok, accumulator} -> accumulator
      {:error, reason} -> raise ArgumentError, "invalid tool call events: #{inspect(reason)}"
    end
  end
end
