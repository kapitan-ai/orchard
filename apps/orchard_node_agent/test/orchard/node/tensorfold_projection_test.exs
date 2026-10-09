defmodule Orchard.Node.TensorFoldProjectionTest do
  use ExUnit.Case, async: true

  alias Orchard.Cluster.V1.ExecuteInferenceRequest
  alias Orchard.Node.TensorFoldProjection

  @incarnation "00000000000040008000000000000001"

  setup do
    binding = %{
      "schema_version" => 1,
      "profile_id" => "frozen-qwen",
      "model_id" => "qwen",
      "version" => String.duplicate("a", 64),
      "artifact_sha256" => String.duplicate("b", 64),
      "template_sha256" => String.duplicate("c", 64),
      "tokenizer_config_sha256" => String.duplicate("d", 64),
      "enable_thinking" => true,
      "reasoning_effort" => "medium",
      "output_projection" => "legacy_blended"
    }

    history =
      Map.merge(binding, %{
        "messages" => [%{"role" => "assistant", "content" => "<think>opaque\n</think>"}],
        "tools" => []
      })

    config = Map.merge(binding, %{"max_projection_bytes" => 8_192, "offer_timeout_ms" => 150})
    offer = Map.put(binding, "incarnation", @incarnation)

    request = %ExecuteInferenceRequest{
      request_id: "resp_00000000-0000-4000-8000-000000000002",
      model_id: binding["model_id"],
      version: binding["version"],
      deadline_unix_ms: System.system_time(:millisecond) + 5_000,
      rendered_prompt_utf8: "rendered medium",
      input_tokens: 3,
      prompt_token_ids: [11, 12, 13],
      tensorfold_history_projection_json: Jason.encode!(history)
    }

    %{binding: binding, history: history, config: config, offer: offer, request: request}
  end

  test "SPEC selected experiment binds fresh incarnation and preserves opaque history", ctx do
    assert {:ok, bound} =
             TensorFoldProjection.bind(ctx.request, Jason.encode!(ctx.offer), ctx.config)

    assert Jason.decode!(bound.tensorfold_history_projection_json) ==
             Map.put(ctx.history, "incarnation", @incarnation)

    assert bound.request_id == ctx.request.request_id
    assert bound.deadline_unix_ms == ctx.request.deadline_unix_ms
    # SPEC.md §7.2.9: binding changes only the projection, never the authoritative tokens.
    assert {bound.rendered_prompt_utf8, bound.input_tokens, bound.prompt_token_ids} ==
             {ctx.request.rendered_prompt_utf8, ctx.request.input_tokens,
              ctx.request.prompt_token_ids}

    assert {:ok, 150} = TensorFoldProjection.lookup_timeout(ctx.request, ctx.config)
  end

  test "default off, expired request and absent offer fail closed", ctx do
    assert {:error, :tensorfold_projection_rejected} =
             TensorFoldProjection.bind(ctx.request, Jason.encode!(ctx.offer), nil)

    assert {:error, :tensorfold_projection_rejected} =
             TensorFoldProjection.bind(ctx.request, "", ctx.config)

    expired = %{ctx.request | deadline_unix_ms: System.system_time(:millisecond) - 1}

    assert {:error, :tensorfold_projection_rejected} =
             TensorFoldProjection.bind(expired, Jason.encode!(ctx.offer), ctx.config)
  end

  test "Worker uuid4 hex incarnation is accepted verbatim and other encodings reject", ctx do
    assert byte_size(@incarnation) == 32

    assert {:ok, bound} =
             TensorFoldProjection.bind(ctx.request, Jason.encode!(ctx.offer), ctx.config)

    assert Jason.decode!(bound.tensorfold_history_projection_json)["incarnation"] == @incarnation

    for incarnation <- [
          nil,
          "",
          String.duplicate("a", 31),
          String.duplicate("a", 33),
          String.duplicate("A", 32),
          "00000000-0000-4000-8000-000000000001"
        ] do
      offer = Map.put(ctx.offer, "incarnation", incarnation)

      assert {:error, :tensorfold_projection_rejected} =
               TensorFoldProjection.bind(ctx.request, Jason.encode!(offer), ctx.config)
    end
  end

  test "canonical Chat and Responses shapes reach the authoritative native normalizer intact",
       ctx do
    messages = [
      %{"role" => "developer", "content" => [%{"type" => "text", "text" => "Use the tool."}]},
      %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Question"}]},
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "call_1",
            "type" => "function",
            "function" => %{"name" => "lookup", "arguments" => "{\"value\":1}"}
          }
        ]
      },
      %{"role" => "tool", "content" => "result", "tool_call_id" => "call_1"}
    ]

    history = Map.put(ctx.history, "messages", messages)
    request = %{ctx.request | tensorfold_history_projection_json: Jason.encode!(history)}
    assert {:ok, bound} = TensorFoldProjection.bind(request, Jason.encode!(ctx.offer), ctx.config)
    assert Jason.decode!(bound.tensorfold_history_projection_json)["messages"] == messages
  end

  test "every immutable binding and caller supplied incarnation are rejected", ctx do
    Enum.each(Map.keys(ctx.binding), fn key ->
      offer = Map.put(ctx.offer, key, "wrong")

      assert {:error, :tensorfold_projection_rejected} =
               TensorFoldProjection.bind(ctx.request, Jason.encode!(offer), ctx.config)
    end)

    request = %{
      ctx.request
      | tensorfold_history_projection_json:
          Jason.encode!(Map.put(ctx.history, "incarnation", @incarnation))
    }

    assert {:error, :tensorfold_projection_rejected} =
             TensorFoldProjection.bind(request, Jason.encode!(ctx.offer), ctx.config)
  end

  test "oversized, duplicate-key, structured reasoning and malformed histories reject", ctx do
    for payload <- [
          String.duplicate(" ", 8_193),
          "{\"schema_version\":1," <>
            String.trim_leading(ctx.request.tensorfold_history_projection_json, "{")
        ] do
      request = %{ctx.request | tensorfold_history_projection_json: payload}

      assert {:error, :tensorfold_projection_rejected} =
               TensorFoldProjection.bind(request, Jason.encode!(ctx.offer), ctx.config)
    end

    assert {:error, :tensorfold_projection_rejected} =
             TensorFoldProjection.bind(ctx.request, String.duplicate(" ", 4_097), ctx.config)

    for messages <- [
          [],
          [%{"role" => "assistant", "content" => "opaque", "reasoning" => "hidden"}],
          [%{"role" => "user", "content" => nil}]
        ] do
      request = %{
        ctx.request
        | tensorfold_history_projection_json:
            Jason.encode!(Map.put(ctx.history, "messages", messages))
      }

      assert {:error, :tensorfold_projection_rejected} =
               TensorFoldProjection.bind(request, Jason.encode!(ctx.offer), ctx.config)
    end
  end

  test "lookup remains within remaining absolute deadline", ctx do
    request = %{ctx.request | deadline_unix_ms: System.system_time(:millisecond) + 50}
    assert {:ok, timeout} = TensorFoldProjection.lookup_timeout(request, ctx.config)
    assert timeout in 1..50
  end
end
