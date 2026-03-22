defmodule Orchard.Inference.ResponsesSerializerTest do
  use ExUnit.Case, async: true

  alias Orchard.CanonicalRequest
  alias Orchard.Inference.ResponsesSerializer
  alias Orchard.InferenceEvent

  test "response_payload/3 builds the bounded response object" do
    canonical =
      CanonicalRequest.new(%{
        internal_id: Ecto.UUID.generate(),
        public_id: "resp_test",
        endpoint: :responses,
        tenant_id: Ecto.UUID.generate(),
        model_ref: %{model_id: "test-model", version: "v1"},
        input_items: [%{"role" => "user", "content" => "hello"}],
        rendered_prompt: "hello",
        input_token_count: 3,
        stream?: false,
        metadata: %{"trace" => "abc"}
      })

    usage = %InferenceEvent.Usage{input_tokens: 3, output_tokens: 2, total_tokens: 5}

    events = [
      InferenceEvent.accepted(1_710_000_123_000),
      InferenceEvent.output_text_delta("Hello"),
      InferenceEvent.output_text_delta(" world"),
      InferenceEvent.completed(:finish_reason_stop, usage)
    ]

    payload = ResponsesSerializer.response_payload(canonical, events)

    assert payload.id == "resp_test"
    assert payload.object == "response"
    assert payload.created_at == 1_710_000_123
    assert payload.status == "completed"
    assert payload.model == "test-model@v1"
    assert payload.output_text == "Hello world"
    assert payload.error == nil
    assert payload.metadata == %{"trace" => "abc"}

    assert payload.output == [
             %{
               type: "message",
               role: "assistant",
               content: [%{type: "output_text", text: "Hello world", annotations: []}]
             }
           ]

    assert payload.usage == %{input_tokens: 3, output_tokens: 2, total_tokens: 5}
  end

  test "success_persistence_attrs/3 returns replay payload and preview" do
    canonical =
      CanonicalRequest.new(%{
        internal_id: Ecto.UUID.generate(),
        public_id: "resp_persist",
        endpoint: :responses,
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

    attrs = ResponsesSerializer.success_persistence_attrs(canonical, events)

    assert attrs.response_preview == "Hello"
    assert attrs.response_payload.output_text == "Hello"
    assert attrs.response_payload.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
  end
end
