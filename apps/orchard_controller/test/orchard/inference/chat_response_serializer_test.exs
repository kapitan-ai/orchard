defmodule Orchard.Inference.ChatResponseSerializerTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.ChatResponseSerializer
  alias Orchard.InferenceEvent

  test "completion_payload/2 matches chat completion shape and uses accepted timestamp" do
    canonical =
      CanonicalRequest.new(%{
        internal_id: Ecto.UUID.generate(),
        public_id: "chatcmpl_test",
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        model_ref: %{model_id: "test-model", version: "v1"},
        input_items: [%{"role" => "user", "content" => "hello"}],
        rendered_prompt: "hello",
        input_token_count: 3,
        stream?: false
      })

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

  test "success_persistence_attrs/2 returns response payload and preview" do
    canonical =
      CanonicalRequest.new(%{
        internal_id: Ecto.UUID.generate(),
        public_id: "chatcmpl_persist",
        endpoint: :chat_completions,
        tenant_id: Ecto.UUID.generate(),
        model_ref: %{model_id: "test-model", version: "v1"},
        input_items: [%{"role" => "user", "content" => "hello"}],
        rendered_prompt: "hello",
        input_token_count: 1,
        stream?: false
      })

    events = [
      InferenceEvent.accepted(42_000),
      InferenceEvent.output_text_delta("Hello"),
      InferenceEvent.completed(:finish_reason_stop, nil)
    ]

    attrs = ChatResponseSerializer.success_persistence_attrs(canonical, events)

    assert attrs.response_preview == "Hello"

    assert attrs.response_payload.choices == [
             %{
               index: 0,
               message: %{role: "assistant", content: "Hello"},
               finish_reason: "stop"
             }
           ]
  end

  test "usage_map/1 zero-fills nil usage" do
    assert ChatResponseSerializer.usage_map(nil) == %{
             prompt_tokens: 0,
             completion_tokens: 0,
             total_tokens: 0
           }
  end
end
