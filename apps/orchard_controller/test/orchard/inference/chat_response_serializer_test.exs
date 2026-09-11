defmodule Orchard.Inference.ChatResponseSerializerTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.ChatResponseSerializer
  alias Orchard.InferenceEvent
  alias Orchard.Requests.CapturePolicy

  test "completion_payload/2 matches chat completion shape and uses accepted timestamp" do
    canonical = build_canonical("chatcmpl_test")
    usage = %InferenceEvent.Usage{input_tokens: 3, output_tokens: 2, total_tokens: 5}

    events = [
      InferenceEvent.accepted(1_710_000_123_000),
      InferenceEvent.output_text_delta("Hello"),
      InferenceEvent.output_text_delta(" world"),
      InferenceEvent.completed(:finish_reason_length, usage)
    ]

    payload = ChatResponseSerializer.completion_payload(canonical, events)

    assert payload.id == canonical.public_id
    assert payload.object == "chat.completion"
    assert payload.created == 1_710_000_123
    assert payload.model == "test-model@v1"

    assert payload.choices == [
             %{
               index: 0,
               message: %{role: "assistant", content: "Hello world"},
               finish_reason: "length"
             }
           ]

    assert payload.usage == %{prompt_tokens: 3, completion_tokens: 2, total_tokens: 5}
  end

  test "SPEC 7.5.3a keeps exact completed usage after cumulative updates" do
    canonical = build_canonical("chatcmpl_usage_updates")

    events = [
      InferenceEvent.usage_update(%InferenceEvent.Usage{
        input_tokens: 3,
        output_tokens: 1,
        total_tokens: 4
      }),
      InferenceEvent.output_text_delta("Hello"),
      InferenceEvent.usage_update(%InferenceEvent.Usage{
        input_tokens: 3,
        output_tokens: 2,
        total_tokens: 5
      }),
      InferenceEvent.completed(
        :finish_reason_stop,
        %InferenceEvent.Usage{input_tokens: 3, output_tokens: 2, total_tokens: 5}
      )
    ]

    payload = ChatResponseSerializer.completion_payload(canonical, events)

    assert payload.usage == %{prompt_tokens: 3, completion_tokens: 2, total_tokens: 5}
  end

  test "tool-call-only response includes tool_calls, null content, and tool_calls finish_reason" do
    canonical = build_canonical("chatcmpl_tools")

    events = [
      InferenceEvent.accepted(1_710_000_123_000),
      tool_call_event("call_0", %{index: 0, type: "function", function: %{name: "lookup_weather"}}),
      tool_call_event("call_0", %{
        index: 0,
        function: %{arguments_delta: "{\"city\":\"Singapore\"}"}
      }),
      InferenceEvent.completed(:finish_reason_tool_calls, nil)
    ]

    payload = ChatResponseSerializer.completion_payload(canonical, events)

    assert payload.choices == [
             %{
               index: 0,
               message: %{
                 role: "assistant",
                 content: nil,
                 tool_calls: [
                   %{
                     id: "call_0",
                     type: "function",
                     function: %{
                       name: "lookup_weather",
                       arguments: "{\"city\":\"Singapore\"}"
                     }
                   }
                 ]
               },
               finish_reason: "tool_calls"
             }
           ]
  end

  test "mixed text and tool-call response preserves both and preview falls back to tool summary" do
    canonical = build_canonical("chatcmpl_mixed")

    mixed_events = [
      InferenceEvent.accepted(42_000),
      InferenceEvent.output_text_delta("Let me check."),
      tool_call_event("call_0", %{index: 0, type: "function", function: %{name: "lookup_weather"}}),
      tool_call_event("call_0", %{
        index: 0,
        function: %{arguments_delta: "{\"city\":\"Singapore\"}"}
      }),
      InferenceEvent.completed(:finish_reason_tool_calls, nil)
    ]

    payload = ChatResponseSerializer.completion_payload(canonical, mixed_events)

    assert payload.choices == [
             %{
               index: 0,
               message: %{
                 role: "assistant",
                 content: "Let me check.",
                 tool_calls: [
                   %{
                     id: "call_0",
                     type: "function",
                     function: %{
                       name: "lookup_weather",
                       arguments: "{\"city\":\"Singapore\"}"
                     }
                   }
                 ]
               },
               finish_reason: "tool_calls"
             }
           ]

    tool_only_events = [
      InferenceEvent.accepted(42_000),
      tool_call_event("call_0", %{index: 0, type: "function", function: %{name: "lookup_weather"}}),
      tool_call_event("call_0", %{
        index: 0,
        function: %{arguments_delta: "{\"city\":\"Singapore\"}"}
      }),
      InferenceEvent.completed(:finish_reason_tool_calls, nil)
    ]

    attrs = ChatResponseSerializer.success_persistence_attrs(canonical, tool_only_events)

    assert attrs.response_preview ==
             "Tool call: lookup_weather({\"city\":\"Singapore\"})"

    assert attrs.response_preview_source == :tool_call
  end

  test "restricted capture drops tool-call previews while full keeps a bounded preview" do
    canonical = build_canonical("chatcmpl_tool_capture")
    arguments = Jason.encode!(%{"private" => String.duplicate("x", 700)})

    events = [
      InferenceEvent.accepted(42_000),
      tool_call_event("call_0", %{index: 0, type: "function", function: %{name: "private_tool"}}),
      tool_call_event("call_0", %{index: 0, function: %{arguments_delta: arguments}}),
      InferenceEvent.completed(:finish_reason_tool_calls, nil)
    ]

    attrs = ChatResponseSerializer.success_persistence_attrs(canonical, events)

    for mode <- [:none, :metadata] do
      restricted = CapturePolicy.terminal_attrs(mode, attrs)
      assert restricted.response_preview == nil
      refute Map.has_key?(restricted, :response_preview_source)
      refute inspect(restricted) =~ "private_tool"
    end

    full = CapturePolicy.terminal_attrs(:full, attrs)
    assert String.starts_with?(full.response_preview, "Tool call: private_tool(")
    assert String.length(full.response_preview) == 512
    refute Map.has_key?(full, :response_preview_source)
  end

  test "usage_map/1 zero-fills nil usage" do
    assert ChatResponseSerializer.usage_map(nil) == %{
             prompt_tokens: 0,
             completion_tokens: 0,
             total_tokens: 0
           }
  end

  defp build_canonical(public_id) do
    CanonicalRequest.new(%{
      internal_id: Ecto.UUID.generate(),
      public_id: public_id,
      endpoint: :chat_completions,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %{model_id: "test-model", version: "v1"},
      input_items: [%{"role" => "user", "content" => "hello"}],
      rendered_prompt: "hello",
      input_token_count: 3,
      stream?: false
    })
  end

  defp tool_call_event(tool_call_id, delta) do
    InferenceEvent.tool_call_delta(tool_call_id, Jason.encode!(delta))
  end
end
