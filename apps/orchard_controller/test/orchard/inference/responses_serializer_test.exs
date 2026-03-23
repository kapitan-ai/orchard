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

  # -- Streaming event builders -----------------------------------------------

  defp build_canonical(overrides \\ %{}) do
    defaults = %{
      internal_id: Ecto.UUID.generate(),
      public_id: "resp_stream",
      endpoint: :responses,
      tenant_id: Ecto.UUID.generate(),
      model_ref: %{model_id: "test-model", version: "v1"},
      input_items: [%{"role" => "user", "content" => "hello"}],
      rendered_prompt: "hello",
      input_token_count: 3,
      stream?: true,
      metadata: %{"trace" => "xyz"}
    }

    CanonicalRequest.new(Map.merge(defaults, overrides))
  end

  test "created_event/2 builds response.created payload" do
    canonical = build_canonical()
    event = ResponsesSerializer.created_event(canonical, 1_710_000_100)

    assert event.type == "response.created"
    assert event.response.id == "resp_stream"
    assert event.response.object == "response"
    assert event.response.created_at == 1_710_000_100
    assert event.response.status == "in_progress"
    assert event.response.model == "test-model@v1"
    assert event.response.output == []
    assert event.response.output_text == ""
    assert event.response.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    assert event.response.error == nil
    assert event.response.metadata == %{"trace" => "xyz"}
  end

  test "output_text_delta_event/2 builds delta payload" do
    event = ResponsesSerializer.output_text_delta_event("resp_stream", "Hello")

    assert event.type == "response.output_text.delta"
    assert event.response_id == "resp_stream"
    assert event.output_index == 0
    assert event.content_index == 0
    assert event.delta == "Hello"
  end

  test "output_text_done_event/2 builds done payload" do
    event = ResponsesSerializer.output_text_done_event("resp_stream", "Hello world")

    assert event.type == "response.output_text.done"
    assert event.response_id == "resp_stream"
    assert event.output_index == 0
    assert event.content_index == 0
    assert event.text == "Hello world"
  end

  test "completed_event/4 builds terminal completed payload with output" do
    canonical = build_canonical()
    usage = %InferenceEvent.Usage{input_tokens: 3, output_tokens: 5, total_tokens: 8}
    event = ResponsesSerializer.completed_event(canonical, "Hello world", usage, 1_710_000_100)

    assert event.type == "response.completed"
    assert event.response.id == "resp_stream"
    assert event.response.status == "completed"
    assert event.response.output_text == "Hello world"
    assert event.response.usage == %{input_tokens: 3, output_tokens: 5, total_tokens: 8}
    assert event.response.error == nil

    assert event.response.output == [
             %{
               type: "message",
               role: "assistant",
               content: [%{type: "output_text", text: "Hello world", annotations: []}]
             }
           ]
  end

  test "completed_event/4 with nil usage returns zero usage" do
    canonical = build_canonical()
    event = ResponsesSerializer.completed_event(canonical, "", nil, 1_710_000_100)

    assert event.response.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    assert event.response.output == []
  end

  test "failed_event/5 builds terminal failed payload with error map and partial output" do
    canonical = build_canonical()

    error_map = %{
      message: "Worker unavailable",
      type: "server_error",
      code: "server_error",
      param: nil
    }

    event = ResponsesSerializer.failed_event(canonical, "partial", nil, error_map, 1_710_000_100)

    assert event.type == "response.failed"
    assert event.response.id == "resp_stream"
    assert event.response.status == "failed"
    assert event.response.output_text == "partial"
    assert event.response.error == error_map
    assert event.response.usage == %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

    assert event.response.output == [
             %{
               type: "message",
               role: "assistant",
               content: [%{type: "output_text", text: "partial", annotations: []}]
             }
           ]
  end

  test "failed_event/5 with empty output text returns empty output array" do
    canonical = build_canonical()
    error_map = %{message: "Timeout", type: "server_error", code: "timeout", param: nil}
    event = ResponsesSerializer.failed_event(canonical, "", nil, error_map, 1_710_000_100)

    assert event.response.output == []
    assert event.response.output_text == ""
  end
end
